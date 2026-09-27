# tests/e2e_windows — manual GUI proofs

`v test` never opens a window and never starts aria2c. That is deliberate (the
rpc client takes an injected `Transport`), but it means the last mile is
verified by hand, exactly as the vails repo does it.

## Setup

```powershell
.\scripts\setup.ps1
.\scripts\dev.ps1          # dev server + the real router
```

## Phase 0 — the chain, and what each observation proves

Open <http://127.0.0.1:8413/> in a normal browser too: the page degrades to a
"no window.vails runtime" card instead of a blank screen.

| Check | How | Expected | What it proves |
|---|---|---|---|
| window | `Get-Process fluxget` | a window titled `Fluxget`, 1360×880 | `vails.json` → `webview.run` |
| dev server | `curl http://127.0.0.1:8413/` | 200, HTML containing `__vails_dev_version` | livereload injection |
| assets | `curl .../css/tokens.css`, `.../js/boot.js` | 200 with the right content types | capability-scoped serving |
| scoping | `curl .../vails.json`, `.../nope.js` | 404 | reads outside the granted root are refused |
| round trip | the page's `ping -> pong` | `pong` | JS → `bridge.Router` → handler → JS |
| grants | the page's last log line | `forbidden: fluxget.not_granted is not allowed for window "main"` | the T2 gate denies, and says `forbidden:` rather than `unknown method:` |
| engine | the `engine` card | `bootstrap: aria2 engine starts in Phase 1` | Phase 0 does not fake a ready engine |

Proof: `phase0-bridge.png` in this directory.

To retake it, capture the window by handle:

```powershell
Add-Type -AssemblyName System.Drawing
. .\scripts\common.ps1
$p = Get-Process fluxget
# CopyFromScreen over GetWindowRect($p.MainWindowHandle)
```

A synthesised click does not reach WebView2 content reliably, which is why the
page calls the bridge itself — the same trick the vails repo uses with
`VAILS_DIALOG_PROBE`. When a probe is genuinely needed later, follow that
pattern with `FLUXGET_PROBE=`.

## Production transport

```powershell
.\scripts\build.ps1
.\build\fluxget.exe          # no --dev
```

Expected: the window opens with no server involved, and the `transport` card
reads `packed document (set_html)`. This needs `tools/pack`, which lands in
Phase 2 — before that, `find_packed()` returns empty and the app explains
itself rather than showing a blank window.

## When vails breaks

```powershell
.\scripts\sync-vails.ps1 -Report
```

Read `docs/compat/vails-compat.md`. If a contract symbol is listed as missing,
the window will not open and this directory's checks are the wrong place to look
— fix `platform/`, or roll back:

```powershell
.\scripts\sync-vails.ps1 -Rollback
```

## Later phases

Each phase adds its own checklist here, and a proof screenshot with the same
`phase<N>-<what>.png` naming. Nothing in this folder runs from `v test`, by
design.
