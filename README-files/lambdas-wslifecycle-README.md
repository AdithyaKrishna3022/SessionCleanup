# src/lambdas/wslifecycle

## Purpose
Shared logic for the lifecycle handlers: pool configuration, the Active Directory snapshot, the reconciliation rules, WorkSpaces API helpers, and the audit trail.

## Dependencies
- `ldap3` (packaged in the Lambda zip) for LDAPS
- `boto3` (from the Lambda runtime) for SSM, Secrets Manager, WorkSpaces, DynamoDB, CloudWatch and SNS
- Used by [`handlers`](../handlers/README.md)

## Inputs
| Module | What it does | Key inputs |
|---|---|---|
| `config.py` | Loads and caches the pool configuration published to SSM | `CONFIG_PARAMETER`, `CONFIG_TTL_SECONDS` (default 300). The parameter's `schema_version` must be 1 |
| `ad.py` | Takes the AD snapshot over LDAPS, including nested groups | LDAP credentials from Secrets Manager, CA certificate, server list and base DN |
| `reconcile.py` | Pure functions (no AWS calls) that compare desired (AD) with actual (WorkSpaces) and produce a plan | Complete desired snapshot, managed WorkSpaces, limits and pool priorities |
| `workspaces.py` | WorkSpaces helpers: list managed desktops, find, create, restore, mark pending termination, terminate, resolve the bundle | `DESKTOP_TAGS` (JSON org tag schema) |
| `audit.py` | Status table rows, CloudWatch metrics and SNS alerts | `ALERT_TOPIC_ARN`, `METRIC_NAMESPACE` |

## Outputs
- `reconcile.plan_reconciliation` returns a plan with `actions` (`CREATE`, `RESTORE`, `DEPROVISION`, `REVOKE`), `withheld` removals, `skipped` creates, and whether the circuit breaker tripped, with its reason.
- Managed desktops carry the tags `ManagedBy=ia-iwd-ws-lifecycle`, `Pool`, `tenant` (when the pool has one) and `PendingTermination` (a date, set on deprovision), plus the org tag schema.

## Usage
```python
from wslifecycle import config, reconcile
cfg = config.load(ssm_client)
plan = reconcile.plan_reconciliation(desired=..., actual=..., known_pools=set(cfg.pools),
    max_deprovisions_per_run=cfg.deprovisioning.max_deprovisions_per_run,
    max_deprovision_percent=cfg.deprovisioning.max_deprovision_percent)
```
Tests are in `../tests` (`pytest` from `src/lambdas`).

## Notes and limits
- `reconcile` rules: desired and no desktop gives `CREATE`. Desired with a pending-termination desktop gives `RESTORE`. Left the group gives `DEPROVISION`. Account disabled gives `REVOKE`. The input must be a complete snapshot of every pool group.
- Circuit breaker: removals are withheld when they exceed `max_deprovisions_per_run`, or exceed the larger of `max_deprovision_percent` of the managed fleet and 1. Creates and restores still proceed.
- `ad` raises on any connection, bind or search failure, or if an AD group is not found exactly once, so a partial snapshot is never reconciled.
- LDAPS uses `CERT_REQUIRED` and checks the host name. Credentials come from Secrets Manager and are never in environment variables.
- `workspaces` only touches desktops tagged as managed. Desktops created by hand are never reconciled or terminated.
- Audit writes, metrics and alerts are best effort: failures are logged and never stop a lifecycle action.
