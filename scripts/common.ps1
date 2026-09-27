# scripts/common.ps1 - shared helpers for every Fluxget script.
#
# Dot-sourced, never run directly. Holds the one definition of "where do
# things live" so setup/test/dev/build/ext/sync-vails cannot drift apart.

Set-StrictMode -Version Latest

# Resolve the project root from this file, so scripts work from any cwd.
function Get-FluxRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

$script:FluxRoot = Get-FluxRoot

function Test-IsWindowsHost {
    <#
    $IsWindows only exists from PowerShell 6, and this host is 5.1, where
    Set-StrictMode turns reading it into a terminating error. $env:OS is the
    portable check and is present on every Windows PowerShell.
    #>
    return ($env:OS -eq 'Windows_NT')
}

function Get-VailsHome {
    # The vendored submodule wins. VAILS_HOME is the escape hatch for working
    # against a sibling checkout (e.g. D:\MyProjects\vails) without re-cloning.
    $envVar = $env:VAILS_HOME
    if ($envVar -and (Test-Path (Join-Path $envVar 'v.mod'))) {
        return (Resolve-Path $envVar).Path
    }
    $vendored = Join-Path $script:FluxRoot 'vendor\vails'
    if (Test-Path (Join-Path $vendored 'v.mod')) {
        return (Resolve-Path $vendored).Path
    }
    return ''
}

function Get-VailsSha {
    $home_ = Get-VailsHome
    if (-not $home_) { return '' }
    $sha = (git -C $home_ rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0) { return '' }
    return $sha.Trim()
}

function Get-VailsDate {
    $home_ = Get-VailsHome
    if (-not $home_) { return '' }
    $d = (git -C $home_ log -1 --format=%aI 2>$null)
    if ($LASTEXITCODE -ne 0) { return '' }
    return $d.Trim()
}

# The five MSYS2 ucrt64 DLLs a Vails GUI binary needs side-by-side on Windows.
$script:FluxRuntimeDlls = @(
    'libwebview-0.12.dll',
    'WebView2Loader.dll',
    'libgcc_s_seh-1.dll',
    'libstdc++-6.dll',
    'libwinpthread-1.dll'
)

$script:FluxMsysBin = 'C:\msys64\ucrt64\bin'

function Enable-Toolchain {
    # gcc must resolve to the MSYS2 ucrt64 one, and stay first on PATH.
    $env:PATH = "$script:FluxMsysBin;$env:PATH"
}

function Test-Toolchain {
    <# Returns a hashtable: gcc => bool, webviewH => path-or-'', dllsMissing => string[] #>
    Enable-Toolchain
    $gccOk = $false
    $gccVer = ''
    $gccOut = & gcc --version 2>$null
    if ($LASTEXITCODE -eq 0 -and $gccOut) {
        $gccOk = $true
        $gccVer = ($gccOut | Select-Object -First 1).Trim()
    }
    $header = 'C:\msys64\ucrt64\include\webview\webview.h'
    $missing = @()
    foreach ($d in $script:FluxRuntimeDlls) {
        if (-not (Test-Path (Join-Path $script:FluxMsysBin $d))) { $missing += $d }
    }
    return @{
        gcc      = $gccOk
        gccVer   = $gccVer
        webviewH = if (Test-Path $header) { $header } else { '' }
        missing  = $missing
    }
}

function Get-FluxVModules {
    <#
    Both roots have to be on VMODULES:
      * the vails root, so its modules (bridge, webview, services, ...) resolve
        by bare name;
      * the project root, so our own modules (rpc, engine, api, ...) do too.
    This mirrors what `vails build` does internally (join_modules_path prepends
    the vails home to whatever was already in VMODULES and keeps it) — we do
    it here because our build script calls `v` directly, so we also control
    the gcc/dll staging `vails build` does not do yet.

    Order matters only for shadowing; nothing in Fluxget collides with a vails
    module name, and the vails root comes first so it always wins.
    #>
    $sep = [System.IO.Path]::PathSeparator   # ';' on Windows
    $parts = @()
    $home_ = Get-VailsHome
    if ($home_) { $parts += $home_ }
    $parts += $script:FluxRoot
    $env:VMODULES = ($parts -join $sep)
    return $env:VMODULES
}

function Set-FluxEnv {
    $home_ = Get-VailsHome
    if ($home_) { $env:VAILS_HOME = $home_ }
    Get-FluxVModules | Out-Null
    Enable-Toolchain
}

function Write-Step {
    param([string]$Message, [string]$Color = 'Cyan')
    Write-Host "==> $Message" -ForegroundColor $Color
}

function Write-Ok {
    param([string]$Message)
    Write-Host "    ok  $Message" -ForegroundColor 'Green'
}

function Write-Warn2 {
    param([string]$Message)
    Write-Host "    !!  $Message" -ForegroundColor 'Yellow'
}

function Write-Err2 {
    param([string]$Message)
    Write-Host "    XX  $Message" -ForegroundColor 'Red'
}

function Get-FluxVTargets {
    <#
    The paths `v fmt` and `v test` must be given, so they never walk into
    vendor/vails.

    Both commands recurse: `v fmt -w .` would rewrite the submodule's working
    tree, and `v test .` would re-run the framework's own 26 test files (60s
    wasted, and a green run that says nothing about Fluxget). So we hand them
    an explicit list instead:

      * every Fluxget .v file, minus vendor/, build/ and .git
      * grouped by directory, so a module is passed once

    Files that sit in the project root are passed as file paths rather than as
    '.', because '.' is the only form that recurses into the submodule.
    #>
    $root = $script:FluxRoot
    $skip = @('vendor', 'build', 'node_modules', '.git', '.v', '.vmodules')

    $dirs = @{}
    $files = @()
    Get-ChildItem -Path $root -Filter '*.v' -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = $_.FullName.Substring($root.Length + 1)
        $parts = @($rel -split '[\\/]')
        # Test every directory segment above the file, so both vendor/vails/x.v
        # and a nested vendor/vails/examples/hello/x.v are excluded.
        if ($parts.Count -gt 1) {
            $parents = $parts[0..($parts.Count - 2)]
            if (@($parents | Where-Object { $skip -contains $_ }).Count -gt 0) { return }
            $dirs[($parents -join '/')] = $true
        } else {
            $files += ('./' + $rel)
        }
    }

    $targets = @()
    $targets += @($dirs.Keys | Sort-Object | ForEach-Object { './' + ($_ -replace '/', '\') })
    $targets += @($files | Sort-Object)
    return $targets
}

function Get-VCFlags {
    <#
    Compiler flags that are mandatory on this machine, for `v test` as well as
    for the build. They are not cargo-culted; each one has a reason:

      -cc gcc
          MSYS2 ucrt64 gcc is the only C toolchain installed, and V's default
          (tcc) is not in this V build.

      -cflags -Wno-incompatible-pointer-types
          V ships thirdparty/vschannel/vschannel.c, which predates GCC 14.
          GCC 14 turned that pointer-type mismatch into a hard error and the
          installed GCC is 16.1, so the file no longer compiles as shipped.
          The vails repo documents the same flag for the same reason.

      -ldflags -lws2_32
          Anything importing `net` needs the winsock import library linked
          explicitly. Our api/ control server and vails' dev server both do.

    Windows-only; on Linux the flags are empty and -gc none applies instead
    (see the vails ADR-0005 note, not relevant to this build).
    #>
    $flags = @('-cc', 'gcc')
    if (Test-IsWindowsHost) {
        $flags += @('-cflags', '-Wno-incompatible-pointer-types')
        $flags += @('-ldflags', '-lws2_32')
    }
    return $flags
}

function Get-Lock {
    $path = Join-Path $script:FluxRoot 'vails.lock'
    if (-not (Test-Path $path)) { return $null }
    return (Get-Content $path -Raw | ConvertFrom-Json)
}

function Invoke-Native {
    <#
    Runs a native command and returns @{ Code; Output } with stderr folded in.

    PowerShell 5.1 turns a native command's stderr into a *terminating*
    error whenever $ErrorActionPreference is 'Stop', which would abort every
    one of our scripts on the first line of compiler or git diagnostics. So
    the preference is relaxed for the duration of the call and the exit code
    is what the caller inspects — never $ErrorActionPreference.

        $r = Invoke-Native v @('test', '.')
        if ($r.Code -ne 0) { ... $r.Output ... }
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = '',
        [int]$Tail = 0   # when > 0, keep only the last N lines
    )

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        Push-Location $WorkingDirectory
        try {
            $raw = & $Command @Arguments 2>&1
            $code = $LASTEXITCODE
        } finally {
            Pop-Location
        }
    } finally {
        $ErrorActionPreference = $prev
    }

    $lines = @($raw | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { "$_" } })
    if ($Tail -gt 0 -and $lines.Count -gt $Tail) {
        $lines = $lines[($lines.Count - $Tail)..($lines.Count - 1)]
    }
    return @{ Code = $code; Output = $lines }
}

function Save-Lock {
    param([string]$Sha, [string]$Note)
    $existing = Get-Lock
    $obj = [ordered]@{
        sha      = $Sha
        checked  = (Get-Date).ToUniversalTime().ToString('o')
        fluxget  = if ($existing) { $existing.fluxget } else { '0.1.0' }
        note     = if ($Note) { $Note } elseif ($existing) { $existing.note } else { '' }
    }
    $json = $obj | ConvertTo-Json
    [System.IO.File]::WriteAllText((Join-Path $script:FluxRoot 'vails.lock'), $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
    return ($obj | ConvertTo-Json)
}
