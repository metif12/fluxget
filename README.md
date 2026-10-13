# Fluxget

An aria2-powered download manager for the desktop, built on
**[vails](https://github.com/metif12/vails)** — a V-language desktop framework
that uses the OS webview instead of bundling a browser engine.

```
V 0.5.2  ·  vails 0.2.0  ·  aria2 1.37  ·  no npm, no CDN, no bundler
```

> **Status: Phases 0–3 complete, Phase 4 half done, plus a UI overhaul.** The
> window opens, the bridge round-trips, and **a real download runs**. Every row is
> operable by keyboard and by mouse, the queue is searchable and categorised,
> settings persist, and the production build ships as **one packed document**.
> Phase 4's mirror work is done — aria2 tells us which mirror it is using, and a
> dead one is dropped so the set continues — and the rest of it (adaptive
> connections, force-sequential streaming, checksums, `fluxget bench`) is not.
> What is outstanding is tracked in [docs/BACKLOG.md](docs/BACKLOG.md).

![Phase 1: a real 1 MiB download, complete, with the Finished notice](tests/e2e_windows/phase1-download.png)

That screenshot is not a mockup. The real window, the real dev server, the real
`bridge.Router`, a real `aria2c` child process, and a real 100% HTTP transfer.
The `1Mb.dat` row is the file's own name (it took three bugs to get right), and
the `Finished 1Mb.dat` toast is the notice queue noticing a transition it was
told about by diffing two ticks — nothing pushed it. The `ping → pong` round trip
and the ungranted command refused with `forbidden:` are the Phase 0 chain, still
working now that the handlers hold state.

The second proof needs no network at all: [the session round-trip](tests/e2e_windows/phase1-session-resume.png)
shows a queue that arrived from a hand-written `--input-file`, with the `out=`
option honoured.

### Phase 2: the packed build, in Persian, with a reason

![Phase 2: the packed document, RTL Persian, a real failure with aria2's own reason](tests/e2e_windows/phase2-packed-fa-download.png)

This is the **release** binary, not `--dev`: all three stylesheets and all three
scripts inlined into a single `build/web/index.html` by `tools/pack`, because
`set_html` gives the document no origin and a relative `<script src>` cannot load.
The empty window you would get otherwise is the least explicable failure a
desktop app has.

Two things in that frame are the phase's actual content. `ناموفق: downloads — Got
EOF from the server.` is a **Notice** composed from structured facts — kind, name,
and aria2's own error — by the one composer in `frontend/js/i18n.js`, not an
English sentence the UI could not translate. And **"Got EOF from the server." is
there at all** because `rpc/rpc.v` was reading a JSON key that aria2 has never
sent: `rpc/fake.v`'s fixture also said `error`, so a green suite agreed with a
decoder that was wrong. Fixed against a captured `aria2c 1.37.0` response; see
[AGENTS.md](AGENTS.md#and-since-phase-1).

### Phase 3: a row you can operate, and settings that are actually in force

![Phase 3: the release binary, an errored row selected and offering retry and remove](tests/e2e_windows/phase3-packed-fa-rows.png)

That is the **release** binary again, with a real `aria2c` child. The selected row
is a download that failed, and it offers exactly the two actions that make sense
for a failed download — `تلاش دوباره` and `حذف`. Which buttons exist is a function
of the row's status, because offering "pause" on a finished download invites a
refusal from aria2 that arrives as an error toast and looks like the app breaking.

The settings dialog is where the phase's actual idea lives, and it is one rule:

**"saved" and "in force" are different claims.** `store/` clamps every value on
the way in and reports the correction, `platform/settings_cmd.v` pushes to
`changeGlobalOption`, reads back what aria2 actually holds, and only then persists
— so the document can never keep asking for a value the engine already refused. A
value aria2 rejects is rewritten from aria2's own echo rather than from the user's
wish, and the dialog shows what happened:

![Phase 3: the settings dialog, RTL, three columns, with the note that a value was corrected](tests/e2e_windows/phase3-ui-settings.png)

*(That one, and `phase3-ui-rows.png`, are layout proofs taken in a browser against
the dev server with a **stubbed bridge** — they show layout, CSS and i18n and prove
nothing about the commands. The reasons and the limits are written down in
[tests/e2e_windows/README.md](tests/e2e_windows/README.md#phase-3---every-row-operable-and-settings-that-survive-a-restart).)*

Three things the tests caught, all of them mine and all of them the kind of bug that
compiles:

- `RemoveParams.purge` was defaulted to `true` and then **overwritten by the
  decoder**, because a JSON body that omits a bool decodes it as `false`. Every
  payload the frontend sends left the history intact. The flag is now
  `keep_record`, whose *zero* value is the wanted behaviour.
- `read_back_settings` parsed an absent key as `0`, so an engine that echoed only
  `split` silently reset every other limit to zero. A read-back must be
  non-destructive.
- `window_ready` held the state mutex and called a function that locks it again —
  a **deadlock**. The app painted and then ignored every key, and the screenshot
  tool hung. Now no function that takes the lock may call one that does.

And one that only real aria2 could have told us: **`retry` did not work.** For a
download in `error`, `aria2.getUris` answers *"No URI data is available"* — so the
one case retry exists for is the one case where the engine cannot say where the
download came from. `core.State` now remembers what Fluxget was asked to download,
and a download neither source knows for says what to do instead: add it again.

---

## Why the setup is unusual

vails is one day old: 14 commits, 8 of them on its first day, no git tags, no
CI, and a hardcoded version string. Its roadmap says it will "freeze
`application/` + `bridge/` API before starting" vails Phase 6 — so a breaking
change is on the announced path.

Fluxget is therefore built as a **showcase that cannot be held hostage by its
framework**. Three mechanisms, and they are the interesting part of this repo:

| | what it does | where |
|---|---|---|
| **The seam** | Only `main.v` and `platform/` may import vails. Everything else — `rpc/`, `engine/`, `api/`, the whole frontend — is plain V with no framework knowledge. Enforced by a script, not by discipline. | `scripts/check-isolation.ps1` |
| **The contract** | ~34 vails symbols Fluxget depends on, machine-checked in two layers: compiling `platform/contract.v` *is* the check, and `contract_test.v` proves the behaviour still holds. | `platform/contract.v` |
| **The pin** | `vendor/vails` is a git submodule, `vails.lock` records the last revision that passed the gate. `sync-vails.ps1` always tries `origin/main` and **rolls back automatically** if the gate goes red. | `scripts/sync-vails.ps1` |

`grep -r COMPAT` lists every place where Fluxget implements something the
framework will ship in the next release wave, with the upstream service named.

The reasoning is in [ADR-0001](docs/ADR/0001-platform-seam.md), the engine's
life cycle in [ADR-0002](docs/ADR/0002-engine-lifecycle-and-tick-not-push.md),
and the competitive scope in
[ADR-0003](docs/ADR/0003-compete-without-owning-the-transfer.md).

---

## Requirements

| Need | Windows | Checked by |
|---|---|---|
| V | 0.5.x | `vails doctor` equivalent in `scripts/setup.ps1` |
| C toolchain | MSYS2 **ucrt64** gcc — put `C:\msys64\ucrt64\bin` first on `PATH` | ditto |
| webview | `pacman -S mingw-w64-ucrt-x86_64-webview mingw-w64-ucrt-x86_64-webview2-loader` | ditto |
| Browser engine | Edge WebView2 Runtime (ships with Windows 11) | ditto |
| aria2 | `runtime/aria2c.exe`, or on `PATH`, or a path in Settings | `scripts/fetch-aria2.ps1` |
| Git | any recent — needed for the submodule | ditto |

## Getting started

```powershell
git clone <this-repo> fluxget
cd fluxget
git submodule update --init --recursive

.\scripts\setup.ps1 -FetchAria2   # doctor, fetch aria2, compile
.\scripts\dev.ps1                 # run it, with frontend livereload
```

The gate and the build:

```powershell
.\scripts\test.ps1                # contract, isolation, v fmt, v test
.\scripts\build.ps1               # build\fluxget.exe + DLLs + packed frontend
```

## Two compiler flags, and why

```powershell
v -cc gcc -cflags '-Wno-incompatible-pointer-types' -ldflags '-lws2_32' -o build\fluxget.exe .
```

- **`-Wno-incompatible-pointer-types`** — V ships
  `thirdparty/vschannel/vschannel.c`, which predates GCC 14. GCC 14 turned that
  pointer-type mismatch in `WSAConnectByNameW()` into a hard error, and the
  installed GCC is 16.1. The vails repo documents the same flag for the same
  reason.
- **`-lws2_32`** — anything importing `net` needs winsock linked explicitly.

`scripts/common.ps1:Get-VCFlags` builds them, so `test.ps1` and `build.ps1` pick
them up. `v test` and `v fmt` recurse, so they get an explicit target list
(`Get-FluxVTargets`) — `v test .` would re-run the framework's own 26 test
files, and `v fmt -w .` would rewrite the submodule's working tree.

## How it fits together

```
┌──────────────────────── Fluxget.exe (V) ─────────────────────────┐
│                                                                  │
│  main.v ── vails.json ── platform.boot ── webview.run            │
│                    │                                             │
│  frontend/  ◄── tick ──────────────────────────────────┐         │
│    views, charts, i18n, RTL                        │         │
│                                                    │         │
│  platform/  fluxget.* commands  ◄─────────────────┘         │
│  core/      shared state + notice queue                        │
│    ├── rpc/       aria2 JSON-RPC (injectable Transport)        │
│    ├── aria2ctl/  spawn, health-check, restart, shutdown       │
│    ├── engine/    add, control, snapshot, limits, torrent      │
│    ├── schedule/  pure (rules, conditions, now, state)         │
│    ├── store/     settings + history, atomic writes            │
│    └── api/       127.0.0.1:8735 for the browser extension    │
│                        │                                       │
│                    ┌───▼────┐                                  │
│                    │aria2c  │  HTTP/HTTPS/FTP/BT/Metalink      │
│                    └────────┘                                  │
└──────────────────────────────────────────────────────────────────┘
```

**The frontend polls, it is not pushed to.** vails ADR-0010 requires V→JS eval
to happen on the webview main thread, and a `Ctx` cannot emit from a spawned
worker. So the UI runs its own `setInterval` against `fluxget.tick`, which makes
one `system.multicall` per beat and returns a snapshot. Notifications are
diffed between ticks in `core/` and ride along in the response. Nothing ever
calls `Ctx.emit` from a worker — and nothing calls it at all yet.

The gate is the gate: `.\scripts\test.ps1` is contract, isolation, `v fmt` and
`v test` in one command, and `v test` opens no window and starts no process. The
interesting part is what the gate **cannot** reach, which is why
[tests/e2e_windows](tests/e2e_windows/README.md) exists and why Phase 1 says
loudly that talking to a real aria2 found three bugs the suite could not.

## Feature ownership

Everything the vails roadmap will ship is implemented locally and marked, so
adopting the upstream service is a one-line change rather than a rewrite.

| Capability | Today | vails, when it lands | Switch |
|---|---|---|---|
| Open a folder / file | not yet (`shell/`, only if vails does not ship `opener` first) | `opener` (S1 wave 2) | `platform/natives.v`, by grant |
| Finish notifications | in-app toast from the notice queue | **withdrawn upstream** | nothing to switch to; we own it |
| Copy a magnet link | not yet | `clipboard` | same |
| Single instance | Control API port as the lock (Phase 6) | `single-instance` (S2) | same |
| Persistence | session file via aria2; no `store/` yet | **withdrawn upstream** — `state/store.v` was removed in `e4e99ad` | nothing to switch to; Phase 3 writes our own |
| Window geometry | not yet | `window-state` | same |
| Frontend `.d.ts` | `platform/host.v: dts_text`, from the manifest | `$for` reflection (vails Phase 7) | delete `dts_text` |
| Tray icon | **not implemented** | `tray` | documented, not built |
| Global hotkeys | none | `global-shortcut` | documented, not built |

Tray and global hotkeys are out because both need C interop and native message
loop work. That belongs in vails as a service, where the HWND is already
available through `webview.Ctx.parent` — not in app code.

## The browser extension

MV3 for Chrome and Firefox, **zero npm dependencies**, one base manifest and two
build targets. It talks only to the Control API on `127.0.0.1:8735`, never to
aria2's RPC, so it never holds the engine secret.

```powershell
.\scripts\ext.ps1    # dist/chrome, dist/firefox, and a zip of each
```

Planned: download interception via `downloads.onCreated` (cancel, erase, hand
the URL over), a context menu for links/media/frames, magnet links from a
content script **plus** OS-level `magnet:` registration by the app itself, a
live badge, and an options page for pairing.

## An MCP server, planned

Phase 8. An MCP server written in V, so an assistant can drive Fluxget the way
the browser extension does. It is **a second consumer of the Control API, not a
second way into the engine**, and that is the whole design:

- **stdio, not a socket.** The assistant's host is the parent process, so there
  is no port to reach and no second pairing secret. That is a *tighter* boundary
  than the extension's loopback HTTP, not a looser one.
- **It never speaks aria2's RPC and never holds the engine secret.** The same
  argument as the extension, and it makes them one class of consumer: a
  compromised consumer can "ask for a download", not "drive the engine". It also
  cannot start a second aria2c, so the single-instance lock still means what it
  says.
- **Named tools only** — `add_download`, `list_downloads`, `pause`, `resume`,
  `remove`, `set_speed_limit`. No generic "call any aria2 method" tool. This is
  the one that matters most: an assistant can be *talked into* calling a tool by
  content it read on a web page, so that list is the entire attack surface and
  has to stay short and auditable.
- **`mcp/` stays vails-free with an injected transport**, like `rpc.Client`, so
  `v test` stays pure (AGENTS.md §4). An MCP server is a protocol adapter; the
  interesting part is the boundary, and that is what gets tested.

One trap worth recording now: **MCP is JSON-RPC 2.0 over stdio, and so is
aria2's RPC.** They look alike and are not the same protocol — `initialize` /
`tools/list` / `tools/call` against `aria2.*` / `system.*`. Nothing should ever
bridge them.

Likely shape: a `--mcp` mode on the same binary rather than a second
executable, since it never boots a window and so never touches `platform/`.

## Roadmap

Re-planned in September 2026 around competitive parity with
[Surge](https://github.com/SurgeDM/Surge), the TUI download manager this app
competes with. The reasoning, and the one thing we chose not to build, are in
[ADR-0003](docs/ADR/0003-compete-without-owning-the-transfer.md). Ordered by
competitive value, not by what happened to be built first.

| Phase | What | Gate |
|---|---|---|
| **0** ✅ | Repo, submodule, scripts, window, bridge | window opens, gate green |
| **0.5** ✅ | The seam, the contract, `vails.lock`, compat reports | 13 contract tests green |
| **1** ✅ | `aria2ctl/` + `core/` + `engine/`, real download in the UI | a real download visible in the window |
| **2** ✅ | **Product feel** — design system, i18n with `fa` RTL, light + dark, keyboard shortcuts, speed charts, `tools/pack` | switch language and theme live; a chart redraws every tick; the packed document runs |
| **3** ✅ | **Control + settings** — pause/resume/remove/retry/move, global and per-item limits, `store/` | every row operable; limits and settings survive a restart |
| **4** ◑ | **Speed + mirrors** — adaptive connections, mirror sets with liveness probing, force-sequential streaming, checksums, `fluxget bench` | `bench` publishes numbers against aria2c/curl **including where we lose**; a dead mirror is dropped and the set continues |
| **5** | **Torrents** — magnet and `.torrent`, peers, trackers, file selection, seed policy | a magnet and a `.torrent` both finish |
| **6** | **Automation** — Control API, browser extension, CLI, headless mode, shell completion, autostart | a Chrome download reaches Fluxget; `fluxget add` drives a running instance |
| **7** | **Scheduler** — presets, day windows, conditions | a window really changes the global limit |
| **8** | **MCP server** — stdio, named tools, over the Control API | an assistant can ask Fluxget for a download |

**◑ half done** — Phase 4's mirror half landed: `engine/mirror.v` reads which
mirror aria2 is pulling from (`aria2.getUris` answers `used`/`waiting`, expanded
to more rows than were submitted), `Engine.mirror_state` maps that to a set, and
`engine.retry_set` drops the idle ones so a dead mirror stops costing a
connection. The subtlety it got right is in the code: `waiting` means both "not
needed yet" and "gave up on", so nothing is dropped unless at least one mirror is
live, because a retry set narrowed to nothing has nothing to re-add.

### Landed between the phases

Unnumbered work that is done and did not fit a phase row. Recorded so the table
above is not read as the whole of the app.

- **Per-language fonts.** Inter for English, Vazirmatn for Persian, JetBrains Mono
  for numbers. All SIL OFL, shipped with the app, and chosen by `html[lang]` so
  switching language switches the face. Embedded as data URIs because the CSP is
  `font-src 'self' data:`.
- **Two sidebars.** The queue's categories are built-in views derived from a row's
  status (so they cannot be deleted) plus user categories that persist in the
  settings document. Settings has a sidebar so limits, files, categories and the
  developer log are findable.
- **Full-text search** over the whole queue, in the pane header where it is always
  visible, matching name, directory, gid, and aria2's error text.
- **Add as a dialog.** Paste five URLs and it detects them, de-duplicates them,
  labels each as url/magnet/torrent, and lets you pick. The folder it offers is
  guessed from the address's path segment, and it is an offer.
- **Row details on click.** Pieces, piece length, verified length, connections in
  use, the file list, the tracker list, and which mirror aria2 is using — fetched
  per row on demand rather than carried in every tick.
- **A full-width header** with one add path, and four tools distinguishable by
  shape rather than by colour.
- **Byte settings as sliders** over a curated ladder with a readout, and the exact
  number field kept because the slider snaps.

### Where we already stand against Surge

Reading this before planning a feature, because two of the three answers are
"we already have this":

- **BitTorrent and Metalink are ours and Surge's are not.** Its docs and topics
  never mention them. aria2 gives us the swarm engine for free; Phase 5 is UI
  and policy, not protocol work. If that is the first question a user asks —
  and it usually is — we are ahead on it today.
- **A window, not a terminal.** vails is a webview framework, so a TUI is
  unreachable and we should not want one. The GUI is the wedge; the CLI
  (Phase 6) is the honest answer to the automation story, and it needs no
  webview.
- **We lose the single-file speed comparison, on purpose.** Their published
  benchmark claims 1.38× aria2c, and it comes from owning the transfer. See
  ADR-0003 for what that costs and what we build instead.

### What we will not build, and why

Three of these are differences, not gaps. Recording them so they are not
re-litigated as missing features:

- **No TUI.** See above — there is no terminal in vails.
- **No remote control on `0.0.0.0`.** Surge binds every interface with a bearer
  token; our Control API is loopback-only. That is a security decision with a
  reason in [CONTEXT.md](CONTEXT.md#control-api), and losing that comparison is
  cheaper than reversing it.
- **No macOS** until vails Phase 6. That is half of Surge's install surface
  unavailable to us, and it is a framework constraint rather than a choice.

Debrid support is genuinely worth doing — it is an HTTP source plugin — but it
is not parity, so it is not on the roadmap.

### What Phase 1 actually established

Worth reading before Phase 2, because three of it was *finding out*:

- **The engine is a supervised child, and readiness is a polled phase, never an
  assumption.** A successful spawn proves nothing — aria2 still has to bind its
  RPC port — so "ready" means exactly one thing: `aria2.getVersion` answered.
  A crash loop is 3 restarts in 60s with a 1s/2s/4s backoff, then silence with an
  explanation. The reasoning, and the three designs that are ruled out, are in
  [ADR-0002](docs/ADR/0002-engine-lifecycle-and-tick-not-push.md).
- **A missing aria2c must still open a window**, because that window *is* the
  Setup screen. So the engine starts from `on_ready`, not before `boot`.
- **The RPC port is 16800, not aria2's 6800.** Guessing wrong is not a clean
  error: Fluxget would reach the *user's* aria2, get an auth failure, and report
  "engine not ready" while the daemon it spawned died on the bind.
- **Nothing is ever pushed.** `os.Process.pipe_read` is non-blocking, so the
  engine's stderr is drained *by the tick*, and there is no reader thread to own
  state and race on it.
- **The fake transport cannot catch a wire-format bug.** 32 green tests were not
  enough: the real HTTP transport timed out on every call (a `Duration` compared
  against a millisecond budget), the multicall sent its arguments as a JSON
  string, and rows were labelled with folders. All three were found by talking to
  a real aria2, and all three now have a test that fails on the broken shape.

## Repository layout

```
main.v            bootstrap: resolve the root, build the App, then platform.boot
vails.json        window + capability grants (a command name IS a grant)
vails.lock        last vails revision that passed the gate
platform/         the ONLY code that knows vails exists
rpc/              aria2 JSON-RPC client, injectable Transport
aria2ctl/         locating, configuring and supervising aria2c
core/             shared state, diffing, the notice queue
engine/           the app-facing facade over aria2
store/            settings and history, atomic writes (Phase 3)
schedule/         a pure evaluator, testable against a table of times (Phase 7)
api/              the Control API: the one remote surface (Phase 6)
extension/        MV3 for Chrome and Firefox (Phase 6)
mcp/              the MCP server: stdio in, Control API out (Phase 8)
shell/            native fallbacks until vails ships the service
frontend/         hand-written HTML/CSS/ES, no bundler
tools/pack/       the micro-packer: frontend/** → one index.html (Phase 2)
scripts/          sync-vails, test, build, dev, setup, ext, fetch-aria2,
                  check-isolation, capture-window
docs/ADR/         decisions that would be expensive to reverse
tests/e2e_windows/  manual GUI proofs
```

`store/`, `schedule/`, `api/`, `extension/`, `mcp/`, `shell/` and `tools/pack/`
do not exist yet; the phase in brackets is when each lands. `shell/` has no
phase because it is only built if vails does not ship the service first.

## Licence

MIT. `vendor/vails` is MIT (© 2026 metif12). The aria2 binary is GPL and is
never committed — `runtime/` is gitignored and populated by
`scripts/fetch-aria2.ps1`.
