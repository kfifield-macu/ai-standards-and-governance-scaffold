#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Run the scaffold's tests. No AI model is used.

.DESCRIPTION
    Two suites:
      policy     tests/policy/*.yaml. Scripted agent actions run through the dry-run policy
                 engine (tests/lib/policy-engine.ps1); asserts the decision and error category.
      validator  tests/validator/mutations.yaml. Copies the repo to a temp folder, breaks it on
                 purpose, runs scripts/validate.ps1, and asserts it rejects the change.
    Exit code 0 = all passed, 1 = failures, 2 = missing module.

.EXAMPLE
    pwsh -NoProfile -File tests/run.ps1
    pwsh -NoProfile -File tests/run.ps1 -Suite policy -Filter '*prod*'
#>
param(
    [ValidateSet('all', 'policy', 'validator')][string]$Suite = 'all',
    [string]$Filter = '*'
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Host 'ERROR missing module powershell-yaml. Install with: Install-Module powershell-yaml -Scope CurrentUser'
    exit 2
}
Import-Module powershell-yaml
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'lib/policy-engine.ps1')

$script:Pass = 0
$script:Failed = [System.Collections.Generic.List[string]]::new()

function Write-Result([bool]$Ok, [string]$Name, [string]$Detail = '') {
    if ($Ok) { $script:Pass++; Write-Host "  PASS $Name" }
    else { $script:Failed.Add($Name); Write-Host "  FAIL $Name"; if ($Detail) { Write-Host "       $Detail" } }
}

# ---- policy suite ----------------------------------------------------------------------------
if ($Suite -in 'all', 'policy') {
    Write-Host 'policy suite'
    $engine = New-PolicyEngine $Root
    foreach ($file in Get-ChildItem (Join-Path $PSScriptRoot 'policy') -Filter *.yaml | Sort-Object Name) {
        $spec = Read-YamlFile $file.FullName
        foreach ($case in @(L $spec.cases)) {
            $label = "$($spec.capability): $($case.name)"
            if ($label -notlike $Filter) { continue }
            try {
                $env = if ($case.environment) { $case.environment } else { 'dev' }
                $got = Invoke-PolicyCheck $engine $spec.capability $env $case.usage $case.action
                $problems = @()
                if ($got.Decision -ne $case.expect.decision) { $problems += "decision: expected $($case.expect.decision), got $($got.Decision)" }
                if ($case.expect.ContainsKey('error') -and $got.Error -ne $case.expect.error) { $problems += "error: expected $($case.expect.error), got $($got.Error)" }
                if ($case.expect.tier -and $got.Tier -ne $case.expect.tier) { $problems += "tier: expected $($case.expect.tier), got $($got.Tier)" }
                if ($case.expect.rule -and $case.expect.rule -notin $got.Fired) { $problems += "rule $($case.expect.rule) did not fire (fired: $($got.Fired -join ', '))" }
                $detail = ($problems -join '; ') + $(if ($problems) { "  [reason: $($got.Reason)]" })
                Write-Result ($problems.Count -eq 0) $label $detail
            }
            catch { Write-Result $false $label "exception: $($_.Exception.Message)" }
        }
    }
}

# ---- validator suite -------------------------------------------------------------------------
if ($Suite -in 'all', 'validator') {
    Write-Host 'validator suite'
    $spec = Read-YamlFile (Join-Path $PSScriptRoot 'validator/mutations.yaml')
    $copyDirs = 'capabilities', 'context', 'governors', 'permissions', 'observability', 'evals', 'models', 'schemas', 'scripts'
    $placeholders = @{ '{{AWS_KEY}}' = ('AKIA' + 'ABCDEFGHIJKLMNOP') }   # built at runtime, never a literal

    foreach ($case in @(L $spec.cases)) {
        if ($case.name -notlike $Filter) { continue }
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("scaffold-test-" + [guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Directory -Path $tmp | Out-Null
            foreach ($d in $copyDirs) { Copy-Item -Recurse (Join-Path $Root $d) (Join-Path $tmp $d) }
            foreach ($m in @(L $case.mutations)) {
                $target = Join-Path $tmp $m.file
                $text = [string]$m.text
                foreach ($k in $placeholders.Keys) { $text = $text.Replace($k, $placeholders[$k]) }
                switch ($m.op) {
                    'replace' {
                        $content = Get-Content -LiteralPath $target -Raw
                        if (-not $content.Contains($m.find)) { throw "mutation target not found in $($m.file): '$($m.find)' (test is stale)" }
                        Set-Content -LiteralPath $target -Value $content.Replace($m.find, $m.with) -NoNewline
                    }
                    'append' { Add-Content -LiteralPath $target -Value $text }
                    'create' {
                        New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
                        Set-Content -LiteralPath $target -Value $text
                    }
                    'delete' { Remove-Item -Recurse -Force -LiteralPath $target }
                    default { throw "unknown mutation op '$($m.op)'" }
                }
            }
            $out = (& pwsh -NoProfile -File (Join-Path $tmp 'scripts/validate.ps1') 2>&1 | Out-String)
            $code = $LASTEXITCODE
            $problems = @()
            if ($code -ne $case.expect_exit) { $problems += "exit code: expected $($case.expect_exit), got $code" }
            foreach ($s in @(L $case.expect_contains)) {
                if (-not $out.Contains($s)) { $problems += "output missing '$s'" }
            }
            $detail = ''
            if ($problems) { $detail = ($problems -join '; ') + "`n       validator said: " + (($out -split "`n" | Where-Object { $_ -match 'ERROR|FAILED|OK' } | Select-Object -First 3) -join ' | ') }
            Write-Result ($problems.Count -eq 0) $case.name $detail
        }
        catch { Write-Result $false $case.name "exception: $($_.Exception.Message)" }
        finally { if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp } }
    }
}

Write-Host ''
Write-Host ("{0}: {1} passed, {2} failed" -f $(if ($script:Failed.Count) { 'FAILED' } else { 'OK' }), $script:Pass, $script:Failed.Count)
exit $(if ($script:Failed.Count) { 1 } else { 0 })
