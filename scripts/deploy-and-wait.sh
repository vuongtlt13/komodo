#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Script: deploy-and-wait.sh
# Purpose: Triggers a Komodo Stack deployment and polls until the execution
#          completes. Emits execution summaries/logs and returns the exact
#          exit code representing deployment success or failure.
# ==============================================================================

# ------------------------------------------------------------------------------
# Functions
# ------------------------------------------------------------------------------

# Ensures a required environment variable is defined.
# Arguments:
#   $1 - The name of the environment variable.
require_env() {
  local var_name="$1"
  if [[ -z "${!var_name:-}" ]]; then
    echo "Error: Missing required environment variable: $var_name" >&2
    exit 1
  fi
}

# Performs an authenticated POST request against the Komodo API.
# Arguments:
#   $1 - The API endpoint path (e.g. /custom/deployment/deploy-stack)
#   $2 - The JSON string payload body
post_api() {
  local endpoint_path="$1"
  local json_payload="$2"

  curl -sS -f \
    -H "x-api-key: $KOMODO_API_KEY" \
    -H "x-api-secret: $KOMODO_API_SECRET" \
    -H "Content-Type: application/json" \
    -X POST \
    "$KOMODO_HOST$endpoint_path" \
    -d "$json_payload"
}

# Submits the initial deployment command for the target Stack.
# Arguments:
#   $1 - The Stack name
# Returns:
#   The JSON response representing the initial Update.
trigger_deployment() {
  local stack_name="$1"
  local payload
  payload=$(jq -n --arg stack "$stack_name" '{stack: $stack, services:[]}')

  post_api "/custom/deployment/deploy-stack" "$payload"
}

# Fetches the details of a specific Update execution.
# Arguments:
#   $1 - The Update ID
# Returns:
#   The JSON representation of the Update object.
get_update_status() {
  local update_id="$1"
  local payload
  payload=$(jq -n --arg id "$update_id" '{id: $id}')

  post_api "/read/GetUpdate" "$payload"
}

# Extracts the Mongo ID (hex string) from a JSON Resource or Update object.
# Arguments:
#   $1 - The raw JSON response string
# Returns:
#   The extracted ID string on stdout.
extract_update_id() {
  local json_string="$1"
  echo "$json_string" | jq -r '.id // ._id["$oid"]'
}

# Formats and prints the accumulated execution logs to stdout.
# Arguments:
#   $1 - The raw JSON Update object representing a complete run
print_execution_logs() {
  local json_update="$1"

  echo "--- Execution Logs ---"
  echo "$json_update" | jq -r '.logs[] | "Stage: \(.stage)\nCommand: \(.command)\nSuccess: \(.success)\nStdout:\n\(.stdout)\nStderr:\n\(.stderr)\n----------------------------------------"'
}

# ------------------------------------------------------------------------------
# Main Execution
# ------------------------------------------------------------------------------

# 1. Validation
require_env "KOMODO_HOST"
require_env "KOMODO_API_KEY"
require_env "KOMODO_API_SECRET"
require_env "STACK_NAME"

POLL_INTERVAL_SECS="${POLL_INTERVAL_SECS:-2}"
TIMEOUT_SECS="${TIMEOUT_SECS:-600}"

command -v jq >/dev/null || {
  echo "Error: 'jq' is required to parse JSON responses but was not found." >&2
  exit 1
}

# 2. Trigger
echo "==> Initiating deploy for Stack '$STACK_NAME'..."
deploy_res=$(trigger_deployment "$STACK_NAME")
update_id=$(extract_update_id "$deploy_res")

if [[ -z "$update_id" || "$update_id" == "null" ]]; then
  echo "Error: Failed to obtain deployment update ID from response." >&2
  echo "Raw Response: $deploy_res" >&2
  exit 1
fi

echo "==> Deployment triggered. Update ID: $update_id"
echo "==> Monitoring progress (polling every ${POLL_INTERVAL_SECS}s with ${TIMEOUT_SECS}s timeout)..."

# 3. Polling Loop
start_time=$(date +%s)
while true; do
  current_time=$(date +%s)
  elapsed=$((current_time - start_time))

  if (( elapsed > TIMEOUT_SECS )); then
    echo "Error: Deployment monitoring timed out after ${TIMEOUT_SECS}s." >&2
    exit 1
  fi

  update_res=$(get_update_status "$update_id")
  status=$(echo "$update_res" | jq -r '.status')
  # Convert status to lowercase for comparison
  status_lower=$(echo "$status" | tr '[:upper:]' '[:lower:]')

  if [[ "$status_lower" == "complete" ]]; then
    success=$(echo "$update_res" | jq -r '.success')
    # Convert success to lowercase for comparison
    success_lower=$(echo "$success" | tr '[:upper:]' '[:lower:]')

    echo ""
    echo "=== Final Deployment Summary ==="
    echo "Status: $status"
    echo "Success: $success"
    echo "================================"

    print_execution_logs "$update_res"

    if [[ "$success_lower" == "true" ]]; then
      echo "==> Deployment completed successfully in ${elapsed}s!"
      exit 0
    else
      echo "Error: Deployment completed with failures." >&2
      exit 1
    fi
  fi

  echo "Progress: Status is '$status' (elapsed: ${elapsed}s)..."
  sleep "$POLL_INTERVAL_SECS"
done
