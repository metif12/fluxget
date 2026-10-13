# BACKLOG

The list that makes the roadmap and the session agree. Three sections, on purpose
kept apart because conflating them is how a backlog becomes useless:

- **Landed, not recorded** — work that shipped and that the README roadmap does
  not mention yet. Each line here is a doc debt, and it should empty.
- **Asked for, not built** — things a reviewer asked for or that a phase needs.
  This is the real backlog.
- **Landmines** — problems that are not the code and cost more time to diagnose
  than to fix. Read before debugging a red gate.

## Landed, not recorded

None of these are in the README's phase table. They are either unnumbered UI work
or the first half of Phase 4.

| Work | Commit | Should be recorded as |
|---|---|---|
| Per-language fonts, embedded and served as data URIs | `b9440af` | Phase 2 "product feel", now genuinely done |
| Sidebars: queue categories + Settings pages | `b9440af` | Phase 3, and a new row in the phase table |
| Full-text search over the queue | `b9440af` | Phase 3 |
| Add dialog: paste detection, folder suggestion, simple/advanced | `b9440af` | Phase 3's add path |
| Row click → full details (files, pieces, trackers, mirror state) | `b9440af` | Phase 3 |
| Categories that survive a restart | `791ebc6` | Phase 3's `store/` |
| Full-width header, single add path | `f14bb8e` | Phase 3 |
| Byte settings as sliders over a curated ladder | `6c6dac9` | Phase 4's "settings" half |
| Mirror reading: which mirror aria2 is actually using | `e909a58` | Phase 4a |
| Dead mirror dropped, set continues | `880662e` | Phase 4b — half of Phase 4's gate |

## Asked for, not built

**Help text, not a shortcut list.** A reviewer asked for "راهنما و توضیحات" —
guidance and explanation. What shipped is `shortcuts.body`, a list of keys. It
says what a key does, not what the app is for or why a row went red. Real help
wants: what aria2 is doing on this machine, why a download failed and what to do
about it, and where settings actually live. Expected with Phase 6's Control API,
or earlier if it is wanted on its own.

**The rest of Phase 4.**
- adaptive connections — tuning `max-connection-per-server` from observed
  throughput;
- force-sequential streaming — `stream-piece-length` + `split=1`. Note that
  `aria2.getOption` does **not** echo `stream-piece-length` back (verified on
  1.37.0), so this can only be proved by behaviour, not by reading the option;
- checksums — algorithm dispatch and the resume question;
- `fluxget bench` publishing against aria2c and curl **including where we lose**.

**Per-item options have an API but no UI.** `fluxget.set_item_options` exists and
is tested; nothing in the window calls it. The dialog's advanced mode sets
per-batch options at add time, not on an existing row.

**Nothing else open** from this session's review list — the earlier items (add
dialog, paste detection, folder suggestion, both sidebars, global search, row
details, categories, header redesign, byte sliders) are all done.

## Landmines

**Do not rebuild V while a gate is running.** Something on this machine was
modifying the V installation concurrently during one run, and the gate failed with:
`Permission denied` removing files under V's module cache, `cannot duplicate
operator overload` in `vlib/math/`, and a `make v1` fallback. Three untracked
`vlib/` files appeared, then vanished between two commands.

Before blaming your change:
```powershell
git -C C:\Users\xman\v\ status --short    # untracked vlib files = a rebuild in flight
```
Fluxget's own suite was 14/14 green in the same run, which is the tell.

**Force-killing Fluxget leaks aria2c.** Stop-Process leaves the child running and
holding the RPC port, and the next run reaches the stale engine with a fresh
secret, so every call comes back `aria2:1 Unauthorized`. Looks like an auth bug;
it is a leak. Full detail in `tests/e2e_windows/README.md`.

**Screenshots must not be committed.** They render local paths and the account
name. The rule lives in `tests/e2e_windows/README.md` and the repo history was
purged to enforce it once already.
