<#
.SYNOPSIS
    Enforce rule R1: only main.v and platform/ may import vails modules.

.DESCRIPTION
    vails is pre-1.0 and changes daily. The whole point of the platform/ seam
    is that an upstream break is a one-file fix, and that only holds if the
    boundary is enforced rather than merely intended.

    This script greps every .v file for an import of a vails module and fails
    when it finds one outside the allowlist. It is cheap (no compiler), so it
    runs inside build.ps1 before every compile.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

# The complete set of vails module names. Keep in step with
# scripts/sync-vails.ps1's contract list and platform/contract.v.
$vailsModules = @('bridge', 'capabilities', 'config', 'dev', 'events', 'mobile',
	'state', 'assets', 'generator', 'jsesc', 'services', 'webview', 'application')

$root = $script:FluxRoot
$allowedFiles = @('main.v', 'platform\host.v', 'platform\contract.v')

$pattern = '^\s*import\s+(' + (($vailsModules | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')(\s|\.)'

$offenders = @()
Get-ChildItem -Path $root -Filter '*.v' -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
        # vendor/vails is a submodule: not our code, not our rule
        $_.FullName -notmatch '\\vendor\\'
    } |
    ForEach-Object {
        $rel = $_.FullName.Substring($root.Length + 1)
        if ($allowedFiles -contains $rel) { return }
        $hits = Select-String -Path $_.FullName -Pattern $pattern
        foreach ($h in $hits) {
            $offenders += [pscustomobject]@{ File = $rel; Line = $h.LineNumber; Text = $h.Line.Trim() }
        }
    }

if ($offenders.Count -eq 0) {
    Write-Ok ("isolation holds: only {0} may import vails" -f ($allowedFiles -join ', '))
    exit 0
}

Write-Err2 ("isolation violated: {0} file(s) import a vails module outside the allowlist" -f ($offenders.Count))
$offenders | ForEach-Object {
    Write-Host ("      {0}:{1}  {2}" -f $_.File, $_.Line, $_.Text) -ForegroundColor 'Red'
}
Write-Host ''
Write-Host '    Move that capability behind platform/ - that is the entire point of the seam.' -ForegroundColor 'Yellow'
Write-Host '    If it genuinely needs the framework, add the file to $allowedFiles on purpose.' -ForegroundColor 'Yellow'
exit 1
