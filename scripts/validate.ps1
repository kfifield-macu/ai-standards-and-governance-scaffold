#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Validate the scaffold: JSON Schemas plus the cross-file rules from the standard.

.DESCRIPTION
    Run from anywhere; paths resolve from the repo root (the folder above scripts/).
    Requires: PowerShell 7+, and the powershell-yaml module
      (Install-Module powershell-yaml -Scope CurrentUser)
    Exit code 0 = valid, 1 = errors.

    Note: CEL expressions are checked for presence only, not evaluated. Evaluation belongs
    to the enforcer (see README, conformance level L3).

.EXAMPLE
    pwsh -NoProfile -File scripts/validate.ps1
#>
$ErrorActionPreference = 'Stop'
# Not '#Requires -Modules': with 'pwsh -File' it swallows this script's exit code.
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Host 'ERROR missing module powershell-yaml. Install with: Install-Module powershell-yaml -Scope CurrentUser'
    exit 2
}
Import-Module powershell-yaml

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:Errs = [System.Collections.Generic.List[string]]::new()

$SecretPatterns = [ordered]@{
    'aws-access-key'     = 'AKIA[0-9A-Z]{16}'
    'github-token'       = 'gh[pousr]_[A-Za-z0-9]{30,}'
    'slack-token'        = 'xox[baprs]-[A-Za-z0-9-]{10,}'
    'private-key'        = '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    'generic-assignment' = '(?i)(api[_-]?key|secret|token|password)\s*[:=]\s*[''"]?[A-Za-z0-9/+_\-]{16,}'
}

function Add-Err([string]$Where, [string]$Msg) { $script:Errs.Add("${Where}: $Msg") }
function Get-Rel([string]$Path) { [IO.Path]::GetRelativePath($Root, $Path).Replace('\', '/') }
# Always call as @(L $x): turns $null into an empty array and a lone value into a 1-item array.
function L($x) { if ($null -eq $x) { @() } else { @($x) } }

function Read-Yaml([string]$Path) {
    try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml) }
    catch { Add-Err (Get-Rel $Path) "invalid YAML: $($_.Exception.Message)"; return $null }
}

function Test-Schema([string]$Path, [string]$SchemaName) {
    $data = Read-Yaml $Path
    if ($null -eq $data) { return $null }
    $schema = Get-Content -LiteralPath (Join-Path $Root "schemas/$SchemaName") -Raw
    $json = ConvertTo-Json -InputObject $data -Depth 50
    $ev = $null
    $ok = Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue -ErrorVariable ev
    if (-not $ok) {
        $msgs = @(L $ev) | ForEach-Object { $_.Exception.Message -replace '^The JSON is not valid with the schema:\s*', '' }
        # Test-Json returns False without any message for some conditional (if/then) failures.
        if (@($msgs).Count -eq 0) {
            $msgs = @("does not satisfy schemas/$SchemaName (a conditional rule such as if/then failed; check required fields)")
        }
        foreach ($m in $msgs) { Add-Err (Get-Rel $Path) $m }
    }
    return $data
}

function Get-FrontMatter([string]$Path) {
    $text = Get-Content -LiteralPath $Path -Raw
    if ($text -match '(?s)^---\r?\n(.*?)\r?\n---\r?\n') {
        $fm = $Matches[1] | ConvertFrom-Yaml
        if ($fm) { return $fm }
    }
    return @{}
}

# --- Global invariants + tool descriptors ----------------------------------------------
$inv = Test-Schema (Join-Path $Root 'permissions/invariants.yaml') 'invariants.schema.json'
$deniedPaths = [System.Collections.Generic.HashSet[string]]::new()
$deniedOps = [System.Collections.Generic.HashSet[string]]::new()
foreach ($x in @(L $inv.secrets.denied_paths)) { [void]$deniedPaths.Add($x) }
foreach ($x in @(L $inv.secrets.denied_operations)) { [void]$deniedOps.Add($x) }

$tools = @{}
foreach ($p in Get-ChildItem (Join-Path $Root 'permissions/tools') -Filter *.yaml | Sort-Object Name) {
    $d = Test-Schema $p.FullName 'tool-descriptor.schema.json'
    if (-not $d) { continue }
    $tools[$d.name] = $d
    # Rule: every declared credential store is automatically denied.
    foreach ($s in @(L $d.auth.store_paths)) { [void]$deniedPaths.Add($s) }
    foreach ($op in @(L $d.operations)) {
        if ($deniedOps.Contains("$($d.name).$($op.name)")) {
            Add-Err (Get-Rel $p.FullName) "operation $($op.name) is globally denied by the secrets invariant"
        }
    }
}

# --- Org defaults (ceiling) ---------------------------------------------------------------
$org = Test-Schema (Join-Path $Root 'permissions/org-defaults.yaml') 'permissions.schema.json'
[void](Test-Schema (Join-Path $Root 'governors/org-defaults.yaml') 'governor.schema.json')
$orgOps = [System.Collections.Generic.HashSet[string]]::new()
foreach ($t in @(L $org.tools)) { foreach ($o in @(L $t.operations)) { [void]$orgOps.Add("$($t.tool)|$o") } }

$tiers = (Read-Yaml (Join-Path $Root 'models/tiers.yaml')).tiers
$knownProviders = [System.Collections.Generic.HashSet[string]]::new()
foreach ($k in $tiers.Keys) { foreach ($prov in $tiers[$k].Keys) { [void]$knownProviders.Add($prov) } }

# --- Capabilities -----------------------------------------------------------------------------
foreach ($p in Get-ChildItem (Join-Path $Root 'capabilities') -Filter *.yaml | Sort-Object Name) {
    $cap = Test-Schema $p.FullName 'capability.schema.json'
    if (-not $cap) { continue }
    $rel = Get-Rel $p.FullName
    $name = $cap.name

    if ($p.BaseName -ne $name) { Add-Err $rel "file name must match capability name '$name'" }
    if ([string]::IsNullOrWhiteSpace($cap.owner)) { Add-Err $rel 'owner is required. Nobody has decided this.' }

    $model = $cap.model
    if ($model.ContainsKey('tier') -and -not $tiers.ContainsKey($model.tier)) {
        Add-Err $rel "tier $($model.tier) missing from models/tiers.yaml"
    }
    if ($model.ContainsKey('pin')) {
        foreach ($prov in $model.pin.Keys) {
            if (-not $knownProviders.Contains($prov)) {
                Add-Err $rel "model.pin provider '$prov' not listed in models/tiers.yaml"
            }
        }
    }

    $obs = $cap.observability
    if ($obs.content_capture -and -not ($obs.retention_days -and $obs.redact)) {
        Add-Err $rel 'content_capture requires retention_days and redact: true'
    }

    # Evals required at L2+.
    if ($cap.conformance -in 'L2', 'L3') {
        $evDir = if ($cap.evals) { Join-Path $Root $cap.evals } else { $null }
        if (-not $evDir -or -not (Test-Path -LiteralPath $evDir -PathType Container)) {
            Add-Err $rel "$($cap.conformance) requires an evals directory"
        }
        else {
            $files = @(Get-ChildItem $evDir -Filter *.yaml)
            if ($files.Count -eq 0) { Add-Err $rel 'evals directory is empty' }
            foreach ($f in $files) { [void](Test-Schema $f.FullName 'eval.schema.json') }
        }
    }

    # Referenced files exist and validate.
    foreach ($key in 'governor', 'permissions', 'context') {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $cap[$key]) -PathType Leaf)) {
            Add-Err $rel "$key file not found: $($cap[$key])"
        }
    }
    $ctx = Join-Path $Root $cap.context
    $govPath = Join-Path $Root $cap.governor
    $permPath = Join-Path $Root $cap.permissions
    if (Test-Path -LiteralPath $govPath -PathType Leaf) { [void](Test-Schema $govPath 'governor.schema.json') }
    $perm = if (Test-Path -LiteralPath $permPath -PathType Leaf) { Test-Schema $permPath 'permissions.schema.json' } else { $null }

    # Auth profiles must be references to profiles that exist.
    foreach ($ref in @(L $cap.auth.profiles)) {
        $tool, $prof = ($ref -replace '^profile:', '') -split '/', 2
        if ($prof -notin @(L $tools[$tool].auth.profiles)) {
            Add-Err $rel "auth profile $ref not declared by any tool descriptor"
        }
    }

    if (-not $perm) { continue }
    $permRel = Get-Rel $permPath

    # Narrow-only: capability may not widen the org ceiling.
    foreach ($t in @(L $perm.tools)) {
        if (-not $tools.ContainsKey($t.tool)) { Add-Err $permRel "unknown tool $($t.tool)"; continue }
        $known = @(L $tools[$t.tool].operations) | ForEach-Object { $_.name }
        foreach ($o in @(L $t.operations)) {
            if ($o -notin $known) { Add-Err $permRel "$($t.tool).$o is not in the tool descriptor" }
            if (-not $orgOps.Contains("$($t.tool)|$o")) { Add-Err $permRel "$($t.tool).$o widens org-defaults" }
            if ($deniedOps.Contains("$($t.tool).$o")) { Add-Err $permRel "$($t.tool).$o is denied by the secrets invariant" }
        }
    }
    foreach ($h in @(L $perm.network.egress)) {
        if ($h -notin @(L $org.network.egress)) { Add-Err $permRel "egress $h widens org-defaults" }
    }
    foreach ($s in @(L $perm.attach_sources)) {
        if ($s -notin @(L $org.attach_sources)) { Add-Err $permRel "attach source $s widens org-defaults" }
    }
    foreach ($w in @(L $perm.paths.write)) {
        if ($w -notin @(L $org.paths.write)) { Add-Err $permRel "write path $w widens org-defaults" }
    }
    foreach ($kind in 'read', 'write') {
        foreach ($path in @(L $perm.paths[$kind])) {
            if ($deniedPaths.Contains($path)) { Add-Err $permRel "path $path is denied by the secrets invariant" }
        }
    }

    # Context may only attach sources the permissions allow.
    if (Test-Path -LiteralPath $ctx -PathType Leaf) {
        foreach ($s in @(L (Get-FrontMatter $ctx).attach)) {
            if ($s -notin @(L $perm.attach_sources)) {
                Add-Err (Get-Rel $ctx) "attaches '$s' but permissions do not allow it"
            }
        }
    }
}

# --- No secret-looking literals anywhere ------------------------------------------------------
$exts = '.yaml', '.yml', '.md', '.json'
foreach ($p in Get-ChildItem $Root -Recurse -File -Force | Where-Object { $_.Extension -in $exts }) {
    $rel = Get-Rel $p.FullName
    if ($rel -like 'scripts/*' -or $rel -like '.git/*') { continue }
    $text = Get-Content -LiteralPath $p.FullName -Raw
    foreach ($label in $SecretPatterns.Keys) {
        if ([regex]::IsMatch($text, $SecretPatterns[$label])) {
            Add-Err $rel "possible secret literal ($label). References only, never values."
        }
    }
}

foreach ($e in $script:Errs) { Write-Host "ERROR $e" }
Write-Host ''
Write-Host ("{0}: {1} error(s)" -f $(if ($script:Errs.Count) { 'FAILED' } else { 'OK' }), $script:Errs.Count)
$code = if ($script:Errs.Count -gt 0) { 1 } else { 0 }
exit $code
