# Symphony Elixir (GitLab CE)

This directory contains the Elixir/OTP Symphony runtime adapted for GitLab CE issue workflows.

## Implemented architecture

- Workflow loader + live reload (`WORKFLOW.md`)
- Typed runtime config with env indirection
- Polling orchestrator with dispatch/reconciliation/backoff
- Per-issue isolated workspaces with lifecycle hooks
- Codex app-server runner integration
- GitLab REST tracker adapter
- Terminal dashboard + optional HTTP observability API

## GitLab endpoints used

- `GET /projects/:id/issues`
- `GET /projects/:id/issues/:issue_iid`
- `PUT /projects/:id/issues/:issue_iid`
- `POST /projects/:id/issues/:issue_iid/notes`
- `GET /projects/:id/issues/:issue_iid/links`
- Optional dynamic tool compatibility: `POST /api/graphql`

## Configuration

`WORKFLOW.md` defines tracker, polling, workspace, hooks, agent, and codex behavior.

Primary env vars:

- `SYMPHONY_GITLAB_BASE_URL`
- `SYMPHONY_GITLAB_TOKEN`
- `SYMPHONY_GITLAB_PROJECT_ID`

Compatibility fallbacks are also supported:

- `GITLAB_URL`
- `PAT`
- `GITLAB_REPO`

## Run

```bash
cd elixir
mix deps.get
mix run --no-halt
```

CLI mode:

```bash
cd elixir
mix escript.build
./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails WORKFLOW.md
```

## Test

```bash
cd elixir
mix test
```
