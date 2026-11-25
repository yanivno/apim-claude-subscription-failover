#!/usr/bin/env bash
# List Claude models (and versions / SKUs) offered to your subscription in a region.
# Usage: ./scripts/list-claude-models.sh [region]   (default: swedencentral)
set -euo pipefail
REGION="${1:-swedencentral}"
az cognitiveservices model list -l "$REGION" \
  --query "[?model.format=='Anthropic'].{model:model.name, version:model.version, skus:join(',', model.skus[].name)}" \
  -o table
