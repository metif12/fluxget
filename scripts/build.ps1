<#
.SYNOPSIS
    Compile Fluxget to build/fluxget.exe with the Windows runtime staged.

.DESCRIPTION
    The two compiler flags are not optional on this machine and are worth
    understanding rather than copying:

      -cflags -Wno-incompatible-pointer-types
          V's own thirdparty/vschannel/vschannel.c predates GCC 14, which
          turned the pointer-type mismatch in WSAConnectByNameW() into a hard
          error. GCC 16.1 (MSYS2 ucrt64) is what is installed. The vails repo
          documents the same flag for the same reason.

      -ldflags -lws2_32
          Anything importing `net` (our api/ control server, and vails' dev
          server) needs the winsock import library linked explicitly. Vails'
          CLI build documents this too.

    Both are Windows-only; the script passes them only on Windows.
#>
[CmdletBinding()]
param(
    [switch]$SkipGate,
    [switch]$Release
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$root = $script:FluxRoot
$vailsHome = Get-VailsHome
if (-not $vailsHome) {
    Write-Err2 'vendor/vails not found. Run: git submodule update --init --recursive'
    exit 2
}

# ---- rule R2: the compat gate runs before every build --------------------
if (-not $SkipGate) {
    Write-Step 'compat gate'
    & (Join-Path $PSScriptRoot 'sync-vails.ps1') -Probe
    if ($LASTEXITCODE -ne 0) {
        Write-Err2 'contract check failed - build aborted'
        Write-Warn2 'run .\scripts\sync-vails.ps1 -Report, fix platform/, or -Rollback'
        exit 1
    }
}

# ---- rule R1: nothing outside platform/ may import vails ------------------
& (Join-Path $PSScriptRoot 'check-isolation.ps1')
if ($LASTEXITCODE -ne 0) { exit 1 }

$buildDir = Join-Path $root 'build'
New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
$outExe = Join-Path $buildDir 'fluxget.exe'

$env:VMODULES = (Get-FluxVModules)
$env:VAILS_HOME = $vailsHome
Enable-Toolchain

$vArgs = Get-VCFlags
if (-not $Release) { $vArgs += @('-g') }
$vArgs += @('-o', $outExe, '.')

Write-Step "compiling  ->  $outExe"
Write-Host "    VMODULES=$env:VMODULES"
Write-Host "    v $($vArgs -join ' ')"

$r = Invoke-Native -Command 'v' -Arguments $vArgs -WorkingDirectory $root
if ($r.Code -ne 0) {
    Write-Err2 'compile failed'
    $r.Output | Select-Object -First 40 | ForEach-Object { Write-Host "    $_" -ForegroundColor 'Red' }
    exit 1
}
# Notices are not failures, but a stale "unused function" warning is worth
# seeing: it usually means a contract probe stopped being called.
$r.Output | Where-Object { $_ -match 'notice:' } | Select-Object -First 10 | ForEach-Object {
    Write-Host "    $_" -ForegroundColor 'DarkGray'
}

$size = [math]::Round((Get-Item $outExe).Length / 1MB, 2)
Write-Ok "fluxget.exe  $size MB"

# ---- Windows runtime DLLs, side by side (vails Phase 1 finding) -----------
if (Test-IsWindowsHost) {
    Write-Step 'staging runtime DLLs'
    $missing = @()
    foreach ($d in $script:FluxRuntimeDlls) {
        $src = Join-Path $script:FluxMsysBin $d
        if (Test-Path $src) {
            Copy-Item $src $buildDir -Force
        } else {
            $missing += $d
        }
    }
    if ($missing.Count -gt 0) {
        Write-Warn2 "missing from $script:FluxMsysBin : $($missing -join ', ')"
        Write-Warn2 'pacman -S mingw-w64-ucrt-x86_64-webview mingw-w64-ucrt-x86_64-webview2-loader'
    } else {
        Write-Ok "$($script:FluxRuntimeDlls.Count) DLLs next to the exe"
    }
}

# ---- frontend packing -----------------------------------------------------
$packSrc = Join-Path $root 'tools\pack'
if (Test-Path (Join-Path $packSrc 'main.v')) {
    Write-Step 'packing frontend'
    $packExe = Join-Path $buildDir 'pack.exe'
    $env:VMODULES = $script:FluxRoot
    $r = Invoke-Native -Command 'v' -Arguments @('-o', $packExe, $packSrc) -WorkingDirectory $root
    if ($r.Code -ne 0) {
        Write-Err2 'tools/pack did not compile'
        $r.Output | Select-Object -First 20 | ForEach-Object { Write-Host "    $_" -ForegroundColor 'Red' }
        exit 1
    }
    $r = Invoke-Native -Command $packExe -Arguments @() -WorkingDirectory $root
    if ($r.Code -ne 0) {
        Write-Err2 'tools/pack failed'
        $r.Output | ForEach-Object { Write-Host "    $_" -ForegroundColor 'Red' }
        exit 1
    }
    $r.Output | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" }
    Write-Ok 'build/web/index.html'
} else {
    Write-Warn2 'tools/pack not present yet - production frontend will be empty'
}

Write-Step 'done'
Write-Host "    run it:  .\build\fluxget.exe --dev" -ForegroundColor 'Green'
Write-Host "    release: .\build\fluxget.exe" -ForegroundColor 'Green'
exit 0
