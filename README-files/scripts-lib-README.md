# scripts/lib

## Purpose
Shared shell helpers for the scripts in `scripts/`. `tags.sh` applies the org's tag schema to resources created through the AWS CLI, because provider `default_tags` do not reach those resources.

## Dependencies
- Sourced by `iso-import.sh`, `register-bundle.sh`, `appstream-build-image.sh` and `create-ldap-inputs.sh`
- Reads tag values from `live/<env>/iwd/env.auto.tfvars`
- No AWS calls

## Inputs
| Function | Arguments | Description |
|---|---|---|
| `assert_schema_tags` | `<env>` | Checks that the seven required values exist in `env.auto.tfvars` and contain no comma or double quote. Call it first |
| `schema_tags_kv` | `<env> <service> <name>` | Prints tags as `key=value,key=value` (Image Builder and AppStream) |
| `schema_tags_list` | `<env> <service> <name>` | Fills the array `SCHEMA_TAG_ARGS` with one `Key=<k>,Value=<v>` element per tag (WorkSpaces, Secrets Manager, SSM) |

Required values in `env.auto.tfvars`: `environment_tag`, `project`, `agency`, `owner`, `application`, `cost_center`, `data_classification`. `compliance` is added when set. `service` and `Name` are passed per resource.

## Outputs
| Name | Description |
|---|---|
| Tag string | Printed by `schema_tags_kv`: `environment`, `project`, `agency`, `owner`, `application`, `cost-center`, `data-classification`, `compliance` (when set), `service`, `Name` |
| `SCHEMA_TAG_ARGS` | Array set by `schema_tags_list`, for use as `--tags "${SCHEMA_TAG_ARGS[@]}"` |

## Usage
```bash
source scripts/lib/tags.sh
assert_schema_tags prod
aws imagebuilder import-disk-image ... --tags "$(schema_tags_kv prod imagebuilder <name>)"

schema_tags_list prod ssm <name>
aws ssm put-parameter ... --tags "${SCHEMA_TAG_ARGS[@]}"
```

## Notes and limits
- The environment tag always comes from `environment_tag` (`prod` or `nonprod`), never from the environment folder name. If `environment_tag` is not set, the folder name is used, matching `live/_shared/shared_providers.tf`.
- A missing value or a value containing a comma or double quote stops the calling script before any resource is created. Commas and quotes would split one tag into two in the AWS CLI shorthand syntax. Spaces are fine.
- The org SCPs require the nine-key schema at creation time, so fix `env.auto.tfvars` and retry.
