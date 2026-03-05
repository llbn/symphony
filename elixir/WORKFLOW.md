---
tracker:
  kind: gitlab
  endpoint: "$SYMPHONY_GITLAB_BASE_URL"
  api_key: "$SYMPHONY_GITLAB_TOKEN"
  project_id: "$SYMPHONY_GITLAB_PROJECT_ID"
  active_states: ["opened"]
  terminal_states: ["closed"]
polling:
  interval_ms: 30000
workspace:
  root: null
agent:
  max_concurrent_agents: 10
  max_turns: 20
  max_retry_backoff_ms: 300000
  max_concurrent_agents_by_state: {}
codex:
  command: "codex app-server"
  approval_policy:
    reject:
      sandbox_approval: true
      rules: true
      mcp_elicitations: true
  thread_sandbox: "workspace-write"
  turn_timeout_ms: 3600000
  read_timeout_ms: 5000
  stall_timeout_ms: 300000
hooks:
  timeout_ms: 60000
observability:
  dashboard_enabled: true
  refresh_ms: 1000
  render_interval_ms: 16
---
You are working on a GitLab issue.

Issue: {{ issue.identifier }}
Title: {{ issue.title }}

{% if issue.description %}
Description:
{{ issue.description }}
{% endif %}

If `attempt` is present, this is retry attempt {{ attempt }}.
