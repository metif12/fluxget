# Fluxget

An aria2-powered download manager for the desktop, built on
**[vails](https://github.com/metif12/vails)** — a V-language desktop framework
that uses the OS webview instead of bundling a browser engine.

```
V 0.5.2  ·  vails 0.2.0  ·  aria2 1.37  ·  no npm, no CDN, no bundler
```

> **Status: Phase 0 + 0.5 complete.** The window opens, the bridge round-trips,
> and the download engine lands in Phase 1. See [Roadmap](#roadmap).

![Phase 0: the whole chain proven end to end](tests/e2e_windows/phase0-bridge.png)

That screenshot is not a mockup. It is the real window: the real dev server, the
real `bridge.Router`, the real capability gate — `ping -> pong` is a JS → V → JS
round trip, and the log line under it is an **ungranted** command being refused
with `forbidden:`, which is the security property the whole design rests on.

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
one `system.multicall` per beat and returns a snapshot. Notifications queue up
in `core/` and ride along in the next snapshot's `notices` array. Nothing ever
calls `Ctx.emit` from a worker.

## Feature ownership

Everything the vails roadmap will ship is implemented locally and marked, so
adopting the upstream service is a one-line change rather than a rewrite.

| Capability | Today | vails, when it lands | Switch |
|---|---|---|---|
| Open a folder / file | `shell/` (`explorer.exe`) | `opener` (S1 wave 2) | `platform/natives.v`, by grant |
| Finish notifications | in-app toast + `dialog.message` | `notification` | same |
| Copy a magnet link | `shell/` (`clip`) | `clipboard` | same |
| Single instance | Control API port as the lock | `single-instance` (S2) | same |
| Persistence | `store/`, atomic JSON | `store` (S2) | same |
| Window geometry | `store` | `window-state` | same |
| Frontend `.d.ts` | `platform/dts.v` from the manifest | `$for` reflection (Phase 7) | delete `dts.v` |
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

## Roadmap

| Phase | What | Gate |
|---|---|---|
| **0** ✅ | Repo, submodule, scripts, window, bridge | window opens, gate green |
| **0.5** ✅ | The seam, the contract, `vails.lock`, compat reports | 13 contract tests green |
| **1** | `rpc/` + `aria2ctl/` + snapshot | a real download visible in the UI |
| **2** | Design system, router, i18n, RTL, both themes, speed chart | rows update live |
| **3** | pause/resume/remove/retry, add dialogs, speed presets | full manual control |
| **4** | Torrents: peers, trackers, file selection, seed policy | a magnet and a `.torrent` finish |
| **5** | Scheduler: day windows plus conditional rules | windows really change the global limit |
| **6** | Control API + the browser extension | a Chrome download reaches Fluxget |
| **7** | aria2 setup page, pairing QR, logs, README with screenshots | clean build from scratch |

## Repository layout

```
main.v            bootstrap: transport selection, then platform.boot
vails.json        window + capability grants (a command name IS a grant)
vails.lock        last vails revision that passed the gate
platform/         the ONLY code that knows vails exists
rpc/              aria2 JSON-RPC client, injectable Transport
aria2ctl/         locating, configuring and supervising aria2c
core/             shared state, diffing, the notice queue
engine/           the app-facing facade over aria2
schedule/         a pure evaluator, testable against a table of times
store/            settings and history, atomic writes
api/              the loopback control API for the extension
shell/            native fallbacks until vails ships the service
frontend/         hand-written HTML/CSS/ES modules, no bundler
extension/        MV3 for Chrome and Firefox
tools/pack/       the micro-packer: frontend/** → one index.html
scripts/          sync-vails, test, build, dev, setup, ext, check-isolation
docs/ADR/         decisions that would be expensive to reverse
tests/e2e_windows/  manual GUI proofs
```

## Licence

MIT. `vendor/vails` is MIT (© 2026 metif12). The aria2 binary is GPL and is
never committed — `runtime/` is gitignored and populated by
`scripts/fetch-aria2.ps1`.
