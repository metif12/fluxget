# CONTEXT.md — Fluxget's domain model

The ubiquitous language. If a word here means two things in two files, one of
them is wrong. Terms borrowed from vails keep vails' meaning so the seam reads
honestly.

## Engine

**Engine** — the aria2 process Fluxget supervises, plus the client that drives
it. Never used for the *code* that talks to it; that is `engine/`.

**aria2c** — the upstream binary. GPL, never committed; it lives in
`runtime/`, or is found on PATH, or is pointed at in Settings.

**RPC** — aria2's JSON-RPC endpoint on loopback. Fluxget never speaks XML-RPC
and never lets the browser extension see it (see *Control API*).

**daemon** — the running aria2c, from the app's point of view. `aria2c` in
*supervised* mode, never the system service.

**supervisor** — the code that starts, health-checks, restarts and shuts down
the daemon. Owns the restart budget.

**GID** — aria2's 16-hex download id. The primary key everywhere in Fluxget:
the UI, the history, the scheduler's targets, the API. Opaque string, never
parsed.

**session** — aria2's saved download set, written on `aria2.saveSession()` and
read back through `--input-file` on the next start. How a closed app does not
lose its queue.

## Download

**Download** — one item: an HTTP(S)/FTP file, a torrent, or a magnet. A torrent
with forty files is still one Download.

**URI** — a source for a Download. A Download may have several (mirrors).
**Magnet** is a URI form, not a separate thing.

**Torrent** — a Download whose payload comes from a swarm. Distinguished by
having an **info hash**, seeders and leechers.

**Piece** — the torrent unit aria2 verifies. A single piece can span two files,
which is why selecting file 3 still writes file 4's bytes.

**Selection** — which files of a torrent to fetch, i.e. aria2's
`select-file`. Only settable while a Download is waiting or paused: applying it
to an active one makes aria2 restart the item, so the UI only offers it before
the item starts.

**Seed** — serving a finished torrent. Governed by a **seed policy**: a ratio,
a time, or neither.

**Status** — where a Download is: `active`, `waiting`, `paused`, `complete`,
`error`, `removed`. aria2's vocabulary, passed through unchanged so an aria2
release cannot invent a state the UI has never heard of.

## State

**Snapshot** — the whole world at one instant: global stats plus every
Download. One `system.multicall` per tick, which is why the UI never makes
three round trips.

**Tick** — one poll of the engine, from the frontend or the API. The UI's
heartbeat, and the only way the window learns anything changed.

**Notice** — a queued event (finished, failed, schedule applied). Delivered in
the *next* snapshot rather than pushed, because a handler may not emit from a
worker thread. `core/` owns the queue.

**Limit** — a speed cap. **Global** applies to everything (`max-overall-*`),
**item** to one Download, and a **schedule** rewrites the global one on a
schedule. Three layers, in that order of precedence.

**Preset** — a named Limit, e.g. `night` = 1 MiB/s. A schedule chooses presets;
it never hard-codes numbers.

## Schedule

**Rule** — a recurring window: days, a start and an end time, and what should
hold inside it. Windows may wrap past midnight; that is not a special case, it
is a window.

**Condition** — an event that overrides the rules: everything finished, idle
too long, a metered link, the network dropped.

**Effect** — what the scheduler decided: set a Preset, pause everything, stop
seeding. `schedule/eval` is a pure function `(rules, conditions, now, state)
-> Effect`, which is what makes it testable against a table of times instead of
by waiting.

## Platform

**Platform** — the `platform/` seam: the only Fluxget code allowed to know
vails exists. Everything else is ordinary V.

**Command** — one bound method, `fluxget.<name>`. A Command name *is* a
capability grant in `vails.json`; there is no second list of them.

**Manifest** — the declaration of a service's Commands and the TypeScript
shapes behind them. Data, not code: it is what the router is installed from,
what the `.d.ts` is generated from, and what `vails doctor` would print.

**Grant** — a capability in `vails.json` allowing a Command for a window. A
Command with no Grant does not exist as far as the window is concerned, and the
rejection says `forbidden:`, never `unknown method:` — the difference between
"denied" and "does not exist" is the security property.

**Contract** — the machine-checked list of vails API Fluxget depends on.
Compiling `platform/contract.v` is the check; `contract_test.v` proves the
behaviour. See `AGENTS.md` §2.

**COMPAT marker** — a `// COMPAT(x)` comment on code that exists only because
the framework does not have `x` yet, naming the service that will replace it.
`grep -r COMPAT` is the migration list.

## Control API

**Control API** — the loopback HTTP server the browser extension talks to
(`127.0.0.1:8735`). The extension never speaks aria2's RPC and never holds its
secret, so the blast radius of a compromised extension is "can ask for a
download", not "can drive the engine".

**Pairing token** — the shared secret between the app and the extension. Shown
in the app, pasted once into the extension's options page. Loopback only.

**Grab** — the extension's word for handing a URL, magnet or `.torrent` to the
app. One endpoint, three payloads.

**Single instance** — enforced by the Control API's port: if something already
answers there, this process does not start. No mutex, no C.

## Frontend

**Transport** — how the document reached the window: the dev server (livereload,
multi-file) or the packed single file. The app always knows which, and says so
in `fluxget.info`, so a screenshot is never ambiguous.

**View** — one tab. Vails is single-window for now, so settings, scheduler and
torrent detail are views rather than windows.

**Packed document** — `build/web/index.html`, every stylesheet and script
inlined. Required in production: `webview_set_html` gives the document no real
origin, so relative `<script src>` would not load.

**Locale** — `fa` (RTL) or `en` (LTR). Switchable at runtime; direction is a
document attribute, spacing is logical properties, numbers stay LTR.
