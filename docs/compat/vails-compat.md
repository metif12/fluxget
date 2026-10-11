# vails compatibility report

Generated 2026-10-11 11:09:56 +03:30 by `scripts/sync-vails.ps1`.

| | |
|---|---|
| locked (vails.lock) | `9ab887728f9f4260e2125265a38420e019aa31f0` |
| checked out | `9ab887728f9f4260e2125265a38420e019aa31f0` |
| origin/main | `9ab887728f9f4260e2125265a38420e019aa31f0` |
| vails commit date | 2026-10-05T11:18:58+03:30 |

## Contract symbols (34 checked)

All contract symbols are present in the checked-out tree.

## Checked-out tree vs locked: 0 added, 0 removed

No change in the `pub` surface between the locked revision and the checked-out tree.

## origin/main vs locked: 0 added, 0 removed

Upstream HEAD matches the locked revision on the `pub` surface.
## Fluxget commits to vails

Listed in the vails plan: `clipboard` (native half), `menu`, `tray`, `opener`,
`window-state`, then S2 `single-instance`. Each already has a `// COMPAT(...)` marker in
the Fluxget source; the ownership table lives in README.md under "Feature ownership".

Withdrawn upstream before Fluxget adopted them, so there is nothing to switch to and the
capability is ours to build: `notification` (`services/notification.v`) and the `store`
service (`state/store.v`). Both were in the plan and both are gone as of the revision
named in the `origin/main` section above.

