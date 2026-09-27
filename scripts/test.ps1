<#
.SYNOPSIS
    The Fluxget quality gate: contract, isolation, formatting, unit tests.

.DESCRIPTION
    `v fmt -w .` and `v test .` are the law, same as in the vails repo. This
    script is the one place that runs them, plus the two project-specific
    rules that must hold before any build:

      R1  isolation  - only main.v and platform/ may import vails
      R2  contract   - the vails API surface Fluxget depends on still exists

    `v test .` never opens a window and never touches aria2c: the rpc client
    takes an injected Transport, so the whole test suite is pure.
#>
[CmdletBinding()]
param(
    [switch]$Format,      # rewrite instead of verifying
    [switch]$SkipVails    # do not run the vendored framework's own tests
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$root = $script:FluxRoot
$vailsHome = Get-VailsHome
$env:VMODULES = (Get-FluxVModules)
if ($vailsHome) { $env:VAILS_HOME = $vailsHome }
Enable-Toolchain

$failed = @()

# ---- R2: contract --------------------------------------------------------
Write-Step 'R2  vails API contract'
& (Join-Path $PSScriptRoot 'sync-vails.ps1') -Probe
if ($LASTEXITCODE -ne 0) { $failed += 'contract probe' }

# ---- R1: isolation -------------------------------------------------------
Write-Step 'R1  platform/ isolation'
& (Join-Path $PSScriptRoot 'check-isolation.ps1')
if ($LASTEXITCODE -ne 0) { $failed += 'isolation' }

# ---- the vendored framework must still be green --------------------------
if ($vailsHome -and -not $SkipVails) {
    Write-Step 'vendor/vails  v test .'
    $r = Invoke-Native -Command 'v' -Arguments ((Get-VCFlags) + @('test', '.')) -WorkingDirectory $vailsHome
    $summary = ($r.Output | Select-String 'Summary for all V' | Select-Object -Last 1)
    if ($r.Code -eq 0) {
        Write-Ok $(if ($summary) { $summary.ToString().Trim() } else { 'green' })
    } else {
        Write-Err2 'vendor/vails tests failed'
        $r.Output | Select-Object -Last 25 | ForEach-Object { Write-Host "    $_" -ForegroundColor 'Red' }
        $failed += 'vendor/vails v test .'
    }
}

# ---- format --------------------------------------------------------------
$targets = Get-FluxVTargets
if ($Format) {
    Write-Step ("v fmt -w  ({0} target(s))" -f $targets.Count)
    $r = Invoke-Native -Command 'v' -Arguments (@('fmt', '-w') + $targets) -WorkingDirectory $root
    if ($r.Code -eq 0) {
        Write-Ok 'formatted'
        $r.Output | Select-Object -First 15 | ForEach-Object { Write-Host "    $_" }
    } else {
        Write-Err2 'v fmt -w failed'
        $r.Output | Select-Object -First 20 | ForEach-Object { Write-Host "    $_" -ForegroundColor 'Red' }
        $failed += 'v fmt -w'
    }
} else {
    Write-Step ("v fmt -verify  ({0} target(s))" -f $targets.Count)
    $r = Invoke-Native -Command 'v' -Arguments (@('fmt', '-verify') + $targets) -WorkingDirectory $root -Tail 25
    if ($r.Code -eq 0) {
        Write-Ok 'formatting clean'
    } else {
        Write-Err2 'unformatted files (run .\scripts\test.ps1 -Format)'
        $r.Output | ForEach-Object { Write-Host "    $_" -ForegroundColor 'Yellow' }
        $failed += 'v fmt -verify'
    }
}

# ---- our tests -----------------------------------------------------------
Write-Step ("fluxget  v test  ({0} target(s))" -f $targets.Count)
$r = Invoke-Native -Command 'v' -Arguments ((Get-VCFlags) + @('test') + $targets) -WorkingDirectory $root -Tail 40
$summary = ($r.Output | Select-String 'Summary for all V' | Select-Object -Last 1)
if ($r.Code -eq 0) {
    Write-Ok $(if ($summary) { $summary.ToString().Trim() } else { 'green (no test files yet)' })
} else {
    Write-Err2 'tests failed'
    $r.Output | ForEach-Object { Write-Host "    $_" -ForegroundColor 'Red' }
    $failed += 'fluxget v test .'
}

if ($failed.Count -eq 0) {
    Write-Step 'gate green' 'Green'
    exit 0
}
Write-Step ("gate red: {0}" -f ($failed -join ', ')) 'Red'
exit 1
