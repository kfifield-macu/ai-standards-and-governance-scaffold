# Agents (stub)

Role definitions: persona, preferred model tier, and which capabilities the role runs. Mapped per provider (Claude subagents, Copilot custom agents) by a generator, from one definition here.

**Contract:** an agent references the capabilities it runs. It cannot hold tools, budget or permissions of its own. Those belong to the capability.

Suggested shape:

```yaml
apiVersion: agent-standards/v1
name: incident-responder
role: Investigates incidents and proposes next steps.
model_tier: balanced
capabilities: [troubleshooting]
```

Nothing here yet.
