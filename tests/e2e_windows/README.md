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

## The screenshots are not committed

The proof artefacts are deliberately **not in git**. They are rendered pixels of
a developer's machine: window titles, local filesystem paths in the status cards,
the account name in a settings dialog, sometimes a download URL.

That is not tiny, and it is not a secret either. It is identity that nobody
benefits from having in a public repo, and a screenshot is the one artefact in
this project that is easy to leak accidentally. So the policy is:

- capture them locally with `capture-window.ps1`;
- read them and act on what they show;
- commit the *finding*, never the frame.

Every reference to a `.png` below names the file you would create, not a file
this directory ships.

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

Capture as `phase0-bridge.png` locally.

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

Before committing anything from this directory, check what is *in* the frame:
```powershell
git status --short tests\e2e_windows
```
If a PNG shows up, stop and read it.

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

Capture as `phase1-download.png`.

The **log pane is empty** in that frame, and that is correct:
`--console-log-level=warn` means a healthy engine says nothing. The log is for
the day it does.

### The session round-trip, proved without a large download

`--input-file` and `--save-session` are the same file, and a queue that vanishes
when the app closes is the one thing a download manager must not do. Prove the
*read* side with no large transfer: hand aria2 a session file and let the app
pick it up.

```powershell
$dir = "$env:USERPROFILE\Downloads\fluxget-e2e"
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

### Shutdown

Close the window, then `Get-Process aria2c` must come back empty: the supervisor
saves the session, asks aria2 to stop, waits two seconds, and only kills it if it
has not exited. `webview.Config` has no close hook, so this runs from `main.v`
after `platform.boot` returns.

**A force-kill does not do this.** `Stop-Process -Force` leaves `aria2c` running
and holding the RPC port, and the *next* run then reaches the stale engine with a
new secret and every call comes back `aria2:1 Unauthorized` — which looks like an
auth bug and is really a leak. Between manual runs:

```powershell
Stop-Process -Name fluxget,aria2c -Force -ErrorAction SilentlyContinue
```

Phase 2 lost a run to exactly this, twice.

## Phase 2 — the packed document, in Persian

```powershell
.\scripts\build.ps1            # packs build\web\index.html
$env:FLUXGET_SETTINGS = "$env:TEMP\fluxget-e2e\settings.json"   # never your real one
$env:FLUXGET_PROBE = 'https://ash-speed.hetzner.com/1MB.bin'   # 1 MiB, opt-in
.\build\fluxget.exe            # NOT --dev: this is the packed path
.\scripts\capture-window.ps1 -Out tests\e2e_windows\phase2-packed-fa-download.png
```

`FLUXGET_SETTINGS` is set because the real location is
`%USERPROFILE%\.fluxget\settings.json` and an e2e run has no business rewriting
it.

| Check | How | Expected | What it proves |
|---|---|---|---|
| packed | no `--dev`, and the transport card | `بسته‌شده` / `packed` | `set_html` got a self-contained document |
| direction | any text | Persian, right-aligned, `dir="rtl"` | the layout is RTL-first, not translated into RTL |
| reason | the failing row's red badge | aria2's own sentence | `errorMessage` is being read, not an invented `error` key |
| toast | `ناموفق: <name> — <reason>` | composed in Persian | `I18n.compose_notice` is the one composer |

Two of these failed first and are the reason the frame is worth having:

- **the chart pane did not fill its column.** A `.pane` defaults to `flex: 0 1
  auto`, which sizes it to its content, and a chart is sized by its container.
  Only visible in the image.
- **the engine card read `— در حال آماز`.** Forcing `direction: ltr` on every
  card value reordered a Persian sentence around its em dash and then ellipsised
  half a word away. Only values that really are LTR — a path, a version — may
  opt in now.

A probe URL that no longer serves is not an app bug: a host that answers
`Got EOF from the server.` still renders the reason, which is the point.

## Phase 3 — every row operable, and settings that survive a restart

```powershell
.\scripts\build.ps1
$env:FLUXGET_SETTINGS = "$env:TEMP\fluxget-e2e\settings.json"
$env:FLUXGET_PROBE = 'https://ash-speed.hetzner.com/1MB.bin'
.\build\fluxget.exe
.\scripts\capture-window.ps1 -Out tests\e2e_windows\phase3-packed-fa-rows.png
```

| Check | How | Expected | What it proves |
|---|---|---|---|
| row actions | the row is selected on open | `تلاش دوباره` / `حذف` on an errored row | the buttons come from the row's real status |
| settings | the queue header, no dialog | options pushed at startup, no refusal notice | `changeGlobalOption` under aria2's own names |
| settings file | `FLUXGET_SETTINGS` | written on the first save, read on the next start | the document round-trips |

### The two UI frames, and what they are NOT

`phase3-ui-rows` and `phase3-ui-settings` are **layout proofs taken in a normal
browser against the dev server with a stubbed `window.vails`**. They exist
because of one specific gap: the row actions are revealed by `.row.is-selected`
and the settings dialog opens on a keypress, and an unattended run can do
neither — so the states Phase 3 adds could not otherwise be looked at.

They prove layout, CSS and i18n. They prove **nothing** about the bridge: every
command in them is answered from a table in the init script. The evidence that the
commands work is `platform/control_test.v` (which asserts the aria2 method and
arguments on the wire) and the release-binary frame above. Do not quote these two
as evidence that a command works.

```powershell
# How they were taken, if you want to reproduce one:
.\build\fluxget.exe --dev                       # serves frontend/ on :8413
# open http://127.0.0.1:8413/ in a browser with window.vails.call stubbed by an
# init script, then open the settings dialog and screenshot.
```

Two layout bugs were found this way and would not have been found otherwise: the
settings grid fitted exactly one column at a 420px panel and made the dialog
taller than the window, and a toast list rebuilt on every notice sat permanently
at `opacity: 0` because rebuilding restarts the entrance animation.

### When aria2c is missing

Delete or rename `runtime\aria2c.exe` and start the app. The window must still
open — that window *is* the Setup screen — and the `ENGINE` card should read
`missing` with the full list of the places that were searched and a sentence
naming `fetch-aria2.ps1`. A missing engine is a state of this app, not a
different app.

## Production transport

```powershell
.\scripts\build.ps1
.\build\fluxget.exe          # no --dev
```

Expected: the window opens with no server involved, and the transport card
reads `packed`. This needs `tools/pack`; without it `find_packed()` returns empty
and the app explains itself rather than showing a blank window.

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

Each phase adds its own checklist here. Nothing in this folder runs from
`v test`, by design — and nothing in it should end up in a commit.
