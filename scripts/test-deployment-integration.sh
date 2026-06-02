#!/usr/bin/env bash
set -euo pipefail

require() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required env: $name" >&2
    exit 1
  fi
}

require KOMODO_HOST

if [[ -z "${KOMODO_API_KEY:-}" || -z "${KOMODO_API_SECRET:-}" ]]; then
  if [[ -z "${KOMODO_TOKEN:-}" ]]; then
    echo "Set KOMODO_API_KEY + KOMODO_API_SECRET, or KOMODO_TOKEN" >&2
    exit 1
  fi
fi

command -v jq >/dev/null || {
  echo "jq is required" >&2
  exit 1
}

REPO_NAME="${REPO_NAME:-ci-deployment-integration-repo}"
STACK_NAME="${STACK_NAME:-ci-deployment-integration-stack}"
GIT_PROVIDER="${GIT_PROVIDER:-github.com}"
GIT_HTTPS="${GIT_HTTPS:-true}"
GIT_ACCOUNT="${GIT_ACCOUNT:-}"
GIT_REPO="${GIT_REPO:-moghtech/komodo}"
GIT_BRANCH="${GIT_BRANCH:-main}"
RUN_DIRECTORY="${RUN_DIRECTORY:-.}"
COMPOSE_FILE="${COMPOSE_FILE:-compose.yaml}"
STACK_ENVIRONMENT="${STACK_ENVIRONMENT:-}"
RECREATE="${RECREATE:-false}"
DEPLOY="${DEPLOY:-false}"
LOG_FULL_RESPONSE="${LOG_FULL_RESPONSE:-true}"
SERVER_ID="${SERVER_ID:-}"
SWARM_ID="${SWARM_ID:-}"

AUTH_ARGS=()
if [[ -n "${KOMODO_API_KEY:-}" && -n "${KOMODO_API_SECRET:-}" ]]; then
  AUTH_ARGS+=("-H" "x-api-key: $KOMODO_API_KEY")
  AUTH_ARGS+=("-H" "x-api-secret: $KOMODO_API_SECRET")
else
  AUTH_ARGS+=("-H" "Authorization: Bearer $KOMODO_TOKEN")
fi

post() {
  local path="$1"
  local body="$2"
  curl -sS -f \
    "${AUTH_ARGS[@]}" \
    -H "Content-Type: application/json" \
    -X POST \
    "$KOMODO_HOST$path" \
    -d "$body"
}

log_json() {
  local title="$1"
  local payload="$2"
  echo "--- $title ---"
  if [[ "$LOG_FULL_RESPONSE" == "true" ]]; then
    echo "$payload" | jq .
  else
    echo "$payload"
  fi
}

log_request() {
  local title="$1"
  local body="$2"
  log_json "$title request body" "$body"
}

log_response() {
  local title="$1"
  local response="$2"
  log_json "$title response" "$response"
}

repo_body=$(jq -n \
  --arg name "$REPO_NAME" \
  --arg server_id "$SERVER_ID" \
  --arg git_provider "$GIT_PROVIDER" \
  --argjson git_https "$GIT_HTTPS" \
  --arg git_account "$GIT_ACCOUNT" \
  --arg repo "$GIT_REPO" \
  --arg branch "$GIT_BRANCH" \
  --argjson recreate "$RECREATE" \
  '{
    name: $name,
    recreate: $recreate,
    config: {
      git_provider: $git_provider,
      git_https: $git_https,
      git_account: $git_account,
      repo: $repo,
      branch: $branch
    }
  }
  | if $server_id == "" then . else .config.server_id = $server_id end')

echo "==> Upserting repo '$REPO_NAME'"
log_request "recreate-repo" "$repo_body"
repo_res=$(post "/custom/deployment/recreate-repo" "$repo_body")
log_response "recreate-repo" "$repo_res"
repo_action=$(echo "$repo_res" | jq -r '.action')
repo_id=$(echo "$repo_res" | jq -r '.repo.id // .repo._id.$oid')
if [[ "$repo_action" != "created" && "$repo_action" != "updated" && "$repo_action" != "recreated" ]]; then
  echo "Unexpected repo action: $repo_action" >&2
  exit 1
fi

stack_body=$(jq -n \
  --arg repo "$REPO_NAME" \
  --arg name "$STACK_NAME" \
  --arg server_id "$SERVER_ID" \
  --arg swarm_id "$SWARM_ID" \
  --arg run_directory "$RUN_DIRECTORY" \
  --arg compose_file "$COMPOSE_FILE" \
  --arg environment "$STACK_ENVIRONMENT" \
  '{
    repo: $repo,
    name: $name,
    config: {
      run_directory: $run_directory,
      file_paths: [$compose_file],
      environment: $environment
    }
  }
  | if $server_id == "" then . else .config.server_id = $server_id end
  | if $swarm_id == "" then . else .config.swarm_id = $swarm_id end')

echo "==> Upserting stack '$STACK_NAME' from repo '$REPO_NAME'"
log_request "upsert-stack-from-repo" "$stack_body"
stack_res=$(post "/custom/deployment/upsert-stack-from-repo" "$stack_body")
log_response "upsert-stack-from-repo" "$stack_res"
stack_action=$(echo "$stack_res" | jq -r '.action')
linked_repo=$(echo "$stack_res" | jq -r '.stack.config.linked_repo')
if [[ "$stack_action" != "created" && "$stack_action" != "updated" ]]; then
  echo "Unexpected stack action: $stack_action" >&2
  exit 1
fi
if [[ "$linked_repo" != "$repo_id" ]]; then
  echo "Expected stack linked_repo '$linked_repo' to equal repo id '$repo_id'" >&2
  exit 1
fi

if [[ "$DEPLOY" != "true" ]]; then
  echo "==> Skipping deploy. Set DEPLOY=true to call /custom/deployment/deploy-stack."
  echo "Integration API smoke test passed."
  exit 0
fi

deploy_body=$(jq -n --arg stack "$STACK_NAME" '{stack: $stack, services:[]}')
echo "==> Deploying stack '$STACK_NAME'"
log_request "deploy-stack" "$deploy_body"
deploy_res=$(post "/custom/deployment/deploy-stack" "$deploy_body")
log_response "deploy-stack" "$deploy_res"
update_id=$(echo "$deploy_res" | jq -r '.id')
if [[ -z "$update_id" || "$update_id" == "null" ]]; then
  echo "Deploy did not return an update id" >&2
  exit 1
fi

echo "Integration deploy test passed. Update id: $update_id"
