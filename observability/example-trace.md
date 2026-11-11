# Example trace (denied tool call)

```
span: execute_tool deployment.redeploy    status: ERROR
  gen_ai.operation.name    execute_tool
  gen_ai.tool.name         deployment.redeploy
  gen_ai.tool.call.id      call_1

  capability.name          troubleshooting
  capability.owner         platform-team@example.com
  capability.version       0.1.0
  enduser.id               <set by the harness>
  target.environment       prod
  policy.decision          approval_required
  policy.rule              no-writes-outside-dev
  error.type               permission_denied
```
