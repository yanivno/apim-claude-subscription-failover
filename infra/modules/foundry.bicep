// Microsoft Foundry account + project + Claude model deployments.
// Based on the Azure-Samples/claude starter kit (infra-bicep/infra/foundry.bicep).
//
// IMPORTANT: Deploying a Claude model accepts the Anthropic Marketplace offer
// terms on behalf of the organization in modelProviderData.
// Review https://www.anthropic.com/legal/commercial-terms before deploying.

param location string
param accountName string
param projectName string

@description('Claude deployments: [{ name, model, version, capacity, routePrefix }]. capacity = thousands of TPM.')
param claudeDeployments array

param claudeOrganizationName string
param claudeCountryCode string
param claudeIndustry string

resource account 'Microsoft.CognitiveServices/accounts@2025-10-01-preview' = {
  name: accountName
  location: location
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: accountName
    allowProjectManagement: true
    publicNetworkAccess: 'Enabled'
    // APIM calls Foundry with its managed identity only; no API keys needed.
    disableLocalAuth: true
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-10-01-preview' = {
  parent: account
  name: projectName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {}
}

// Foundry serializes deployment operations on one account: create them one at a time.
@batchSize(1)
resource deployments 'Microsoft.CognitiveServices/accounts/deployments@2025-10-01-preview' = [for d in claudeDeployments: {
  parent: account
  name: d.name
  sku: {
    name: 'GlobalStandard'
    capacity: d.capacity
  }
  properties: {
    model: {
      format: 'Anthropic'
      name: d.model
      version: d.version
    }
    // Required by the RP for Anthropic deployments but missing from the published Bicep types.
    #disable-next-line BCP037
    modelProviderData: {
      organizationName: claudeOrganizationName
      countryCode: claudeCountryCode
      industry: claudeIndustry
    }
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
    raiPolicyName: 'Microsoft.DefaultV2'
  }
  dependsOn: [
    project
  ]
}]

output accountName string = account.name
output claudeBaseUrl string = 'https://${account.name}.services.ai.azure.com/anthropic'
output deploymentNames array = [for (d, i) in claudeDeployments: deployments[i].name]
