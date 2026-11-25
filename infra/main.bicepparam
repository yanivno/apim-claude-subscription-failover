using 'main.bicep'

param apimName = 'apim-claude-gw-CHANGEME'
param publisherEmail = 'platform@example.com'
param publisherName = 'Platform Team'

param location = 'swedencentral'

// ---- Microsoft Foundry -------------------------------------------------------
// true  = create the Foundry account + Claude deployments in this resource group
// false = use an existing account: set foundryAccountName, foundryResourceGroup, foundryModelMap
param deployFoundry = true
param foundryLocation = 'swedencentral'

// Legal entity sent to Anthropic in modelProviderData. Deploying accepts the
// Anthropic Marketplace terms for this organization.
param claudeOrganizationName = 'CHANGEME Ltd'
param claudeCountryCode = 'IL'
param claudeIndustry = 'technology'

// Check model IDs/versions available in your region: ./scripts/list-claude-models.sh swedencentral
// routePrefix = the Anthropic model-ID prefix Claude Code sends. First entry = default.
param claudeDeployments = [
  { name: 'claude-sonnet', model: 'claude-sonnet-4-6', version: '1', capacity: 25, routePrefix: 'claude-sonnet' }
  { name: 'claude-haiku', model: 'claude-haiku-4-5', version: '1', capacity: 25, routePrefix: 'claude-haiku' }
  // { name: 'claude-opus', model: '<opus-model-id-from-catalog>', version: '1', capacity: 25, routePrefix: 'claude-opus' }
]

// ---- Gateway behaviour ---------------------------------------------------------
param fallbackDefaultTtlSeconds = 900
param foundryTpmPerUser = 200000
param foundryMonthlyTokenQuotaPerUser = 50000000
