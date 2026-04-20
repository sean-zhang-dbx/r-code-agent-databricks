#!/usr/bin/env bash
# One-time setup: create a Databricks secret scope and store the credentials
# the UC function needs to reach the Command Execution API.
#
# Prereqs:
#   - Databricks CLI v0.240+ configured for the target workspace
#   - An all-purpose cluster with R preinstalled (use ML Runtime)
#   - A PAT or service principal token with permission to attach to that cluster
#
# Usage:
#   DATABRICKS_HOST=https://<workspace>.cloud.databricks.com \
#   R_CLUSTER_ID=<cluster-id> \
#   R_TOOL_TOKEN=<pat-or-sp-token> \
#   ./sql/01_setup.sh

set -euo pipefail

: "${DATABRICKS_HOST:?must be set}"
: "${R_CLUSTER_ID:?must be set}"
: "${R_TOOL_TOKEN:?must be set}"

SCOPE="${R_TOOL_SCOPE:-r_code_agent}"

echo "Creating secret scope: $SCOPE"
databricks secrets create-scope "$SCOPE" || echo "(scope may already exist)"

echo "Storing workspace host, cluster id, and token"
databricks secrets put-secret "$SCOPE" databricks_host --string-value "$DATABRICKS_HOST"
databricks secrets put-secret "$SCOPE" databricks_token --string-value "$R_TOOL_TOKEN"
databricks secrets put-secret "$SCOPE" r_cluster_id --string-value "$R_CLUSTER_ID"

echo
echo "Done. The UC function reads these three values from env vars that you must"
echo "inject at function execution time. See README.md for how to wire the secret"
echo "scope into the serverless compute that runs the UC function."
