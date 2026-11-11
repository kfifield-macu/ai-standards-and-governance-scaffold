# Agent standards

Canonical instructions for any AI agent working in repos that adopt these standards.
Provider-specific files (`CLAUDE.md`, `.github/copilot-instructions.md`) are generated from this file by `scripts/sync.sh`. Edit this file only.

## Secrets (non-negotiable)

- Never read, print, search for, copy or otherwise handle secrets or credentials.
- You may be told where secrets live (for example `profile:newrelic/readonly`). Reference the name only. Never open the location.
- Do not run commands that dump environment or credentials (`env`, `printenv`, `kubectl get secret`, sensitive variable listings).
- If a tool fails authentication, report `auth_failed` and the tool name. Do not try to fix it by locating credentials.

## Capabilities

- Work happens inside a capability (`capabilities/<name>.yaml`). Stay within its inputs, outputs and permissions.
- Default is deny. Use only the tools and operations the capability permits.
- Never declare the target environment yourself. The harness provides it.
- Prefer read operations first. Writes outside dev need human approval.

## Errors

Report failures as one line: `<category>: <cause>`. Categories: `auth_failed`, `permission_denied`, `budget_exceeded`, `secret_detected`, `tool_unavailable`, `invalid_input`. Never include credential material.

## Validation

Run `pwsh -NoProfile -File scripts/validate.ps1` after changing anything under `capabilities/`, `context/`, `governors/`, `permissions/`, `observability/` or `evals/`.
