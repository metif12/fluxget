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

### How state reaches a handler without a global

A bridge handler's signature is fixed — `fn (params string) !string` — so there
is nowhere to thread state through it, and "no globals" rules out the obvious
workaround. The pattern: the state is a **heap** object, and the handlers are
**closures** that capture it.

```v
@[heap]
pub struct App { pub mut: state &core.State }

pub fn default_backend(app &App) map[string]Handler {
	mut backend := map[string]Handler{}
	mut a := app                                  // REQUIRED, see below
	backend['fluxget.tick'] = fn [mut a] (_ string) !string { return a.tick_json() }
	return backend
}
```

Two rules that are not obvious:

- `mut a := app` before the closure is **load-bearing**. A V closure gets a *copy*
  of what it captures unless the capture is mutable. Drop it and every handler
  mutates a private copy.
- The build then prints `` `app` is immutable, cannot have a mutable reference
  to an immutable object ``. **The notice is wrong.** `App` is `@[heap]` and
  shared by pointer, so the mutation lands on the one object.
  `platform/contract_test.v::test_two_commands_see_the_same_state` proves it:
  push a notice onto the state, call `fluxget.tick` through the router, require
  the notice back. If that test fails, believe the test.

### V traps this codebase already paid for

`platform/contract.v` keeps the original list with explanations. The Phase 1
list is below, and each one is recorded in the file that hit it.

- A function returning only `!` yields a **bool**, not a Result. `f() == none`
  is always false; `f() != none` is always true. Use `f() or { }`. The helper
  `install_ok` exists so nobody has to remember.
- A map literal with function values does not work. Build maps with
  `mut m := map[string]F{}` plus assignment.
- `!` **cannot propagate inside `assert`**: `assert f()! == x` fails to compile
  with "to propagate a Result, the call must also return a Result type", because
  `assert` is a statement. Use a helper that returns the value and asserts.
- **`err` only exists for a Result, never for an Option.** `or { err.msg() }` is
  correct after a call returning `!T` and does not compile after one returning
  `?T` — `opt_map`, `opt_arr`, `m['key'] or { }`. An Option has no error to
  report, so say what you *expected* instead of reaching for a variable that is
  not there. (Shipped broken once; `build.ps1` cannot see it.)
- A `mut` method cannot be called on a temporary. `eng(f).add(x)` does not
  compile however it is parenthesised — bind `mut e := eng(f)` first.
- `if x := expr` is only legal when `expr` is an **Option or a Result**. It is a
  hard error on a `string` or an `int`, so `if p := os.getenv(..)` and
  `if n := p.int()` both fail. Use `os.getenv_opt` and `strconv.atoi`.
- `import crypto.rand` is **miscompiled**: the codegen drops the qualifier and
  emits `string__bytes(crypto.rand)`, a hard C error at link time with a clean
  comptime. The alias form works and is load-bearing:
  `import crypto.rand as csprng`.
- A `_test.v` file is compiled **into** the module under test, not beside it.
  So its top-level names share a namespace (`const sep` here collided with a
  local `sep` in the module), and any `fn test_*` in it is treated as a test to
  run — a helper called `test_app` is rejected as an "invalid test signature".
- `init:` requires `len:`. `[]T{cap: n, init: v}` is a hard error, and the trap
  goes the other way too: `[]T{len: n}` on a sum-type array is only a *warning*.
- Numeric literal type suffixes do not exist in 0.5.2: `1700000000000i64` and
  `1.44f64` are "unsuitable digit". Use a cast — and note an untyped constant
  expression is evaluated as `int`, so `2 * 1024 * 1024 * 1024` overflows.
- `String.index_of` does not exist; `String.index` returns `?int`. The unknown
  method then cascades into unrelated-looking errors three lines later.
- `String.trim_space()` takes no cutset, and there is no `trim(cutset)`.
- `map[string]T{cap: n}` is rejected: "explicit `map` initialization does not
  support parameters".
- No float format specifier: `${v:0.1f}` is "unsuitable digit", there is no
  `str_float_precision`, and `strconv.ftoa_64` is scientific. See
  `engine/limits.v` for the integer-arithmetic version.

### One claim in this file that is false

`rpc/types.v` says "Comments in this project are ASCII only ... scripts/test.ps1
enforces it". **No script enforces it**, and 8 of our own `.v` files contain
non-ASCII bytes (em-dashes) with a green gate. So the stated *reason* — V 0.5.2's
scanner mis-terminating a multi-byte comment — is unverified: the code compiles
and the tests pass with those bytes present. New files stay ASCII, and
`v fmt` keeps its place as the formatting authority, but nobody should read the
enforcement as a checked property. Fix the claim or add the check; do not leave
it as an unbacked reason.

### Two V facts this project's design depends on

- **`os` has no `find_executable` and no `which`.** The PATH walk in
  `aria2ctl/locate.v` is ours, and it is a pure function so the search *order* is
  testable on a machine with no aria2c — which is most machines.
- **`webview.Config` has `on_ready` and no close hook.** `webview.run` returns
  after the window closes, so the engine shutdown belongs in `main.v` after
  `platform.boot` returns, and the `App` is built in `main.v` so somebody owns
  its lifetime. `boot()` cannot own it: a temporary inside `boot()` would be shut
  down by luck.

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
- A handler may not `time.sleep`. A scheduled restart records *when* it is due
  and the tick performs it (ADR-0002).

The reasoning, and the two designs that are ruled out because of this, are in
[ADR-0002](docs/ADR/0002-engine-lifecycle-and-tick-not-push.md).

## 7. Network use

This machine's bandwidth is not free and not unlimited. Treat the network as
something to spend deliberately, not something to reach for by default.

**The gate is already network-free, and must stay that way.** `test.ps1` and
`build.ps1` both call `sync-vails.ps1 -Probe`, which greps the vendored tree and
touches no network. If a change ever makes the gate fetch something, that is a
regression in this section even when it is faster.

- **`.\scripts\sync-vails.ps1` with no arguments is the only thing that moves the
  pin**, and it runs `git fetch origin/main` plus a full gate. Use it when the pin
  genuinely needs to move, or when investigating a break (§3). Do not run it as a
  reflex before unrelated work — for a routine contract check, `-Probe` is enough
  and costs nothing.
- **Do not fetch pages, docs or search the web unless asked.** Prefer what is
  already on disk: `vendor/vails` is a complete checkout of the framework, and the
  vails repo's own `docs/` and `ROADMAP` answer most "what does upstream do"
  questions without a request.
- **Do not download test data at run time by default.** Anything that needs a
  file from the internet is opt-in behind an explicit switch or environment
  variable, and it is small: the e2e probe is 1 MiB and that is the ceiling.
- **`scripts/fetch-aria2.ps1` is the one unavoidable download** — 2.4 MB, once,
  a GPL binary that is never committed. It is a build prerequisite, not a test
  fixture, and re-running it needs `-Force`.

Phase 4's `fluxget bench` is where this is easiest to forget: a benchmark that
downloads a 1 GB file to look impressive is exactly the wrong thing to leave in a
script. It measures what is on disk, or takes a URL the operator supplies.

## 8. Definition of done

- `.\scripts\test.ps1` green (add `-Format` first if it complains)
- **…and green on the tree you are about to commit.** A gate result describes the
  tree as it was when the gate ran; every edit after it invalidates the result.
  This is not hypothetical: 67925c8 shipped a `rpc_test.v` that did not compile,
  because a green gate run from before the last edit was reported afterwards.
- **`build.ps1` cannot catch a broken test.** It compiles `.`, and `.` excludes
  `_test.v`, so a test file can be broken while the build is green. Only
  `test.ps1` sees it.
- New public API has a test in the same commit
- A `// COMPAT(x)` marker on anything with an upstream replacement coming
- A `docs/ADR/` entry for a decision that would be expensive to reverse
- `vails.lock` re-stamped by `sync-vails.ps1`, never by hand

### And, since Phase 1

- **A test that cannot fail is worse than no test.** Two bugs here survived
  32 green tests because the assertions passed on the broken shape: the multicall
  sent its arguments as a JSON *string* while the test asserted
  `contains('[0,10]')`, which matches happily inside that string. Assert the
  **type** and the **shape** of what crosses a boundary, not a substring of it.
- **The fake transport cannot catch a wire-format bug.** `rpc.Fake` returns
  canned responses, so it never validates a request. Everything about how a
  request is *shaped* is unverified until a real aria2 answers. When a protocol
  detail is load-bearing, check it against the real thing with `curl` and pin
  what you find in the fixture — that is how aria2's nested multicall results and
  its "no token on the outer call" rule were established.
- **A screenshot must be checked.** `scripts/capture-window.ps1` refuses to write
  a blank frame, because a capture that silently failed looks exactly like a
  successful one.
