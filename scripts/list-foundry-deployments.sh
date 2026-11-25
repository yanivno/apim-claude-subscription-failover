#!/usr/bin/env bash
# List the Claude deployments on an existing Foundry account and print a suggested
# foundryModelMap for infra/main.bicepparam.
#
# Usage: ./scripts/list-foundry-deployments.sh <foundry-resource-group> <foundry-account-name>
set -euo pipefail

RG="${1:?foundry resource group}"
ACCOUNT="${2:?foundry account name}"

echo "Claude deployments on ${ACCOUNT}:"
az cognitiveservices account deployment list -g "$RG" -n "$ACCOUNT" \
  --query "[?properties.model.format=='Anthropic'].{deployment:name, model:properties.model.name, version:properties.model.version, sku:sku.name, capacity:sku.capacity}" \
  -o table

# Suggested map: one entry per family (opus / sonnet / haiku / ...), first Sonnet (or first deployment) as default.
MAP="$(az cognitiveservices account deployment list -g "$RG" -n "$ACCOUNT" \
  --query "[?properties.model.format=='Anthropic'].[name, properties.model.name]" -o tsv |
  awk -F'\t' '
    {
      family = $2; sub(/^claude-/, "", family); sub(/-.*/, "", family)
      if (!(family in seen)) { seen[family] = 1; entries = entries (entries ? ";" : "") "claude-" family "=" $1 }
      if (first == "") first = $1
      if (family == "sonnet" && def == "") def = $1
    }
    END { if (def == "") def = first; if (first != "") print entries ";*=" def }')"

if [[ -z "$MAP" ]]; then
  echo "No Anthropic (Claude) deployments found on ${ACCOUNT}." >&2
  exit 1
fi

echo
echo "Suggested line for infra/main.bicepparam (review before use):"
echo "param foundryModelMap = '${MAP}'"
