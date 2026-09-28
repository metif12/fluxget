<#
.SYNOPSIS
    Capture the Fluxget window to a PNG.

.DESCRIPTION
    `v test` never opens a window (AGENTS.md section 4), so the last mile of
    every phase is proved by hand and the proof is a screenshot. This script
    makes that repeatable instead of a snippet someone retypes.

    HOW IT CAPTURES, and why it is not CopyFromScreen:

    A screen grab only works if the window is on top, and SetForegroundWindow
    from a background process is refused by Windows' foreground lock - silently,
    and regardless of the return value being checked. The result of a naive
    capture is a PNG of whatever was on the desktop, at the right size, which
    looks like a successful screenshot and is worse than no screenshot at all.

    So this uses PrintWindow with PW_RENDERFULLCONTENT, which asks the window to
    render itself into a memory DC and does not care about z-order. That works
    for WebView2 content, which is a separately composited surface.

    And it CHECKS the result: a capture with fewer than a handful of distinct
    colours is a blank frame, and this fails rather than writing a file that a
    reader would take as evidence. A proof script that can produce a plausible
    lie is not a proof script.

    A synthesised click is NOT attempted. It does not reach WebView2 content
    reliably, which is why the page drives the bridge itself - the same trick the
    vails repo uses with VAILS_DIALOG_PROBE. Where a run needs a download it
    does not have a user to paste, FLUXGET_PROBE does it (see core/state.v,
    seed_probe).

.EXAMPLE
    .\scripts\capture-window.ps1 -Out tests\e2e_windows\phase1-download.png
    .\scripts\capture-window.ps1 -Process fluxget -Settle 5 -Out shot.png
#>
[CmdletBinding()]
param(
    [string]$Out = '',
    [string]$Process = 'fluxget',
    # Seconds to wait before capturing: the window exists a beat before its
    # content has painted, and a screenshot of an empty window proves nothing.
    [int]$Settle = 3
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

Add-Type -AssemblyName System.Drawing

Add-Type @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
public class FluxWin {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint flags);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    // PW_RENDERFULLCONTENT (2) is the flag that makes PrintWindow work for
    // composited content such as WebView2; without it the frame comes back
    // empty or with the surface missing.
    public const uint PW_RENDERFULLCONTENT = 2;

    // Capture renders the window into a bitmap via PrintWindow.
    public static Bitmap Capture(IntPtr hWnd) {
        RECT r;
        if (!GetWindowRect(hWnd, out r)) throw new Exception("GetWindowRect failed");
        int w = r.Right - r.Left, h = r.Bottom - r.Top;
        if (w <= 0 || h <= 0) throw new Exception("window rectangle is empty");
        Bitmap bmp = new Bitmap(w, h, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(bmp)) {
            IntPtr hdc = g.GetHdc();
            try {
                if (!PrintWindow(hWnd, hdc, PW_RENDERFULLCONTENT))
                    throw new Exception("PrintWindow failed");
            } finally { g.ReleaseHdc(hdc); }
        }
        return bmp;
    }

    // DistinctColours is a blank-frame detector. A rendered UI has thousands of
    // distinct pixel values; an empty window has one or two.
    public static int DistinctColours(Bitmap bmp) {
        var seen = new System.Collections.Generic.HashSet<int>();
        for (int y = 0; y < bmp.Height; y += 3) {
            for (int x = 0; x < bmp.Width; x += 3) {
                seen.Add(bmp.GetPixel(x, y).ToArgb());
                if (seen.Count > 64) return seen.Count;
            }
        }
        return seen.Count;
    }
}
'@ -ReferencedAssemblies 'System.Drawing.dll'

$procs = @(Get-Process -Name $Process -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne 0 })
if ($procs.Count -eq 0) {
    Write-Err2 "no window found for process '$Process'"
    exit 1
}
if ($procs.Count -gt 1) {
    Write-Warn2 "$($procs.Count) windows for '$Process'; capturing the first"
}
$p = $procs[0]
if (-not [FluxWin]::IsWindowVisible($p.MainWindowHandle)) {
    Write-Err2 "the window of pid $($p.Id) is not visible"
    exit 1
}

Write-Host "    settling ${Settle}s before capture (content paints after the window exists)"
Start-Sleep -Seconds $Settle

$bmp = $null
try {
    $bmp = [FluxWin]::Capture($p.MainWindowHandle)
    $colours = [FluxWin]::DistinctColours($bmp)

    # Refuse to write a blank frame. This is the check that makes the file
    # trustworthy: a capture that failed to render is a failure, not evidence.
    if ($colours -lt 4) {
        Write-Err2 "the capture is blank ($colours distinct colours) - refusing to write it"
        Write-Host '    The window probably has not painted yet; raise -Settle.' -ForegroundColor 'Yellow'
        exit 1
    }

    if (-not $Out) {
        $Out = Join-Path $script:FluxRoot ("tests\e2e_windows\window-{0}.png" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }
    if (-not [System.IO.Path]::IsPathRooted($Out)) {
        $Out = Join-Path $script:FluxRoot $Out
    }
    $dir = Split-Path -Parent $Out
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
} finally {
    if ($bmp) { $bmp.Dispose() }
}

$kb = [math]::Round((Get-Item $Out).Length / 1KB, 1)
Write-Ok ("{0}  {1}x{2}  {3} KB  ({4} distinct colours)" -f $Out, $bmp.Width, $bmp.Height, $kb, $colours)
Write-Host "    window: '$($p.MainWindowTitle)'  pid $($p.Id)"
exit 0
