# Agent Standards Scaffold

A provider-agnostic standard for governing AI agents (Claude, GitHub Copilot, and others). It answers five questions, each with its own spec:

| # | Standard | Question it answers | Where |
|---|----------|---------------------|-------|
| 1 | **Capability interface** | What can be asked for? | `capabilities/`, `schemas/capability.schema.json` |
| 2 | **Context templates** | What gets sent? | `context/` |
| 3 | **Token governors** | How much can be used? | `governors/`, `schemas/governor.schema.json` |
| 4 | **Agent permissions** | What can it do? | `permissions/`, `schemas/permissions.schema.json` |
| 5 | **Observability** | What crossed, and what was recorded? | `observability/` |

This folder is **specs and schemas only**. It defines the contract and validates it. Enforcement (a gateway, an MCP proxy, a host harness) is built against it separately.

## Contents

- [Design principles](#design-principles)
- [Layout](#layout)
- [The capability is the root](#the-capability-is-the-root)
- [1. Capability interface](#1-capability-interface)
- [2. Context templates](#2-context-templates)
- [3. Token governors](#3-token-governors)
- [4. Agent permissions](#4-agent-permissions)
- [5. Observability](#5-observability)
- [The secrets invariant](#the-secrets-invariant)
- [Conformance levels](#conformance-levels)
- [Precedence](#precedence)
- [Evals](#evals)
- [Skills and agents](#skills-and-agents)
- [Provider portability](#provider-portability)
- [Tooling](#tooling)
- [Boundaries and assumptions](#boundaries-and-assumptions)
- [Open decisions](#open-decisions)
- [Adding a capability](#adding-a-capability)

## Design principles

1. **Capability is the root.** Ownership, permissions, budget and audit all trace to one named capability with one owner.
2. **Adopt, don't invent.** AGENTS.md for instructions, Agent Skills (`SKILL.md`) for playbooks, OpenTelemetry GenAI conventions for traces, MCP for tools. Only the capability manifest and its permission and budget fields are new.
3. **Default deny.** Nothing is allowed unless a capability says so and the org ceiling permits it.
4. **Honest enforcement.** Every rule says whether it is `advisory` or `enforced`, so a consumer knows what is actually guaranteed.
5. **Secrets are never an agent concern.** See [the secrets invariant](#the-secrets-invariant).
6. **One trace, not another log.** Audit is OpenTelemetry spans, not a parallel logging system.

## Layout

```
.
├── AGENTS.md                      canonical agent instructions (source for CLAUDE.md, copilot-instructions.md)
├── README.md                      this file
├── presentation.md                team-meeting summary
├── capabilities/                  one manifest per capability
│   ├── code-review.yaml
│   └── troubleshooting.yaml
├── context/                       context templates (Markdown + front matter)
├── governors/                     token governors (org-defaults + per capability)
├── permissions/
│   ├── invariants.yaml            GLOBAL secrets invariant (cannot be overridden)
│   ├── org-defaults.yaml          org ceiling; capabilities may only narrow it
│   ├── <capability>.yaml          per-capability policy
│   └── tools/                     tool descriptors (newrelic, octopus, git)
├── observability/                 required attributes, error taxonomy, example trace
├── models/tiers.yaml              logical tier -> provider model ID (also the valid providers for pins)
├── evals/<capability>/            minimal eval files
├── schemas/                       JSON Schemas for every file type
├── skills/                        stub (see skills/README.md)
├── agents/                        stub (see agents/README.md)
└── scripts/
    ├── validate.ps1               schema + cross-file rule checks (PowerShell 7)
    └── sync.sh                    generate provider files from AGENTS.md
```

## The capability is the root

A capability manifest is the single document that ties the five standards together. It points to a context template, a governor and a permissions policy, and carries the owner, version, status and model (a tier, specific models, or both).

```yaml
apiVersion: agent-standards/v1
name: troubleshooting
version: 0.1.0
status: draft                # draft | active | deprecated
owner: platform-team@example.com
conformance: L2              # L1 | L2 | L3
model: { tier: balanced }    # tier and/or pin: { provider: model-id }
context: context/troubleshooting.md
governor: governors/troubleshooting.yaml
permissions: permissions/troubleshooting.yaml
observability: { content_capture: false, retention_days: 30, redact: true }
auth:
  profiles: [profile:newrelic/readonly, profile:octopus/readonly]   # references only
evals: evals/troubleshooting/
```

## 1. Capability interface

Defines what users and services can ask for.

- **Typed inputs and outputs** are JSON Schema inside the manifest (`inputs`, `outputs`).
- **Model: tier, specific models, or both.** A capability sets `model.tier` (`fast | balanced | deep`), `model.pin` (a map of provider to exact model ID), or both. At least one is required.
  - The **tier** resolves through `models/tiers.yaml`, so a model change touches one file. It is the portable default.
  - A **pin** names a specific model for a provider, for capabilities that need one.
  - **Resolution** for the active provider: a pin for that provider wins, otherwise the tier mapping. With neither, the run fails with `tool_unavailable`.
  - Pin provider names must exist in `models/tiers.yaml`. Governor `downgrade_to` still uses tiers.

  ```yaml
  model:
    tier: balanced                       # portable default
    pin: { anthropic: claude-sonnet-5-5 } # Anthropic always uses this; others use the tier
  ```
- **Lifecycle.** `status` is `draft`, `active` or `deprecated`. `version` is semver. A change to permissions or budgets requires owner review.
- **Required owner.** A capability without an owner is rejected ("Nobody has decided this").
- **Evals** are required at L2 and above (see [evals](#evals)).
- **Exposure.** The manifest is the source. Adapters are generated from it: Agent Skills for IDE and CLI hosts, MCP prompt or tool for services.

## 2. Context templates

Define what is sent to the agent. Markdown with front matter:

```markdown
---
attach: [diff, CONTRIBUTING.md, style-guide]
---
Review this diff against our style guide.
Return findings as a table, ranked by severity.
```

Rules:

- **Resolver contract.** Each `attach` name is resolved by a resolver: source name in, content out. The standard does not say who runs the resolver (host, library or gateway).
- **Attach only what is permitted.** A template may attach only sources listed in its capability's `attach_sources`. The validator enforces this.
- **Redact before send.** Redaction runs after resolution and before anything leaves for the provider.
- **Record what was attached** in the trace.

## 3. Token governors

Define how much a capability may use and what happens at the limit.

```yaml
# governors/troubleshooting.yaml
apiVersion: agent-standards/v1
enforcement: enforced
budget: { amount: 400, currency: USD, period: month, scope: capability }
limits:
  - { requests: 20, per: developer, period: day }
on_limit: queue          # queue, don't deny
```

- **`on_limit`:** `queue | deny | downgrade | approve`. `downgrade` requires `downgrade_to` (a cheaper tier). `approve` pauses for a human.
- **Scopes:** `developer | team | capability | org`.
- **Meaning, not mechanics.** The standard defines what a limit means. Counting is the enforcer's job.
- **Enforcement field.** For developer-side agents (IDE, CLI) most governors are `advisory`. They become `enforced` behind a gateway.

## 4. Agent permissions

Define what an agent can and cannot actually do. Policy rules are written in **CEL** over a tool-call input document. The Kyverno `ValidatingPolicy` shape is the model, but Kyverno is not required, because agents also use tools Kyverno has no scope over (`newrelic`, `octopus`). Kyverno remains an optional adapter for Kubernetes tools.

```yaml
# permissions/troubleshooting.yaml (excerpt)
default: deny
tools:
  - tool: octopus
    operations: [release.list, deployment.status, deployment.redeploy]
rules:
  - name: no-writes-outside-dev
    enforcement: enforced
    expression: >-
      tool_call.risk != "read" && target.environment != "dev"
    decision: approve
    message: "Writes outside dev need human approval."
```

### Tool descriptors

The agent never supplies a raw command string. Each tool has a descriptor (`permissions/tools/*.yaml`) listing its operations, each with:

- a **`risk`** class: `read | write | destructive`,
- an **argument schema** (JSON Schema),
- a fixed **command template** the harness fills in,
- how the **target** is derived.

Where an MCP tool definition already exists, reuse it and add only the risk and auth fields. CLI descriptors are for tools with no MCP server. Matching raw command lines is deliberately not supported, since it is fragile and easy to bypass.

### Target and environment

The permission input includes `target.environment` (and account or cluster). The **harness or tool descriptor determines it, never the agent's own claim.** That lets rules combine `risk` and environment: "read anywhere, write only in dev, anything in prod needs approval."

### Scope in v1

Tools and operations, file paths, network egress, human-approval gates. **Deferred:** data classification.

### Decisions

A rule's `decision` is `deny` or `approve`. Nothing in a capability can widen access, only narrow it ([precedence](#precedence)).

## 5. Observability

Defines what crossed and what was recorded. It uses OpenTelemetry GenAI semantic conventions plus a few additions:

```
span: execute_tool deployment.redeploy    status: ERROR
  gen_ai.operation.name    execute_tool
  gen_ai.tool.name         deployment.redeploy
  gen_ai.tool.call.id      call_1
  capability.name          troubleshooting
  capability.owner         platform-team@example.com
  enduser.id               <set by the harness>
  target.environment       prod
  policy.decision          approval_required
  error.type               permission_denied
```

- **Metadata is always recorded:** tool name, policy decision and rule, token counts, capability name, owner and version, user.
- **Content is opt-in per capability** (`content_capture: true`), and then requires `redact: true` and a `retention_days`.
- **Denials are spans**, so "what was refused" is as queryable as "what ran".
- **`enduser.id` is required**, but its source is an [open decision](#open-decisions).

### Error taxonomy

Failures surface at runtime as one line, `<category>: <cause>`, with no credential material. The `error.type` attribute uses exactly these categories (`observability/errors.yaml`):

| Category | Meaning |
|----------|---------|
| `auth_failed` | Credentials missing or rejected for a profile |
| `permission_denied` | Policy denied the tool call |
| `budget_exceeded` | Governor limit reached (see `on_limit`) |
| `secret_detected` | Scanner found a secret in output; run halted |
| `tool_unavailable` | Tool not installed or not reachable |
| `invalid_input` | Input failed the capability's input schema |

## The secrets invariant

Agents may be told **where** a secret lives (`profile:newrelic/readonly`). They must **never access, view or handle** one. This sits above every capability and every conformance level, and no manifest can waive it (`permissions/invariants.yaml`).

| Layer | What it does |
|-------|--------------|
| 1. Global invariant | One file, above all capabilities, cannot be overridden |
| 2. Deny rules | Denied paths (`~/.aws`, `.env`, kubeconfig, keys) and denied operations (`env`, `kubectl get secret`, sensitive variable listings) |
| 3. Output scrubbing | Tool output is scanned and redacted before it reaches the model, through a generic `scanner/v1` interface (`ggshield` is an optional implementation) |
| 4. Detection events | A hit becomes a `secret.detected` trace event carrying the rule and location, never the value |

On a detection the run **redacts, logs and halts**. A leaked secret is an incident, not a warning.

### How tools authenticate without the agent seeing credentials

- Manifests hold **references only**: `profile:<tool>/<name>`. The validator rejects secret-looking literals in any YAML, Markdown or JSON file.
- The harness runs the CLI **with that profile**, so the CLI reads its own credential store. The agent never holds a plaintext secret.
- Each tool descriptor declares an `auth` block (native method, `store_paths`, profile names). **Every declared `store_paths` entry is automatically added to the denied paths**, so a descriptor cannot forget to protect its own store.
- Every capability using an authenticated tool names a **least-privilege profile** (for example `readonly` for troubleshooting).

## Conformance levels

| Level | Meaning |
|-------|---------|
| **L1** | Documented. The files exist and describe intent. |
| **L2** | Validated. `scripts/validate.ps1` passes: schemas, owner, evals, narrow-only permissions, secret scan. |
| **L3** | Gateway-enforced. A runtime enforces permissions, governors and the secrets invariant. |

A capability declares the level it claims. Per-rule `enforcement` (`advisory | enforced`) says which individual rules are actually guaranteed at that level.

## Precedence

- Rules exist at two levels in v1: **org defaults** and **the capability**.
- A lower level can only **narrow** what a higher level allows, never widen it.
- **Deny wins** at any level.
- **The secrets invariant outranks all of them.**

The validator checks narrowing for tools, operations, network egress, attach sources and write paths.

## Evals

The path is reserved by `evals:` and required at L2 and above. A minimal eval is:

```yaml
apiVersion: agent-standards/v1
capability: code-review
name: flags-obvious-style-violation
input: { diff: "..." }
expect: ["findings is a table ranked by severity"]
pass: "all expect items hold"
```

A fuller eval framework can come later.

## Skills and agents

Both folders are stubs. The relationship is fixed now:

- A **capability** is the governed contract: what can be asked, with limits.
- A **skill** (`SKILL.md`) is a portable playbook that implements part of a capability.
- An **agent** is a role definition (persona, model tier, capabilities it runs).

Skills and agents **reference the capability**, so ownership and policy always trace back to it. Neither can hold tools, budget or permissions of its own.

## Provider portability

- **Instructions:** `AGENTS.md` is canonical. `scripts/sync.sh [target-repo]` creates `CLAUDE.md` and `.github/copilot-instructions.md` as symlinks to it in a target repo.
- **Models:** `models/tiers.yaml` maps tiers to each provider's model ID, and a capability may pin specific models per provider. Replace the placeholder Copilot entries with your current models.
- **Tools:** MCP definitions are reused where they exist.
- **Telemetry:** OpenTelemetry is provider-neutral.

## Tooling

```bash
# install once (needs PowerShell 7+, i.e. `pwsh`)
pwsh -NoProfile -Command "Install-Module powershell-yaml -Scope CurrentUser"

# validate everything (exit code 0 = valid, 1 = errors, 2 = missing module)
pwsh -NoProfile -File scripts/validate.ps1

# push provider files into another repo
scripts/sync.sh /path/to/target-repo
```

The validator checks:

1. Every file against its JSON Schema.
2. Owner is present; file name matches capability name.
3. L2+ capabilities have a non-empty, valid evals directory.
4. Permissions only narrow the org ceiling (tools, operations, egress, sources, write paths).
5. Operations exist in a tool descriptor and are not globally denied.
6. Context templates attach only permitted sources.
7. `auth.profiles` reference profiles a descriptor declares.
8. `content_capture` comes with `redact` and `retention_days`.
9. Descriptor credential stores are added to the denied paths, and no allowed path is listed verbatim in that denylist.
10. The model tier exists in `models/tiers.yaml`, and every `model.pin` provider is listed there.
11. No secret-looking literal appears in any YAML, Markdown or JSON file under the repo (the `scripts/` folder is excluded).

**It does not evaluate CEL.** It checks that rules are well-formed. Evaluating them is the enforcer's job (L3).

Notes on the validator:

- **PowerShell 7+ required.** Windows PowerShell 5.1 (the one built into Windows) lacks `Test-Json -Schema`. Install `pwsh` separately if needed.
- **Schema errors are terse.** `Test-Json` reports one schema problem per file at a time, so fix and rerun. For some conditional rules (for example "`downgrade_to` is required when `on_limit` is `downgrade`") it gives no detail, and the validator prints a generic message naming the schema to check.
- **`sync.sh` is bash.** On Windows, run it from WSL or Git Bash.

## Boundaries and assumptions

- **Bootstrapper is out of scope.** Installing tools and setting up each user's credentials (in whatever store a tool natively uses) is done by a separate tool that is not governed by this standard. This standard assumes credentials are provisioned before an agent runs.
- **No pre-flight check.** If setup is wrong, the run fails with a one-line categorized error (for example `auth_failed: profile newrelic/readonly rejected`).
- **No enforcer here.** This folder defines and validates the contract. A gateway or harness implements enforcement.
- **Audience is both** developer-side agents (IDE, CLI) and services calling model APIs. Governors are mostly advisory for the first and enforceable for the second.

## Open decisions

| Decision | Options | Status |
|----------|---------|--------|
| **Source of `enduser.id`** | The bootstrapper records it; SSO/OIDC at a gateway; OS or git identity | **Open.** The field is required and the source is pluggable. No default chosen. |
| Data classification in permissions | Add as a fifth permission dimension | Deferred past v1 |
| Fuller eval framework | Scoring, datasets, CI gate | Deferred |
| Real skills and agents | Fill the stubs | Deferred |
| Enforcer implementation | Gateway, MCP proxy or host harness | Deferred (L3) |

## Adding a capability

1. Create `capabilities/<name>.yaml` with an owner, a model (tier and/or pinned models) and a conformance level.
2. Write `context/<name>.md`, listing only the sources it needs under `attach`.
3. Write `permissions/<name>.yaml`. Start from deny and list only needed tools and operations. Every one must exist in `permissions/tools/` and in `org-defaults.yaml`.
4. Write `governors/<name>.yaml`.
5. If it uses an authenticated tool, add `auth.profiles` with a least-privilege profile.
6. For L2 and above, add `evals/<name>/` with at least one eval.
7. Run `pwsh -NoProfile -File scripts/validate.ps1`.
8. Get owner review. Changes to permissions or budgets always need it.
