using 'main.bicep'

param apimName = 'apim-claude-gw-CHANGEME'
param publisherEmail = 'platform@example.com'
param publisherName = 'Platform Team'

param location = 'swedencentral'

// ---- Existing Microsoft Foundry account (must already have Claude deployments) ----
param foundryAccountName = 'CHANGEME-foundry-account'
param foundryResourceGroup = 'CHANGEME-foundry-rg'

// Anthropic model-ID prefix -> Foundry deployment name; "*" = default. First match wins.
// Generate from your account: ./scripts/list-foundry-deployments.sh <rg> <account>
param foundryModelMap = 'claude-opus=CHANGEME-opus-deployment;claude-sonnet=CHANGEME-sonnet-deployment;claude-haiku=CHANGEME-haiku-deployment;*=CHANGEME-sonnet-deployment'

// ---- Gateway behaviour ----------------------------------------------------------
param fallbackDefaultTtlSeconds = 900
param foundryTpmPerUser = 200000
param foundryMonthlyTokenQuotaPerUser = 50000000
