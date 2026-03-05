---
name: gitlab
description: |
  Use Symphony's `gitlab_graphql` client tool for raw GitLab GraphQL
  operations during Codex app-server turns.
---

# GitLab GraphQL

Use this skill for ad-hoc GitLab GraphQL calls when the built-in REST tracker
flow is not enough for a specific run.

## Primary tool

Use the `gitlab_graphql` client tool exposed by Symphony's app-server session.
It reuses Symphony's configured GitLab auth for the session.

Tool input:

```json
{
  "query": "query or mutation document",
  "variables": {
    "optional": "graphql variables object"
  }
}
```

You can also pass a raw query string directly as the arguments payload.

Tool behavior:

- Keep one operation per tool call.
- A top-level `errors` array is treated as a failed operation
  (`"success": false`) even if transport succeeded.
- `operationName` is ignored by the tool wrapper; send a single operation
  document to avoid ambiguity errors.

## Discovering unfamiliar operations

When you need an unfamiliar mutation, input object, or field, use targeted
introspection through `gitlab_graphql`.

List root query fields:

```graphql
query QueryFields {
  __type(name: "Query") {
    fields {
      name
    }
  }
}
```

List root mutation fields:

```graphql
query MutationFields {
  __type(name: "Mutation") {
    fields {
      name
    }
  }
}
```

Inspect a specific type:

```graphql
query TypeShape($name: String!) {
  __type(name: $name) {
    name
    kind
    fields {
      name
    }
    inputFields {
      name
    }
  }
}
```

## Common workflows

### Verify auth + endpoint wiring

```graphql
query CurrentUser {
  currentUser {
    id
    username
    name
  }
}
```

### Query a project issue by IID

Use project full path (for example `group/subgroup/project`) plus issue IID.

```graphql
query IssueByIid($fullPath: ID!, $iid: String!) {
  project(fullPath: $fullPath) {
    issue(iid: $iid) {
      id
      iid
      title
      state
      webUrl
      updatedAt
    }
  }
}
```

### Fetch issue notes/comments

```graphql
query IssueNotes($fullPath: ID!, $iid: String!) {
  project(fullPath: $fullPath) {
    issue(iid: $iid) {
      notes {
        nodes {
          id
          body
          createdAt
          author {
            username
          }
        }
      }
    }
  }
}
```

### Discover mutation input before writing

Use introspection first, then run the mutation only after field names and input
shape are confirmed for the target GitLab instance/version.

## Usage rules

- Prefer built-in tracker behavior for normal issue polling/comment/state flows;
  use `gitlab_graphql` only for targeted runtime gaps.
- Keep selection sets minimal to reduce payload size and parsing overhead.
- If a call fails with auth/transport errors, verify `tracker.api_key` in
  `WORKFLOW.md` or `GITLAB_API_KEY` in the environment.
- Do not add raw token shell helpers for GraphQL; use the dynamic tool.
