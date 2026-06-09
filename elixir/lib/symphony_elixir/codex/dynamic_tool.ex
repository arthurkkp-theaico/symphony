defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{Config, Jira, Linear}

  @linear_graphql_tool "linear_graphql"
  @jira_rest_tool "jira_rest"
  @jira_issue_transition_path ~r{^(/rest/api/(?:2|3|latest))/issue/([^/?]+)/transitions/?(?:\?.*)?$}i
  @jira_unsafe_status_mutation_path ~r{^/(?:rest/servicedeskapi/request/[^/?]+/transition|rest/api/(?:2|3|latest)/bulk/issues/(?:move|transition))/?(?:\?.*)?$}i
  @jira_create_issue_path ~r{^/rest/api/(?:2|3|latest)/issue/?(?:\?.*)?$}i
  @jira_issue_link_path ~r{^/rest/api/(?:2|3|latest)/issueLink/?(?:\?.*)?$}i
  @jira_search_path ~r{^/rest/api/(?:2|3|latest)/search/jql/?(?:\?.*)?$}i
  @jira_comment_collection_path ~r{^/rest/api/(?:2|3|latest)/issue/([^/?]+)/comment/?(?:\?.*)?$}i
  @jira_remote_link_collection_path ~r{^/rest/api/(?:2|3|latest)/issue/([^/?]+)/remotelink/?(?:\?.*)?$}i
  @jira_comment_item_path ~r{^/rest/api/(?:2|3|latest)/issue/([^/?]+)/comment/\d+/?(?:\?.*)?$}i
  @jira_remote_link_item_path ~r{^/rest/api/(?:2|3|latest)/issue/([^/?]+)/remotelink/\d+/?(?:\?.*)?$}i
  @jira_merging_state "merging"
  @jira_workpad_marker "## Codex Workpad"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @jira_rest_description """
  Execute an allowlisted Jira Cloud REST request using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }
  @jira_rest_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["method", "path"],
    "properties" => %{
      "method" => %{
        "type" => "string",
        "enum" => ["GET", "POST", "PUT", "DELETE"],
        "description" => "HTTP method for the Jira REST request."
      },
      "path" => %{
        "type" => "string",
        "description" => "Jira REST path, for example /rest/api/3/issue/SD-1."
      },
      "body" => %{
        "type" => ["object", "array", "null"],
        "description" => "Optional JSON body.",
        "additionalProperties" => true
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    tracker_kind = Keyword.get_lazy(opts, :tracker_kind, &configured_tracker_kind/0)

    case {tracker_kind, tool} do
      {"linear", @linear_graphql_tool} ->
        execute_linear_graphql(arguments, opts)

      {"jira", @jira_rest_tool} ->
        execute_jira_rest(arguments, opts)

      {_tracker_kind, other} ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names(tracker_kind)
          }
        })
    end
  end

  @spec tool_specs(String.t() | nil) :: [map()]
  def tool_specs(tracker_kind \\ configured_tracker_kind()) do
    case tracker_kind do
      "linear" ->
        [
          %{
            "name" => @linear_graphql_tool,
            "description" => @linear_graphql_description,
            "inputSchema" => @linear_graphql_input_schema
          }
        ]

      "jira" ->
        [
          %{
            "name" => @jira_rest_tool,
            "description" => @jira_rest_description,
            "inputSchema" => @jira_rest_input_schema
          }
        ]

      _other ->
        []
    end
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Linear.Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_jira_rest(arguments, opts) do
    context = %{
      github_repository: Keyword.get(opts, :github_repository),
      issue_identifier: Keyword.get(opts, :issue_identifier),
      jira_client: Keyword.get(opts, :jira_client, &Jira.Client.rest/4),
      project_key: Keyword.get(opts, :project_key),
      pull_request_client: Keyword.get(opts, :pull_request_client, &fetch_github_pull_request/1),
      terminal_states: Keyword.get(opts, :terminal_states, []),
      workspace: Keyword.get(opts, :workspace)
    }

    with {:ok, method, path, body} <- normalize_jira_rest_arguments(arguments),
         :ok <- guard_jira_request(method, path, body, context),
         {:ok, response} <- context.jira_client.(method, path, body, []) do
      dynamic_tool_response(true, encode_payload(response))
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_jira_rest_arguments(arguments) when is_map(arguments) do
    with {:ok, method} <- normalize_jira_method(arguments),
         {:ok, path} <- normalize_jira_path(arguments),
         {:ok, body} <- normalize_jira_body(arguments) do
      {:ok, method, path, body}
    end
  end

  defp normalize_jira_rest_arguments(_arguments), do: {:error, :invalid_jira_arguments}

  defp guard_jira_request("GET", _path, _body, _context), do: :ok

  defp guard_jira_request("POST", path, body, context) do
    case Regex.run(@jira_issue_transition_path, path) do
      [_, api_prefix, issue_id] ->
        guard_jira_transition_target(api_prefix, issue_id, path, body, context)

      nil ->
        if Regex.match?(@jira_unsafe_status_mutation_path, path) do
          {:error, :jira_unsupported_status_mutation}
        else
          guard_allowed_jira_post(path, body, context)
        end
    end
  end

  defp guard_jira_request("PUT", path, body, context) do
    case Regex.run(@jira_comment_item_path, path) do
      [_, issue_id] ->
        with :ok <- guard_jira_issue_scope(issue_id, context),
             :ok <- guard_jira_workpad_body(body),
             do: guard_existing_jira_workpad(path, context)

      nil ->
        {:error, :jira_rest_path_not_allowed}
    end
  end

  defp guard_jira_request("DELETE", path, _body, context) do
    cond do
      match = Regex.run(@jira_comment_item_path, path) ->
        [_, issue_id] = match

        with :ok <- guard_jira_issue_scope(issue_id, context),
             do: guard_existing_jira_workpad(path, context)

      match = Regex.run(@jira_remote_link_item_path, path) ->
        [_, issue_id] = match

        with :ok <- guard_jira_issue_scope(issue_id, context),
             do: guard_existing_jira_pull_request_link(path, context)

      true ->
        {:error, :jira_rest_path_not_allowed}
    end
  end

  defp guard_allowed_jira_post(path, body, context) do
    cond do
      Regex.match?(@jira_create_issue_path, path) ->
        guard_jira_issue_creation(body, context)

      Regex.match?(@jira_issue_link_path, path) ->
        guard_jira_issue_link(body, context)

      Regex.match?(@jira_search_path, path) ->
        :ok

      true ->
        guard_jira_issue_collection_post(path, body, context)
    end
  end

  defp guard_jira_issue_collection_post(path, body, context) do
    cond do
      match = Regex.run(@jira_comment_collection_path, path) ->
        [_, issue_id] = match

        with :ok <- guard_jira_issue_scope(issue_id, context),
             do: guard_jira_workpad_body(body)

      match = Regex.run(@jira_remote_link_collection_path, path) ->
        [_, issue_id] = match

        with :ok <- guard_jira_issue_scope(issue_id, context),
             do: guard_jira_pull_request_link(body, context)

      true ->
        {:error, :jira_rest_path_not_allowed}
    end
  end

  defp guard_jira_issue_creation(body, %{project_key: project_key}) when is_map(body) and is_binary(project_key) do
    if valid_jira_issue_creation?(body, project_key) do
      :ok
    else
      {:error, :jira_issue_creation_not_allowed}
    end
  end

  defp guard_jira_issue_creation(_body, _context), do: {:error, :jira_issue_creation_not_allowed}

  defp valid_jira_issue_creation?(body, project_key) do
    with true <- exact_map_keys?(body, ["fields"]),
         %{} = fields <- Map.get(body, "fields") || Map.get(body, :fields),
         %{} = project <- Map.get(fields, "project") || Map.get(fields, :project),
         requested_key when is_binary(requested_key) <- Map.get(project, "key") || Map.get(project, :key) do
      String.downcase(requested_key) == String.downcase(project_key)
    else
      _other -> false
    end
  end

  defp guard_jira_issue_link(body, %{issue_identifier: issue_identifier})
       when is_map(body) and is_binary(issue_identifier) do
    issue_keys =
      [Map.get(body, "inwardIssue") || Map.get(body, :inwardIssue), Map.get(body, "outwardIssue") || Map.get(body, :outwardIssue)]
      |> Enum.filter(&is_map/1)
      |> Enum.map(&(Map.get(&1, "key") || Map.get(&1, :key)))
      |> Enum.filter(&is_binary/1)

    cond do
      Map.has_key?(body, "comment") or Map.has_key?(body, :comment) ->
        {:error, :jira_issue_link_comment_not_allowed}

      Enum.any?(issue_keys, &(String.downcase(&1) == String.downcase(issue_identifier))) ->
        :ok

      true ->
        {:error, :jira_issue_scope_mismatch}
    end
  end

  defp guard_jira_issue_link(_body, _context), do: {:error, :jira_issue_scope_mismatch}

  defp guard_jira_issue_scope(issue_id, %{issue_identifier: issue_identifier})
       when is_binary(issue_id) and is_binary(issue_identifier) do
    if String.downcase(issue_id) == String.downcase(issue_identifier) do
      :ok
    else
      {:error, :jira_issue_scope_mismatch}
    end
  end

  defp guard_jira_issue_scope(_issue_id, _context), do: {:error, :jira_issue_scope_mismatch}

  defp guard_jira_workpad_body(body) when is_map(body) do
    comment_body = Map.get(body, "body") || Map.get(body, :body)

    if jira_text_contains?(comment_body, @jira_workpad_marker) do
      :ok
    else
      {:error, :jira_workpad_required}
    end
  end

  defp guard_jira_workpad_body(_body), do: {:error, :jira_workpad_required}

  defp guard_existing_jira_workpad(path, context) do
    with {:ok, comment} <- context.jira_client.("GET", path, nil, []),
         :ok <- guard_jira_workpad_body(comment) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :jira_workpad_required}
    end
  end

  defp guard_jira_pull_request_link(payload, context) when is_map(payload) do
    url = get_in(payload, ["object", "url"])

    with true <- is_binary(url),
         {:ok, repository} <- configured_github_repository(context),
         {:ok, ^repository} <- github_pull_request_repository(url) do
      :ok
    else
      _other -> {:error, :jira_pull_request_link_not_allowed}
    end
  end

  defp guard_jira_pull_request_link(_payload, _context), do: {:error, :jira_pull_request_link_not_allowed}

  defp guard_existing_jira_pull_request_link(path, context) do
    with {:ok, remote_link} <- context.jira_client.("GET", path, nil, []),
         :ok <- guard_jira_pull_request_link(remote_link, context) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :jira_pull_request_link_not_allowed}
    end
  end

  defp jira_text_contains?(value, expected) when is_binary(value), do: String.contains?(value, expected)
  defp jira_text_contains?(value, expected) when is_list(value), do: Enum.any?(value, &jira_text_contains?(&1, expected))

  defp jira_text_contains?(value, expected) when is_map(value) do
    value
    |> Map.values()
    |> Enum.any?(&jira_text_contains?(&1, expected))
  end

  defp jira_text_contains?(_value, _expected), do: false

  defp guard_jira_transition_target(api_prefix, issue_id, path, body, context) do
    with :ok <- guard_jira_issue_scope(issue_id, context),
         {:ok, transition_id} <- jira_transition_id(body),
         {:ok, %{"transitions" => transitions}} when is_list(transitions) <-
           context.jira_client.("GET", path, nil, []),
         %{} = transition <- find_jira_transition(transitions, transition_id) do
      guard_jira_terminal_transition(api_prefix, issue_id, transition, context)
    else
      nil -> {:error, :jira_transition_not_available}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :jira_transition_guard_failed}
    end
  end

  defp jira_transition_id(body) when is_map(body) do
    transition = Map.get(body, "transition") || Map.get(body, :transition)

    with true <- exact_map_keys?(body, ["transition"]),
         true <- is_map(transition) and exact_map_keys?(transition, ["id"]) do
      case Map.get(transition, "id") || Map.get(transition, :id) do
        id when is_binary(id) and id != "" -> {:ok, id}
        id when is_integer(id) -> {:ok, Integer.to_string(id)}
        _ -> {:error, :invalid_jira_transition_request}
      end
    else
      _ -> {:error, :invalid_jira_transition_request}
    end
  end

  defp jira_transition_id(_body), do: {:error, :invalid_jira_transition_request}

  defp find_jira_transition(transitions, transition_id) do
    Enum.find(transitions, fn transition ->
      to_string(Map.get(transition, "id") || Map.get(transition, :id)) == transition_id
    end)
  end

  defp guard_jira_terminal_transition(api_prefix, issue_id, transition, context) do
    case normalize_state(jira_transition_target(transition)) do
      "merging" ->
        {:error, :jira_human_transition_required}

      _target ->
        if jira_terminal_transition?(transition, context.terminal_states) do
          verify_jira_terminal_source(api_prefix, issue_id, transition, context)
        else
          :ok
        end
    end
  end

  defp exact_map_keys?(map, keys) when is_map(map) do
    map
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
    |> Kernel.==(Enum.sort(keys))
  end

  defp verify_jira_terminal_source(api_prefix, issue_id, transition, context) do
    case context.jira_client.("GET", "#{api_prefix}/issue/#{issue_id}?fields=status", nil, []) do
      {:ok, %{"key" => issue_key, "fields" => %{"status" => %{"name" => current_state}}}}
      when is_binary(issue_key) ->
        with :ok <- guard_jira_terminal_source(current_state, transition) do
          verify_linked_pull_request(api_prefix, issue_id, issue_key, context)
        end

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :jira_transition_guard_failed}
    end
  end

  defp guard_jira_terminal_source(current_state, transition) do
    if normalize_state(current_state) == @jira_merging_state do
      :ok
    else
      {:error, {:jira_terminal_transition_blocked, current_state, jira_transition_target(transition)}}
    end
  end

  defp verify_linked_pull_request(api_prefix, issue_id, issue_key, context) do
    with {:ok, remote_links} when is_list(remote_links) <-
           context.jira_client.("GET", "#{api_prefix}/issue/#{issue_id}/remotelink", nil, []),
         {:ok, repository} <- configured_github_repository(context),
         {:ok, pull_request_url} <- github_pull_request_url(remote_links, repository) do
      verify_github_pull_request(pull_request_url, issue_key, context.pull_request_client)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :jira_transition_guard_failed}
    end
  end

  defp github_pull_request_url(remote_links, repository) do
    remote_links
    |> Enum.flat_map(&github_pull_request_link/1)
    |> Enum.filter(&(elem(&1, 0) == repository))
    |> Enum.uniq_by(&elem(&1, 1))
    |> case do
      [{_repository, url}] -> {:ok, url}
      [] -> {:error, :jira_pull_request_link_missing}
      _multiple -> {:error, :jira_pull_request_link_ambiguous}
    end
  end

  defp github_pull_request_link(%{"object" => %{"url" => url}}) when is_binary(url) do
    case github_pull_request_repository(url) do
      {:ok, repository} -> [{repository, url}]
      :error -> []
    end
  end

  defp github_pull_request_link(_remote_link), do: []

  defp github_pull_request_repository(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: "github.com", path: path} when is_binary(path) ->
        github_pull_request_repository_from_path(path)

      _other ->
        :error
    end
  end

  defp github_pull_request_repository_from_path(path) do
    with [_, repository] <- Regex.run(~r{^/([^/]+/[^/]+)/pull/\d+/?$}, path),
         normalized when is_binary(normalized) <- normalize_github_repository(repository) do
      {:ok, normalized}
    else
      _other -> :error
    end
  end

  defp configured_github_repository(context) do
    repository =
      context.github_repository ||
        System.get_env("SYMPHONY_GITHUB_REPO") ||
        github_repository_from_workspace(context.workspace)

    case normalize_github_repository(repository) do
      nil -> {:error, :jira_github_repository_unavailable}
      normalized -> {:ok, normalized}
    end
  end

  defp github_repository_from_workspace(workspace) when is_binary(workspace) do
    with git when is_binary(git) <- System.find_executable("git"),
         {remote_url, 0} <- System.cmd(git, ["-C", workspace, "remote", "get-url", "origin"], stderr_to_stdout: true) do
      github_repository_from_remote_url(String.trim(remote_url))
    else
      _other -> nil
    end
  end

  defp github_repository_from_workspace(_workspace), do: nil

  defp github_repository_from_remote_url(remote_url) do
    case Regex.run(~r{github\.com(?::|/)([^/\s]+/[^/\s]+?)(?:\.git)?$}i, remote_url) do
      [_, repository] -> normalize_github_repository(repository)
      nil -> nil
    end
  end

  defp normalize_github_repository(repository) when is_binary(repository) do
    normalized = repository |> String.trim() |> String.trim_trailing(".git") |> String.downcase()

    if Regex.match?(~r{^[^/]+/[^/]+$}, normalized), do: normalized
  end

  defp normalize_github_repository(_repository), do: nil

  defp fetch_github_pull_request(url) do
    case System.find_executable("gh") do
      nil ->
        {:error, :jira_pull_request_verification_unavailable}

      gh ->
        fetch_github_pull_request(gh, url)
    end
  end

  defp fetch_github_pull_request(gh, url) do
    case System.cmd(gh, ["pr", "view", url, "--json", "state,mergedAt,headRefName"], stderr_to_stdout: true) do
      {output, 0} -> Jason.decode(output)
      {_output, _status} -> {:error, :jira_pull_request_verification_failed}
    end
  end

  defp verify_github_pull_request(url, issue_key, pull_request_client) do
    case pull_request_client.(url) do
      {:ok, %{"state" => "MERGED", "mergedAt" => merged_at, "headRefName" => branch}}
      when is_binary(merged_at) and merged_at != "" and is_binary(branch) ->
        if branch_matches_issue?(branch, issue_key) do
          :ok
        else
          {:error, {:jira_pull_request_issue_mismatch, url, issue_key, branch}}
        end

      {:ok, %{"state" => state}} ->
        {:error, {:jira_pull_request_not_merged, url, state}}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :jira_pull_request_verification_failed}
    end
  end

  defp branch_matches_issue?(branch, issue_key) do
    issue_pattern = Regex.escape(String.downcase(issue_key))
    Regex.match?(~r{(?:^|[\/_.-])#{issue_pattern}(?:$|[\/_.-])}, String.downcase(branch))
  end

  defp jira_done_transition?(transition) do
    transition
    |> get_in(["to", "statusCategory", "key"])
    |> normalize_state()
    |> Kernel.==("done")
  end

  defp jira_terminal_transition?(transition, terminal_states) do
    jira_done_transition?(transition) or
      normalize_state(jira_transition_target(transition)) in Enum.map(terminal_states, &normalize_state/1)
  end

  defp jira_transition_target(transition), do: get_in(transition, ["to", "name"]) || "terminal state"

  defp normalize_state(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_state(_value), do: ""

  defp normalize_jira_method(arguments) do
    method = Map.get(arguments, "method") || Map.get(arguments, :method)

    case method do
      method when is_binary(method) ->
        normalized = method |> String.trim() |> String.upcase()

        if normalized in ["GET", "POST", "PUT", "DELETE"] do
          {:ok, normalized}
        else
          {:error, :invalid_jira_method}
        end

      _ ->
        {:error, :invalid_jira_method}
    end
  end

  defp normalize_jira_path(arguments) do
    path = Map.get(arguments, "path") || Map.get(arguments, :path)

    case path do
      path when is_binary(path) ->
        normalize_jira_uri(String.trim(path))

      _ ->
        {:error, :missing_jira_path}
    end
  end

  defp normalize_jira_uri(""), do: {:error, :missing_jira_path}

  defp normalize_jira_uri(path) do
    uri = URI.parse(path)

    with nil <- uri.scheme,
         nil <- uri.host,
         nil <- uri.fragment,
         decoded_path when is_binary(decoded_path) <- URI.decode(uri.path || ""),
         true <- valid_jira_uri_path?(decoded_path) do
      {:ok, append_uri_query(decoded_path, uri.query)}
    else
      _other -> {:error, :invalid_jira_path}
    end
  rescue
    ArgumentError -> {:error, :invalid_jira_path}
  end

  defp valid_jira_uri_path?(path) do
    String.starts_with?(path, "/rest/") and
      not String.contains?(path, ["//", "?", "#", "%"]) and
      not Enum.any?(String.split(path, "/"), &(&1 in [".", ".."]))
  end

  defp append_uri_query(path, nil), do: path
  defp append_uri_query(path, query), do: path <> "?" <> query

  defp normalize_jira_body(arguments) do
    case Map.get(arguments, "body") || Map.get(arguments, :body) do
      nil -> {:ok, nil}
      body when is_map(body) or is_list(body) -> {:ok, body}
      _ -> {:error, :invalid_jira_body}
    end
  end

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload(:missing_jira_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Jira auth. Set `tracker.api_key` in `WORKFLOW.md` or export `JIRA_API_TOKEN`."
      }
    }
  end

  defp tool_error_payload(:missing_jira_email) do
    %{
      "error" => %{
        "message" => "Symphony is missing Jira account email. Set `tracker.email` in `WORKFLOW.md` or export `JIRA_EMAIL`."
      }
    }
  end

  defp tool_error_payload(:invalid_jira_arguments) do
    %{
      "error" => %{
        "message" => "`jira_rest` expects an object with `method`, `path`, and optional `body`."
      }
    }
  end

  defp tool_error_payload(:invalid_jira_method) do
    %{
      "error" => %{
        "message" => "`jira_rest.method` must be one of GET, POST, PUT, or DELETE."
      }
    }
  end

  defp tool_error_payload(:missing_jira_path) do
    %{
      "error" => %{
        "message" => "`jira_rest.path` is required."
      }
    }
  end

  defp tool_error_payload(:invalid_jira_path) do
    %{
      "error" => %{
        "message" => "`jira_rest.path` must be a canonical relative `/rest/` path without fragments or traversal segments."
      }
    }
  end

  defp tool_error_payload(:invalid_jira_body) do
    %{
      "error" => %{
        "message" => "`jira_rest.body` must be a JSON object, array, or null."
      }
    }
  end

  defp tool_error_payload(:invalid_jira_transition_request) do
    %{
      "error" => %{
        "message" => "Jira transition requests require `body.transition.id`."
      }
    }
  end

  defp tool_error_payload(:jira_transition_not_available) do
    %{
      "error" => %{
        "message" => "The requested Jira transition is not available from the issue's current status. Preserve the current status; do not substitute another transition."
      }
    }
  end

  defp tool_error_payload(:jira_transition_guard_failed) do
    %{
      "error" => %{
        "message" => "Symphony could not verify the requested Jira transition, so the mutation was blocked."
      }
    }
  end

  defp tool_error_payload(:jira_unsupported_status_mutation) do
    %{
      "error" => %{
        "message" => "This Jira status mutation route is blocked. Use the issue transition endpoint at `/rest/api/3/issue/{issue}/transitions` so Symphony can enforce lifecycle guards."
      }
    }
  end

  defp tool_error_payload(:jira_rest_path_not_allowed) do
    %{
      "error" => %{
        "message" => "This Jira REST mutation route is not allowed. Use issue comments, remote links, issue links, search, issue creation, or the guarded issue transition endpoint."
      }
    }
  end

  defp tool_error_payload(:jira_human_transition_required) do
    %{
      "error" => %{
        "message" => "The Jira transition into `Merging` is reserved for human approval and cannot be performed by this tool."
      }
    }
  end

  defp tool_error_payload(:jira_issue_scope_mismatch) do
    %{
      "error" => %{
        "message" => "Jira issue mutations are limited to the current orchestration issue."
      }
    }
  end

  defp tool_error_payload(:jira_issue_creation_not_allowed) do
    %{
      "error" => %{
        "message" => "Jira issue creation requires a fields-only body targeting the configured Jira project."
      }
    }
  end

  defp tool_error_payload(:jira_issue_link_comment_not_allowed) do
    %{
      "error" => %{
        "message" => "Jira issue links cannot include comments; update the current issue workpad separately."
      }
    }
  end

  defp tool_error_payload(:jira_workpad_required) do
    %{
      "error" => %{
        "message" => "Jira comment mutations are limited to the active `## Codex Workpad` comment."
      }
    }
  end

  defp tool_error_payload(:jira_pull_request_link_not_allowed) do
    %{
      "error" => %{
        "message" => "Jira remote-link mutations are limited to pull requests from the configured GitHub repository."
      }
    }
  end

  defp tool_error_payload(:jira_pull_request_link_missing) do
    %{
      "error" => %{
        "message" => "Blocked Jira terminal transition because the issue has no linked GitHub pull request from the configured repository."
      }
    }
  end

  defp tool_error_payload(:jira_pull_request_link_ambiguous) do
    %{
      "error" => %{
        "message" => "Blocked Jira terminal transition because the issue has multiple pull-request links from the configured repository. Keep exactly one active implementation PR link."
      }
    }
  end

  defp tool_error_payload(:jira_github_repository_unavailable) do
    %{
      "error" => %{
        "message" => "Blocked Jira terminal transition because Symphony could not determine the configured GitHub repository."
      }
    }
  end

  defp tool_error_payload(:jira_pull_request_verification_unavailable) do
    %{
      "error" => %{
        "message" => "Blocked Jira terminal transition because authenticated GitHub verification is unavailable."
      }
    }
  end

  defp tool_error_payload(:jira_pull_request_verification_failed) do
    %{
      "error" => %{
        "message" => "Blocked Jira terminal transition because Symphony could not verify the linked GitHub pull request."
      }
    }
  end

  defp tool_error_payload({:jira_pull_request_not_merged, url, state}) do
    %{
      "error" => %{
        "message" => "Blocked Jira terminal transition because the linked pull request is `#{state}`, not `MERGED`.",
        "pullRequest" => url
      }
    }
  end

  defp tool_error_payload({:jira_pull_request_issue_mismatch, url, issue_key, branch}) do
    %{
      "error" => %{
        "message" => "Blocked Jira terminal transition because the linked pull request branch `#{branch}` does not match Jira issue `#{issue_key}`.",
        "pullRequest" => url
      }
    }
  end

  defp tool_error_payload({:jira_terminal_transition_blocked, current_state, target_state}) do
    %{
      "error" => %{
        "message" =>
          "Blocked Jira terminal transition from `#{current_state}` to `#{target_state}`. Terminal transitions are allowed only from `Merging`, after the linked pull request is verified merged. Preserve the current status if the required review transition is unavailable."
      }
    }
  end

  defp tool_error_payload({:jira_api_status, status}) do
    %{
      "error" => %{
        "message" => "Jira REST request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:jira_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Jira REST request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names(tracker_kind), do: Enum.map(tool_specs(tracker_kind), & &1["name"])

  defp configured_tracker_kind, do: Config.settings!().tracker.kind
end
