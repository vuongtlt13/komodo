# CI/CD Deployment Integration

This document describes the custom API flow for CI/CD systems that need to:

1. create or recreate a Komodo Repo using a fixed name,
2. create or update a Komodo Stack from that Repo name,
3. deploy the Stack.

The custom endpoints are intentionally separate from Komodo's built-in `/write` and `/execute` request enums to keep this fork easier to rebase against upstream.

## Authentication

All endpoints below require the same authenticated, enabled Komodo user behavior as the normal `/write` and `/execute` APIs.

Use an admin or service user API credential with enough permission to:

- create/update/delete the target Repo,
- create/update the target Stack,
- attach the Stack to the target Server or Swarm,
- execute deploys for the target Stack.

Recommended CI/CD authentication uses a Komodo API key pair. Pass the key and secret as headers:

```sh
-H "Content-Type: application/json" \
-H "x-api-key: $KOMODO_API_KEY" \
-H "x-api-secret: $KOMODO_API_SECRET"
```

`KOMODO_API_KEY` and `KOMODO_API_SECRET` are the `key` and `secret` values generated for a Komodo user or service user.

Bearer tokens are a different auth mechanism, usually a login/session token. They are supported by the smoke test as a fallback, but API key + secret is the recommended option for CI/CD automation.

Bearer example:

```sh
-H "Content-Type: application/json" \
-H "Authorization: Bearer $KOMODO_TOKEN"
```

## Endpoint summary

| Step | Endpoint | Purpose |
| --- | --- | --- |
| 1 | `POST /custom/deployment/recreate-repo` | Create, update, or forcibly recreate a Repo with a fixed name |
| 2 | `POST /custom/deployment/upsert-stack-from-repo` | Create or update a Stack and link it to the Repo by name/id |
| 3 | `POST /custom/deployment/deploy-stack` | Deploy one Stack using Komodo's existing Stack deploy flow |

The normal retry-safe CI path is:

```text
recreate-repo with recreate=false
upsert-stack-from-repo
deploy-stack
```

Use `recreate=true` only when you intentionally want to delete and replace the Repo resource.

## 1. Create or recreate Repo by fixed name

```http
POST /custom/deployment/recreate-repo
```

### Request

```json
{
  "name": "project-a-prod-repo",
  "config": {
    "server_id": "SERVER_ID",
    "git_provider": "github.com",
    "git_https": true,
    "git_account": "github-prod",
    "repo": "owner/project-a",
    "branch": "main"
  },
  "recreate": false
}
```

### Behavior

- If no Repo exists with `name`, the endpoint creates it.
- If a Repo exists and `recreate` is `false`, the endpoint updates the Repo config in place.
- If a Repo exists and `recreate` is `true`, the endpoint deletes the existing Repo and creates a fresh one with the same name.

### Response

```json
{
  "action": "created",
  "repo": {
    "id": "...",
    "name": "project-a-prod-repo"
  }
}
```

`action` can be one of:

- `created`
- `updated`
- `recreated`

### Notes

`recreate=false` is the recommended CI/CD mode. It is safe to retry and keeps the Repo id stable.

`recreate=true` is destructive. It may create a new Repo id. If any Stack was linked to the old Repo id, call `upsert-stack-from-repo` after recreating the Repo so the Stack is relinked to the new Repo id.

## 2. Create or update Stack from Repo name

```http
POST /custom/deployment/upsert-stack-from-repo
```

### Request

```json
{
  "repo": "project-a-prod-repo",
  "name": "project-a-prod-stack",
  "config": {
    "server_id": "SERVER_ID",
    "run_directory": ".",
    "file_paths": ["compose.yaml"],
    "environment": "APP_ENV=production\nDOMAIN=example.com"
  }
}
```

### Behavior

- Resolves `repo` as a Repo name or id.
- Creates or updates a Stack with the fixed Stack `name`.
- Sets `config.linked_repo` to the resolved Repo id.
- Lets the existing Stack validation normalize the linked repo and copy Git metadata from the Repo.

After validation, the Stack stores:

```json
{
  "linked_repo": "REPO_ID"
}
```

The Stack also mirrors linked Repo values for:

- `git_provider`
- `branch`
- `git_https`

### Response

```json
{
  "action": "created",
  "repo": {
    "id": "...",
    "name": "project-a-prod-repo"
  },
  "stack": {
    "id": "...",
    "name": "project-a-prod-stack"
  }
}
```

`action` can be one of:

- `created`
- `updated`

### Compose file paths

If your compose file is at the repo root:

```json
{
  "run_directory": ".",
  "file_paths": ["compose.yaml"]
}
```

If your compose file is at `deploy/compose.prod.yaml`:

```json
{
  "run_directory": "deploy",
  "file_paths": ["compose.prod.yaml"]
}
```

### Stack config files

The `upsert-stack-from-repo` endpoint accepts the full partial Stack config, so it also supports Komodo Stack `config_files`.

`config_files` is Komodo-specific metadata, not a native Docker Compose field. It lets Komodo track additional files related to the Stack, show/edit them in the UI, diff them during `DeployStackIfChanged`, and decide whether a changed file should redeploy, restart, or do nothing.

Example:

```json
{
  "repo": "project-a-prod-repo",
  "name": "project-a-prod-stack",
  "config": {
    "server_id": "SERVER_ID",
    "run_directory": "deploy",
    "file_paths": ["compose.yaml"],
    "config_files": [
      {
        "path": "nginx.conf",
        "services": ["nginx"],
        "requires": "restart"
      },
      {
        "path": "appsettings.json",
        "services": ["api"],
        "requires": "redeploy"
      },
      {
        "path": "README.deploy.md",
        "requires": "none"
      }
    ]
  }
}
```

`config_files` fields:

| Field | Meaning |
| --- | --- |
| `path` | File path relative to `run_directory` |
| `services` | Optional Compose services affected by this file. Empty means global / all services |
| `requires` | What `DeployStackIfChanged` should do if the file changes: `redeploy`, `restart`, or `none` |

Use `additional_env_files` instead of `config_files` for env files that must be passed to Docker Compose with `--env-file`.

## 3. Deploy one Stack

```http
POST /custom/deployment/deploy-stack
```

### Request

```json
{
  "stack": "project-a-prod-stack",
  "services": [],
  "stop_time": null
}
```

### Behavior

This endpoint reuses Komodo's existing `DeployStack` execution flow. It accepts the Stack name or id.

- `services:[]` deploys all services.
- `services: ["api", "worker"]` deploys only those Compose services.
- `stop_time` overrides the default termination max time when the deploy needs to stop existing containers first.

### Response

The response is the normal Komodo `Update` object for the deploy execution.

```json
{
  "id": "UPDATE_ID",
  "operation": "DeployStack",
  "status": "In Progress"
}
```

Use the existing update/read APIs or UI to watch the update until completion.

## Full CI/CD example

```sh
KOMODO_HOST="https://komodo.example.com"
KOMODO_API_KEY="..."
KOMODO_API_SECRET="..."
SERVER_ID="..."

curl -sS -X POST "$KOMODO_HOST/custom/deployment/recreate-repo" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $KOMODO_API_KEY" \
  -H "x-api-secret: $KOMODO_API_SECRET" \
  -d "{
    \"name\": \"project-a-prod-repo\",
    \"config\": {
      \"server_id\": \"$SERVER_ID\",
      \"git_provider\": \"github.com\",
      \"git_https\": true,
      \"git_account\": \"github-prod\",
      \"repo\": \"owner/project-a\",
      \"branch\": \"main\"
    },
    \"recreate\": false
  }"

curl -sS -X POST "$KOMODO_HOST/custom/deployment/upsert-stack-from-repo" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $KOMODO_API_KEY" \
  -H "x-api-secret: $KOMODO_API_SECRET" \
  -d "{
    \"repo\": \"project-a-prod-repo\",
    \"name\": \"project-a-prod-stack\",
    \"config\": {
      \"server_id\": \"$SERVER_ID\",
      \"run_directory\": \".\",
      \"file_paths\": [\"compose.yaml\"],
      \"environment\": \"APP_ENV=production\\nDOMAIN=example.com\"
    }
  }"

curl -sS -X POST "$KOMODO_HOST/custom/deployment/deploy-stack" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $KOMODO_API_KEY" \
  -H "x-api-secret: $KOMODO_API_SECRET" \
  -d '{
    "stack": "project-a-prod-stack",
    "services":[]
  }'
```

## Integration smoke test

A shell smoke test is available at [scripts/test-deployment-integration.sh](scripts/test-deployment-integration.sh).

It verifies:

- fixed-name Repo create/update/recreate endpoint returns a valid action,
- Stack upsert from Repo name works,
- Stack `config.linked_repo` is normalized to the resolved Repo id,
- optional Stack deploy returns an `Update` id.

Required environment:

```sh
export KOMODO_HOST="http://localhost:9120"
export KOMODO_API_KEY="..."
export KOMODO_API_SECRET="..."
```

or:

```sh
export KOMODO_HOST="http://localhost:9120"
export KOMODO_TOKEN="..."
```

Typical non-deploying smoke test:

```sh
REPO_NAME="ci-deployment-integration-repo" \
STACK_NAME="ci-deployment-integration-stack" \
GIT_REPO="owner/project-a" \
GIT_ACCOUNT="github-prod" \
SERVER_ID="SERVER_ID" \
bash scripts/test-deployment-integration.sh
```

Deploying smoke test:

```sh
DEPLOY=true bash scripts/test-deployment-integration.sh
```

## Polling and Waiting in CI/CD

Because the deploy execution is asynchronous, a deployment script is provided at [scripts/deploy-and-wait.sh](scripts/deploy-and-wait.sh) to trigger the deploy and block until the process completes.

It handles:
- calling `/custom/deployment/deploy-stack` and extracting the `Update` ID,
- polling `/read/GetUpdate` every few seconds,
- waiting until `status` is `"Complete"` (case-insensitive),
- checking `success` is `"true"` (case-insensitive) to determine final result,
- printing all execution logs (`stdout` / `stderr`) to the console,
- exiting with code `0` on success, or code `1` on failure to fail the CI pipeline.

Required environment:

```sh
export KOMODO_HOST="https://komodo.example.com"
export KOMODO_API_KEY="..."
export KOMODO_API_SECRET="..."
export STACK_NAME="project-a-prod-stack"

# Optional environment variables
export POLL_INTERVAL_SECS="2"  # Polling interval in seconds (default: 2)
export TIMEOUT_SECS="600"      # Timeout in seconds (default: 600 / 10 minutes)
```

Running in CI/CD step:

```sh
bash scripts/deploy-and-wait.sh
```

## Retry guidance

Recommended retry-safe behavior:

- Use a fixed Repo `name`.
- Use a fixed Stack `name`.
- Keep `recreate=false` for normal runs.
- Run `upsert-stack-from-repo` after every Repo upsert/recreate.
- Deploy by Stack name.

This makes repeated CI runs converge on the same Repo and Stack resources without creating duplicates.

## Failure cases

Common failures include:

- insufficient permission to create/update/delete Repo or Stack,
- target Server/Swarm not found or not attachable,
- Repo is busy cloning, pulling, building, or renaming,
- Stack is busy deploying or being modified,
- invalid Git account or missing token for private repositories,
- missing compose file in the linked repo,
- deploy failure from Docker Compose or Periphery.

When `recreate=true`, Repo deletion may fail if the Repo is busy. In that case, wait for the active Repo operation to finish and retry.

## Relationship to built-in APIs

These custom endpoints are wrappers around existing Komodo behavior:

- Repo create/update/delete use the same resource helpers as `/write/CreateRepo`, `/write/UpdateRepo`, and `/write/DeleteRepo`.
- Stack create/update uses the same resource helpers as `/write/CreateStack` and `/write/UpdateStack`.
- Stack deploy uses the same execution path as `/execute/DeployStack`.

The custom endpoints are not part of the generated Komodo OpenAPI/client schema. This document is the contract for CI/CD usage.
