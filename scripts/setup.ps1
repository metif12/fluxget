<#
.SYNOPSIS
    Check the machine, then make sure the repo and vendored vails are ready.

.DESCRIPTION
    The Fluxget equivalent of `vails doctor`, plus the one-time steps the
    README would otherwise have to carry:

      * submodule  - vendor/vails must be checked out
      * toolchain  - MSYS2 ucrt64 gcc, webview.h, the five runtime DLLs
      * aria2      - runtime/aria2c.exe, fetched (never committed, GPL)
      * build      - a real compile, because a doctor that cannot compile is
                     just a guess

.EXAMPLE
    .\scripts\setup.ps1
    .\scripts\setup.ps1 -FetchAria2
#>
[CmdletBinding()]
param(
    [switch]$FetchAria2,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$root = $script:FluxRoot
$problems = @()
$notes = @()

# ---- vails ---------------------------------------------------------------
Write-Step 'vails'
$sub = Invoke-Native -Command 'git' -Arguments @('-C', $root, 'submodule', 'status')
if ($sub.Code -ne 0 -or -not $sub.Output) {
    Write-Err2 'vendor/vails is not registered'
    $problems += 'run: git submodule update --init --recursive'
} else {
    Write-Ok "vendor/vails @ $(Get-VailsSha)"
    $lock = Get-Lock
    if ($lock) {
        Write-Ok "vails.lock @ $($lock.sha) (checked $($lock.checked))"
        if ($lock.sha -ne (Get-VailsSha)) {
            $notes += 'the checkout is ahead of vails.lock; run .\scripts\sync-vails.ps1 to re-stamp it'
        }
    } else {
        $notes += 'no vails.lock yet; run .\scripts\sync-vails.ps1'
    }
}

# ---- V -------------------------------------------------------------------
Write-Step 'V'
$v = Invoke-Native -Command 'v' -Arguments @('version')
if ($v.Code -ne 0) {
    Write-Err2 'v is not on PATH'
    $problems += 'install V 0.5.x'
} else {
    $ver = ($v.Output | Select-Object -First 1)
    Write-Ok $ver
    if ($ver -notmatch '0\.5\.') {
        $problems += "vails needs V 0.5.x; found $ver"
    }
}

# ---- toolchain -----------------------------------------------------------
Write-Step 'C toolchain (MSYS2 ucrt64)'
$tc = Test-Toolchain
if ($tc.gcc) {
    Write-Ok "gcc  $($tc.gccVer)"
} else {
    Write-Err2 'gcc not found'
    $problems += 'install MSYS2 ucrt64 and put C:\msys64\ucrt64\bin first on PATH'
}
if ($tc.webviewH) {
    Write-Ok "webview.h  $($tc.webviewH)"
} else {
    Write-Err2 'webview.h missing'
    $problems += 'pacman -S mingw-w64-ucrt-x86_64-webview mingw-w64-ucrt-x86_64-webview2-loader'
}
if ($tc.missing.Count -gt 0) {
    Write-Err2 "runtime DLLs missing: $($tc.missing -join ', ')"
    $problems += 'the same pacman command provides the webview DLLs; the three runtime ones ship with MSYS2'
} else {
    Write-Ok "$($script:FluxRuntimeDlls.Count) runtime DLLs present"
}

# ---- WebView2 runtime ----------------------------------------------------
Write-Step 'WebView2 runtime'
$wv = @(
    "$env:ProgramFiles\Microsoft\EdgeWebView\Application",
    "${env:ProgramFiles(x86)}\Microsoft\EdgeWebView\Application"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($wv) {
    Write-Ok $wv
} else {
    $notes += 'WebView2 runtime not found; the window will not open. It ships with Windows 11 and current Windows 10.'
}

# ---- aria2 ---------------------------------------------------------------
Write-Step 'aria2c'
$aria2 = Join-Path $root 'runtime\aria2c.exe'
if (Test-Path $aria2) {
    $a = Invoke-Native -Command $aria2 -Arguments @('--version')
    Write-Ok ($a.Output | Select-Object -First 1)
    $a.Output | Where-Object { $_ -match 'Features' } | ForEach-Object { Write-Host "    $_" -ForegroundColor 'DarkGray' }
} elseif ($FetchAria2) {
    & (Join-Path $PSScriptRoot 'fetch-aria2.ps1')
    if ($LASTEXITCODE -ne 0) { $problems += 'aria2c fetch failed' }
} else {
    Write-Warn2 'runtime\aria2c.exe not present'
    $notes += 'the app shows a setup page until aria2 is available. Run .\scripts\fetch-aria2.ps1, or point Settings at an existing aria2c.exe'
}

# ---- build ---------------------------------------------------------------
if (-not $SkipBuild) {
    Write-Step 'compile'
    & (Join-Path $PSScriptRoot 'build.ps1')
    if ($LASTEXITCODE -ne 0) { $problems += 'compile failed' }
}

# ---- report --------------------------------------------------------------
Write-Host ''
if ($notes.Count -gt 0) {
    Write-Step 'notes' 'Yellow'
    foreach ($n in $notes) { Write-Host "    - $n" -ForegroundColor 'Yellow' }
    Write-Host ''
}
if ($problems.Count -gt 0) {
    Write-Step "$($problems.Count) blocker(s)" 'Red'
    foreach ($p in $problems) { Write-Host "    XX $p" -ForegroundColor 'Red' }
    exit 1
}
Write-Step 'ready' 'Green'
Write-Host '    .\scripts\dev.ps1        run it with livereload'
Write-Host '    .\scripts\test.ps1       the gate'
exit 0
