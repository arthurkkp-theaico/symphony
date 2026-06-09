defmodule SymphonyElixir.Jira.Adapter do
  @moduledoc """
  Jira-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Jira.Client

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    case client_module().rest("POST", "/rest/api/3/issue/#{issue_id}/comment", %{"body" => adf_document(body)}) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, transition_id} <- resolve_transition_id(issue_id, state_name),
         {:ok, _response} <-
           client_module().rest("POST", "/rest/api/3/issue/#{issue_id}/transitions", %{
             "transition" => %{"id" => transition_id}
           }) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  defp resolve_transition_id(issue_id, state_name) do
    with {:ok, %{"transitions" => transitions}} when is_list(transitions) <-
           client_module().rest("GET", "/rest/api/3/issue/#{issue_id}/transitions", nil),
         %{"id" => id} when is_binary(id) <- Enum.find(transitions, &transition_matches?(&1, state_name)) do
      {:ok, id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end

  defp transition_matches?(transition, state_name) when is_map(transition) do
    expected_state = normalize_state(state_name)

    [transition["name"], get_in(transition, ["to", "name"])]
    |> Enum.filter(&is_binary/1)
    |> Enum.any?(&(normalize_state(&1) == expected_state))
  end

  defp transition_matches?(_transition, _state_name), do: false

  defp normalize_state(value), do: value |> String.trim() |> String.downcase()

  defp adf_document(body) do
    %{
      "type" => "doc",
      "version" => 1,
      "content" => [
        %{
          "type" => "paragraph",
          "content" => [
            %{
              "type" => "text",
              "text" => body
            }
          ]
        }
      ]
    }
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :jira_client_module, Client)
  end
end
