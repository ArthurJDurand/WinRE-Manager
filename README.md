# WinRE-Manager
Idempotent, self-healing WinRE manager for managed Win10/11 fleets. Deploys the correct WinRE WIM to a dedicated recovery partition, injects OEM (Dell/HP/Lenovo) and Intel VMD drivers from live manifests, and maintains DesiredStateId-scoped state so re-runs are no-ops.
