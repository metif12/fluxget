# ADR-0001 — vails is a moving target, so the app is built around a seam

- Status: accepted
- Date: 2026-09-27
- Applies to: the whole `platform/` boundary

## Context

Fluxget is a showcase for [vails](https://github.com/metif12/vails), so it
depends on the framework heavily: the window, the JSON-RPC bridge, the
capability model, the service manifests, the dev server, the CSP.

vails at the time of writing is **one day old**. Fourteen commits, eight of them
landed the same day. There are no git tags, no CI, and the version string in the
CLI is a hardcoded `const version = '0.2.0'` rather than anything derived from
the tree. Phase 6 of its roadmap explicitly says it will "freeze
`application/` + `bridge/` API before starting", which means a breaking change
is on the announced path.

So "will the API change?" is the wrong question. It is certain. The question is
how much of Fluxget a change should be able to touch.

The surface Fluxget needs is small — about 34 symbols across eight vails
modules. The wrong move is to sprinkle `import webview` through the app and deal
with breakage whenever it arrives.

## Decision

**1. All vails knowledge lives in `platform/`, and the boundary is enforced, not
documented.**

Only `main.v` and `platform/host.v` may import a vails module.
`scripts/check-isolation.ps1` greps every `.v` file and fails the build on a
violation; it runs inside both `build.ps1` and `test.ps1`. `rpc/`, `aria2ctl/`,
`core/`, `engine/`, `schedule/`, `store/`, `api/`, `shell/`, `pack/` and the
entire frontend have zero framework knowledge and test without it.

**2. The dependency is vendored and pinned by commit, not by version.**

`vendor/vails` is a git submodule. `vails.lock` records the last revision that
passed the full gate — a SHA, because there is nothing else to pin to.
`scripts/sync-vails.ps1` fetches `origin/main` and runs the gate; on failure it
rolls back to the locked revision automatically and writes a report. Default is
"always newest, roll back on break"; `-Rollback`, `-Report`, `-Probe` and
`-NoRollback` cover the other cases.

**3. The contract is machine-checked in two layers.**

`platform/contract.v` references every vails symbol Fluxget needs — as calls,
as types, as struct literals. Compiling it *is* the check, and a named-field
struct literal is the strongest available probe: a renamed `webview.Config`
field fails to compile. `platform/contract_test.v` then proves the behaviour
still holds, which catches the class of change that compiles fine: a capability
registry that stopped denying, a CSP injection that stopped being idempotent, a
service installer that stopped validating its manifest.

`main.v` also runs the behavioural half at startup in dev mode, so a broken
dependency says so in the terminal instead of presenting a UI that silently
calls nothing.

**4. Features that upstream will ship are marked, not merely anticipated.**

The vails roadmap lists `notification`, `clipboard`, `menu`, `tray`, `opener`
and `window-state` in the next service wave, then `single-instance`, `store` and
`autostart`. That is most of what a download manager wants. Every such
capability gets a `// COMPAT(x)` comment in the source and a row in the README
ownership table, and `platform/natives.v` resolves the mapping. `grep -r COMPAT`
is the migration list; adopting an upstream service becomes a one-line change
rather than a rewrite.

## Alternatives considered

**Use the sibling `D:\MyProjects\vails` checkout directly.** Simplest, and
`VAILS_HOME` still supports it. Rejected as the default because the project
would not build on any other machine, which defeats the point of a showcase. It
survives as the documented escape hatch for working against unpushed changes.

**Pin to a fixed SHA and update by hand.** Maximum reproducibility, but it means
missing upstream fixes silently. Rejected: the user asked for "always the latest
git version", and automatic rollback on break gets reproducibility without giving
up freshness.

**No vendoring — resolve vails from a global module path.** Convenient until two
projects need different vails revisions at once. Rejected for the same reason as
the sibling checkout.

**Let the break happen and fix it where it lands.** This is what an app without a
seam does. Measured cost during Phase 0: one real upstream-independent design
decision (the seam) versus four separate multi-file tangles. Not worth it.

**Report compatibility issues to upstream automatically.** Rejected: an
automated issue is noise. The script *drafts* `docs/compat/vails-issue.md` with
the numbers, and a human sends it.

## Consequences

- Building Fluxget needs `git submodule update --init --recursive`. The README
  says so in the first screen.
- `platform/host.v` is load-bearing and must be edited carefully, not casually.
- Two files carry the vails coupling, and adding a third is a deliberate act.
- A vails release that breaks Fluxget costs minutes, not a refactor.
- The compat machinery is a real contribution back: Fluxget is the kind of
  consumer that finds the rough edges before users do.

## Notes

`vails.lock` is never edited by hand. If the gate fails, the fix is either in
`platform/` or in the pinned revision, and `sync-vails.ps1` writes the lock.
