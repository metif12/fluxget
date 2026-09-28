# tests/e2e_windows — manual GUI proofs

`v test` never opens a window and never starts aria2c. That is deliberate (the
rpc client takes an injected `Transport`), but it means the last mile is
verified by hand, exactly as the vails repo does it.

**And it is not optional.** Phase 1 found three bugs that 32 green tests had
not: the real HTTP transport compared a `Duration` against a millisecond budget
and so reported a timeout on *every* call; the multicall sent its arguments as a
JSON string, which a real aria2 rejects; and a queue row was labelled with the
*directory* instead of the file. None were reachable without a real engine, and a
fake transport cannot find any of them — it returns canned responses and never
validates a request.

## Setup

```powershell
.\scripts\setup.ps1
.\scripts\fetch-aria2.ps1      # aria2c 1.37.0 into runtime\ (GPL, never committed)
.\scripts\dev.ps1              # dev server + the real router
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
| round trip | the page's `ping → pong` | `pong` | JS → `bridge.Router` → handler → JS |
| grants | the console line | `forbidden: fluxget.not_granted is not allowed for window "main"` | the T2 gate denies, and says `forbidden:` rather than `unknown method:` |

Proof: `phase0-bridge.png` in this directory.

A synthesised click does not reach WebView2 content reliably, which is why the
page calls the bridge itself — the same trick the vails repo uses with
`VAILS_DIALOG_PROBE`. When a run needs a download it has no user to paste,
`FLUXGET_PROBE` does it (see `core/state.v`, `seed_probe`).

## Capturing

```powershell
.\scripts\capture-window.ps1 -Out tests\e2e_windows\phase1-download.png
```

It uses `PrintWindow` with `PW_RENDERFULLCONTENT`, **not** `CopyFromScreen`. A
screen grab only works if the window is on top, and `SetForegroundWindow` from a
background process is refused by Windows' foreground lock — silently. The naive
version produced a PNG of the *desktop* at exactly the right window size, which
is worse than no screenshot at all.

It also counts distinct colours and **refuses to write a blank frame**. A capture
that failed to render is a failure, not evidence, and a proof script that can
emit a plausible lie is not a proof script.

## Phase 1 — a real download

`FLUXGET_PROBE` seeds exactly one download at startup, through the normal engine
path, once per app run. It exists because an unattended run has nobody to paste a
URL into, and a screenshot of an empty queue proves nothing.

```powershell
$env:FLUXGET_PROBE = 'https://proof.ovh.net/files/1Mb.dat'   # 1 MiB, real HTTP
.\scripts\dev.ps1
.\scripts\capture-window.ps1 -Out tests\e2e_windows\phase1-download.png
```

**Keep the probe file at 1 MB or under.** A 100 MB file finishes between
screenshots on a fast link, and the proof then shows a finished row instead of a
live one.

| Check | Expected | What it proves |
|---|---|---|
| `Get-Process aria2c` | a second process, ours | the supervisor spawned it, after finding it with the search order |
| `ENGINE` card | `1.37.0`, not an error | `aria2.getVersion` answered — readiness is *proven*, not assumed |
| `ARIA2C` card | `…\runtime\aria2c.exe [runtime]` | `aria2ctl.locate` ran and names which rule matched |
| `SPEED` card | a non-zero rate | the multicall decodes against a real aria2 |
| `QUEUE` card | `1 active` | `tellActive` rides the same one-request snapshot |
| a row | the **file name**, its size, its percentage | `files[0].path` is decoded; the row is not labelled with a folder |
| a toast | `Finished …` | the diff in `core/notice.v` noticed the transition |
| `BRIDGE` card | `ping → pong` | the Phase 0 chain still works now that handlers hold state |

Proof: `phase1-download.png` — `1Mb.dat`, complete, 100.0%, with a
`Finished 1Mb.dat` notice.

The **log pane is empty** in that screenshot, and that is correct:
`--console-log-level=warn` means a healthy engine says nothing. The Logs tab is
for the day it does.

### The session round-trip, proved without a large download

`--input-file` and `--save-session` are the same file, and a queue that vanishes
when the app closes is the one thing a download manager must not do. Prove the
*read* side with no large transfer: hand aria2 a session file and let the app
pick it up.

```powershell
$dir = 'D:/MyProjects/fluxget/downloads'
@"
https://proof.ovh.net/files/1Mb.dat
 dir=$dir
 out=resumed-from-session.dat

"@ | Set-Content runtime\aria2.session

$env:FLUXGET_PROBE = ''      # nothing seeded: the queue must come from the file
.\scripts\dev.ps1
```

Expected: a row named `resumed-from-session.dat` — that name came from the
`out=` line in the session file, which is the whole proof.
Proof: `phase1-session-resume.png`.

### Shutdown

Close the window, then `Get-Process aria2c` must come back empty: the supervisor
saves the session, asks aria2 to stop, waits two seconds, and only kills it if it
has not exited. `webview.Config` has no close hook, so this runs from `main.v`
after `platform.boot` returns.

### When aria2c is missing

Delete or rename `runtime\aria2c.exe` and start the app. The window must still
open — that window *is* the Setup screen — and the `ENGINE` card should read
`missing` with the full list of the 32-odd places that were searched and a
sentence naming `fetch-aria2.ps1`. A missing engine is a state of this app, not
a different app.

## Production transport

```powershell
.\scripts\build.ps1
.\build\fluxget.exe          # no --dev
```

Expected: the window opens with no server involved, and the `transport` card
reads `packed document (set_html)`. This needs `tools/pack`, which lands in
Phase 2 — before that, `find_packed()` returns empty and the app explains itself
rather than showing a blank window.

**So every Phase 1 proof above is a dev-mode run, and this is the one claim the
screenshots do not support.** Recorded here rather than left implied.

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
