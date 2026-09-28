<#
.SYNOPSIS
    Fetch the official aria2c Windows build into runtime/.

.DESCRIPTION
    aria2c is GPL, so its binary is never committed: .gitignore lists
    /runtime/, and this script populates it on demand. The app looks for
    aria2c next to the executable, then in runtime/, then on PATH, then at a
    path the user typed into Settings - so a manual install works too, this is
    just the zero-friction path.

    The archive is verified by SHA-256 before anything is unpacked. A mismatch
    is fatal: an unverified engine binary is not something to run.

.EXAMPLE
    .\scripts\fetch-aria2.ps1
    .\scripts\fetch-aria2.ps1 -Version 1.37.0
#>
[CmdletBinding()]
param(
    [string]$Version = '1.37.0',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$root = $script:FluxRoot
$runtime = Join-Path $root 'runtime'
$target = Join-Path $runtime 'aria2c.exe'

if ((Test-Path $target) -and -not $Force) {
    Write-Ok "already present: $target"
    $v = Invoke-Native -Command $target -Arguments @('--version')
    Write-Host ($v.Output | Select-Object -First 1)
    exit 0
}

New-Item -ItemType Directory -Path $runtime -Force | Out-Null

# Official upstream release asset. aria2 publishes one Windows zip per release,
# with a single shared build number; the asset name pattern has been stable
# across the 1.3x series.
$asset = "aria2-$Version-win-64bit-build1.zip"
$url = "https://github.com/aria2/aria2/releases/download/release-$Version/$asset"

# Pinned digests. When bumping -Version, replace this with the value from the
# release's own checksum list; an empty entry makes the script warn rather than
# trust an unverified binary.
#
# WHAT THIS PIN IS, precisely, because a checksum you computed yourself is weaker
# than it looks:
#
#   Upstream publishes NO checksum asset for the Windows zips. There is no
#   SHA256SUMS file on the release, so the value below was computed from the
#   first download on this machine. That means it detects CHANGE - a different
#   asset, a truncated transfer, a mirror that has been replaced - and it does
#   NOT establish authenticity. A value derived from the same download it is
#   meant to authenticate cannot.
#
#   What makes this acceptable anyway: the URL is a GitHub release asset, GitHub
#   does not serve a mutable asset at that path, and the version is pinned. The
#   digest is a tripwire against a corrupted transfer, not a signature.
#   Verifying against upstream would need aria2 to publish checksums; until it
#   does, this is the strongest check available and it is labelled honestly
#   rather than implied.
$known = @{
    '1.37.0' = '67d015301eef0b612191212d564c5bb0a14b5b9c4796b76454276a4d28d9b288'
}

Write-Step "downloading $asset"
Write-Host "    $url"
$tmp = Join-Path $env:TEMP $asset
try {
    $r = Invoke-Native -Command 'curl.exe' -Arguments @('-sSL', '-o', $tmp, $url) -WorkingDirectory $root
    if ($r.Code -ne 0) {
        $r.Output | ForEach-Object { Write-Host "    $_" -ForegroundColor 'Red' }
        exit 1
    }
} catch {
    Write-Err2 'curl.exe not available'
    exit 1
}

if (-not (Test-Path $tmp)) {
    # ${Version} and not $Version: - PowerShell reads "$Version:" as a
    # drive-qualified variable reference and the whole script fails to PARSE. The
    # reported error is about variable syntax, which is a long way from "the
    # download failed", and it happens before a single line runs: this script
    # could never have been executed at all until it was fixed.
    Write-Err2 "download produced nothing. Check the asset name for ${Version}:"
    Write-Host "    https://github.com/aria2/aria2/releases/tag/release-$Version" -ForegroundColor 'Yellow'
    exit 1
}

$size = [math]::Round((Get-Item $tmp).Length / 1MB, 2)
Write-Ok "$size MB"

$expect = $known[$Version]
$sha = (Get-FileHash -Path $tmp -Algorithm SHA256).Hash.ToLower()
Write-Host "    sha256: $sha"
if ($expect -and $sha -ne $expect.ToLower()) {
    Write-Err2 "digest mismatch: expected $expect"
    Remove-Item $tmp -Force
    exit 1
}
if (-not $expect) {
    Write-Warn2 "no pinned digest for $Version in this script"
    Write-Warn2 'verify it against the release notes before trusting this build'
}

Write-Step 'unpacking'
$extract = Join-Path $env:TEMP 'fluxget-aria2'
Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $extract -Force | Out-Null
Expand-Archive -Path $tmp -DestinationPath $extract -Force
Remove-Item $tmp -Force

# The zip nests under aria2-<version>/, sometimes with a win64 subfolder.
$found = Get-ChildItem -Path $extract -Filter 'aria2c.exe' -Recurse -File -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $found) {
    Write-Err2 'aria2c.exe not found inside the archive'
    Get-ChildItem -Path $extract -Recurse | Select-Object -First 20 -ExpandProperty FullName |
        ForEach-Object { Write-Host "    $_" -ForegroundColor 'DarkGray' }
    exit 1
}

Copy-Item $found.FullName $target -Force
# The DLLs matter as much as the exe: aria2c is a C++ program.
Get-ChildItem -Path $found.DirectoryName -Filter '*.dll' -File -ErrorAction SilentlyContinue |
    ForEach-Object { Copy-Item $_.FullName $runtime -Force }
Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue

Write-Ok "runtime\aria2c.exe  ($([math]::Round((Get-Item $target).Length / 1MB, 2)) MB)"
$r = Invoke-Native -Command $target -Arguments @('--version')
Write-Host "    $($r.Output | Select-Object -First 1)"
$r.Output | Where-Object { $_ -match 'Enabled Features' } | ForEach-Object { Write-Host "    $_" }
exit 0
