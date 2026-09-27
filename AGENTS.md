# AGENTS.md — the workflow contract for Fluxget

Read this before writing any code. If a rule here and your judgement disagree,
the rule wins; if the rule is wrong, change it in the same commit as the code
that needed it.

Fluxget is a **desktop app built on [vails](https://github.com/metif12/vails)**
(V 0.5.x). The framework is pre-1.0 and lands commits daily, so most of what
follows is about not being hostage to that.

## 1. Commands

Run from the repo root.

```powershell
.\scripts\sync-vails.ps1        # fetch latest vails, run the gate, stamp vails.lock
.\scripts\sync-vails.ps1 -Probe # fast contract check only (no network)
.\scripts\sync-vails.ps1 -Report# API-surface diff vs the locked revision
.\scripts\test.ps1              # THE GATE: contract, isolation, fmt, tests
.\scripts\test.ps1 -Format      # the gate, but v fmt -w first
.\scripts\build.ps1             # compile + stage DLLs + pack the frontend
.\scripts\dev.ps1 [-Watch]      # run it; -Watch rebuilds on .v changes
.\scripts\setup.ps1             # doctor + the one-time steps
```

Direct `v` invocations are fine for iteration, but they need the flags
`scripts/common.ps1:Get-VCFlags` builds:

```powershell
.\scripts\common.ps1            # dot-source for the helpers
v -cc gcc -cflags '-Wno-incompatible-pointer-types' -ldflags '-lws2_32' test .\platform
```

Those flags are not optional on this machine and are not cargo cult:

- `-Wno-incompatible-pointer-types` — V ships `thirdparty/vschannel/vschannel.c`,
  which predates GCC 14; GCC 14 turned that mismatch into a hard error and the
  installed GCC is 16.1. The vails repo documents the same flag.
- `-lws2_32` — anything importing `net` needs winsock linked explicitly.

Also note `v test` and `v fmt` recurse, so they must be given an explicit
target list (`Get-FluxVTargets`): `v test .` would re-run the framework's own
26 test files, and `v fmt -w .` would rewrite the submodule's working tree.

## 2. Two hard rules

### R1 — only `main.v` and `platform/` may import vails

```sh
.\scripts\check-isolation.ps1   # run inside build.ps1 and test.ps1
```

Modules that must stay vails-free: `rpc/`, `aria2ctl/`, `core/`, `engine/`,
`schedule/`, `store/`, `api/`, `shell/`, `pack/`, and the whole frontend. This
is what makes an upstream break a one-file fix. Adding a file to the allowlist
is allowed, but it should be a deliberate act with a reason in the commit.

### R2 — the compatibility gate runs before every build

`build.ps1` calls `sync-vails.ps1 -Probe` first. It greps the vendored vails
tree for the ~34 symbols Fluxget imports. If one is gone, the build stops
instead of producing something that half works.

The deeper check is `platform/contract.v` (compiling it *is* the contract) and
`platform/contract_test.v` (proving the behaviour still holds). Add a symbol to
all three places:

- `platform/contract.v` — a call, a type reference, or a runtime assertion
- `platform/contract_test.v` — a behavioural case
- `scripts/sync-vails.ps1` — `$ContractPatterns`
- `scripts/check-isolation.ps1` — only if a new file needs to import vails

## 3. When vails breaks

`main` moves daily and untested. The order of attack:

1. `.\scripts\sync-vails.ps1 -Report` — which contract line moved, and what
   else changed in the `pub` surface
2. If the fix is ours, it belongs in `platform/` and nowhere else
3. If HEAD is a half-finished refactor, `-Rollback` and carry on; re-check
   tomorrow
4. If it is a real API change, `docs/compat/vails-issue.md` is already a
   drafted issue — send it. That is how the dependency gets fixed instead of
   worked around forever

`vails.lock` records the last revision that passed the full gate. Never edit it
by hand to make a build pass.

## 4. V style

- `v fmt` is law. One style, no debates.
- No globals. `pub` only what other modules need; `pub mut` only for structs
  that `json.decode` must fill.
- Errors as values: `!T` + `or { }`. Never panic in library code.
- C interop stays out of Fluxget entirely. If something needs it, that is a
  vails service, not app code.
- Tests are pure. `v test` never opens a window and never starts `aria2c`; the
  rpc client takes an injected `Transport` for exactly this reason.

### V traps this codebase already paid for

`platform/contract.v` keeps the full list with explanations. The two that bite
hardest:

- A function returning only `!` yields a **bool**, not a Result. `f() == none`
  is always false; `f() != none` is always true. Use `f() or { }`. The helper
  `install_ok` exists so nobody has to remember.
- A map literal with function values does not work. Build maps with
  `mut m := map[string]F{}` plus assignment.

## 5. Wire format

Every struct that crosses the bridge uses **snake_case field names, and those
names are the JSON keys**. They must be written identically in
`platform/manifest.v`'s `ts_types`, and
`test_dts_text_agrees_with_the_wire_format` fails the build otherwise.

camelCase is unreachable: uppercase in a field name is a hard error, and a
`[json: 'name']` attribute is miscompiled by V 0.5.2. This matches the vails
`os_info` service, so it is the framework convention, not a workaround.

## 6. Threading

vails ADR-0010: handlers run on the webview main thread, and V→JS eval from a
spawned worker is a platform violation. So:

- A command handler does pure, fast work only.
- The frontend polls (`fluxget.tick`) instead of being pushed to.
- Notifications are queued in `core/` and drained into the next tick response.
- A background watcher may exist for the browser extension's badge, but it must
  never touch `webview.Ctx.emit`.

## 7. Definition of done

- `.\scripts\test.ps1` green (add `-Format` first if it complains)
- New public API has a test in the same commit
- A `// COMPAT(x)` marker on anything with an upstream replacement coming
- A `docs/ADR/` entry for a decision that would be expensive to reverse
- `vails.lock` re-stamped by `sync-vails.ps1`, never by hand
