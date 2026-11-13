# Changelog

All notable changes to this repository are documented here. Versions follow
[Semantic Versioning](https://semver.org).

## v1.1.0

- Reusable workflow `secret-scan`: gitleaks over the whole history, built from a pinned
  commit of a repository you choose (for example your fork), cached per commit.

## v1.0.0

- Reusable workflows: `build-java`, `build-dotnet`, `deploy`, `codeql`, `dependency-review`.
- Composite actions: `container-publish`, `smoke-test`.
- Selftest workflow (actionlint, shellcheck, composite action tests) and release workflow
  that moves the major tag.
