# Tests

Tests for the standard itself. **No AI model is involved**: everything is deterministic and free to run. They answer two questions:

1. Do the validator's guardrails still catch what they should? (validator suite)
2. If an agent running a capability tried X, would the policy allow it? (policy suite)

They do not test how a model behaves. Whether an agent follows `AGENTS.md` or produces good findings needs the evals in `evals/` run against a live model.

## Running

```bash
# needs PowerShell 7+ and the powershell-yaml module (same as scripts/validate.ps1)
pwsh -NoProfile -File tests/run.ps1                                  # both suites
pwsh -NoProfile -File tests/run.ps1 -Suite policy                    # policy only (a few seconds)
pwsh -NoProfile -File tests/run.ps1 -Suite validator                 # validator only (~30 s)
pwsh -NoProfile -File tests/run.ps1 -Suite policy -Filter '*prod*'   # cases whose name matches a wildcard
```

Exit code: `0` all passed, `1` at least one failure, `2` the `powershell-yaml` module is missing.

Output is one `PASS` or `FAIL` line per case. A failure prints what differed (for example `decision: expected allow, got deny`) and, for policy cases, the engine's reason.

The policy suite filter matches against `<capability>: <case name>`. The validator suite filter matches the case name.

## Layout

```
tests/
├── run.ps1                      runner for both suites
├── lib/
│   └── policy-engine.ps1        dry-run policy engine (functions only; dot-sourced by run.ps1)
├── policy/
│   ├── code-review.yaml         scenarios per capability
│   └── troubleshooting.yaml
└── validator/
    └── mutations.yaml           break-the-repo cases for scripts/validate.ps1
```

## Policy suite

### What it does

Each case is one agent action in one environment. The runner sends it to the policy engine, which reads the **real** files in `permissions/`, `governors/` and `capabilities/` and returns a decision. The runner compares that to `expect`.

Because the engine reads the real files, editing a policy changes the test results. That is the point: the tests tell you what your edit did.

### Case format

```yaml
capability: troubleshooting          # which capability the agent is running
cases:
  - name: redeploy-in-staging-needs-approval
    environment: staging             # dev | staging | prod. Default dev. Set by the harness in real life
    usage: { requests: 0, spend: 0 } # optional: what the governor has already counted
    action:                          # one of the five types below
      type: tool_call
      tool: octopus
      operation: deployment.redeploy
      args: { project: web, version: "1.2.3", environment: staging }
    expect:
      decision: approve              # required
      error: permission_denied       # optional: taxonomy category (null for non-errors)
      tier: fast                     # optional: for downgrade
      rule: no-writes-outside-dev    # optional: a rule that must have fired
```

### Action types

| `type` | Fields | What is checked |
|--------|--------|-----------------|
| `tool_call` | `tool`, `operation`, `args` | The full decision order below |
| `file` | `access` (`read` or `write`), `path` | Secrets denylist, then the capability's `paths`, then the org ceiling |
| `egress` | `host` | The capability's `network.egress` and the org ceiling (`*` wildcards allowed) |
| `input` | `input` | The capability's `inputs` JSON Schema, giving `invalid_input` on mismatch |
| `output` | `fixture` or `text` | The secret scanner: a match gives `halt` with `secret_detected` |

For `output`, prefer `fixture` (`aws-access-key`, `github-token`, `slack-token`, `private-key`). The engine builds a synthetic secret at runtime, so no secret-looking literal sits in a YAML file.

### Decision order for a tool call

The first step that produces a result wins.

1. **Secrets invariant.** The operation is on `denied_operations` in `permissions/invariants.yaml`: `deny`, `permission_denied`.
2. **Default deny.** The capability does not list `tool.operation`, or the org ceiling does not: `deny`, `permission_denied`.
3. **Argument schema.** `args` do not match the operation's schema in the tool descriptor: `deny`, `invalid_input`.
4. **Rules.** Org rules plus the capability's rules are evaluated. Only `enforcement: enforced` rules decide. If any fired rule says `deny`, the result is `deny` (deny wins). Otherwise, if any says `approve`, the result is `approve`. Advisory rules that fire are recorded but never change the outcome.
5. **Governor.** If `usage` is at or over the budget `amount` or any limit's `requests`, the governor's `on_limit` applies: `queue`, `deny` (`budget_exceeded`), `approve`, or `downgrade` (with the `downgrade_to` tier).
6. Otherwise `allow`.

Governor checks come last on purpose: a call the policy would refuse should not count against a budget.

`file`, `egress`, `input` and `output` actions skip these steps. They use only the check in their row of the table above.

Possible decisions: `allow`, `deny`, `approve`, `queue`, `downgrade`, `halt`.

### The engine is a test double

`lib/policy-engine.ps1` is **not** the L3 enforcer. It is a small stand-in so the rules can be tested before an enforcer exists. Know its limits:

- **CEL support is minimal.** It handles `==` and `!=` against string literals, `has(path)`, `!has(path)`, joined with `&&` and `||`. No parentheses, no other operators. An unsupported expression **throws**, so the case fails loudly rather than being skipped.
- **Variables available to rules:** `tool_call.name`, `tool_call.risk`, `target.environment`, `capability.owner`.
- **Usage is supplied by the test.** There is no real counting or time windows. `usage.requests` is compared to every limit, and `usage.spend` to the budget.
- **Secret scanner patterns are copied** from `scripts/validate.ps1`. If you add a pattern there, add it to `$script:ScannerPatterns` in the engine too.
- **Globs:** `**` matches across folders, `*` within one folder, `**/` also matches zero folders (so `**/.env` matches `.env`). Paths use `~` for the home folder, as in the denylist.

When a real enforcer exists, point these same scenario files at it and keep the engine as a reference.

## Validator suite

### What it does

A rule that stops failing when it is broken is a bug. Each case copies the repo to a fresh temp folder, applies mutations, runs the copy's `scripts/validate.ps1`, and checks the exit code and output. Your working tree is never modified, and the temp folder is deleted afterwards.

The copy includes `capabilities`, `context`, `governors`, `permissions`, `observability`, `evals`, `models`, `schemas` and `scripts`.

### Case format

```yaml
- name: widening-egress-past-the-org-ceiling-is-rejected
  mutations:
    - { op: replace, file: permissions/code-review.yaml, find: "egress: []", with: 'egress: ["evil.example.com"]' }
  expect_exit: 1                                          # 1 = validator found errors, 0 = valid
  expect_contains: ["egress evil.example.com widens org-defaults"]   # every string must appear in the output
```

### Mutation ops

| `op` | Fields | Effect |
|------|--------|--------|
| `replace` | `file`, `find`, `with` | Exact text replacement. If `find` is not in the file the case **fails** ("test is stale"), so a renamed rule or reworded file cannot silently turn a test into a no-op |
| `append` | `file`, `text` | Add text to the end of a file |
| `create` | `file`, `text` | Write a new file. `{{AWS_KEY}}` expands to a synthetic key built at runtime |
| `delete` | `file` | Remove a file or folder |

`baseline-repo-passes` has no mutations and expects exit `0`. It proves the repo is valid, so a failing mutation case means the mutation was caught, not that the repo was already broken.

## Adding tests

- **New or changed rule in `permissions/`:** add policy cases for both sides: the action it should block and a nearby action it should not. Name cases for the behavior, for example `redeploy-in-staging-needs-approval`.
- **New validator check in `scripts/validate.ps1`:** add a mutation that triggers it, and `expect_contains` the message so a different error cannot satisfy the test.
- **New capability:** add `tests/policy/<capability>.yaml`. The runner picks up every `*.yaml` in that folder. Cover its permitted tools, a denied one, its governor, and the secrets paths.
- **New tool descriptor:** add cases for each operation, including an invalid-args case.

## Gotchas

- **Secret literals.** `validate.ps1` scans every YAML, Markdown and JSON file outside `scripts/` for secret-looking strings, and that includes `tests/`. Use `fixture` and `{{AWS_KEY}}` instead of pasting values. The `.ps1` files are not scanned, which is why the fixtures are built in PowerShell.
- **Keep test files free of `token:`-style assignments** with 16 or more characters after them. The generic secret pattern matches them.
- **Speed.** The policy suite takes seconds. The validator suite starts a new `pwsh` per case, so it takes about two seconds per case.
- **No CI yet.** Nothing runs these automatically. Adding `tests/run.ps1` next to `scripts/validate.ps1` in CI would also make the "version bump" check in [Open decisions](../README.md#open-decisions) possible later.
