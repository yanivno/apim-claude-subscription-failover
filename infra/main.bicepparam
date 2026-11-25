using 'main.bicep'

param apimName = 'apim-claude-gw-CHANGEME'
param publisherEmail = 'platform@example.com'
param publisherName = 'Platform Team'

param location = 'swedencentral'

param foundryAccountName = 'my-foundry-account'
param foundryResourceGroup = 'rg-foundry'

// Prefix -> Foundry deployment name. Match these to your actual deployment names.
param foundryModelMap = 'claude-opus=claude-opus-5-5;claude-sonnet=claude-sonnet-5-5;claude-haiku=claude-haiku-5-5;*=claude-sonnet-5-5'

param fallbackDefaultTtlSeconds = 900
param foundryTpmPerUser = 200000
param foundryMonthlyTokenQuotaPerUser = 50000000
