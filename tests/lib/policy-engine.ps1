# POLICY ENGINE (test double). Dot-source this file; it defines functions only.
#
# A tiny, deterministic dry-run of what an enforcer (README conformance level L3) would decide.
# It reads the real files in permissions/, governors/, capabilities/ and answers:
# "if an agent running <capability> tried <action>, what would happen?" No model involved.
#
# It is NOT the real enforcer. It exists so the standard's rules can be tested like code.
# CEL support is deliberately minimal: ==, != against string literals, has(path), !has(path),
# joined with && or ||. Anything else throws, so an unsupported rule fails loudly in tests
# instead of being silently ignored.

function L($x) { if ($null -eq $x) { @() } else { @($x) } }

function Read-YamlFile([string]$Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml }

# ---- globs -----------------------------------------------------------------------------------
function ConvertTo-GlobRegex([string]$Glob) {
    $sb = [System.Text.StringBuilder]::new('^')
    $i = 0
    while ($i -lt $Glob.Length) {
        $c = $Glob[$i]
        if ($c -eq '*') {
            if ($i + 1 -lt $Glob.Length -and $Glob[$i + 1] -eq '*') {
                if ($i + 2 -lt $Glob.Length -and $Glob[$i + 2] -eq '/') { [void]$sb.Append('(?:.*/)?'); $i += 3 }
                else { [void]$sb.Append('.*'); $i += 2 }
            }
            else { [void]$sb.Append('[^/]*'); $i++ }
        }
        elseif ($c -eq '?') { [void]$sb.Append('[^/]'); $i++ }
        else { [void]$sb.Append([regex]::Escape([string]$c)); $i++ }
    }
    [void]$sb.Append('$')
    $sb.ToString()
}

function Test-GlobAny([string]$Value, $Globs) {
    foreach ($g in @(L $Globs)) { if ($Value -match (ConvertTo-GlobRegex $g)) { return $true } }
    $false
}

# ---- minimal CEL -----------------------------------------------------------------------------
function Get-CelPath($Ctx, [string]$Path) {
    $cur = $Ctx
    foreach ($seg in $Path.Split('.')) {
        if ($cur -is [System.Collections.IDictionary] -and $cur.Contains($seg)) { $cur = $cur[$seg] } else { return $null }
    }
    $cur
}

function Test-CelTerm([string]$Term, $Ctx) {
    if ($Term -match '^(!?)has\(([\w.]+)\)$') {
        $neg = $Matches[1] -eq '!'; $path = $Matches[2]
        $has = $null -ne (Get-CelPath $Ctx $path)
        return $(if ($neg) { -not $has } else { $has })
    }
    if ($Term -match '^([\w.]+) (==|!=) "([^"]*)"$') {
        $path = $Matches[1]; $op = $Matches[2]; $lit = $Matches[3]
        $v = Get-CelPath $Ctx $path
        $eq = ($null -ne $v) -and ([string]$v -ceq $lit)
        return $(if ($op -eq '==') { $eq } else { -not $eq })
    }
    throw "unsupported CEL term in policy engine: '$Term'"
}

function Test-Cel([string]$Expr, $Ctx) {
    $e = ($Expr -replace '\s+', ' ').Trim()
    foreach ($orPart in ($e -split ' \|\| ')) {
        $all = $true
        foreach ($term in ($orPart -split ' && ')) {
            if (-not (Test-CelTerm $term.Trim() $Ctx)) { $all = $false; break }
        }
        if ($all) { return $true }
    }
    $false
}

# ---- schema helper ---------------------------------------------------------------------------
function Test-AgainstSchema($Data, $Schema) {
    if ($null -eq $Data) { $Data = @{} }
    $json = ConvertTo-Json -InputObject $Data -Depth 50
    $schemaJson = ConvertTo-Json -InputObject $Schema -Depth 50
    $ev = $null
    [bool](Test-Json -Json $json -Schema $schemaJson -ErrorAction SilentlyContinue -ErrorVariable ev)
}

# ---- secret scanner (same patterns as scripts/validate.ps1; keep in sync) --------------------
$script:ScannerPatterns = [ordered]@{
    'aws-access-key'     = 'AKIA[0-9A-Z]{16}'
    'github-token'       = 'gh[pousr]_[A-Za-z0-9]{30,}'
    'slack-token'        = 'xox[baprs]-[A-Za-z0-9-]{10,}'
    'private-key'        = '-----BEGIN [A-Z ]*PRIVATE KEY-----'
}

# Synthetic secret-shaped strings, built at runtime so no literal sits in a scanned file.
function Get-ScannerFixture([string]$Name) {
    switch ($Name) {
        'aws-access-key' { return 'AKIA' + 'ABCDEFGHIJKLMNOP' }
        'github-token' { return 'ghp_' + ('a' * 36) }
        'slack-token' { return 'xoxb-' + ('1' * 12) }
        'private-key' { return '-----BEGIN RSA ' + 'PRIVATE KEY-----' }
        default { throw "unknown scanner fixture '$Name'" }
    }
}

# ---- engine ----------------------------------------------------------------------------------
function New-PolicyEngine([string]$Root) {
    $inv = Read-YamlFile (Join-Path $Root 'permissions/invariants.yaml')
    $denied = [System.Collections.Generic.List[string]]::new()
    foreach ($x in @(L $inv.secrets.denied_paths)) { $denied.Add($x) }
    $tools = @{}
    foreach ($f in Get-ChildItem (Join-Path $Root 'permissions/tools') -Filter *.yaml) {
        $d = Read-YamlFile $f.FullName
        $tools[$d.name] = $d
        foreach ($s in @(L $d.auth.store_paths)) { $denied.Add($s) }   # store paths are auto-denied
    }
    @{
        Root        = $Root
        Tools       = $tools
        DeniedPaths = $denied
        DeniedOps   = @(L $inv.secrets.denied_operations)
        Org         = Read-YamlFile (Join-Path $Root 'permissions/org-defaults.yaml')
        Caps        = @{}
    }
}

function Get-PolicyCapability($Engine, [string]$Name) {
    if (-not $Engine.Caps.ContainsKey($Name)) {
        $cap = Read-YamlFile (Join-Path $Engine.Root "capabilities/$Name.yaml")
        $Engine.Caps[$Name] = @{
            Manifest = $cap
            Perm     = Read-YamlFile (Join-Path $Engine.Root $cap.permissions)
            Gov      = Read-YamlFile (Join-Path $Engine.Root $cap.governor)
        }
    }
    $Engine.Caps[$Name]
}

function New-Decision([string]$Decision, [string]$Error = $null, [string]$Reason = '') {
    [pscustomobject]@{ Decision = $Decision; Error = $Error; Reason = $Reason; Tier = $null; Fired = @() }
}

# Returns a decision object: Decision (allow|deny|approve|queue|downgrade|halt), Error (taxonomy
# category or $null), Reason, Tier (for downgrade), Fired (names of rules that fired).
#   Action: @{ type = tool_call|file|egress|input|output; ... } (see tests/policy/*.yaml)
function Invoke-PolicyCheck($Engine, [string]$Capability, [string]$Environment, $Usage, $Action) {
    $c = Get-PolicyCapability $Engine $Capability
    $perm = $c.Perm; $org = $Engine.Org

    switch ($Action.type) {
        'input' {
            if (Test-AgainstSchema $Action.input $c.Manifest.inputs) { return New-Decision 'allow' }
            return New-Decision 'deny' 'invalid_input' 'input does not match the capability inputs schema'
        }
        'output' {
            $text = if ($Action.fixture) { Get-ScannerFixture $Action.fixture } else { [string]$Action.text }
            foreach ($label in $script:ScannerPatterns.Keys) {
                if ($text -match $script:ScannerPatterns[$label]) {
                    # Report the rule only, never the value.
                    return New-Decision 'halt' 'secret_detected' "scanner rule $label matched; run halted"
                }
            }
            return New-Decision 'allow'
        }
        'file' {
            $kind = $Action.access   # read | write
            if (Test-GlobAny $Action.path $Engine.DeniedPaths) {
                return New-Decision 'deny' 'permission_denied' "path $($Action.path) is on the secrets denylist"
            }
            if (-not (Test-GlobAny $Action.path $perm.paths[$kind])) {
                return New-Decision 'deny' 'permission_denied' "$kind of $($Action.path) not allowed by policy"
            }
            if (-not (Test-GlobAny $Action.path $org.paths[$kind])) {
                return New-Decision 'deny' 'permission_denied' "$kind of $($Action.path) not allowed by org ceiling"
            }
            return New-Decision 'allow'
        }
        'egress' {
            if ((Test-GlobAny $Action.host $perm.network.egress) -and (Test-GlobAny $Action.host $org.network.egress)) {
                return New-Decision 'allow'
            }
            return New-Decision 'deny' 'permission_denied' "egress to $($Action.host) not allowed"
        }
        'tool_call' { }
        default { throw "unknown action type '$($Action.type)'" }
    }

    # ---- tool_call ----
    $tool = [string]$Action.tool; $opName = [string]$Action.operation
    $full = "$tool.$opName"

    # 1. Secrets invariant: global, outranks everything.
    if ($Engine.DeniedOps -contains $full -or $Engine.DeniedOps -contains $opName -or $Engine.DeniedOps -contains $tool) {
        return New-Decision 'deny' 'permission_denied' "$full is denied by the secrets invariant"
    }

    # 2. Default deny: capability must list the operation, and so must the org ceiling.
    $listed = @(L $perm.tools) | Where-Object { $_.tool -eq $tool -and $opName -in @(L $_.operations) }
    if (-not $listed) { return New-Decision 'deny' 'permission_denied' "$full is not allowed for $Capability (default deny)" }
    $orgListed = @(L $org.tools) | Where-Object { $_.tool -eq $tool -and $opName -in @(L $_.operations) }
    if (-not $orgListed) { return New-Decision 'deny' 'permission_denied' "$full is outside the org ceiling" }

    # 3. Args must match the descriptor's schema.
    $op = @(L $Engine.Tools[$tool].operations) | Where-Object { $_.name -eq $opName } | Select-Object -First 1
    if (-not $op) { return New-Decision 'deny' 'tool_unavailable' "no descriptor for $full" }
    if (-not (Test-AgainstSchema $Action.args $op.args)) {
        return New-Decision 'deny' 'invalid_input' "arguments for $full do not match the tool descriptor"
    }

    # 4. Rules (org + capability). Enforced rules decide; advisory rules are only recorded.
    $ctx = @{
        tool_call  = @{ name = $full; risk = $op.risk }
        target     = @{ environment = $Environment }   # set by the harness, never the agent
        capability = @{ owner = $c.Manifest.owner }
    }
    $fired = @(); $deny = $null; $approve = $null
    foreach ($r in @(@(L $org.rules) + @(L $perm.rules))) {
        if (-not (Test-Cel $r.expression $ctx)) { continue }
        $fired += $r.name
        if ($r.enforcement -ne 'enforced') { continue }
        if ($r.decision -eq 'deny' -and -not $deny) { $deny = $r }
        if ($r.decision -eq 'approve' -and -not $approve) { $approve = $r }
    }
    if ($deny) {
        $d = New-Decision 'deny' 'permission_denied' "$($deny.name): $($deny.message)"; $d.Fired = $fired; return $d   # deny wins
    }
    if ($approve) {
        $d = New-Decision 'approve' $null "$($approve.name): $($approve.message)"; $d.Fired = $fired; return $d
    }

    # 5. Governor: only calls that policy would allow count against limits.
    $gov = $c.Gov
    $hit = $null
    if ($Usage) {
        if ($null -ne $Usage.spend -and $Usage.spend -ge $gov.budget.amount) { $hit = 'budget' }
        foreach ($lim in @(L $gov.limits)) {
            if ($null -ne $Usage.requests -and $Usage.requests -ge $lim.requests) { $hit = 'rate limit' }
        }
    }
    if ($hit) {
        switch ($gov.on_limit) {
            'queue' { $d = New-Decision 'queue' $null "$hit reached; request queued" }
            'deny' { $d = New-Decision 'deny' 'budget_exceeded' "$hit reached" }
            'approve' { $d = New-Decision 'approve' $null "$hit reached; human approval required" }
            'downgrade' { $d = New-Decision 'downgrade' $null "$hit reached; downgraded"; $d.Tier = $gov.downgrade_to }
        }
        $d.Fired = $fired; return $d
    }

    $d = New-Decision 'allow'; $d.Fired = $fired; $d
}
