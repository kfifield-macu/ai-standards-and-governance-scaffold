---
# attach: named sources sent with the prompt. Must all be listed in
# permissions/troubleshooting.yaml under attach_sources. Redacted before sending.
attach: [runbook, incident-ticket]
---
Investigate the incident using read-only observability queries first.
Credentials are not available to you and you must not look for them.
If a tool needs authentication it is already configured; reference the profile by name only.
Return: hypothesis, evidence (queries run), and recommended next step.
