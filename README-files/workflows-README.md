# .github/workflows

## Purpose
GitHub Actions workflows that validate, deploy and operate the IWD AWS VDI platform in the prod environment: static checks on every change, Terraform plan/apply for the 10-shared and WorkSpaces Personal roots, golden-image jobs, and WorkSpaces client login-screen branding.

## Resources created
The workflows create no AWS resources themselves. They run Terraform and the scripts in `scripts/`, which create and change the resources.

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` | Push and pull request to `main`, manual | Static checks with no AWS access: `terraform fmt`, validate and `terraform test` for modules, validate for every prod root, tflint, ruff and pytest for `src/lambdas`, shellcheck for `scripts/`, branding input check, actionlint, Trivy config scan (report-only) |
| `terraform.yml` | Push to `main` (path-filtered), manual | Entry point for infrastructure changes. Selects the roots to run and calls `tf-env.yml` for prod |
| `tf-env.yml` | Called by `terraform.yml` | Plans and applies the selected roots in dependency order |
| `tf-layer.yml` | Called by `tf-env.yml` | Plans or applies one root, with approval and a checked plan artifact |
| `images.yml` | Manual, `main` only | Golden-image jobs: ISO import, image builds, WorkSpaces bundle registration |
| `branding.yml` | Manual | Validates or applies the WorkSpaces client login-screen branding |

Root order used by `tf-env.yml` (each root plans only after the applies it depends on):

`10-shared` → `personal/20-directory` → `personal/30-storage` → `personal/40-images` → `personal/50-pools` → `personal/60-automation` → `personal/70-monitoring`

## Dependencies
- Upstream folders: `scripts/` (`tf-init.sh`, `build-lambdas.sh`, `apply-client-branding.sh`, `check-branding.sh`, `build-images.sh`, `iso-import.sh`, `register-bundle.sh`), `modules/`, `live/prod/`, `src/lambdas/`, `branding/config.json`, `.terraform-version`, `.tflint.hcl`
- Root order: `live/prod/iwd/apply-order.txt`. Account and region: `live/prod/iwd/env.auto.tfvars`
- External: the prod AWS account, reached through an OIDC role set in repository variables; GitHub environments `prod-plan` and `prod` with required reviewers; `live/prod/_bootstrap`, which is applied by hand (see `live/README.md`)

## Inputs
Repository variables (names only; set in repository settings):

| Name | Type | Default | Required | Description |
|---|---|---|---|---|
| `AWS_ROLE_ARN` | string | - | yes | Role the workflows assume through OIDC. Must belong to the account in `env.auto.tfvars` |
| `AWS_ACCOUNT_ID` | string | - | no | If set, must equal `account_id` in `env.auto.tfvars` |

### `terraform.yml` (manual run)
| Name | Type | Default | Required | Description |
|---|---|---|---|---|
| `layers` | string | `all` | no | Roots to plan and apply, comma-separated (for example `10-shared,personal/40-images`), or `all`. Unselected roots are skipped and do not block their dependents. `applications/*` is rejected |

### `images.yml` (manual run)
| Name | Type | Default | Required | Description |
|---|---|---|---|---|
| `job` | choice | - | yes | `image-build-start`, `image-build-status`, `iso-import-start`, `iso-import-status` or `register-bundle` |
| `images` | string | empty | no | `image-build-start`: pipeline names, space-separated (names start with `ia-iwd-ws-`). Empty lists the pipelines |
| `dry_run` | boolean | false | no | `image-build-start`: only check parents and running builds, start nothing |
| `pools` | string | empty | no | `register-bundle`: pool names, space-separated. Required for that job |

### `branding.yml` (manual run)
| Name | Type | Default | Required | Description |
|---|---|---|---|---|
| `env` | choice | `prod` | yes | Environment directory under `live/`. Only `prod` is deployed from this repo |
| `mode` | choice | `validate` | yes | `validate` reads the current branding. `apply` pushes `branding/config.json` |

### Called workflows
- `tf-env.yml`: `env`, `layers` (comma-wrapped list from `terraform.yml`)
- `tf-layer.yml`: `env`, `layer`, `mode` (`plan` or `apply`), `plan-sha256` (required for `apply`)

## Outputs
| Name | Description |
|---|---|
| `changes` (`tf-layer.yml`) | `true` when the plan has changes |
| `plan-sha256` (`tf-layer.yml`) | SHA-256 of the saved plan. The apply refuses a plan that does not match |
| Artifact `tfplan-<env>-<layer>` | `tfplan`, `plan.txt` and, for `personal/60-automation`, `lambda_package.auto.tfvars.json`. Layer name has `/` replaced by `-`. Kept for 1 day |
| Run summaries | Plan summary per root, image build and import status, and the branding read-back (logo URL, support email and link, forgot-password link, login message) |

## Usage
Open **Actions**, choose the workflow, **Run workflow**, and select `main`.

Apply infrastructure changes:
1. Merge to `main` (a push to a watched path starts a plan automatically), or run `terraform` manually and set `layers`, for example `personal/40-images`.
2. Review the plan and approve it in `prod-plan`.
3. If the plan has changes, approve the apply in `prod`. The apply uses exactly the reviewed plan.

Run an image job: run `images` with the `job` you need. Run the `*-start` job first and then re-run the matching `*-status` job until it finishes. For `register-bundle`, set `pools` and re-run until each pool reports its bundle.

Update login-screen branding: run `branding` with `mode: validate` and review the read-back, then run it again with `mode: apply`.

For troubleshooting, see [Operational Runbook](../../docs/RUNBOOK.md).

## Notes and limits
- Only `prod` is deployed from this repo. `live/sandbox` is reference configuration and has no workflow.
- `terraform.yml` has no pull-request trigger. The CI role trusts only `refs/heads/main`, so a plan cannot run on a PR. PRs are checked by `ci.yml`. Review the plan on `main` before approving the apply.
- `applications/*` (WorkSpaces Applications) is not deployed by `terraform.yml`, which rejects it. `ci.yml` still validates it.
- The plan artifact expires after 1 day. Approve the apply within that time, or re-run the plan.
- A failed or cancelled upstream root blocks the roots after it.
- Ordering: apply `personal/40-images` before running `images.yml`, and apply `personal/20-directory` before running `branding.yml`.
- Image builds and ISO imports take 1-2 hours, so each is split into a start job and a status job.
- Concurrency: one Terraform run per ref, with a newer pending run replacing an older pending one. Applies, image jobs and branding runs queue and are not cancelled. `ci.yml` cancels older runs for the same PR or branch.
- Security: the `approve` jobs carry the GitHub environment and have no AWS access. The jobs that call AWS have no environment, so their OIDC subject is `refs/heads/main`. Actions are pinned to commit SHAs, and downloaded tool binaries are SHA-256 verified.
- Trivy runs in report-only mode. Setting its exit code to 1 makes it blocking.
