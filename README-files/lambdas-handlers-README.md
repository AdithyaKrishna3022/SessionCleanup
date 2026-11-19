# src/lambdas/handlers

## Purpose
The five Lambda entry points of the WorkSpaces lifecycle automation. Each is a thin handler that calls the shared logic in [`wslifecycle`](../wslifecycle/README.md).

## Dependencies
- `wslifecycle` (`config`, `reconcile`, `ad`, `workspaces`, `audit`)
- Environment variables and IAM set by `modules/lifecycle-automation`. The full variable list is in [src/lambdas/README.md](../README.md)

## Inputs
| Handler | Trigger | Event |
|---|---|---|
| `ad_sync.lambda_handler` | EventBridge, every 5 minutes | none |
| `orchestrator.lambda_handler` | `ad_sync`, asynchronous | `desired`: complete list of users, each with `username`, `enabled` and `pools` |
| `provision.lambda_handler` | Orchestrator, asynchronous | `action` (`create`, `restore` or `deprovision`), `username`, `pool`, and `workspace_id` for restore and deprovision |
| `revoke.lambda_handler` | Orchestrator, asynchronous | `username`, `pool`, `workspace_id` |
| `reaper.lambda_handler` | EventBridge schedule | none |

## Outputs
| Handler | Returns | Side effects |
|---|---|---|
| `ad_sync` | `{users, changed}` | Audit rows in the user-directory table, async call to the orchestrator, `SyncFailed` metric and alert on failure |
| `orchestrator` | Counts per action, plus `withheld` and `skipped` | Async calls to the workers, `DISPATCHED` rows, `DesktopsSkipped` and `CircuitBreakerTripped` metrics, critical alert on a trip |
| `provision` | `created`, `already-provisioned`, `restored` or `pending-termination`, with the WorkSpace ID | Status rows, `Provisioned` or `Deprovisioned` metrics, failure alert |
| `revoke` | `pending-termination` or `terminated`, with the WorkSpace ID | `RevokedAt` tag, status rows, `Revoked` metric, failure alert |
| `reaper` | `{terminated: N}`, or `{terminated: 0, withheld: N}` when the breaker trips | `TERMINATED` rows, `Terminated` metric, critical alert on a trip |

## Usage
Handlers are invoked by AWS, not by hand. To exercise them locally, run the unit tests (`pytest` in `src/lambdas`). To check a run, read the function's CloudWatch log group and the status table.

## Notes and limits
- The orchestrator has reserved concurrency 1, so runs never overlap.
- `revoke` is a separate function so security-driven removals are audited apart from routine offboarding. By default it gives the same grace period as a deprovision. Setting `deprovisioning.revoke_skips_grace_period` terminates immediately.
- The reaper's breaker uses only `max_deprovisions_per_run`. The orchestrator's also uses `max_deprovision_percent`.
- A random 0-2 second delay in `provision` spreads WorkSpaces API calls. The WorkSpaces client retries adaptively, up to 10 attempts.
