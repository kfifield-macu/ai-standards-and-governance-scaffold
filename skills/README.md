# Skills (stub)

Portable playbooks in the open Agent Skills format (`<skill-name>/SKILL.md`), usable by Claude, Copilot and others.

**Contract:** every skill references the capability it serves, so ownership, permissions and budget always trace back to the capability. A skill never grants itself tools or access.

Suggested front matter addition:

```yaml
---
name: example-skill
description: One line on when to use it.
capability: troubleshooting   # required: the governing capability
---
```

Nothing here yet. Skills come after the five standards settle.
