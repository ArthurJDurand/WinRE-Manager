
For each disk whose number is not the OS disk, query `Get-RecoveryPartitions`. For each partition found:

- If it is type-coded (GPT `{de94bba4-06d1-4d40-a16a-bfd50179d6ac}` or MBR `0x27`) and at most 2 GiB, delete it.
- If it is not type-coded (label-only match), log and skip.
- If it is larger than 2 GiB, preserve it, log a warning, and mark the run for operator review.

A deletion failure sets `$Script:nonFatalWarning = $true` and returns `$false`.

The function is called from the fast path, the enable-only path, both pending-reboot exits, and Step 7 of the full-update path. In every case the call is the same; the read-only scan cost when there are no strays is a single `Get-Disk` and a few `Get-Partition` calls per non-OS disk.

## GPT vs MBR

The script handles both partition styles.

**GPT:**

- Recovery type: `{de94bba4-06d1-4d40-a16a-bfd50179d6ac}`.
- Attributes: `0x8000000000000001` (`GPT_ATTRIBUTE_PLATFORM_REQUIRED` + `GPT_ATTRIBUTE_NO_DRIVE_LETTER`).
- Type code applied at creation via `New-Partition -GptType` (v43 patch 5).
- Attributes applied after format via `Set-RecoveryPartitionAttributes`.
- Detection during `Get-RecoveryPartitions`: match on `GptType`.

**MBR:**

- Recovery type: `0x27` (`PARTITION_IFS` with the recovery flag).
- Type code applied at creation via `New-Partition -MbrType 0x27` (v43 patch 5).
- Detection during `Get-RecoveryPartitions`: match on `MbrType`.

The script determines the style from `Get-OSDisk`'s `PartitionStyle` property and passes the appropriate value to both `New-Partition` and `Set-RecoveryPartitionAttributes`.

## Related documents

- [architecture.md](architecture.md) — where the partition lifecycle fits in the pipeline.
- [state-and-idempotency.md](state-and-idempotency.md) — how `GeometryRestoreFailed` and the deferral marker interact with the state file.
- [troubleshooting.md](troubleshooting.md) — the recovery procedure if the partition is lost.
- [driver-injection.md](driver-injection.md) — what happens before the partition work.
