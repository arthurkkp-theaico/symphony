---
tracker:
  kind: jira
  endpoint: "https://theaicompany-team-a0c6o5ij.atlassian.net"
  board_url: "https://theaicompany-team-a0c6o5ij.atlassian.net/jira/servicedesk/projects/SD/boards/1"
  project_key: "SD"
  email: $JIRA_EMAIL
  api_key: $JIRA_API_TOKEN
  required_labels: []
  active_states:
    - Open
    - Triaged
    - Pending
    - Work in progress
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 5000
workspace:
  root: ~/code/doordash-data-platform-strawman-workspaces
  github_repository: arthurkkp-theaico/doordash-data-platform-strawman
hooks:
  after_create: |
    provider="${SYMPHONY_REPO_PROVIDER:-github}"
    case "$provider" in
      gitlab)
        repo_url="${SYMPHONY_GITLAB_REPO_URL:-file://${HOME}/code/gitlab-dummy/symphony-dummy.git}"
        ;;
      github|*)
        repo_url="${SYMPHONY_GITHUB_REPO_URL:-https://github.com/arthurkkp-theaico/doordash-data-platform-strawman.git}"
        ;;
    esac
    git clone --depth 1 "$repo_url" .
    if command -v uv >/dev/null 2>&1; then
      env -u VIRTUAL_ENV uv sync --all-groups
    fi
  before_remove: |
    provider="${SYMPHONY_REPO_PROVIDER:-github}"
    github_repo="${SYMPHONY_GITHUB_REPO:-arthurkkp-theaico/doordash-data-platform-strawman}"
    branch="$(git branch --show-current)"
    if [ -n "$branch" ] && command -v mise >/dev/null 2>&1; then
      symphony_elixir_dir="${SYMPHONY_ELIXIR_DIR:-${HOME}/Documents/Symphony/elixir}"
      cd "$symphony_elixir_dir"
      mise exec -- mix workspace.before_remove --provider "$provider" --repo "$github_repo" --branch "$branch"
    fi
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
---

You are working on a Jira ticket `{{ issue.identifier }}`

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the issue remains in an active state unless you are blocked by missing required permissions/secrets.
  {% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Only stop early for a true blocker (missing required auth/permissions/secrets). If blocked, record it in the workpad and move the issue according to workflow.
3. Final message must report completed actions and blockers only. Do not include "next steps for user".

Work only in the provided repository copy. Do not touch any other path.

## Prerequisite: Jira REST access is available

The agent should be able to talk to Jira via the injected `jira_rest` tool. If it is unavailable, stop and ask the user to configure Jira.

## Default posture

- Start by determining the ticket's current status, then follow the matching flow for that status.
- Start every task by opening the tracking workpad comment and bringing it up to date before doing new implementation work.
- Spend extra effort up front on planning and verification design before implementation.
- Reproduce first: always confirm the current behavior/issue signal before changing code so the fix target is explicit.
- Keep ticket metadata current (state, checklist, acceptance criteria, links).
- Treat a single persistent Jira comment as the source of truth for progress.
- Use that single workpad comment for all progress and handoff notes; do not post separate "done"/summary comments.
- Treat any ticket-authored `Validation`, `Test Plan`, or `Testing` section as non-negotiable acceptance input: mirror it in the workpad and execute it before considering the work complete.
- Treat this workflow's review and merge lifecycle as authoritative over conflicting ticket prose. A request to "close" or "complete" workflow verification never permits skipping `Ready for review`, human approval, or PR merge.
- When meaningful out-of-scope improvements are discovered during execution,
  file a separate Jira issue instead of expanding scope. The follow-up issue
  must include a clear title, description, and acceptance criteria, be placed in
  `Backlog`, be assigned to the same project as the current issue, link the
  current issue as `related`, and use a blocking relationship when the follow-up depends on
  the current issue.
- Move status only when the matching quality bar is met.
- Operate autonomously end-to-end unless blocked by missing requirements, secrets, or permissions.
- Use the blocked-access escape hatch only for true external blockers (missing required tools/auth) after exhausting documented fallbacks.

## Repository operations

- `jira_rest`: interact with Jira through the injected dynamic tool.
- Use standard `git` and authenticated `gh` commands for branch, commit, push, PR, review, and merge operations.
- Name every GitHub implementation branch with the lowercase Jira key, for example `codex/sd-14-short-description`; the terminal-state guard binds the PR to the issue through this key.
- Run `make test` as the default local validation gate; add narrower or broader checks when the ticket requires them.
- The target repository does not contain Symphony's repo-local workflow skills. Do not require `.codex/skills/*` files to proceed.

## Repository provider

- Default provider is GitHub:
  - `SYMPHONY_REPO_PROVIDER=github`
  - `SYMPHONY_GITHUB_REPO_URL=https://github.com/arthurkkp-theaico/doordash-data-platform-strawman.git`
  - `SYMPHONY_GITHUB_REPO=arthurkkp-theaico/doordash-data-platform-strawman`
- Dummy GitLab provider is available for demos:
  - `SYMPHONY_REPO_PROVIDER=gitlab`
  - `SYMPHONY_GITLAB_REPO_URL=file://${HOME}/code/gitlab-dummy/symphony-dummy.git`
- In GitLab dummy mode, use ordinary `git` operations against `origin`. Do not call GitHub-only `gh pr ...` commands unless the workspace remote is GitHub again.
- If no GitLab MR tool/auth is configured, record branch, commit, and validation proof in the workpad instead of treating MR automation as available.

## Status map

- `Backlog` -> out of scope for this workflow; do not modify.
- `Open` -> queued; immediately use Jira's `Assign` transition to move into `Triaged` before active work.
  - Special case: if a PR is already attached, treat as feedback/rework loop (run full PR feedback sweep, address or explicitly push back, revalidate, return to `Ready for review`).
- `Triaged` -> implementation actively underway.
- `In Progress` -> implementation actively underway.
- `Pending` -> worker is actively executing the issue.
- `Work in progress` -> worker is actively executing the issue.
- `Ready for review` -> PR is attached and validated; waiting on human approval.
- `Merging` -> approved by human; validate, wait for green checks, then squash-merge with `gh`.
- `Rework` -> reviewer requested changes; planning + implementation required.
- `Done` -> terminal state; no further action required.

## Step 0: Determine current ticket state and route

1. Fetch the issue by explicit ticket ID using Jira REST.
2. Read the current state.
3. Route to the matching flow:
   - `Backlog` -> do not modify issue content/state; stop and wait for human to move it to `Open`.
   - `Open` -> immediately move to `Triaged` using Jira's `Assign` transition, then ensure bootstrap workpad comment exists (create if missing), then start execution flow.
     - If PR is already attached, start by reviewing all open PR comments and deciding required changes vs explicit pushback responses.
   - `Triaged` -> continue execution flow from current scratchpad comment, creating it first if missing.
   - `In Progress` -> continue execution flow from current scratchpad comment.
   - `Pending` -> continue execution flow from current scratchpad comment.
   - `Work in progress` -> continue execution flow from current scratchpad comment.
   - `Ready for review` -> wait and poll for decision/review updates.
   - `Merging` -> run the merge flow in Step 3.
   - `Rework` -> run rework flow.
   - `Done` -> do nothing and shut down.
4. Check whether a PR already exists for the current branch and whether it is closed.
   - If a branch PR exists and is `CLOSED` or `MERGED`, treat prior branch work as non-reusable for this run.
   - Create a fresh branch from `origin/main` and restart execution flow as a new attempt.
5. For `Open` tickets, do startup sequencing in this exact order:
   - transition issue to `Triaged` with Jira's `Assign` transition
   - find/create `## Codex Workpad` bootstrap comment
   - only then begin analysis/planning/implementation work.
6. Add a short comment if state and issue content are inconsistent, then proceed with the safest flow.

## Step 1: Start/continue execution (Open, Triaged, In Progress, Pending, or Work in progress)

1.  Find or create a single persistent scratchpad comment for the issue:
    - Search existing comments for a marker header: `## Codex Workpad`.
    - Ignore resolved comments while searching; only active/unresolved comments are eligible to be reused as the live workpad.
    - If found, reuse that comment; do not create a new workpad comment.
    - If not found, create one workpad comment and use it for all updates.
    - Persist the workpad comment ID and only write progress updates to that ID.
2.  If arriving from `Open`, do not delay on additional status transitions: the issue should already be `Triaged` before this step begins.
3.  Immediately reconcile the workpad before new edits:
    - Check off items that are already done.
    - Expand/fix the plan so it is comprehensive for current scope.
    - Ensure `Acceptance Criteria` and `Validation` are current and still make sense for the task.
4.  Start work by writing/updating a hierarchical plan in the workpad comment.
5.  Ensure the workpad includes a compact environment stamp at the top as a code fence line:
    - Format: `<host>:<abs-workdir>@<short-sha>`
    - Example: `devbox-01:/home/dev-user/code/symphony-workspaces/MT-32@7bdde33bc`
    - Do not include metadata already inferable from Jira issue fields (`issue ID`, `status`, `branch`, `PR link`).
6.  Add explicit acceptance criteria and TODOs in checklist form in the same comment.
    - If changes are user-facing, include a UI walkthrough acceptance criterion that describes the end-to-end user path to validate.
    - If changes affect platform behavior or Compose services, add explicit flow checks to `Acceptance Criteria` (launch path, changed interaction, and expected result).
    - If the ticket description/comment context includes `Validation`, `Test Plan`, or `Testing` sections, copy those requirements into the workpad `Acceptance Criteria` and `Validation` sections as required checkboxes (no optional downgrade).
7.  Run a principal-style self-review of the plan and refine it in the comment.
8.  Before implementing, capture a concrete reproduction signal and record it in the workpad `Notes` section (command/output, screenshot, or deterministic UI behavior).
9.  Fetch and merge the latest `origin/main` before any code edits, then record the sync result in the workpad `Notes`.
    - Include a `main sync evidence` note with:
      - merge source(s),
      - result (`clean` or `conflicts resolved`),
      - resulting `HEAD` short SHA.
10. Compact context and proceed to execution.

## PR feedback sweep protocol (required)

When a ticket has an attached PR, run this protocol before moving to `Ready for review`:

1. Identify the PR number from issue links/attachments.
2. Gather feedback from all channels:
   - Top-level PR comments (`gh pr view --comments`).
   - Inline review comments (`gh api repos/<owner>/<repo>/pulls/<pr>/comments`).
   - Review summaries/states (`gh pr view --json reviews`).
3. Treat every actionable reviewer comment (human or bot), including inline review comments, as blocking until one of these is true:
   - code/test/docs updated to address it, or
   - explicit, justified pushback reply is posted on that thread.
4. Update the workpad plan/checklist to include each feedback item and its resolution status.
5. Re-run validation after feedback-driven changes and push updates.
6. Repeat this sweep until there are no outstanding actionable comments.

## Blocked-access escape hatch (required behavior)

Use this only when completion is blocked by missing required tools or missing auth/permissions that cannot be resolved in-session.

- GitHub is **not** a valid blocker by default. Always try fallback strategies first (alternate remote/auth mode, then continue publish/review flow).
- Do not move to `Ready for review` for GitHub access/auth until all fallback strategies have been attempted and documented in the workpad.
- If a non-GitHub required tool is missing, or required non-GitHub auth is unavailable, move the ticket to `Ready for review` with a short blocker brief in the workpad that includes:
  - what is missing,
  - why it blocks required acceptance/validation,
  - exact human action needed to unblock.
- Keep the brief concise and action-oriented; do not add extra top-level comments outside the workpad.

## Step 2: Execution phase (Open -> Triaged -> Ready for review)

1.  Determine current repo state (`branch`, `git status`, `HEAD`) and verify the kickoff `pull` sync result is already recorded in the workpad before implementation continues.
2.  If current issue state is `Open`, move it to `Triaged` with Jira's `Assign` transition; otherwise leave the current state unchanged.
3.  Load the existing workpad comment and treat it as the active execution checklist.
    - Edit it liberally whenever reality changes (scope, risks, validation approach, discovered tasks).
4.  Implement against the hierarchical TODOs and keep the comment current:
    - Check off completed items.
    - Add newly discovered items in the appropriate section.
    - Keep parent/child structure intact as scope evolves.
    - Update the workpad immediately after each meaningful milestone (for example: reproduction complete, code change landed, validation run, review feedback addressed).
    - Never leave completed work unchecked in the plan.
    - For tickets that started as `Open` with an attached PR, run the full PR feedback sweep protocol immediately after kickoff and before new feature work.
5.  Run validation/tests required for the scope.
    - Mandatory gate: execute all ticket-provided `Validation`/`Test Plan`/ `Testing` requirements when present; treat unmet items as incomplete work.
    - Prefer a targeted proof that directly demonstrates the behavior you changed.
    - You may make temporary local proof edits to validate assumptions (for example: tweak a local build input for `make`, or hardcode a UI account / response path) when this increases confidence.
    - Revert every temporary proof edit before commit/push.
    - Document these temporary proof steps and outcomes in the workpad `Validation`/`Notes` sections so reviewers can follow the evidence.
    - For runtime-touching changes, run the relevant documented `make` flow and record its deterministic output before handoff.
6.  Re-check all acceptance criteria and close any gaps.
7.  Before every `git push` attempt, run the required validation for your scope and confirm it passes; if it fails, address issues and rerun until green, then commit and push changes.
8.  Attach PR URL to the issue (prefer attachment/link fields; use the workpad comment only if attachment is unavailable).
9.  Merge latest `origin/main` into branch, resolve conflicts, and rerun checks.
10. Update the workpad comment with final checklist status and validation notes.
    - Mark completed plan/acceptance/validation checklist items as checked.
    - Add final handoff notes (commit + validation summary) in the same workpad comment.
    - Do not include PR URL in the workpad comment when Jira attachment/link fields are available.
    - Add a short `### Confusions` section at the bottom when any part of task execution was unclear/confusing, with concise bullets.
    - Do not post any additional completion summary comment.
11. Before moving to `Ready for review`, poll PR feedback and checks:
    - Read the PR `Manual QA Plan` comment (when present) and use it to sharpen UI/runtime test coverage for the current change.
    - Run the full PR feedback sweep protocol.
    - Confirm PR checks are passing (green) after the latest changes.
    - Confirm every required ticket-provided validation/test-plan item is explicitly marked complete in the workpad.
    - Repeat this check-address-verify loop until no outstanding comments remain and checks are fully passing.
    - Re-open and refresh the workpad before state transition so `Plan`, `Acceptance Criteria`, and `Validation` exactly match completed work.
12. Only then move issue to `Ready for review`.
    - Exception: if blocked by missing required non-GitHub tools/auth per the blocked-access escape hatch, move to `Ready for review` with the blocker brief and explicit unblock actions.
    - If Jira does not expose the required transition, keep the issue in its current non-terminal state, record the workflow mismatch in the workpad, and report the blocker. Never substitute a terminal or nearest-available transition.
13. For `Open` tickets that already had a PR attached at kickoff:
    - Ensure all existing PR feedback was reviewed and resolved, including inline review comments (code changes or explicit, justified pushback response).
    - Ensure branch was pushed with any required updates.
    - Then move to `Ready for review`.

## Step 3: Ready for review and merge handling

1. When the issue is in `Ready for review`, do not code or change ticket content.
2. Poll for updates as needed, including GitHub PR review comments from humans and bots.
3. If review feedback requires changes, move the issue to `Rework` and follow the rework flow.
4. If approved, human moves the issue to `Merging` with Jira's `Approve for merge` transition.
5. When the issue is in `Merging`, run `make test`, resolve all actionable review feedback, wait for `gh pr checks` to pass, then run `gh pr merge --squash --delete-branch`. Keep working until the PR is merged or a true external blocker is recorded.
6. After merge is complete, move the issue to `Done` with Jira's `Finish merge` transition.

## Step 4: Rework handling

1. Treat `Rework` as a full approach reset, not incremental patching.
2. Re-read the full issue body and all human comments; explicitly identify what will be done differently this attempt.
3. Close the existing PR tied to the issue.
   - Remove that PR's Jira remote link before attaching its replacement; the issue must have exactly one active implementation PR link.
4. Remove the existing `## Codex Workpad` comment from the issue.
5. Create a fresh branch from `origin/main`.
6. Start over from the normal kickoff flow:
   - If current issue state is `Open`, move it to `Triaged` with Jira's `Assign` transition; otherwise keep the current state.
   - Create a new bootstrap `## Codex Workpad` comment.
   - Build a fresh plan/checklist and execute end-to-end.

## Completion bar before Ready for review

- Step 1/2 checklist is fully complete and accurately reflected in the single workpad comment.
- Acceptance criteria and required ticket-provided validation items are complete.
- Validation/tests are green for the latest commit.
- PR feedback sweep is complete and no actionable comments remain.
- PR checks are green, branch is pushed, and PR is linked on the issue.
- Runtime-touching changes have deterministic evidence from the relevant documented `make` flow.

## Guardrails

- If the branch PR is already closed/merged, do not reuse that branch or prior implementation state for continuation.
- For closed/merged branch PRs, create a new branch from `origin/main` and restart from reproduction/planning as if starting fresh.
- If issue state is `Backlog`, do not modify it; wait for human to move to `Open`.
- Do not edit the issue body/description for planning or progress tracking.
- Use exactly one persistent workpad comment (`## Codex Workpad`) per issue.
- If comment editing is unavailable in-session, use the Jira REST fallback. Only report blocked if both direct tool use and fallback REST editing are unavailable.
- Temporary proof edits are allowed only for local verification and must be reverted before commit.
- If out-of-scope improvements are found, create a separate Backlog issue rather
  than expanding current scope, and include a clear
  title/description/acceptance criteria, same-project assignment, a `related`
  link to the current issue, and a blocking relationship when the follow-up depends on the
  current issue.
- Do not move to `Ready for review` unless the `Completion bar before Ready for review` is satisfied.
- Do not enter a Done-category state unless the issue is already in `Merging` and the linked PR is confirmed merged.
- Never substitute another Jira transition when the required target state is unavailable.
- In `Ready for review`, do not make changes; wait and poll.
- If state is terminal (`Done`), do nothing and shut down.
- Keep issue text concise, specific, and reviewer-oriented.
- If blocked and no workpad exists yet, add one blocker comment describing blocker, impact, and next unblock action.

## Workpad template

Use this exact structure for the persistent workpad comment and keep it updated in place throughout execution:

````md
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan

- [ ] 1\. Parent task
  - [ ] 1.1 Child task
  - [ ] 1.2 Child task
- [ ] 2\. Parent task

### Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2

### Validation

- [ ] targeted tests: `<command>`

### Notes

- <short progress note with timestamp>

### Confusions

- <only include when something was confusing during execution>
````
