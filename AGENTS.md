# Repository Guidelines

## Project Structure & Module Organization

```text
repo
|-- SPEC.md                 # behavior contract
|-- README.md               # overview
|-- docs/                   # explainers
|-- .github/                # CI and PR template
`-- elixir/
    |-- lib/symphony_elixir/      # orchestration, config, trackers
    |-- lib/symphony_elixir_web/  # Phoenix dashboard/API
    |-- lib/mix/tasks/            # validation tasks
    |-- test/                     # ExUnit tests/fixtures
    |-- priv/static/              # dashboard assets
    |-- WORKFLOW.md               # workflow config
    `-- Makefile                  # dev/CI entrypoints
```

## Architecture Overview

```text
Architecture dashboard
+-------------+     +---------------------+     +----------------------+
| Tracker     | --> | Orchestrator        | --> | Workspace + Codex    |
| Linear/Jira |     | retries/state/logs  |     | app-server sessions  |
+-------------+     +----------+----------+     +----------------------+
                            |
                            v
                 +-----------------------+
                 | Phoenix Observability|
                 | LiveView + JSON API  |
                 +-----------------------+
```

Keep behavior aligned with `SPEC.md`; update it when behavior changes.

## Build, Test, and Development Commands

- `mise install`: install Elixir/Erlang.
- `mix setup` or `make setup`: fetch Mix dependencies.
- `mix build` or `make build`: build `bin/symphony`.
- `make test`: run ExUnit tests.
- `make coverage`: run tests with coverage.
- `make lint`: run `mix specs.check` and `credo --strict`.
- `make all`: full gate: setup, build, format check, lint, coverage, dialyzer.
- `make e2e`: live external test requiring `LINEAR_API_KEY`.

## Coding Style & Naming Conventions

- Run commands from `elixir/`; use `mix format`.
- Keep public `def` functions in `lib/` paired with adjacent `@spec`; `defp` specs are optional.
- Prefer `SymphonyElixir.Config` over ad hoc environment reads.
- Use `SymphonyElixir.*` for core code and `SymphonyElixirWeb.*` for Phoenix code.
- Keep Codex turn working directories inside configured workspace roots.

## Testing Guidelines

- Place tests under `elixir/test/**/*_test.exs`.
- Use `mix test path/to/test.exs` while iterating, then run `make all`.
- Snapshot fixtures live in `elixir/test/fixtures/`; update only for intentional output changes.
- Live e2e tests are opt-in through `SYMPHONY_RUN_LIVE_E2E=1` via `make e2e`.

## Commit & Pull Request Guidelines

- Use concise subjects; fixes often use `fix(elixir): ...`.
- Keep changes narrow and avoid unrelated refactors.
- PR bodies must follow `.github/pull_request_template.md`.
- Include `make -C elixir all` and targeted checks in the test plan.

## Security & Configuration Tips

- Do not commit tokens or generated local logs.
- `LINEAR_API_KEY`, `JIRA_EMAIL`, and `JIRA_API_TOKEN` should come from the environment.
- Review `WORKFLOW.md`, workspace hooks, SSH, and Codex sandbox changes carefully.
