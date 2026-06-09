defmodule SymphonyElixir.Jira.Client do
  @moduledoc """
  Jira Cloud REST client for polling candidate issues.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue}

  @issue_page_size 50
  @max_error_body_log_bytes 1_000

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with :ok <- validate_jira_config(tracker),
         {:ok, assignee_filter} <- routing_assignee_filter() do
      do_fetch_by_states(tracker.project_key, tracker.active_states, assignee_filter)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker

      with :ok <- validate_jira_config(tracker) do
        do_fetch_by_states(tracker.project_key, normalized_states, nil)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = issue_ids |> Enum.map(&to_string/1) |> Enum.uniq()

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with :ok <- validate_jira_config(Config.settings!().tracker),
             {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_by_jql(issue_id_jql(ids), assignee_filter)
        end
    end
  end

  @spec rest(String.t(), String.t(), map() | nil, keyword()) ::
          {:ok, map() | list() | String.t() | nil} | {:error, term()}
  def rest(method, path, body \\ nil, opts \\ []) when is_binary(method) and is_binary(path) do
    request_fun = Keyword.get(opts, :request_fun, &request/4)

    with {:ok, headers} <- jira_headers(),
         {:ok, response} <- request_fun.(String.upcase(method), path, body, headers) do
      case response do
        %{status: status, body: response_body} when status in 200..299 ->
          {:ok, response_body}

        %{status: status} ->
          Logger.error("Jira REST request failed status=#{status} path=#{path} body=#{summarize_error_body(Map.get(response, :body))}")
          {:error, {:jira_api_status, status}}
      end
    else
      {:error, reason} ->
        Logger.error("Jira REST request failed: #{inspect(reason)}")
        {:error, {:jira_api_request, reason}}
    end
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue), do: normalize_issue(issue, nil)

  defp do_fetch_by_states(project_key, state_names, assignee_filter) do
    jql =
      [
        "project = #{jql_string(project_key)}",
        "status in (#{Enum.map_join(state_names, ", ", &jql_string/1)})"
      ]
      |> Enum.join(" AND ")
      |> maybe_add_assignee_jql(assignee_filter)

    do_fetch_by_jql(jql, assignee_filter)
  end

  defp do_fetch_by_jql(jql, assignee_filter), do: do_fetch_by_jql(jql, assignee_filter, nil, [])

  defp do_fetch_by_jql(jql, assignee_filter, next_page_token, acc_issues) do
    body =
      %{
        "jql" => jql,
        "maxResults" => @issue_page_size,
        "fields" => [
          "summary",
          "description",
          "status",
          "priority",
          "assignee",
          "labels",
          "created",
          "updated",
          "issuelinks"
        ]
      }
      |> maybe_put_next_page_token(next_page_token)

    with {:ok, response} <- rest("POST", "/rest/api/3/search/jql", body),
         {:ok, issues, next_token} <- decode_search_response(response, assignee_filter) do
      updated_acc = Enum.reverse(issues, acc_issues)

      case next_token do
        nil -> {:ok, Enum.reverse(updated_acc)}
        token -> do_fetch_by_jql(jql, assignee_filter, token, updated_acc)
      end
    end
  end

  defp maybe_put_next_page_token(body, nil), do: body
  defp maybe_put_next_page_token(body, token), do: Map.put(body, "nextPageToken", token)

  defp decode_search_response(
         %{"issues" => nodes} = response,
         assignee_filter
       )
       when is_list(nodes) do
    issues =
      nodes
      |> Enum.map(&normalize_issue(&1, assignee_filter))
      |> Enum.reject(&is_nil/1)

    next_token =
      if response["isLast"] == false do
        response["nextPageToken"]
      end

    {:ok, issues, next_token}
  end

  defp decode_search_response(_unknown, _assignee_filter), do: {:error, :jira_unknown_payload}

  defp request(method, path, body, headers) do
    url = jira_url(path)

    opts =
      [
        method: method,
        url: url,
        headers: headers,
        connect_options: [timeout: 30_000]
      ]
      |> maybe_put_json(body)

    Req.request(opts)
  end

  defp maybe_put_json(opts, nil), do: opts
  defp maybe_put_json(opts, body), do: Keyword.put(opts, :json, body)

  defp jira_url("http" <> _ = url), do: url

  defp jira_url(path) do
    Config.settings!().tracker.endpoint
    |> String.trim_trailing("/")
    |> Kernel.<>(if String.starts_with?(path, "/"), do: path, else: "/" <> path)
  end

  defp jira_headers do
    tracker = Config.settings!().tracker

    cond do
      not is_binary(tracker.email) ->
        {:error, :missing_jira_email}

      not is_binary(tracker.api_key) ->
        {:error, :missing_jira_api_token}

      true ->
        token = Base.encode64("#{tracker.email}:#{tracker.api_key}")

        {:ok,
         [
           {"Authorization", "Basic #{token}"},
           {"Accept", "application/json"},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp validate_jira_config(tracker) do
    cond do
      not is_binary(tracker.email) -> {:error, :missing_jira_email}
      not is_binary(tracker.api_key) -> {:error, :missing_jira_api_token}
      not is_binary(tracker.endpoint) -> {:error, :missing_jira_endpoint}
      not is_binary(tracker.project_key) -> {:error, :missing_jira_project_key}
      true -> :ok
    end
  end

  defp normalize_issue(%{"fields" => fields} = issue, assignee_filter) when is_map(fields) do
    assignee = fields["assignee"]
    key = issue["key"]

    %Issue{
      id: issue["id"],
      identifier: key,
      title: fields["summary"],
      description: adf_to_text(fields["description"]),
      priority: parse_priority(fields["priority"]),
      state: get_in(fields, ["status", "name"]),
      branch_name: nil,
      url: issue_url(key),
      assignee_id: assignee_field(assignee, "accountId"),
      blocked_by: extract_blockers(fields),
      labels: extract_labels(fields),
      assigned_to_worker: assigned_to_worker?(assignee, assignee_filter),
      created_at: parse_datetime(fields["created"]),
      updated_at: parse_datetime(fields["updated"])
    }
  end

  defp normalize_issue(_issue, _assignee_filter), do: nil

  defp issue_url(nil), do: nil
  defp issue_url(key), do: Config.settings!().tracker.endpoint |> String.trim_trailing("/") |> Kernel.<>("/browse/#{key}")

  defp assignee_field(%{} = assignee, field), do: assignee[field]
  defp assignee_field(_assignee, _field), do: nil

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values}) do
    assignee
    |> assignee_id()
    |> then(fn
      nil -> false
      assignee_id -> MapSet.member?(match_values, assignee_id)
    end)
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp assignee_id(%{} = assignee), do: normalize_assignee_match_value(assignee["accountId"])

  defp routing_assignee_filter do
    case Config.settings!().tracker.assignee do
      nil -> {:ok, nil}
      assignee -> build_assignee_filter(assignee)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case normalize_assignee_match_value(assignee) do
      nil -> {:ok, nil}
      normalized -> {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp maybe_add_assignee_jql(jql, nil), do: jql
  defp maybe_add_assignee_jql(jql, %{configured_assignee: assignee}), do: jql <> " AND assignee = #{jql_string(assignee)}"

  defp issue_id_jql(ids) do
    {keys, numeric_ids} = Enum.split_with(ids, &String.match?(&1, ~r/^[A-Za-z][A-Za-z0-9]+-\d+$/))

    [
      maybe_jql_clause("key", keys),
      maybe_jql_clause("id", numeric_ids)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" OR ")
    |> then(&"(#{&1})")
  end

  defp maybe_jql_clause(_field, []), do: nil
  defp maybe_jql_clause(field, values), do: "#{field} in (#{Enum.map_join(values, ", ", &jql_string/1)})"

  defp jql_string(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    ~s("#{escaped}")
  end

  defp adf_to_text(nil), do: nil
  defp adf_to_text(text) when is_binary(text), do: text

  defp adf_to_text(%{} = node) do
    node
    |> adf_text_parts([])
    |> Enum.reverse()
    |> Enum.join("")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
    |> then(fn text -> if text == "", do: nil, else: text end)
  end

  defp adf_to_text(_value), do: nil

  defp adf_text_parts(%{"type" => "text", "text" => text}, acc) when is_binary(text), do: [text | acc]

  defp adf_text_parts(%{"type" => type, "content" => content}, acc) when is_list(content) do
    acc = Enum.reduce(content, acc, &adf_text_parts/2)

    if type in ["paragraph", "heading", "listItem"] do
      ["\n" | acc]
    else
      acc
    end
  end

  defp adf_text_parts(%{"content" => content}, acc) when is_list(content), do: Enum.reduce(content, acc, &adf_text_parts/2)
  defp adf_text_parts(_node, acc), do: acc

  defp extract_labels(%{"labels" => labels}) when is_list(labels), do: Enum.map(labels, &String.downcase(to_string(&1)))
  defp extract_labels(_), do: []

  defp extract_blockers(%{"issuelinks" => links}) when is_list(links) do
    Enum.flat_map(links, fn
      %{"type" => %{"inward" => inward}, "inwardIssue" => blocker_issue} when is_binary(inward) and is_map(blocker_issue) ->
        if String.downcase(inward) == "is blocked by", do: [blocked_issue(blocker_issue)], else: []

      _ ->
        []
    end)
  end

  defp extract_blockers(_), do: []

  defp blocked_issue(%{"fields" => fields} = issue) when is_map(fields) do
    %{id: issue["id"], identifier: issue["key"], state: get_in(fields, ["status", "name"])}
  end

  defp blocked_issue(issue), do: %{id: issue["id"], identifier: issue["key"], state: nil}

  defp parse_priority(%{"id" => id}) when is_binary(id) do
    case Integer.parse(id) do
      {priority, ""} -> priority
      _ -> nil
    end
  end

  defp parse_priority(_priority), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_raw), do: nil

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end
end
