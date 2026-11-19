# src/lambdas

## Purpose
Python 3.13 (arm64) code for `modules/lifecycle-automation`. One package, five handlers, that keep WorkSpaces Personal desktops in step with Active Directory: users in a pool's AD group get a desktop, users who leave the group or whose account is disabled lose it after a grace period, with circuit breakers to stop mass removals.

## Resources created
This folder creates nothing by itself. It is packaged by `scripts/build-lambdas.sh` into `lifecycle.zip` and deployed by `personal/60-automation` through `modules/lifecycle-automation`. The package acts on these resources:
- WorkSpaces (create, restore, stop, terminate) in the directory, tagged `ManagedBy`, `Pool`, `tenant` and, on deprovision, `PendingTermination`
- A DynamoDB status table (lifecycle events) and a user-directory table (pool changes per user)
- CloudWatch metrics in the `IA-IWD/WorkSpaces` namespace and SNS alerts

| Handler | Trigger | Does |
|---|---|---|
| `handlers.ad_sync.lambda_handler` | EventBridge, every 5 min | Takes a full AD snapshot of every pool group over LDAPS, writes an audit row when a user's pools or enabled state change, and invokes the orchestrator |
| `handlers.orchestrator.lambda_handler` | `ad_sync` (async) | Runs `wslifecycle.reconcile.plan_reconciliation`, applies the circuit breaker and dispatches one action per change. Reserved concurrency 1, so runs never overlap |
| `handlers.provision.lambda_handler` | Orchestrator (async) | Create, restore or deprovision one WorkSpace (idempotent) |
| `handlers.revoke.lambda_handler` | Orchestrator (async) | Disabled account: stop now, terminate per policy |
| `handlers.reaper.lambda_handler` | EventBridge schedule | Terminates WorkSpaces whose `PendingTermination` tag is older than `grace_days` |

Shared logic is in `wslifecycle/` (see [wslifecycle/README.md](wslifecycle/README.md)). Handlers are described in [handlers/README.md](handlers/README.md).

## Dependencies
- Runtime: Python 3.13 on arm64, `ldap3==2.9.1` (packaged); boto3 comes from the Lambda runtime
- Development: pytest 8 or later, ruff 0.8 or later, boto3 1.35 or later (`requirements-dev.txt`)
- Pool configuration: the SSM parameter published by `personal/50-pools` (`modules/workspaces-personal`)
- LDAP read account and AD CS root certificate, created by `scripts/create-ldap-inputs.sh` (see [scripts](../../scripts/README.md))
- WorkSpaces bundles from `scripts/register-bundle.sh`, named `<prefix>-<pool>-bundle-<version>-b<build>`
- Deployed by `personal/60-automation` (apply order: after `50-pools`; monitoring in `70-monitoring`)

## Inputs
Environment variables, set by `modules/lifecycle-automation`:

| Name | Used by | Required | Description |
|---|---|---|---|
| `CONFIG_PARAMETER` | all handlers | yes | SSM parameter holding the pool configuration |
| `CONFIG_TTL_SECONDS` | all handlers | no (300) | How long the pool config is cached. A config change can take up to this long to take effect |
| `STATUS_TABLE` | orchestrator, provision, revoke, reaper | yes | DynamoDB table for lifecycle events |
| `USER_DIRECTORY_TABLE` | ad_sync | yes | DynamoDB table for per-user pool changes |
| `ORCHESTRATOR_FUNCTION` | ad_sync | yes | Function invoked with the desired snapshot |
| `PROVISION_FUNCTION`, `REVOKE_FUNCTION` | orchestrator | yes | Worker functions |
| `AD_SERVERS` | ad_sync | yes | Comma-separated domain controller host names |
| `AD_BASE_DN` | ad_sync | yes | Search base for the directory |
| `AD_SECRET_ARN` | ad_sync | yes | Secrets Manager secret with the LDAP `username` and `password` |
| `LDAPS_CA_PARAMETER` | ad_sync | no | SSM parameter with the CA certificate (PEM) used to validate the domain controllers |
| `AD_SERVER_ADDRESSES` | ad_sync | no | `host=ip,host=ip` for VPCs that cannot resolve the domain. TLS still validates the host name |
| `DESKTOP_TAGS` | provision | no | JSON of the org tag schema applied to new desktops |
| `ALERT_TOPIC_ARN` | all handlers | no | SNS topic for alerts. If unset, alerts are only logged |
| `METRIC_NAMESPACE` | all handlers | no (`IA-IWD/WorkSpaces`) | CloudWatch namespace |

Pool configuration (SSM, `schema_version` 1):
- Top level: `directory_id`, `volume_kms_key_arn`, `pools`, `deprovisioning`, `one_desktop_per_user` (default true)
- Per pool: `ad_group`, `image_name`, `compute_type`, `root_volume_gb`, `user_volume_gb`, `running_mode`, `auto_stop_timeout_minutes`, `bundle_name_prefix`, optional `bundle_id`, `priority` (default 100) and optional `tenant`
- `deprovisioning`: `grace_days`, `max_deprovisions_per_run`, `max_deprovision_percent`, `revoke_skips_grace_period`

## Outputs
| Name | Description |
|---|---|
| WorkSpaces and tags | Desktops created, restored, stopped and terminated |
| Status table rows | One per lifecycle event. Statuses: `DISPATCHED`, `PROVISIONING`, `ALREADY_PROVISIONED`, `RESTORED`, `PENDING_TERMINATION`, `TERMINATED`, `FAILED` |
| User-directory table rows | One per user whose pools or enabled state changed, with added and removed pools, plus a `__snapshot__` row |
| Metrics (per pool where applicable) | `Provisioned`, `Deprovisioned`, `Revoked`, `Terminated`, `Failed`, `DesktopsSkipped`, `CircuitBreakerTripped`, `SyncFailed` |
| SNS alerts | AD sync failed, circuit breaker tripped (orchestrator and reaper), and provision or revoke failures |
| `dist/lifecycle.zip`, `dist/lifecycle.json`, `dist/lambda_package.auto.tfvars.json` | Build output of `scripts/build-lambdas.sh` |

## Usage
Local checks (CI runs the same):

```bash
cd src/lambdas
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
.venv/bin/pytest                         # safety rules: reconcile, workers, AD snapshot, config
.venv/bin/ruff check . && .venv/bin/ruff format --check .
../../scripts/build-lambdas.sh [artifacts-bucket]   # -> dist/lifecycle.zip + dist/lifecycle.json
```

Deploying a change: merge to `main`. The `terraform` workflow plans `personal/60-automation` (this builds and uploads the package), then approve the plan and the apply. See [.github/workflows](../../.github/workflows/README.md).

Day-to-day operation:
- Onboard a user: add them to the pool's AD group (account enabled). A desktop is created within about 5 minutes of the next sync.
- Offboard a user: remove them from the group or disable the account. The desktop is stopped and marked pending termination, and the reaper terminates it after `grace_days`. Re-adding the user before then restores it.

For alerts and troubleshooting, see [Operational Runbook](../../docs/RUNBOOK.md).

## Notes and limits
- **Fail closed.** `ad_sync` aborts if any group or search fails, so a partial snapshot never reaches the orchestrator. Without that, users in a missing group would be deprovisioned.
- **Circuit breakers.** The orchestrator withholds all removals (deprovision and revoke) when they exceed `max_deprovisions_per_run` or `max_deprovision_percent` of the managed fleet. Creates and restores still proceed. The reaper stops if more desktops are due than `max_deprovisions_per_run`. Each trips a critical SNS alert.
- **One desktop per user** (default). A user in several pool groups keeps the desktop they have. A new one is created only in the highest-priority pool (lowest `priority`, then name). Other pools are skipped, not failed. A pool move waits until the old desktop is terminated.
- **Managed fleet only.** Only desktops tagged `ManagedBy=ia-iwd-ws-lifecycle` with a `Pool` tag are reconciled or terminated. Desktops in a pool that is removed from the config are ignored.
- **Bundles.** A new desktop uses the pool's pinned `bundle_id`, otherwise the newest AVAILABLE bundle whose name starts with `bundle_name_prefix`. Existing desktops are not rebuilt.
- **Idempotent and retry-safe.** Workers re-check WorkSpaces before acting. A failed action is recorded as `FAILED` and alerted. The next sync recomputes the plan.
- **Audit is best effort.** Failures writing status rows, metrics or alerts are logged and do not stop the lifecycle action.
- **Credentials.** The LDAP credentials are read from Secrets Manager at runtime. They are never in environment variables or Terraform state. Rotate them with `scripts/create-ldap-inputs.sh`, with no redeploy.
- **Scale.** The `__snapshot__` item in the user-directory table holds the previous run's user names and is sized for roughly 15,000 users (the 400 KB item limit).
- **Nested groups count.** Membership uses a nested-group (matching rule in chain) search. Accounts are matched by `sAMAccountName`.
