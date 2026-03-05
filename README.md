# Symphony (GitLab CE)

This repository contains a GitLab-adapted Symphony implementation aligned to [`SPEC.md`](./SPEC.md).

## Repository structure

- `SPEC.md`: Symphony service specification
- `elixir/`: Elixir/OTP implementation of the GitLab-backed orchestrator
- `.gitlab-ci.yml`: GitLab CI pipeline (`make all` + MR description lint)
- `.gitlab/merge_request_templates/`: merge request description templates

## Elixir implementation

See [`elixir/README.md`](./elixir/README.md) for setup, configuration, and runtime details.

## License

Licensed under the [Apache License 2.0](./LICENSE).
