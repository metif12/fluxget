# Fluxget

An aria2-powered download manager for the desktop, built on
**[vails](https://github.com/metif12/vails)** — a V-language desktop framework
that uses the OS webview instead of bundling a browser engine.

```
V 0.5.2  ·  vails 0.2.0  ·  aria2 1.37  ·  no npm, no CDN, no bundler
```

> **Status: Phase 1 complete.** The window opens, the bridge round-trips, and
> **a real download runs**: Fluxget finds aria2c, spawns it, speaks JSON-RPC to
> it, and shows the queue live. See [Roadmap](#roadmap).

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

---

## Why the setup is unusual

vails is one day old: 14 commits, 8 of them on its first day, no git tags, no
CI, and a hardcoded version string. Its roadmap says it will "freeze
`application/` + `bridge/` API before starting" Phase 6 — so a breaking change
is on the announced path.

Fluxget is therefore built as a **showcase that cannot be held hostage by its
framework**. Three mechanisms, and they are the interesting part of this repo:

| | what it does | where |
|---|---|---|
| **The seam** | Only `main.v` and `platform/` may import vails. Everything else — `rpc/`, `engine/`, `api/`, the whole frontend — is plain V with no framework knowledge. Enforced by a script, not by discipline. | `scripts/check-isolation.ps1` |
| **The contract** | ~34 vails symbols Fluxget depends on, machine-checked in two layers: compiling `platform/contract.v` *is* the check, and `contract_test.v` proves the behaviour still holds. | `platform/contract.v` |
| **The pin** | `vendor/vails` is a git submodule, `vails.lock` records the last revision that passed the gate. `sync-vails.ps1` always tries `origin/main` and **rolls back automatically** if the gate goes red. | `scripts/sync-vails.ps1` |

`grep -r COMPAT` lists every place where Fluxget implements something the
framework will ship in the next release wave, with the upstream service named.

The reasoning is in [ADR-0001](docs/ADR/0001-platform-seam.md).

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
| Open a folder / file | not yet (`shell/` is Phase 3) | `opener` (S1 wave 2) | `platform/natives.v`, by grant |
| Finish notifications | in-app toast from the notice queue | `notification` | same |
| Copy a magnet link | not yet | `clipboard` | same |
| Single instance | Control API port as the lock (Phase 6) | `single-instance` (S2) | same |
| Persistence | session file via aria2; no `store/` yet | `store` (S2) | same |
| Window geometry | not yet | `window-state` | same |
| Frontend `.d.ts` | `platform/host.v: dts_text`, from the manifest | `$for` reflection (Phase 7) | delete `dts_text` |
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

| Phase | What | Gate |
|---|---|---|
| **0** ✅ | Repo, submodule, scripts, window, bridge | window opens, gate green |
| **0.5** ✅ | The seam, the contract, `vails.lock`, compat reports | 13 contract tests green |
| **1** ✅ | `aria2ctl/` + `core/` + `engine/`, real download in the UI | a real download visible in the window |
| **2** | Design system, router, i18n, RTL, both themes, speed chart, `tools/pack` | rows update live, packed document runs |
| **3** | pause/resume/remove/retry, settings, speed presets | full manual control |
| **4** | Torrents: peers, trackers, file selection, seed policy | a magnet and a `.torrent` finish |
| **5** | Scheduler: day windows plus conditional rules | windows really change the global limit |
| **6** | Control API + the browser extension | a Chrome download reaches Fluxget |
| **7** | aria2 setup page, pairing QR, logs, README with screenshots | clean build from scratch |
| **8** | MCP server in V, over the Control API | an assistant can ask Fluxget for a download |

## What Phase 1 actually established

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
mcp/              the MCP server: stdio in, Control API out (Phase 8)
schedule/         a pure evaluator, testable against a table of times
store/            settings and history, atomic writes
api/              the loopback control API for the extension and the MCP server
shell/            native fallbacks until vails ships the service
frontend/         hand-written HTML/CSS/ES, no bundler
extension/        MV3 for Chrome and Firefox
tools/pack/       the micro-packer: frontend/** → one index.html (Phase 2)
scripts/          sync-vails, test, build, dev, setup, ext, fetch-aria2,
                  check-isolation, capture-window
docs/ADR/         decisions that would be expensive to reverse
tests/e2e_windows/  manual GUI proofs
```

`schedule/`, `store/`, `api/`, `shell/`, `extension/`, `mcp/` and `tools/pack/`
are still Phase 2+ and are listed as the shape they will take.

## Licence

MIT. `vendor/vails` is MIT (© 2026 metif12). The aria2 binary is GPL and is
never committed — `runtime/` is gitignored and populated by
`scripts/fetch-aria2.ps1`.
