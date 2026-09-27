<#
.SYNOPSIS
    Build the Fluxget browser extension for Chrome and Firefox.

.DESCRIPTION
    Two targets, one source. There is no npm here on purpose: no bundler, no
    node_modules, no build toolchain to keep alive. The extension is plain ES
    modules plus one base manifest, and this script copies the tree twice,
    swapping in the per-browser manifest, then zips each.

    What actually differs between the two, and why:

      Chrome  background.service_worker        MV3 service worker
      Firefox background.scripts (+ type:
               module) and browser_specific_settings.gecko

    Firefox does not support background.service_worker in a shipping extension
    yet, so the same code has to load both ways. The background script is
    written to work as either: no top-level await, listeners registered
    synchronously at import time.

.EXAMPLE
    .\scripts\ext.ps1
    .\scripts\ext.ps1 -Open
#>
[CmdletBinding()]
param(
    [switch]$Open
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$root = $script:FluxRoot
$extRoot = Join-Path $root 'extension'
$src = Join-Path $extRoot 'src'
$dist = Join-Path $extRoot 'dist'

if (-not (Test-Path $src)) {
    Write-Err2 "extension/src not found at $src"
    exit 2
}

# Sanity: a manifest variant that does not exist yet must say so clearly rather
# than producing a zip that cannot be loaded.
$targets = @(
    @{ Name = 'chrome'; Manifest = 'manifest.chrome.json' }
    @{ Name = 'firefox'; Manifest = 'manifest.firefox.json' }
)

Remove-Item $dist -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $dist -Force | Out-Null

Write-Step "packaging  src\  ($(((Get-ChildItem -Path $src -Recurse -File).Count)) file(s))"

foreach ($t in $targets) {
    $manifestPath = Join-Path $src $t.Manifest
    if (-not (Test-Path $manifestPath)) {
        Write-Warn2 "$($t.Name): $($t.Manifest) not present yet, skipped"
        continue
    }

    $out = Join-Path $dist $t.Name
    New-Item -ItemType Directory -Path $out -Force | Out-Null

    # Everything except the per-browser manifests, then the right one as
    # manifest.json. A stray manifest.chrome.json inside a Firefox zip is a
    # confusing way to find out you packed the wrong thing.
    Get-ChildItem -Path $src -Recurse -File |
        Where-Object { $_.Name -notlike 'manifest.*.json' } |
        ForEach-Object {
            $rel = $_.FullName.Substring($src.Length + 1)
            $dest = Join-Path $out $rel
            New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
            Copy-Item $_.FullName $dest -Force
        }
    Copy-Item $manifestPath (Join-Path $out 'manifest.json') -Force

    # Parse it, so a syntax error is caught here rather than in the browser.
    try {
        $null = Get-Content (Join-Path $out 'manifest.json') -Raw | ConvertFrom-Json
    } catch {
        Write-Err2 "$($t.Name): manifest.json is not valid JSON: $($_.Exception.Message)"
        exit 1
    }

    $zip = Join-Path $dist "fluxget-$($t.Name).zip"
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Compress-Archive -Path (Join-Path $out '*') -DestinationPath $zip -Force

    $count = (Get-ChildItem -Path $out -Recurse -File).Count
    $size = [math]::Round((Get-Item $zip).Length / 1KB, 1)
    Write-Ok ("{0,-8} {1} file(s), {2} KB  ->  dist\{3}" -f $t.Name, $count, $size, (Split-Path $zip -Leaf))
}

Write-Host ''
Write-Step 'how to load them' 'Cyan'
Write-Host '  Chrome    chrome://extensions -> Developer mode -> Load unpacked -> extension\dist\chrome' -ForegroundColor 'DarkGray'
Write-Host '  Firefox   about:debugging#/runtime/this-firefox -> Load Temporary Add-on' -ForegroundColor 'DarkGray'
Write-Host '            -> extension\dist\firefox\manifest.json' -ForegroundColor 'DarkGray'
Write-Host ''
Write-Host '  Then open Fluxget, go to the Extension tab, and press Pair.' -ForegroundColor 'DarkGray'
Write-Host '  The token it shows goes into the extension options page.' -ForegroundColor 'DarkGray'

if ($Open) {
    Invoke-Item (Join-Path $dist 'chrome')
}
exit 0
