#!/usr/bin/env bash
# Create (or re-show) a per-user APIM subscription on the "claude-code" product
# and print the Claude Code settings snippet for that user.
#
# Usage: ./scripts/add-user.sh <resource-group> <apim-name> <user-email>
set -euo pipefail

RG="${1:?resource group}"
APIM="${2:?apim name}"
USER_EMAIL="${3:?user email}"

SUB_ID="$(az account show --query id -o tsv)"
# Subscription resource name: lowercase, alphanumeric and dashes only
SID="cc-$(echo "$USER_EMAIL" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')"
BASE="https://management.azure.com/subscriptions/${SUB_ID}/resourceGroups/${RG}/providers/Microsoft.ApiManagement/service/${APIM}"
API_VERSION="2024-05-01"

az rest --method put \
  --url "${BASE}/subscriptions/${SID}?api-version=${API_VERSION}" \
  --body "{\"properties\":{\"displayName\":\"${USER_EMAIL}\",\"scope\":\"/products/claude-code\",\"state\":\"active\"}}" \
  --output none

KEY="$(az rest --method post \
  --url "${BASE}/subscriptions/${SID}/listSecrets?api-version=${API_VERSION}" \
  --query primaryKey -o tsv)"

GATEWAY="$(az apim show -g "$RG" -n "$APIM" --query gatewayUrl -o tsv)"

cat <<EOF

Subscription '${SID}' ready for ${USER_EMAIL}.
Send the user this ~/.claude/settings.json "env" block (deliver the key over a secure channel):

{
  "env": {
    "ANTHROPIC_BASE_URL": "${GATEWAY}/claude",
    "ANTHROPIC_CUSTOM_HEADERS": "Ocp-Apim-Subscription-Key: ${KEY}"
  }
}

Then: run 'claude', then '/login' with the user's Claude Team account.
EOF
