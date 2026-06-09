defmodule Mix.Tasks.Workspace.BeforeRemove do
  use Mix.Task

  @shortdoc "Close open review requests for the current branch before workspace removal"

  @moduledoc """
  Closes open review requests for the current Git branch when the configured
  repository provider supports it.

  This task is intended for use from the `before_remove` workspace hook.

  Usage:

      mix workspace.before_remove
      mix workspace.before_remove --branch feature/my-branch
      mix workspace.before_remove --repo arthurkkp-theaico/symphony
      mix workspace.before_remove --provider gitlab --branch feature/my-branch
  """

  @default_provider "github"
  @default_github_repo "arthurkkp-theaico/symphony"

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [branch: :string, help: :boolean, provider: :string, repo: :string],
        aliases: [h: :help]
      )

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        provider = opts[:provider] || System.get_env("SYMPHONY_REPO_PROVIDER") || @default_provider
        repo = opts[:repo] || default_repo(provider)
        branch = opts[:branch] || current_branch()

        maybe_close_open_review_requests(provider, repo, branch)
    end
  end

  defp maybe_close_open_review_requests(_provider, _repo, nil), do: :ok

  defp maybe_close_open_review_requests("github", repo, branch) do
    if gh_available?() and gh_authenticated?() do
      repo
      |> list_open_pull_request_numbers(branch)
      |> Enum.each(&close_pull_request(repo, branch, &1))
    end

    :ok
  end

  defp maybe_close_open_review_requests("gitlab", _repo, _branch), do: :ok
  defp maybe_close_open_review_requests("none", _repo, _branch), do: :ok

  defp maybe_close_open_review_requests(provider, _repo, _branch) do
    Mix.raise("Unsupported repository provider: #{inspect(provider)}")
  end

  defp default_repo("github"), do: System.get_env("SYMPHONY_GITHUB_REPO") || @default_github_repo
  defp default_repo(_provider), do: nil

  defp gh_available? do
    not is_nil(System.find_executable("gh"))
  end

  defp gh_authenticated? do
    match?({:ok, _output}, run_command("gh", ["auth", "status"]))
  end

  defp list_open_pull_request_numbers(repo, branch) do
    case run_command("gh", [
           "pr",
           "list",
           "--repo",
           repo,
           "--head",
           branch,
           "--state",
           "open",
           "--json",
           "number",
           "--jq",
           ".[].number"
         ]) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.reject(&(&1 == ""))

      {:error, _reason} ->
        []
    end
  end

  defp close_pull_request(repo, branch, pr_number) do
    case run_command("gh", [
           "pr",
           "close",
           pr_number,
           "--repo",
           repo,
           "--comment",
           closing_comment(branch)
         ]) do
      {:ok, _output} ->
        Mix.shell().info("Closed PR ##{pr_number} for branch #{branch}")

      {:error, {status, output}} ->
        trimmed_output = String.trim(output)

        Mix.shell().error("Failed to close PR ##{pr_number} for branch #{branch}: exit #{status}#{format_output(trimmed_output)}")
    end
  end

  defp closing_comment(branch) do
    "Closing because the tracker issue for branch #{branch} entered a terminal state without merge."
  end

  defp format_output(""), do: ""
  defp format_output(output), do: " output=#{inspect(output)}"

  defp current_branch do
    case run_command("git", ["branch", "--show-current"]) do
      {:ok, output} ->
        case String.trim(output) do
          "" -> nil
          branch -> branch
        end

      {:error, _reason} ->
        nil
    end
  end

  defp run_command(command, args) do
    case System.find_executable(command) do
      nil ->
        {:error, {:enoent, ""}}

      path ->
        case System.cmd(path, args, stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {output, status} -> {:error, {status, output}}
        end
    end
  end
end
