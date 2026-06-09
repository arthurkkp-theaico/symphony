defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  test "tool_specs advertises tracker tool input contracts" do
    assert [
             %{
               "description" => linear_description,
               "inputSchema" => %{
                 "properties" => %{
                   "query" => _,
                   "variables" => _
                 },
                 "required" => ["query"],
                 "type" => "object"
               },
               "name" => "linear_graphql"
             }
           ] = DynamicTool.tool_specs("linear")

    assert [
             %{
               "description" => jira_description,
               "inputSchema" => %{
                 "properties" => %{
                   "method" => _,
                   "path" => _,
                   "body" => _
                 },
                 "required" => ["method", "path"],
                 "type" => "object"
               },
               "name" => "jira_rest"
             }
           ] = DynamicTool.tool_specs("jira")

    assert linear_description =~ "Linear"
    assert jira_description =~ "Jira"
    assert DynamicTool.tool_specs("memory") == []
    assert DynamicTool.tool_specs(nil) == []
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["linear_graphql"]
             }
           }

    assert response["contentItems"] == [
             %{
               "type" => "inputText",
               "text" => response["output"]
             }
           ]
  end

  test "tracker-scoped dispatch rejects cross-provider tools before calling clients" do
    jira_response =
      DynamicTool.execute("jira_rest", %{"method" => "GET", "path" => "/rest/api/3/issue/SD-1"},
        tracker_kind: "linear",
        jira_client: fn _method, _path, _body, _opts ->
          flunk("Jira client must not be called for a Linear tracker")
        end
      )

    linear_response =
      DynamicTool.execute("linear_graphql", "query Viewer { viewer { id } }",
        tracker_kind: "jira",
        linear_client: fn _query, _variables, _opts ->
          flunk("Linear client must not be called for a Jira tracker")
        end
      )

    assert get_in(Jason.decode!(jira_response["output"]), ["error", "supportedTools"]) == ["linear_graphql"]
    assert get_in(Jason.decode!(linear_response["output"]), ["error", "supportedTools"]) == ["jira_rest"]
  end

  test "linear_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{"includeTeams" => false}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]
  end

  test "jira_rest returns successful REST responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "jira_rest",
        %{
          "method" => "get",
          "path" => "/rest/api/3/issue/SD-1"
        },
        tracker_kind: "jira",
        jira_client: fn method, path, body, opts ->
          send(test_pid, {:jira_client_called, method, path, body, opts})
          {:ok, %{"key" => "SD-1"}}
        end
      )

    assert_received {:jira_client_called, "GET", "/rest/api/3/issue/SD-1", nil, []}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"key" => "SD-1"}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]
  end

  test "jira_rest canonicalizes encoded paths and blocks terminal transitions before Merging" do
    test_pid = self()
    transition_path = "/rest/api/3/issue/SD-14/transitions"

    response =
      DynamicTool.execute(
        "jira_rest",
        %{
          "method" => "POST",
          "path" => "/rest/api/3/issue/SD-14/trans%69tions",
          "body" => %{"transition" => %{"id" => "9"}}
        },
        tracker_kind: "jira",
        issue_identifier: "SD-14",
        jira_client: fn
          "GET", ^transition_path, nil, [] ->
            {:ok,
             %{
               "transitions" => [
                 %{
                   "id" => "9",
                   "name" => "Resolved",
                   "to" => %{
                     "name" => "Completed",
                     "statusCategory" => %{"key" => "done"}
                   }
                 }
               ]
             }}

          "GET", "/rest/api/3/issue/SD-14?fields=status", nil, [] ->
            {:ok, %{"key" => "SD-14", "fields" => %{"status" => %{"name" => "Work in progress"}}}}

          method, path, body, opts ->
            send(test_pid, {:unexpected_jira_call, method, path, body, opts})
            {:ok, %{}}
        end
      )

    refute_received {:unexpected_jira_call, _, _, _, _}
    assert response["success"] == false

    assert get_in(Jason.decode!(response["output"]), ["error", "message"]) =~
             "Blocked Jira terminal transition from `Work in progress` to `Completed`"
  end

  test "jira_rest permits a terminal transition from Merging after the linked PR is merged" do
    test_pid = self()
    pull_request_url = "https://github.com/acme/widgets/pull/42"

    response =
      DynamicTool.execute(
        "jira_rest",
        %{
          "method" => "POST",
          "path" => "/rest/api/3/issue/SD-14/transitions",
          "body" => %{"transition" => %{"id" => "91"}}
        },
        tracker_kind: "jira",
        issue_identifier: "SD-14",
        jira_client: fn
          "GET", "/rest/api/3/issue/SD-14/transitions", nil, [] ->
            {:ok,
             %{
               "transitions" => [
                 %{
                   "id" => "91",
                   "name" => "Finish merge",
                   "to" => %{"name" => "Done", "statusCategory" => %{"key" => "done"}}
                 }
               ]
             }}

          "GET", "/rest/api/3/issue/SD-14?fields=status", nil, [] ->
            {:ok, %{"key" => "SD-14", "fields" => %{"status" => %{"name" => "Merging"}}}}

          "GET", "/rest/api/3/issue/SD-14/remotelink", nil, [] ->
            {:ok,
             [
               %{
                 "id" => 101,
                 "object" => %{"url" => pull_request_url}
               }
             ]}

          "POST", "/rest/api/3/issue/SD-14/transitions", body, [] ->
            send(test_pid, {:jira_transition_posted, body})
            {:ok, nil}
        end,
        github_repository: "acme/widgets",
        pull_request_client: fn ^pull_request_url ->
          send(test_pid, :pull_request_verified)

          {:ok,
           %{
             "state" => "MERGED",
             "mergedAt" => "2026-06-09T08:00:00Z",
             "headRefName" => "codex/sd-14-freshness"
           }}
        end
      )

    assert_received :pull_request_verified
    assert_received {:jira_transition_posted, %{"transition" => %{"id" => "91"}}}
    assert response["success"] == true
  end

  test "jira_rest blocks a v2 terminal transition when the linked PR is still open" do
    test_pid = self()
    transition_path = "/rest/api/2/issue/SD-14/transitions/?expand=transitions.fields"
    pull_request_url = "https://github.com/acme/widgets/pull/43"

    response =
      DynamicTool.execute(
        "jira_rest",
        %{
          "method" => "POST",
          "path" => transition_path,
          "body" => %{"transition" => %{"id" => "91"}}
        },
        tracker_kind: "jira",
        issue_identifier: "SD-14",
        jira_client: fn
          "GET", ^transition_path, nil, [] ->
            {:ok,
             %{
               "transitions" => [
                 %{
                   "id" => "91",
                   "name" => "Finish merge",
                   "to" => %{"name" => "Done", "statusCategory" => %{"key" => "done"}}
                 }
               ]
             }}

          "GET", "/rest/api/2/issue/SD-14?fields=status", nil, [] ->
            {:ok, %{"key" => "SD-14", "fields" => %{"status" => %{"name" => "Merging"}}}}

          "GET", "/rest/api/2/issue/SD-14/remotelink", nil, [] ->
            {:ok,
             [
               %{"id" => 100, "object" => %{"url" => "https://github.com/other/widgets/pull/40"}},
               %{"id" => 101, "object" => %{"url" => pull_request_url}}
             ]}

          method, path, body, opts ->
            send(test_pid, {:unexpected_jira_call, method, path, body, opts})
            {:ok, nil}
        end,
        github_repository: "acme/widgets",
        pull_request_client: fn ^pull_request_url ->
          {:ok, %{"state" => "OPEN", "mergedAt" => nil, "headRefName" => "codex/sd-14-freshness"}}
        end
      )

    refute_received {:unexpected_jira_call, _, _, _, _}
    assert response["success"] == false

    assert get_in(Jason.decode!(response["output"]), ["error", "message"]) =~
             "linked pull request is `OPEN`, not `MERGED`"
  end

  test "jira_rest rejects fragments and residual encoding before dispatch" do
    paths = [
      "/rest/api/3/issue/SD-14/transitions#unguarded",
      "/rest/api/3/issue/SD-14/trans%2569tions",
      "/rest/api/3/issue/SD-14/%252e%252e/transitions"
    ]

    for path <- paths do
      response =
        DynamicTool.execute(
          "jira_rest",
          %{
            "method" => "POST",
            "path" => path,
            "body" => %{"transition" => %{"id" => "9"}}
          },
          tracker_kind: "jira",
          jira_client: fn _method, _path, _body, _opts ->
            flunk("Jira client should not be called for noncanonical path #{path}")
          end
        )

      assert response["success"] == false

      assert get_in(Jason.decode!(response["output"]), ["error", "message"]) =~
               "canonical relative `/rest/` path"
    end
  end

  test "jira_rest blocks ambiguous or issue-mismatched pull-request links" do
    pull_request_url = "https://github.com/acme/widgets/pull/42"

    cases = [
      {
        [
          %{"object" => %{"url" => pull_request_url}},
          %{"object" => %{"url" => "https://github.com/acme/widgets/pull/43"}}
        ],
        %{"state" => "MERGED", "mergedAt" => "2026-06-09T08:00:00Z", "headRefName" => "codex/sd-14"},
        "multiple pull-request links"
      },
      {
        [%{"object" => %{"url" => pull_request_url}}],
        %{"state" => "MERGED", "mergedAt" => "2026-06-09T08:00:00Z", "headRefName" => "codex/sd-99"},
        "does not match Jira issue `SD-14`"
      }
    ]

    for {remote_links, pull_request, expected_error} <- cases do
      response =
        DynamicTool.execute(
          "jira_rest",
          %{
            "method" => "POST",
            "path" => "/rest/api/3/issue/SD-14/transitions",
            "body" => %{"transition" => %{"id" => "91"}}
          },
          tracker_kind: "jira",
          issue_identifier: "SD-14",
          jira_client: fn
            "GET", "/rest/api/3/issue/SD-14/transitions", nil, [] ->
              {:ok,
               %{
                 "transitions" => [
                   %{
                     "id" => "91",
                     "name" => "Finish merge",
                     "to" => %{"name" => "Done", "statusCategory" => %{"key" => "done"}}
                   }
                 ]
               }}

            "GET", "/rest/api/3/issue/SD-14?fields=status", nil, [] ->
              {:ok, %{"key" => "SD-14", "fields" => %{"status" => %{"name" => "Merging"}}}}

            "GET", "/rest/api/3/issue/SD-14/remotelink", nil, [] ->
              {:ok, remote_links}

            "POST", "/rest/api/3/issue/SD-14/transitions", _body, [] ->
              flunk("terminal transition should be blocked")
          end,
          github_repository: "acme/widgets",
          pull_request_client: fn ^pull_request_url -> {:ok, pull_request} end
        )

      assert response["success"] == false
      assert get_in(Jason.decode!(response["output"]), ["error", "message"]) =~ expected_error
    end
  end

  test "jira_rest blocks status mutation routes that bypass guarded issue transitions" do
    paths = [
      "/rest/servicedeskapi/request/SD-14/transition",
      "/rest/servicedeskapi/request/SD-14/transition/?expand=transitions",
      "/rest/api/3/bulk/issues/move",
      "/rest/api/latest/bulk/issues/transition"
    ]

    for path <- paths do
      response =
        DynamicTool.execute(
          "jira_rest",
          %{"method" => "POST", "path" => path, "body" => %{}},
          tracker_kind: "jira",
          jira_client: fn _method, _path, _body, _opts ->
            flunk("Jira client should not be called for bypass route #{path}")
          end
        )

      assert response["success"] == false

      assert get_in(Jason.decode!(response["output"]), ["error", "message"]) =~
               "status mutation route is blocked"
    end
  end

  test "jira_rest allows only the mutation routes required by the workflow" do
    test_pid = self()
    pull_request_url = "https://github.com/acme/widgets/pull/42"

    workpad_body = %{
      "body" => %{
        "type" => "doc",
        "content" => [%{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "## Codex Workpad"}]}]
      }
    }

    remote_link_body = %{"object" => %{"url" => pull_request_url}}

    requests = [
      {"POST", "/rest/api/3/issue", %{"fields" => %{"project" => %{"key" => "SD"}}}, nil},
      {"POST", "/rest/api/3/issueLink",
       %{
         "type" => %{"name" => "Relates"},
         "inwardIssue" => %{"key" => "SD-14"},
         "outwardIssue" => %{"key" => "SD-15"}
       }, nil},
      {"POST", "/rest/api/3/search/jql", %{}, nil},
      {"POST", "/rest/api/3/issue/SD-14/comment", workpad_body, nil},
      {"POST", "/rest/api/3/issue/SD-14/remotelink", remote_link_body, nil},
      {"PUT", "/rest/api/3/issue/SD-14/comment/10001", workpad_body, :workpad},
      {"DELETE", "/rest/api/3/issue/SD-14/comment/10001", nil, :workpad},
      {"DELETE", "/rest/api/3/issue/SD-14/remotelink/10002", nil, :remote_link}
    ]

    for {method, path, body, preflight} <- requests do
      response =
        DynamicTool.execute(
          "jira_rest",
          %{"method" => method, "path" => path, "body" => body},
          tracker_kind: "jira",
          github_repository: "acme/widgets",
          issue_identifier: "SD-14",
          project_key: "SD",
          jira_client: fn called_method, called_path, called_body, opts ->
            case {called_method, preflight} do
              {"GET", :workpad} ->
                {:ok, workpad_body}

              {"GET", :remote_link} ->
                {:ok, remote_link_body}

              _other ->
                send(test_pid, {:jira_mutation_called, called_method, called_path, called_body, opts})
                {:ok, %{}}
            end
          end
        )

      assert_received {:jira_mutation_called, ^method, ^path, ^body, []}
      assert response["success"] == true
    end
  end

  test "jira_rest blocks destructive and unrecognized mutation routes" do
    requests = [
      {"DELETE", "/rest/api/3/issue/SD-14"},
      {"PUT", "/rest/api/3/issue/SD-14"},
      {"POST", "/rest/api/3/project"},
      {"PUT", "/rest/api/3/issue/SD-14/transitions"},
      {"PUT", "/rest/api/3/issue/SD-14/remotelink/10002"},
      {"DELETE", "/rest/api/3/issue/SD-14/comment"}
    ]

    for {method, path} <- requests do
      response =
        DynamicTool.execute(
          "jira_rest",
          %{"method" => method, "path" => path, "body" => %{}},
          tracker_kind: "jira",
          jira_client: fn _method, _path, _body, _opts ->
            flunk("Jira client should not be called for blocked route #{method} #{path}")
          end
        )

      assert response["success"] == false

      assert get_in(Jason.decode!(response["output"]), ["error", "message"]) =~
               "mutation route is not allowed"
    end
  end

  test "jira_rest reserves Merging for humans and rejects transition side effects" do
    transition_path = "/rest/api/3/issue/SD-14/transitions"

    merging_response =
      DynamicTool.execute(
        "jira_rest",
        %{
          "method" => "POST",
          "path" => transition_path,
          "body" => %{"transition" => %{"id" => "41"}}
        },
        tracker_kind: "jira",
        issue_identifier: "SD-14",
        jira_client: fn
          "GET", ^transition_path, nil, [] ->
            {:ok,
             %{
               "transitions" => [
                 %{
                   "id" => "41",
                   "to" => %{"name" => "Merging", "statusCategory" => %{"key" => "indeterminate"}}
                 }
               ]
             }}

          _method, _path, _body, _opts ->
            flunk("Merging transition should not be dispatched")
        end
      )

    assert get_in(Jason.decode!(merging_response["output"]), ["error", "message"]) =~
             "reserved for human approval"

    side_effect_response =
      DynamicTool.execute(
        "jira_rest",
        %{
          "method" => "POST",
          "path" => transition_path,
          "body" => %{
            "transition" => %{"id" => "31"},
            "fields" => %{"summary" => "unexpected edit"}
          }
        },
        tracker_kind: "jira",
        issue_identifier: "SD-14",
        jira_client: fn _method, _path, _body, _opts ->
          flunk("Transition requests with side effects should not reach Jira")
        end
      )

    assert get_in(Jason.decode!(side_effect_response["output"]), ["error", "message"]) =~
             "require `body.transition.id`"
  end

  test "jira_rest treats configured terminal state names as guarded transitions" do
    transition_path = "/rest/api/3/issue/SD-14/transitions"

    response =
      DynamicTool.execute(
        "jira_rest",
        %{
          "method" => "POST",
          "path" => transition_path,
          "body" => %{"transition" => %{"id" => "51"}}
        },
        tracker_kind: "jira",
        issue_identifier: "SD-14",
        terminal_states: ["Closed", "Done"],
        jira_client: fn
          "GET", ^transition_path, nil, [] ->
            {:ok, %{"transitions" => [%{"id" => "51", "to" => %{"name" => "Closed"}}]}}

          "GET", "/rest/api/3/issue/SD-14?fields=status", nil, [] ->
            {:ok, %{"key" => "SD-14", "fields" => %{"status" => %{"name" => "In Progress"}}}}

          _method, _path, _body, _opts ->
            flunk("Configured terminal transition should be blocked before mutation")
        end
      )

    assert get_in(Jason.decode!(response["output"]), ["error", "message"]) =~
             "Blocked Jira terminal transition from `In Progress` to `Closed`"
  end

  test "jira_rest scopes issue mutations and follow-up creation" do
    scope_response =
      DynamicTool.execute(
        "jira_rest",
        %{"method" => "POST", "path" => "/rest/api/3/issue/SD-99/comment", "body" => %{}},
        tracker_kind: "jira",
        issue_identifier: "SD-14",
        jira_client: fn _method, _path, _body, _opts ->
          flunk("Cross-issue mutations should not reach Jira")
        end
      )

    assert get_in(Jason.decode!(scope_response["output"]), ["error", "message"]) =~
             "limited to the current orchestration issue"

    invalid_create_bodies = [
      %{"fields" => %{"project" => %{"key" => "OTHER"}}},
      %{
        "fields" => %{"project" => %{"key" => "SD"}},
        "transition" => %{"id" => "31"}
      }
    ]

    for body <- invalid_create_bodies do
      response =
        DynamicTool.execute(
          "jira_rest",
          %{"method" => "POST", "path" => "/rest/api/3/issue", "body" => body},
          tracker_kind: "jira",
          issue_identifier: "SD-14",
          project_key: "SD",
          jira_client: fn _method, _path, _body, _opts ->
            flunk("Invalid follow-up creation should not reach Jira")
          end
        )

      assert get_in(Jason.decode!(response["output"]), ["error", "message"]) =~
               "fields-only body targeting the configured Jira project"
    end

    issue_link_response =
      DynamicTool.execute(
        "jira_rest",
        %{
          "method" => "POST",
          "path" => "/rest/api/3/issueLink",
          "body" => %{
            "type" => %{"name" => "Relates"},
            "inwardIssue" => %{"key" => "SD-14"},
            "outwardIssue" => %{"key" => "SD-15"},
            "comment" => %{"body" => "side effect"}
          }
        },
        tracker_kind: "jira",
        issue_identifier: "SD-14",
        jira_client: fn _method, _path, _body, _opts ->
          flunk("Issue links with comments should not reach Jira")
        end
      )

    assert get_in(Jason.decode!(issue_link_response["output"]), ["error", "message"]) =~
             "cannot include comments"
  end

  test "jira_rest protects non-workpad comments and unrelated pull-request links" do
    human_comment = %{
      "body" => %{
        "type" => "doc",
        "content" => [%{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "Human review note"}]}]
      }
    }

    workpad_update = %{
      "body" => %{
        "type" => "doc",
        "content" => [%{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "## Codex Workpad"}]}]
      }
    }

    comment_cases = [
      {"POST", "/rest/api/3/issue/SD-14/comment", human_comment},
      {"PUT", "/rest/api/3/issue/SD-14/comment/10001", workpad_update},
      {"DELETE", "/rest/api/3/issue/SD-14/comment/10001", nil}
    ]

    for {method, path, body} <- comment_cases do
      response =
        DynamicTool.execute(
          "jira_rest",
          %{"method" => method, "path" => path, "body" => body},
          tracker_kind: "jira",
          issue_identifier: "SD-14",
          jira_client: fn
            "GET", ^path, nil, [] -> {:ok, human_comment}
            _called_method, _called_path, _called_body, _opts -> flunk("Non-workpad comment mutation should be blocked")
          end
        )

      assert get_in(Jason.decode!(response["output"]), ["error", "message"]) =~
               "active `## Codex Workpad` comment"
    end

    wrong_link = %{"object" => %{"url" => "https://github.com/other/widgets/pull/42"}}

    post_response =
      DynamicTool.execute(
        "jira_rest",
        %{
          "method" => "POST",
          "path" => "/rest/api/3/issue/SD-14/remotelink",
          "body" => wrong_link
        },
        tracker_kind: "jira",
        github_repository: "acme/widgets",
        issue_identifier: "SD-14",
        jira_client: fn _method, _path, _body, _opts ->
          flunk("Wrong-repository remote link should be blocked")
        end
      )

    delete_path = "/rest/api/3/issue/SD-14/remotelink/10002"

    delete_response =
      DynamicTool.execute(
        "jira_rest",
        %{"method" => "DELETE", "path" => delete_path},
        tracker_kind: "jira",
        github_repository: "acme/widgets",
        issue_identifier: "SD-14",
        jira_client: fn
          "GET", ^delete_path, nil, [] -> {:ok, wrong_link}
          _method, _path, _body, _opts -> flunk("Wrong-repository remote-link deletion should be blocked")
        end
      )

    for response <- [post_response, delete_response] do
      assert get_in(Jason.decode!(response["output"]), ["error", "message"]) =~
               "configured GitHub repository"
    end
  end

  test "linear_graphql accepts a raw GraphQL query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        "  query Viewer { viewer { id } }  ",
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_456"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql ignores legacy operationName arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "operationName" => "Viewer"},
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_789"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql passes multi-operation documents through unchanged" do
    test_pid = self()

    query = """
    query Viewer { viewer { id } }
    query Teams { teams { nodes { id } } }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query},
        linear_client: fn forwarded_query, variables, opts ->
          send(test_pid, {:linear_client_called, forwarded_query, variables, opts})
          {:ok, %{"errors" => [%{"message" => "Must provide operation name if query contains multiple operations."}]}}
        end
      )

    assert_received {:linear_client_called, forwarded_query, %{}, []}
    assert forwarded_query == String.trim(query)
    assert response["success"] == false
  end

  test "linear_graphql rejects blank raw query strings even when using the default client" do
    response = DynamicTool.execute("linear_graphql", "   ")

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "linear_graphql marks GraphQL error responses as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation BadMutation { nope }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }
  end

  test "linear_graphql marks atom-key GraphQL error responses as failures" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert response["success"] == false
  end

  test "linear_graphql validates required arguments before calling Linear" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"variables" => %{"commentId" => "comment-1"}},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }

    blank_query =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "   "},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the query is blank")
        end
      )

    assert blank_query["success"] == false
  end

  test "linear_graphql rejects invalid argument types" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        [:not, :valid],
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
             }
           }
  end

  test "linear_graphql rejects invalid variables" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "variables" => ["bad"]},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when variables are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "linear_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :missing_linear_api_token} end
      )

    assert missing_token["success"] == false

    assert Jason.decode!(missing_token["output"]) == %{
             "error" => %{
               "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
             }
           }

    status_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_status, 503}} end
      )

    assert Jason.decode!(status_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed with HTTP 503.",
               "status" => 503
             }
           }

    request_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_request, :timeout}} end
      )

    assert Jason.decode!(request_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "linear_graphql formats unexpected failures from the client" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :boom} end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL tool execution failed.",
               "reason" => ":boom"
             }
           }
  end

  test "linear_graphql falls back to inspect for non-JSON payloads" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true
    assert response["output"] == ":ok"
  end
end
