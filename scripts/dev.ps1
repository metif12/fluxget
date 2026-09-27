<#
.SYNOPSIS
    Build and run Fluxget with frontend livereload.

.DESCRIPTION
    This is the day-to-day loop. Two jobs:

      1. keep build/fluxget.exe current with the V sources
      2. start it in --dev mode, where the window is pointed at the vails dev
         server so frontend edits reload on their own

    Unlike `vails run`, the window opened here has the REAL router bound, so
    the bridge works while you iterate. That matters: `vails run` opens the
    first window with an empty router, which is a frontend-only mode.

    -Watch recompiles on every .v change. It is a 60-line polling watcher
    rather than `v -live` because the build needs -cc gcc, the two Windows
    cflags and the DLL staging, none of which `v -live` does for us.

.EXAMPLE
    .\scripts\dev.ps1
    .\scripts\dev.ps1 -Watch
#>
[CmdletBinding()]
param(
    [switch]$Watch,
    [switch]$NoBuild,
    [int]$Port = 0
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$root = $script:FluxRoot
$exe = Join-Path $root 'build\fluxget.exe'

function Start-App {
    $args = @('--dev')
    if ($Port -gt 0) {
        $env:FLUXGET_PORT = "$Port"
    }
    $p = Start-Process -FilePath $exe -ArgumentList $args -WorkingDirectory $root -PassThru -WindowStyle Normal
    Start-Sleep -Seconds 3
    if ($p.HasExited) {
        Write-Err2 "the app exited immediately (code $($p.ExitCode))"
        Write-Warn2 'run .\build\fluxget.exe --dev from a console to see the error'
        return $null
    }
    Write-Ok "pid $($p.Id)  window '$($p.MainWindowTitle)'  dev server http://127.0.0.1:$(if($Port -gt 0){$Port}else{8413})/"
    return $p
}

if (-not $NoBuild) {
    & (Join-Path $PSScriptRoot 'build.ps1')
    if ($LASTEXITCODE -ne 0) { exit 1 }
}

$app = Start-App
if (-not $app) { exit 1 }

if (-not $Watch) {
    Write-Host ''
    Write-Host '  frontend edits reload automatically; .v edits need a rebuild.' -ForegroundColor 'DarkGray'
    Write-Host '  close the window, then run .\scripts\dev.ps1 -Watch to iterate on V.' -ForegroundColor 'DarkGray'
    exit 0
}

# ---- watch loop ----------------------------------------------------------
Write-Step 'watching .v files (Ctrl+C to stop)'
$seen = @{}
Get-ChildItem -Path $root -Filter '*.v' -Recurse -File |
    Where-Object { $_.FullName -notmatch '\\vendor\\' } |
    ForEach-Object { $seen[$_.FullName] = $_.LastWriteTimeUtc.Ticks }

try {
    while ($true) {
        Start-Sleep -Seconds 2
        $changed = @()
        Get-ChildItem -Path $root -Filter '*.v' -Recurse -File |
            Where-Object { $_.FullName -notmatch '\\vendor\\' } |
            ForEach-Object {
                $k = $_.FullName
                $t = $_.LastWriteTimeUtc.Ticks
                if (!$seen.contains($k)) {
                    $seen[$k] = $t
                    $changed += $k
                } elseif ($seen[$k] -ne $t) {
                    $seen[$k] = $t
                    $changed += $k
                }
            }
        if ($changed.Count -eq 0) { continue }

        foreach ($c in $changed) {
            Write-Host "    changed: $($c.Substring($root.Length + 1))" -ForegroundColor 'DarkGray'
        }
        if ($app -and -not $app.HasExited) {
            $app.Kill()
            $app.WaitForExit(3000) | Out-Null
        }
        Write-Step 'rebuilding'
        & (Join-Path $PSScriptRoot 'build.ps1')
        if ($LASTEXITCODE -ne 0) {
            Write-Err2 'build failed; the old window is gone. Fix and it will restart on the next save.'
            continue
        }
        $app = Start-App
    }
} finally {
    if ($app -and -not $app.HasExited) { $app.Kill() }
}
