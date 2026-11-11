---
# CONTEXT TEMPLATE front matter. Everything between the --- lines is configuration;
# everything below is the prompt text sent to the agent.
#
# attach: list of named sources to resolve and send along with the prompt.
#   - Each name is resolved by a resolver (name in, content out).
#   - Every name must be in this capability's permissions attach_sources, or validation fails.
#   - Content is redacted after resolution and before it is sent.
#   - Which sources were attached is recorded in the trace.
attach: [diff, CONTRIBUTING.md, style-guide]
---
Review this diff against our style guide.
Return findings as a table, ranked by severity.
