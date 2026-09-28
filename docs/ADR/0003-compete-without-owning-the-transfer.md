# ADR-0003 — compete with Surge without owning the transfer

- Status: accepted
- Date: 2026-09-28
- Applies to: the whole roadmap, and specifically Phase 4

## Context

The request was to make Fluxget "as complete as Surge, with all its features, so
it can compete". First: get the right Surge. `SurgeDM/Surge` is **not** the
Surge proxy client — it is a *"blazing fast TUI download manager built in Go for
power users"*. Same category, so the request is answerable, and a competitor we
can actually read.

Its feature surface, from its own docs:

- **Modes** — TUI, headless server, system service, and a remote TUI client
- **Transfer** — 16 workers, large fixed chunks, **HealthCheck** (restart any
  worker under 0.3× the mean speed), **StealWork** (idle fast workers take slow
  workers' bytes near the end)
- **Mirrors** — discovered and spread across automatically
- **Streaming** — forced-sequential, so media can be previewed while fetching
- **Automation** — a full CLI, an HTTP API on `:1700` with a bearer token bound
  to `0.0.0.0`, shell completion, a browser extension
- **Extras** — debrid integration, themes, published benchmarks, installers for
  macOS/Linux/Windows/Docker

And two facts that reframe the comparison:

1. **Surge has no BitTorrent.** Neither its docs nor its topics mention it.
   Fluxget inherits BitTorrent, Metalink, per-connection splitting, resume and
   checksums from aria2 today. That is a differentiator we already own and only
   need UI for.
2. **Its speed advantage is an engine advantage.** It reimplemented the
   downloader, so it owns chunk scheduling. The published 1.38× over aria2c is a
   claim about *its core against ours*, not about its scheduling ideas.

## The decision

**Keep aria2 as the engine. Compete on features, UX and scope — not on the
single-file speed benchmark.**

The alternative is to write a segmented HTTP downloader in V with large chunks,
HealthCheck, StealWork and mirror discovery, keeping aria2 for BitTorrent and
Metalink. Rejected, and the reasons are worth keeping:

- **It is a second engine, and the seam stops paying.** ADR-0001 exists so an
  upstream vails change costs one file. The moment Fluxget owns the transfer, the
  interesting correctness surface — resume, mirrors, piece verification, BitTorrent
  — is split across two engines, each half-tested, each with its own bugs. The
  vails showcase also stops being the point.
- **It re-treads aria2.** The work is not "add a scheduler"; it is "write a
  correct resumable downloader", which is the part aria2 has been for fifteen
  years.
- **It does not close the whole gap.** To match Surge on a BT magnet you would
  still need aria2, because their core does not do torrents at all.

## What this costs, precisely

Two of Surge's three named optimisations are **structurally unreachable** with
aria2, and saying so here is the point of this ADR:

- **HealthCheck needs per-*connection* speed.** aria2's RPC reports one
  aggregate `downloadSpeed` per GID. We cannot see which connection is slow, so
  we cannot evict it.
- **StealWork needs byte-range hand-off between independent workers.** aria2 will
  not accept "download bytes A–B of this URL"; it owns the transfer of a single
  download. A N-worker scheduler of our own cannot exist without our own
  transport.

aria2 *does* schedule its chunks dynamically internally, so some of StealWork's
benefit is already inside the engine. The honest claim is narrower than "we are
as fast": **on a single file from a server that limits bandwidth per connection,
we are bounded by aria2's scheduler.**

## What we build instead

Phase 4 is the honest version of the speed work — everything reachable without
owning the transfer:

- **Adaptive connection tuning.** Watch aggregate throughput per GID and move
  `--max-connection-per-server` / `--split` with `aria2.changeOption`. This is
  reachable and is a real effect on a connection-limited server.
- **Mirror sets with liveness probing.** A user-declared set per download,
  probed with a ranged request, and the alive subset handed to aria2 as `uris[]`.
  That is aria2's multi-source fetching, and it is most of what a user means by
  "mirrors". **User-declared only** — Fluxget will not scrape a page looking for
  alternate sources of arbitrary content.
- **Force-sequential streaming mode.** aria2 has `--force-sequential`, settable
  per download. Media preview while downloading comes free.
- **Checksums.** `--checksum` per download, so a resumed transfer is verified
  rather than trusted.
- **`fluxget bench`**, which reproduces Surge's methodology against aria2c and
  curl and **publishes the numbers even where we are slower**. A comparison you
  decline to publish is indistinguishable from one you cannot win.

## The three consumers, and the invariant

Re-planning put the CLI and the MCP server next to the browser extension. They
are the same kind of thing:

> **One engine, one Control API, N consumers.** The GUI, the extension, the CLI
> and the MCP server all reach aria2 through `engine/` by way of the Control API.
> None of them may open a socket to aria2, hold the engine secret, or start a
> process.

That is what keeps single-instance (which is enforced by the Control API's port)
meaningful as the consumer count grows, and it is what keeps CONTEXT.md's
blast-radius argument true: a compromised consumer can *ask for a download*, not
drive the engine. A CLI that owned an engine would make the number of consumers
the number of ways to drive aria2, and the whole boundary argument collapses.

## Alternatives considered

**Write the native HTTP core now, keep aria2 for BitTorrent only.** Be the only
one that both beats Surge on speed and has a GUI. Rejected for the reasons above;
it is the right call *later*, if the benchmark ever shows the gap matters more
than the feature work. If that day comes it is a new ADR and a per-download engine
switch, not a rewrite.

**Re-implement the three optimisations as best-effort approximations on top of
aria2.** Tempting because it needs no new engine. Rejected: an approximation of
StealWork that cannot hand off byte ranges is not a weaker StealWork, it is a
setting. Shipping it under that name would be a claim we cannot support.

**Skip Phase 4 and go straight at torrents and automation.** Defensible — both are
differentiators. Rejected only because the speed comparison is Surge's headline
claim, and answering it with our own published numbers is worth more than dodging
it. The order is the one thing genuinely worth overrule here: if you think
torrents win more comparisons than speed does, swap Phases 4 and 5.

**Match remote control on `0.0.0.0`.** Surge does it with a token. Rejected: the
Control API is loopback-only by design, and a remote surface is not a feature we
should acquire to win an argument. The pairing token exists for the loopback case
already.

## Consequences

- The roadmap is ordered by competitive value, and the honest limits are written
  down instead of being discovered in Phase 4.
- We compete on GUI, torrents, scheduling, automation and mirrors — and lose the
  per-connection speed benchmark, on the record.
- `fluxget bench` publishes numbers we do not like. That is the point.
- The mirror work is user-declared sets, never scraping.
- Every new surface (CLI, MCP) is a consumer, and `check-isolation.ps1` plus the
  no-second-engine rule are what keep that true.
- Phase 2 is the biggest single chunk of work in the plan. It is capped
  deliberately: no component library, hand-written CSS on the existing token
  file, one chart type.

## Notes

The engine boundary this depends on is `engine/`, and the consumer boundary is
CONTEXT.md's *Control consumer*. Both are already described there, which is why
this ADR needed no new vocabulary.
