---
name: Feature request
about: Suggest a new capability or improvement.
labels: ['enhancement', 'needs-triage']
---

## Use case

<!-- What problem does this solve? Give a concrete field scenario. -->

## Proposed behaviour

<!-- What would you like to see happen? -->

## Alternatives considered

<!-- Anything else you have tried or thought about. -->

## Impact on existing deployments

- Would this change the `ScriptVersion`? If so, why does the deployed WIM need to change?
- Would this change the `DesiredStateId` inputs? Adding a new hardware property or deployment input to the ID forces every managed machine to rebuild once on the next run. If so, describe the `Migration note` the change would need.
- Would this force a rebuild on healthy machines?
- Would this alter any exit-code semantics?
- Does it touch the partition lifecycle, BitLocker state, or the state file?

---

**On the design invariants.** WinRE Manager's design is organized around four rules, in this order — see [`docs/architecture.md`](../docs/architecture.md) for the full hierarchy:

1. **Never break Windows RE.**
2. **Never leave a machine without a working recovery route** — to the extent the machine, its OS, and its storage stack allow.
3. **Minimize the `reagentc /disable` → `reagentc /enable` window.**
4. **Do no work unless needed. When work is needed, prepare everything before touching anything.**

If your feature would serve one of these rules, say so — it helps the maintainer weigh it against the rest of the backlog. If your feature would **weaken** any of rules 1–3, say so explicitly; it will need a field case to justify it.

**If the feature would touch the destructive sequence** (`Get-PartitionPlan`, `Ensure-AdequateRecoveryPartition`, the partition create/format/attribute steps and their failure paths, `Remove-OrphanPartition`, `Restore-OSPartitionSize`, `Restore-PreviousWinRERoute`, `Assert-RecoveryPartitionLayout`, `Remove-StrayRecoveryPartitions`), be aware that any eventual PR will be gated. The gate is on the deliberate post-deletion failure test documented in [`docs/testing.md`](../docs/testing.md); see [`CONTRIBUTING.md`](../CONTRIBUTING.md) for the scope. A feature that would change the post-deletion segment cannot ship until that test has run and its result is recorded.
