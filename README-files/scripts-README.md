# scripts

## Purpose
Operator and CI helper scripts for the IWD AWS VDI platform: Terraform backend initialisation, Lambda packaging, golden-image builds and WorkSpaces bundle registration, client login-screen branding, the AD-lifecycle inputs, and the WorkSpaces Applications (AppStream) image build. They exist because the AWS provider has no resource for these operations. Most are run by the GitHub Actions workflows (see [.github/workflows](../.github/workflows/README.md)). A few are run by hand.

## Resources created
| Script | Run by | What it does and what it creates or changes |
|---|---|---|
| `tf-init.sh` | `tf-layer.yml`, `branding.yml` | Runs `terraform init` for a root using the nearest `backend.hcl`. Creates no AWS resources |
| `build-lambdas.sh` | `tf-layer.yml` (plan of `personal/60-automation`) | Builds the lifecycle Lambda package and optionally uploads it to the artifacts bucket (S3 object `lambdas/lifecycle/<hash>.zip`) |
| `build-images.sh` | `images.yml` | Starts EC2 Image Builder pipeline executions (new image builds) and shows build status |
| `iso-import.sh` | `images.yml` | Imports a Windows 11 Enterprise ISO as the BYOL base image (a new Image Builder image build version) |
| `register-bundle.sh` | `images.yml` | Imports an Image Builder build as a BYOL WorkSpaces image and creates the pool's WorkSpaces bundle |
| `check-branding.sh` | `ci.yml`, `branding.yml` | Validates `branding/config.json` and its logo. Read-only, no AWS access |
| `apply-client-branding.sh` | `tf-layer.yml` (after `personal/20-directory`), `branding.yml` | Applies the client login-screen branding to a directory (`import-client-branding`) |
| `create-ldap-inputs.sh` | By hand | Creates or updates the LDAP read-account secret (Secrets Manager) and the AD CS root certificate parameter (SSM String) used by `personal/60-automation` |
| `appstream-build-image.sh` | By hand (operator side) | Starts the AppStream image builder and prints a connect URL. With `--finalize`, waits for the image and tags it |
| `appstream-image-assistant.ps1` | By hand, inside the image-builder session | Adds the kiosk application to the image catalog and creates the AppStream image |
| `appstream-mount-fsx.ps1` | Inside an AppStream session | Maps the FSx profile share as a drive letter |
| `appstream-usage-reports.sh` | By hand | Enables daily AppStream usage reports, once per account and region |
| `lib/tags.sh` | Sourced by `iso-import.sh`, `register-bundle.sh`, `appstream-build-image.sh` and `create-ldap-inputs.sh` | Org tag schema helpers. See [lib/README.md](lib/README.md) |

## Dependencies
- Upstream folders and files: `live/<env>/iwd/env.auto.tfvars` (account, region, artifacts bucket and tag values), the `backend.hcl` file above each root, `live/<env>/iwd/platform.auto.tfvars`, `src/lambdas/`, `branding/config.json` and its logo, `cert/RootCA.pem`
- Terraform-published inputs: the SSM parameter `/<prefix>/<env>/pools` (from `personal/50-pools`, used by `register-bundle.sh`) and the Image Builder infrastructure configuration `<prefix>-<env>-imagebuilder` (from `personal/40-images`)
- Tools: bash, AWS CLI, `jq`, `openssl`, `zip`, `python3` with `pip`, Terraform. `iso-import.sh` needs an AWS CLI that supports `--windows-configuration` (the workflow installs AWS CLI v1 for this). The `.ps1` files need PowerShell inside the AppStream builder or session
- AWS access: credentials for the target account. `build-images.sh`, `register-bundle.sh` and `create-ldap-inputs.sh` stop if the credentials belong to a different account than the one in `env.auto.tfvars`
- External: the AD domain (LDAP read account and CA certificate, owned by the AD team), the artifacts bucket, and an FSx share for the Applications profile drive

## Inputs
Environment is `prod` unless noted. Required arguments are in angle brackets.

| Script | Argument or variable | Default | Required | Description |
|---|---|---|---|---|
| `tf-init.sh` | `<root>` and extra args | - | yes | Terraform root directory. Extra arguments go to `terraform init` |
| `build-lambdas.sh` | `[s3-bucket]` | build only | no | Upload the zip to this bucket |
| | `PYTHON_VERSION`, `PLATFORM` | `3.13`, `manylinux2014_aarch64` | no | Target runtime and platform for dependencies |
| | `ARTIFACTS_KMS_KEY_ARN` | unset (SSE-S3) | no | Use SSE-KMS for the upload |
| `build-images.sh` | `start\|status`, `<env>`, `<image>...` | - | yes | Image names start with `ia-iwd-ws-`. No names lists the pipelines |
| | `DRY_RUN=1` | off | no | Check parents and running builds only |
| `iso-import.sh` | `start\|status`, `<env>`, `<iso-s3-key>`, `<image-name>`, `<semver>`, `[image-index]` | - | yes (index optional) | For `status`, pass `""` for the key. Index is the 1-based edition in a multi-edition ISO. Omit it for single-edition ISOs |
| | `AWS_CLI` | `aws` | no | CLI used for the import |
| `register-bundle.sh` | `<env>`, `<pool>`, `[version]` | newest version | yes (version optional) | Pool name as published in the pools SSM parameter |
| | `DRY_RUN=1` | off | no | Print the plan and stop |
| | `NO_WAIT=1` | off | no | Start or check the import and return |
| | `NAME_PREFIX`, `POLL_SECONDS`, `MAX_WAIT_MINUTES`, `OS_VERSION` | `ia-iwd-ws`, `60`, `180`, `Windows_11` | no | Naming prefix, polling interval, wait limit and OS version |
| `check-branding.sh` | `[config.json]` | `branding/config.json` | no | Config file to validate |
| `apply-client-branding.sh` | `<directory-id>`, `[config.json]` | `branding/config.json` | yes (config optional) | Directory to brand |
| `create-ldap-inputs.sh` | `<env>`, `[secret\|ca\|all]` | `all` | yes (second optional) | Which input to create |
| | `CA_PEM` | `cert/RootCA.pem` | no | Path to the AD CS root certificate |
| | `SEGMENT`, `SECRET_NAME`, `CA_PARAM` | `manual-dev`, derived, derived | no | Segment and names of the secret and parameter |
| `appstream-build-image.sh` | `<env>`, `<image-name>`, `[builder-name]`, `--finalize` | builder `<prefix>-<env>-kiosk-image-builder` | yes (builder optional) | Image name must be lowercase alphanumeric segments joined by single hyphens |
| | `NAME_PREFIX`, `POLL_SECONDS`, `MAX_WAIT_MINUTES` | `ia-iwd-ws`, `30`, `90` | no | Naming prefix, polling interval, wait limit |
| `appstream-image-assistant.ps1` | `-ImageName`, `-ApplicationName`, `-ApplicationPath` | - | yes | Same image-name rule. Application must already be installed in the builder |
| | `-DisplayName`, `-IconPath` | application name, none | no | Catalog display name and `.png` or `.ico` icon |
| `appstream-mount-fsx.ps1` | `-UncPath` (or `IWD_FSX_UNC_PATH`), `-DriveLetter` (or `IWD_FSX_DRIVE`) | drive `P` | UNC path yes | Share as `\\<server>\<share>[\<path>]` and a single letter D-Z |
| `appstream-usage-reports.sh` | `<env>` | - | yes | Directory under `live/` |

## Outputs
| Script | Output |
|---|---|
| `tf-init.sh` | Initialised root. Prints which backend config it used |
| `build-lambdas.sh` | `dist/lifecycle.zip`, `dist/lifecycle.json` and `dist/lambda_package.auto.tfvars.json` (the Terraform input for `personal/60-automation`) |
| `build-images.sh` | `START`, `SKIP` or `READY` per image, and a status table. Exits 1 if an image was skipped because it has no pipeline or its parent is not ready |
| `iso-import.sh` | Build ARN on `start`. Table of build, state, reason and AMI on `status` |
| `register-bundle.sh` | WorkSpaces image and bundle, named `<image>-<version>-b<build>` and `<prefix>-<pool>-bundle-<version>-b<build>`. Prints how to pin the bundle |
| `check-branding.sh` | `branding config ok`, a list of errors, or a "not ready" notice while placeholders remain (exit 0) |
| `apply-client-branding.sh` | `Client branding applied to <directory-id>`. Fails while placeholders remain |
| `create-ldap-inputs.sh` | ARNs to set as `ldap_read_secret_arn` and `ldaps_ca_parameter_arn` in `live/<env>/iwd/platform.auto.tfvars` |
| `appstream-build-image.sh` | A connect URL valid for 1 hour (without `--finalize`). The tagged image name and how to pin it (with `--finalize`) |
| `appstream-image-assistant.ps1` | A new AppStream image. The builder session ends |
| `appstream-mount-fsx.ps1` | The mapped drive |
| `appstream-usage-reports.sh` | The usage-report subscription, or the existing bucket and any subscription errors |

## Usage
Normally the workflows call these scripts. To run one by hand, use credentials for the target account and run from the repository root.

```bash
# Initialise a Terraform root
scripts/tf-init.sh live/prod/iwd/personal/40-images

# Build and upload the Lambda package
scripts/build-lambdas.sh <artifacts-bucket>

# Golden image: check first, start, then watch
DRY_RUN=1 scripts/build-images.sh start prod <image-name>
scripts/build-images.sh start prod <image-name>
scripts/build-images.sh status prod

# New base image from an ISO (status uses an empty ISO key)
scripts/iso-import.sh start prod <iso-s3-key> <image-name> <semver> <image-index>
scripts/iso-import.sh status prod "" <image-name> <semver>

# Register a pool bundle (re-run until the bundle is reported)
NO_WAIT=1 scripts/register-bundle.sh prod <pool>

# Client branding
scripts/check-branding.sh
scripts/apply-client-branding.sh <directory-id>

# LDAP inputs for the AD lifecycle (prompts for the password)
scripts/create-ldap-inputs.sh prod secret
scripts/create-ldap-inputs.sh prod ca

# AppStream image
scripts/appstream-build-image.sh prod <image-name>
#   in the builder session, from an elevated PowerShell prompt:
#   .\appstream-image-assistant.ps1 -ImageName <image-name> -ApplicationName <name> -ApplicationPath "<path-to-app.exe>"
scripts/appstream-build-image.sh prod <image-name> --finalize

# AppStream usage reports
scripts/appstream-usage-reports.sh prod
```

## Notes and limits
- **Long operations are split into start and status.** Image builds take 1-2 hours and ISO or WorkSpaces image imports take 45-90 minutes, which is longer than one role-chained CI session. Re-run the status call or the same command until it reports completion.
- **Image build order.** Build the base image first, then `dev-manual`, then `manual-staff-lmi`, `vendor-support` and `arcgis-gpu`. A child image starts only when its parent's newest version has an AVAILABLE build. A pipeline that is already building is skipped.
- **Bundles and images are never deleted by these scripts.** Pools resolve the newest bundle. To pin one, set `bundle_version` for the pool in `live/<env>/iwd/personal/50-pools/terraform.tfvars` and remove `bundle_id`.
- **Tags.** Resources created through the CLI do not receive provider `default_tags`, so the scripts add the org tag schema themselves. A missing value, or a value containing a comma or double quote, stops the script before anything is created.
- **No stored credentials.** `create-ldap-inputs.sh` reads the password silently and passes it through a temporary file with restricted permissions. `appstream-mount-fsx.ps1` uses the session's own Kerberos ticket. The AppStream connect URL is sensitive and expires after 1 hour.
- **Terraform does not manage the LDAP secret or the CA parameter**, by design. Re-running `create-ldap-inputs.sh` is how the password or certificate is changed, with no Terraform change.
- **AppStream names.** Image names must be lowercase alphanumeric segments joined by single hyphens (for example `ws-kiosk-image-2`), because `modules/workspaces-applications` finds images with an anchored pattern. The AppStream scripts are not called by any workflow in this repository.
- **CI.** `ci.yml` runs shellcheck on `scripts/*.sh` and `scripts/lib/*.sh`. The `.ps1` files are not linted.
