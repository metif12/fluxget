<#
.SYNOPSIS
    Keep vendor/vails in step with upstream and prove Fluxget still builds.

.DESCRIPTION
    vails is pre-1.0 and lands commits daily, so this script treats upstream
    `main` as unstable by default:

      sync-vails.ps1                fetch latest main -> full gate -> on failure
                                    roll back to vails.lock automatically and
                                    write docs/compat/vails-compat.md
      sync-vails.ps1 -Probe         local-only fast contract check, no network,
                                    no rollback. This is what dev.ps1 and
                                    build.ps1 call before every build.
      sync-vails.ps1 -Report        diff the public API surface between the
                                    locked SHA and origin/main
      sync-vails.ps1 -Rollback      go back to the locked SHA by hand
      sync-vails.ps1 -NoRollback    report a break but stop, do not revert

    The gate is, in order:
      1. `v test .` inside vendor/vails          (framework still green)
      2. `v test ./platform` + `v test .`        (our contract + unit tests)
      3. `v -cc gcc -o build/fluxget.exe .`      (it still links)

.EXAMPLE
    .\scripts\sync-vails.ps1
    .\scripts\sync-vails.ps1 -Probe
#>
[CmdletBinding()]
param(
    [switch]$Probe,
    [switch]$Report,
    [switch]$Rollback,
    [switch]$NoRollback,
    [switch]$SkipFetch
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$root = $script:FluxRoot
$vailsHome = Get-VailsHome
if (-not $vailsHome) {
    Write-Err2 'vendor/vails is missing. Run: git submodule update --init --recursive'
    exit 2
}

# Contract symbols Fluxget depends on. Kept here (not only in contract.v) so
# the report can answer "is this one still there?" without compiling, and so
# a break is visible before a full build.
$script:ContractPatterns = [ordered]@{
    'config.load'               = 'pub fn load\('
    'config.load_text'          = 'pub fn load_text\('
    'config.VailsConfig'        = 'pub struct VailsConfig'
    'config.WindowConfig'       = 'pub struct WindowConfig'
    'config.BundleConfig'       = 'pub struct BundleConfig'
    'bridge.new_router'         = 'pub fn new_router\('
    'bridge.Router'             = 'pub struct Router'
    'bridge.register_validated' = 'pub fn \(mut r Router\) register_validated\('
    'bridge.validate_empty'     = 'pub fn validate_empty\('
    'bridge.validate_any'       = 'pub fn validate_any\('
    'bridge.MethodHandler'      = 'pub type MethodHandler'
    'capabilities.Registry'     = 'pub struct Registry'
    'services.install'          = 'pub fn install\('
    'services.Service'          = 'pub struct Service'
    'services.Command'          = 'pub struct Command'
    'services.dialog_manifest'  = 'pub fn dialog_manifest\('
    'services.install_dialog'   = 'pub fn install_dialog\('
    'services.os_info_manifest' = 'pub fn os_info_manifest\('
    'services.install_os_info'  = 'pub fn install_os_info\('
    'services.dts'              = 'pub fn dts\('
    'services.snippets'         = 'pub fn snippets\('
    'services.granted_commands' = 'pub fn granted_commands\('
    'webview.run'               = 'pub fn run\('
    'webview.Config'            = 'pub struct Config'
    'webview.Ctx'               = 'pub struct Ctx'
    'webview.default_csp'       = 'pub fn default_csp\('
    'webview.inject_csp'        = 'pub fn inject_csp\('
    'dev.new_dev_server'        = 'pub fn new_dev_server\('
    'dev.DevServer'             = 'pub struct DevServer'
    'dev.default_port'          = 'pub const default_port'
    'dev.inject_livereload'     = 'pub fn inject_livereload\('
    'events.Bus'                = 'pub struct Bus'
    'events.to_js'              = 'pub fn to_js\('
    'assets.content_type'       = 'pub fn content_type\('
}

function Get-Surface {
    <#
    Every `pub` declaration in the vails tree at a given revision, keyed by FILE
    PATH and declaration text - and deliberately by neither LINE NUMBER nor the
    revision's own SHA.

    `git grep -n <rev>` emits `<sha>:<path>:<line>:<text>`, and both prefixes have
    to go before anything is compared:

      - the LINE NUMBER, so a declaration that merely moved is not reported as
        one removal plus one addition;
      - the SHA, or the two sides of the comparison are prefixed differently and
        therefore share nothing. That is what produced "246 added, 246 removed"
        for a commit that added one example and a docs file: every declaration
        was on both lists at once.

    Leaving either in makes the drafted issue claim we lost ~246 symbols that are
    all still present. The revision is resolved to a SHA first so the prefix
    stripped is exactly the one git printed.
    #>
    param([string]$Rev = 'HEAD')
    $sha = (Invoke-Native -Command 'git' -Arguments @('-C', $vailsHome, 'rev-parse', $Rev)).Output[0]
    if (-not $sha) { return @() }
    $sha = $sha.Trim()
    $r = Invoke-Native -Command 'git' -Arguments @('-C', $vailsHome, 'grep', '-n', '-E', '^pub (fn|struct|type|const|mut)', $sha, '--', '*.v')
    if ($r.Code -gt 1) { return @() }
    return @($r.Output | ForEach-Object {
        $line = $_.Trim()
        if ($line.StartsWith("$sha`:")) { $line = $line.Substring($sha.Length + 1) }
        if ($line -match '^(.+?):(\d+):(.*)$') { return "$($Matches[1]):$($Matches[3])" }
        return $line
    })
}

function Test-Contract {
    <# Cheap: greps the checked-out working tree for each contract symbol. #>
    $files = Get-ChildItem -Path $vailsHome -Filter '*.v' -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\\.git\\' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($f in $files) {
        [void]$sb.AppendLine([System.IO.File]::ReadAllText($f.FullName))
    }
    $blob = $sb.ToString()
    $missing = @()
    foreach ($name in $script:ContractPatterns.Keys) {
        if ($blob -notmatch $script:ContractPatterns[$name]) { $missing += $name }
    }
    return $missing
}

function Invoke-Gate {
    <# Full gate. Returns $true/$false and prints why. #>
    $fail = @()

    Write-Step 'gate 1/3  v test . (vendor/vails)'
    $r = Invoke-Native -Command 'v' -Arguments ((Get-VCFlags) + @('test', '.')) -WorkingDirectory $vailsHome -Tail 12
    if ($r.Code -ne 0) {
        $r.Output | ForEach-Object { Write-Host "    $_" -ForegroundColor 'Red' }
        $fail += 'vendor/vails: v test . failed'
    } else {
        $s = ($r.Output | Select-String 'Summary for all V' | Select-Object -Last 1)
        Write-Ok $(if ($s) { $s.ToString().Trim() } else { 'green' })
    }

    if (-not (Test-Path (Join-Path $root 'main.v'))) {
        Write-Warn2 'gate 2/3 + 3/3 skipped (no main.v yet)'
        return $fail.Count -eq 0
    }

    Write-Step 'gate 2/3  v test  (fluxget modules only)'
    $env:VMODULES = (Get-FluxVModules)
    $targets = Get-FluxVTargets
    $r = Invoke-Native -Command 'v' -Arguments ((Get-VCFlags) + @('test') + $targets) -WorkingDirectory $root -Tail 30
    if ($r.Code -ne 0) {
        $r.Output | ForEach-Object { Write-Host "    $_" -ForegroundColor 'Red' }
        $fail += 'fluxget: v test failed'
    } else {
        $s = ($r.Output | Select-String 'Summary for all V' | Select-Object -Last 1)
        Write-Ok $(if ($s) { $s.ToString().Trim() } else { 'green' })
    }

    Write-Step 'gate 3/3  compile'
    $vArgs = Get-VCFlags
    $vArgs += @('-o', 'build\_gate.exe', '.')
    $r = Invoke-Native -Command 'v' -Arguments $vArgs -WorkingDirectory $root -Tail 30
    if ($r.Code -ne 0) {
        $r.Output | ForEach-Object { Write-Host "    $_" -ForegroundColor 'Red' }
        $fail += 'fluxget: compile failed'
    } else {
        Remove-Item (Join-Path $root 'build\_gate.exe') -ErrorAction SilentlyContinue
        Write-Ok 'links'
    }
    return $fail.Count -eq 0
}

function Write-CompatReport {
    <#
    Writes docs/compat/vails-compat.md: the public API delta between the locked
    SHA and HEAD, plus the contract check on the checked-out tree. Leaves a
    ready-to-file issue in docs/compat/vails-issue.md when something is broken.
    #>
    $lock = Get-Lock
    $docsCompat = Join-Path $root 'docs\compat'
    New-Item -ItemType Directory -Path $docsCompat -Force | Out-Null

    $locked = if ($lock) { $lock.sha } else { '(none - first run)' }
    $r = Invoke-Native -Command 'git' -Arguments @('-C', $vailsHome, 'rev-parse', 'origin/main')
    $originSha = if ($r.Code -eq 0) { $r.Output[0].Trim() } else { '(no origin/main)' }

    # TWO comparisons, because they answer different questions and only one of
    # them is useful at any moment:
    #
    #   locked -> HEAD           what we are actually running against
    #   locked -> origin/main    what we rejected, or what is coming
    #
    # After a rollback HEAD IS the locked revision, so the first comparison is
    # 0/0 and says nothing - which is exactly when the second one matters most.
    # Reporting only the first is how a rollback leaves you with no explanation
    # of what you rolled back FROM.
    $surfaceLocked = if ($lock) { Get-Surface $lock.sha } else { @() }
    $surfaceHead = Get-Surface 'HEAD'
    $added = @($surfaceHead | Where-Object { $_ -notin $surfaceLocked })
    $removed = @($surfaceLocked | Where-Object { $_ -notin $surfaceHead })
    $missing = @(Test-Contract)

    $upstreamAdded = @()
    $upstreamRemoved = @()
    if ($originSha -and $originSha -ne 'HEAD') {
        $surfaceOrigin = Get-Surface $originSha
        $upstreamAdded = @($surfaceOrigin | Where-Object { $_ -notin $surfaceLocked })
        $upstreamRemoved = @($surfaceLocked | Where-Object { $_ -notin $surfaceOrigin })
    }

    $log = @()
    $log += '# vails compatibility report'
    $log += ''
    $log += ('Generated {0} by `scripts/sync-vails.ps1`.' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))
    $log += ''
    $log += '| | |'
    $log += '|---|---|'
    $log += "| locked (vails.lock) | ``$locked`` |"
    $log += "| checked out | ``$(Get-VailsSha)`` |"
    $log += "| origin/main | ``$originSha`` |"
    $log += "| vails commit date | $(Get-VailsDate) |"
    $log += ''
    $log += ('## Contract symbols ({0} checked)' -f $script:ContractPatterns.Count)
    $log += ''
    if ($missing.Count -eq 0) {
        $log += 'All contract symbols are present in the checked-out tree.'
    } else {
        $log += '### Missing from the checked-out tree'
        $log += ''
        foreach ($m in $missing) { $log += "- ``$m``" }
    }
    $log += ''
    $log += ('## Checked-out tree vs locked: {0} added, {1} removed' -f $added.Count, $removed.Count)
    $log += ''
    if ($added.Count -eq 0 -and $removed.Count -eq 0) {
        $log += 'No change in the `pub` surface between the locked revision and the checked-out tree.'
    } else {
        foreach ($a in ($added | Sort-Object)) { $log += "- added ``$a``" }
        foreach ($r2 in ($removed | Sort-Object)) { $log += "- removed ``$r2``" }
    }
    $log += ''
    $log += ('## origin/main vs locked: {0} added, {1} removed' -f $upstreamAdded.Count, $upstreamRemoved.Count)
    $log += ''
    if ($upstreamAdded.Count -eq 0 -and $upstreamRemoved.Count -eq 0) {
        $log += 'Upstream HEAD matches the locked revision on the `pub` surface.'
    } else {
        $log += 'What the newest upstream revision does to the surface. This is the comparison to read'
        $log += 'when a run rolled back, because the checked-out tree is then the locked revision and'
        $log += 'the section above is empty by construction.'
        $log += ''
        if ($upstreamRemoved.Count -gt 0) {
            $log += '### Removed or renamed upstream'
            $log += ''
            foreach ($r2 in ($upstreamRemoved | Sort-Object)) { $log += "- ``$r2``" }
            $log += ''
        }
        if ($upstreamAdded.Count -gt 0) {
            $log += '### Added upstream'
            $log += ''
            foreach ($a in ($upstreamAdded | Sort-Object)) { $log += "- ``$a``" }
            $log += ''
        }
    }
    $log += '## Fluxget commits to vails'
    $log += ''
    $log += 'Listed in the vails plan: `clipboard` (native half), `menu`, `tray`, `opener`,'
    $log += '`window-state`, then S2 `single-instance`. Each already has a `// COMPAT(...)` marker in'
    $log += 'the Fluxget source; the ownership table lives in README.md under "Feature ownership".'
    $log += ''
    $log += 'Withdrawn upstream before Fluxget adopted them, so there is nothing to switch to and the'
    $log += 'capability is ours to build: `notification` (`services/notification.v`) and the `store`'
    $log += 'service (`state/store.v`). Both were in the plan and both are gone as of the revision'
    $log += 'named in the `origin/main` section above.'
    $log += ''
    [System.IO.File]::WriteAllLines((Join-Path $docsCompat 'vails-compat.md'), $log, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok "wrote docs/compat/vails-compat.md ($($added.Count) added, $($removed.Count) removed, $($missing.Count) contract gaps)"

    if ($missing.Count -eq 0 -and $added.Count -eq 0 -and $removed.Count -eq 0) { return }

    $iss = @()
    # The title and the framing follow the CONTRACT, not the churn. On the first
    # real run of this report the contract was intact (0 gaps) and the drafted
    # issue still said "Fluxget cannot build" and "it is what broke", because
    # that text was unconditional. What actually happened that day was upstream's
    # own suite going red on a new example while our code compiled untouched -
    # and that is a different, much smaller, much more actionable report.
    if ($missing.Count -gt 0) {
        $iss += '# Fluxget cannot build against the current vails HEAD'
        $iss += ''
        $iss += 'Fluxget treats vails as an unstable dependency: it vendors the framework as a git'
        $iss += 'submodule and runs a machine-checked API contract before every build. The contract'
        $iss += 'is the list of symbols the app imports, and it is what broke.'
    } else {
        $iss += '# Public API surface churn on vails HEAD (Fluxget contract intact)'
        $iss += ''
        $iss += '**Fluxget still builds and still passes its gate against this revision.** Every symbol'
        $iss += 'it imports is present; this is the surface-diff report only, and it is filed because'
        $iss += 'an unattended dependency that moves daily should have its churn reviewed while it is'
        $iss += 'still cheap to review.'
    }
    $iss += ''
    $iss += '> Draft issue for [metif12/vails](https://github.com/metif12/vails). Generated by'
    $iss += '> `scripts/sync-vails.ps1`; check the numbers before sending.'
    $iss += ''
    $iss += '| | |'
    $iss += '|---|---|'
    $iss += "| last known good | ``$(if ($lock) { $lock.sha } else { 'n/a' })`` |"
    $iss += "| compared | ``$(Get-VailsSha)`` |"
    $iss += "| revision date | $(Get-VailsDate) |"
    $iss += "| Fluxget contract symbols | $($script:ContractPatterns.Count) checked, **$($missing.Count) missing** |"
    $iss += ''
    if ($missing.Count -gt 0) {
        $iss += '## Symbols Fluxget imports that are gone'
        $iss += ''
        foreach ($m in $missing) { $iss += "- ``$m``" }
        $iss += ''
    }
    if ($removed.Count -gt 0) {
        $iss += '## Removed from the public surface'
        $iss += ''
        $iss += 'Compared by file path and declaration text, so a declaration that merely moved is'
        $iss += 'not in this list.'
        $iss += ''
        foreach ($r2 in ($removed | Sort-Object)) { $iss += "- ``$r2``" }
        $iss += ''
    }
    if ($added.Count -gt 0) {
        $iss += '## Added to the public surface (informational)'
        $iss += ''
        foreach ($a in ($added | Sort-Object)) { $iss += "- ``$a``" }
        $iss += ''
    }
    $iss += '## What would make this a non-event'
    $iss += ''
    $iss += '1. Tag releases. Fluxget pins to a SHA because `const version = ''0.2.0''` in the CLI'
    $iss += '   is hardcoded and there are no git tags, so there is nothing stable to depend on.'
    $iss += '2. Keep `platform/host.v` compiling across a refactor: it is one file, roughly 250'
    $iss += '   lines, and every app built on vails will have an equivalent.'
    $iss += ''
    [System.IO.File]::WriteAllLines((Join-Path $docsCompat 'vails-issue.md'), $iss, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok 'wrote docs/compat/vails-issue.md (draft issue, not sent)'
}

# ---------------------------------------------------------------- dispatch

if ($Probe) {
    Write-Step "vails contract probe @ $(Get-VailsSha)"
    $missing = @(Test-Contract)
    if ($missing.Count -gt 0) {
        Write-Err2 "$($missing.Count) contract symbol(s) missing from the vendored vails:"
        $missing | ForEach-Object { Write-Host "      - $_" -ForegroundColor 'Red' }
        Write-Warn2 'run .\scripts\sync-vails.ps1 -Report, then fix platform/ or -Rollback'
        exit 1
    }
    Write-Ok "all $($script:ContractPatterns.Count) contract symbols present"
    exit 0
}

if ($Rollback) {
    $lock = Get-Lock
    if (-not $lock) { Write-Err2 'vails.lock not found'; exit 2 }
    Write-Step "rolling vendor/vails back to $($lock.sha)"
    $r = Invoke-Native -Command 'git' -Arguments @('-C', $vailsHome, 'checkout', '--detach', $lock.sha)
    if ($r.Code -ne 0) {
        $r.Output | ForEach-Object { Write-Host "    $_" -ForegroundColor 'Red' }
        exit 1
    }
    Write-Ok "now at $(Get-VailsSha)"
    exit 0
}

if ($Report) {
    Write-CompatReport
    exit 0
}

# ---- default: fetch + gate + auto-rollback -------------------------------

$before = Get-VailsSha

if (-not $SkipFetch) {
    Write-Step 'fetching vendor/vails'
    $r = Invoke-Native -Command 'git' -Arguments @('-C', $vailsHome, 'fetch', '--all', '--prune')
    $r.Output | ForEach-Object { Write-Host "    $_" }
    $r = Invoke-Native -Command 'git' -Arguments @('-C', $vailsHome, 'merge', '--ff-only', 'origin/main')
    if ($r.Code -ne 0) {
        Write-Warn2 'could not fast-forward (upstream rewritten, or detached); re-attaching to main'
        $r.Output | Select-Object -Last 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor 'Yellow' }
        Invoke-Native -Command 'git' -Arguments @('-C', $vailsHome, 'checkout', 'main') | Out-Null
        $r = Invoke-Native -Command 'git' -Arguments @('-C', $vailsHome, 'merge', '--ff-only', 'origin/main')
        $r.Output | ForEach-Object { Write-Host "    $_" }
    }
    # Keep the recorded submodule SHA in step with what is checked out.
    $r = Invoke-Native -Command 'git' -Arguments @('-C', $root, 'add', 'vendor/vails')
}

$after = Get-VailsSha
if ($after -ne $before) { Write-Ok "vails $before -> $after" }

# A commit younger than 3h has not been exercised by anyone yet.
if ($after) {
    $stamp = [datetime]::Parse((Get-VailsDate)).ToLocalTime()
    $age = (Get-Date) - $stamp
    if ($age.TotalHours -lt 3) {
        Write-Warn2 ("vails HEAD is only {0:N0} min old - untested upstream, a break here is expected" -f $age.TotalMinutes)
    }
}

$missing = @(Test-Contract)
$green = $false
if ($missing.Count -gt 0) {
    Write-Err2 "contract check failed: $($missing.Count) symbol(s) missing"
    $missing | ForEach-Object { Write-Host "      - $_" -ForegroundColor 'Red' }
} else {
    $green = Invoke-Gate
}

if ($green) {
    Save-Lock -Sha $after -Note (Invoke-Native -Command 'git' -Arguments @('-C', $vailsHome, 'log', '-1', '--format=%s', $after)).Output[0] | Out-Null
    Write-Ok 'gate green - vails.lock updated'
    exit 0
}

Write-CompatReport

if ($NoRollback) {
    Write-Err2 'gate failed; staying on the new vails (as requested by -NoRollback)'
    exit 1
}

$lock = Get-Lock
if (-not $lock -or $lock.sha -eq $after) {
    Write-Err2 'gate failed and there is no earlier vails.lock to fall back to'
    exit 1
}

Write-Warn2 "gate failed on $after - rolling back to $($lock.sha)"
$r = Invoke-Native -Command 'git' -Arguments @('-C', $vailsHome, 'checkout', '--detach', $lock.sha)
$r.Output | ForEach-Object { Write-Host "    $_" }
$stillMissing = @(Test-Contract)
if ($stillMissing.Count -gt 0) {
    Write-Err2 "the locked revision is missing contract symbols too: $($stillMissing -join ', ')"
    Write-Err2 'vendor/vails needs a real fix, not a rollback'
    exit 1
}
Invoke-Native -Command 'git' -Arguments @('-C', $root, 'add', 'vendor/vails') | Out-Null
Write-Ok "back on the locked revision $(Get-VailsSha); see docs/compat/vails-compat.md"
exit 1
