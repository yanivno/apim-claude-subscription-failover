// Claude Code gateway: Team-subscription passthrough with 429 failover to Claude on Microsoft Foundry.
// Azure API Management Standard v2.

targetScope = 'resourceGroup'

@description('API Management instance name (globally unique).')
param apimName string

@description('Azure region for APIM and monitoring resources.')
param location string = 'swedencentral'

@description('Publisher email shown in APIM.')
param publisherEmail string

@description('Publisher name shown in APIM.')
param publisherName string

// ---------------------------------------------------------------------------
// Foundry: deploy a new account + Claude deployments (default), or use an existing one
// ---------------------------------------------------------------------------
@description('true = create the Foundry account, project and Claude deployments in this resource group. false = use an existing account (foundryAccountName / foundryResourceGroup / foundryModelMap).')
param deployFoundry bool = true

@description('Region for the Foundry account. Claude (Global Standard) is offered in eastus2, swedencentral and westus2; check the live catalog for your models.')
param foundryLocation string = 'swedencentral'

@description('Foundry account name (globally unique; also the custom subdomain). For deployFoundry=false, the existing account name.')
param foundryAccountName string = 'claude-gw-foundry-${uniqueString(resourceGroup().id)}'

@description('Existing account only: resource group of the Foundry account.')
param foundryResourceGroup string = resourceGroup().name

@description('''Claude deployments to create (deployFoundry=true).
- name: deployment name (stable, version-independent; what the gateway sends as "model")
- model: Foundry catalog model ID (list with scripts/list-claude-models.sh)
- version: catalog version ("1" = hosted on Anthropic infrastructure, "2" = hosted on Azure where offered)
- capacity: thousands of tokens per minute
- routePrefix: Anthropic model-ID prefix Claude Code sends that should land on this deployment
The first entry is also the default for unmatched model IDs.''')
param claudeDeployments array = [
  { name: 'claude-sonnet', model: 'claude-sonnet-4-6', version: '1', capacity: 25, routePrefix: 'claude-sonnet' }
  { name: 'claude-haiku', model: 'claude-haiku-4-5', version: '1', capacity: 25, routePrefix: 'claude-haiku' }
]

@description('Legal entity name sent to Anthropic in modelProviderData (required when deployFoundry=true).')
param claudeOrganizationName string = ''

@description('Two-letter ISO country code of the organization.')
@minLength(2)
@maxLength(2)
param claudeCountryCode string = 'IL'

@description('Organization industry (lowercase).')
@allowed([ 'technology', 'finance', 'healthcare', 'education', 'retail', 'manufacturing', 'government', 'media', 'other' ])
param claudeIndustry string = 'technology'

@description('Existing account only: Anthropic model ID prefix -> Foundry deployment name. Format "prefix=deployment;...;*=default". Ignored when deployFoundry=true (built from claudeDeployments).')
param foundryModelMap string = 'claude-sonnet=claude-sonnet;claude-haiku=claude-haiku;*=claude-sonnet'

@description('Entra audience for Foundry Claude inference tokens.')
param foundryTokenAudience string = 'https://ai.azure.com'

@description('How long a user stays on Foundry after an Anthropic 429 when Anthropic sends no reset/retry-after header (seconds, 60-18000).')
@minValue(60)
@maxValue(18000)
param fallbackDefaultTtlSeconds int = 900

@description('Per-user tokens per minute while on the Foundry route.')
param foundryTpmPerUser int = 200000

@description('Per-user monthly token quota on the Foundry route.')
param foundryMonthlyTokenQuotaPerUser int = 50000000

@description('APIM capacity units.')
param apimCapacity int = 1

// ---------------------------------------------------------------------------
// Monitoring (required for llm-emit-token-metric / emit-metric)
// ---------------------------------------------------------------------------
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${apimName}-law'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${apimName}-ai'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

// ---------------------------------------------------------------------------
// API Management
// ---------------------------------------------------------------------------
resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: apimName
  location: location
  sku: {
    name: 'StandardV2'
    capacity: apimCapacity
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
  }
}

resource aiLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: apim
  name: 'appinsights'
  properties: {
    loggerType: 'applicationInsights'
    resourceId: appInsights.id
    credentials: {
      instrumentationKey: appInsights.properties.InstrumentationKey
    }
  }
}

// ---------------------------------------------------------------------------
// Microsoft Foundry (optional)
// ---------------------------------------------------------------------------
module foundry 'modules/foundry.bicep' = if (deployFoundry) {
  name: 'foundry-${uniqueString(resourceGroup().id)}'
  params: {
    location: foundryLocation
    accountName: foundryAccountName
    projectName: 'claude-gateway'
    claudeDeployments: claudeDeployments
    claudeOrganizationName: claudeOrganizationName
    claudeCountryCode: claudeCountryCode
    claudeIndustry: claudeIndustry
  }
}

var effectiveFoundryRg = deployFoundry ? resourceGroup().name : foundryResourceGroup

// prefix=deployment for each Claude deployment, first deployment as the default
var generatedModelMap = '${join(map(claudeDeployments, d => '${d.routePrefix}=${d.name}'), ';')};*=${claudeDeployments[0].name}'
var effectiveModelMap = deployFoundry ? generatedModelMap : foundryModelMap

// Named values referenced by the policies
var namedValues = {
  'claude-foundry-model-map': effectiveModelMap
  'foundry-token-audience': foundryTokenAudience
  'claude-fallback-default-ttl-seconds': string(fallbackDefaultTtlSeconds)
  'foundry-tpm-per-user': string(foundryTpmPerUser)
  'foundry-monthly-token-quota-per-user': string(foundryMonthlyTokenQuotaPerUser)
}

resource nv 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = [for item in items(namedValues): {
  parent: apim
  name: item.key
  properties: {
    displayName: item.key
    value: item.value
    secret: false
  }
}]

// Backends
resource anthropicBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'anthropic-direct'
  properties: {
    title: 'Anthropic API (Team subscription passthrough)'
    url: 'https://api.anthropic.com'
    protocol: 'http'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
}

resource foundryBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'foundry-claude'
  properties: {
    title: 'Claude on Microsoft Foundry (fallback)'
    url: 'https://${foundryAccountName}.services.ai.azure.com/anthropic'
    protocol: 'http'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
}

// API
resource claudeApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'claude'
  properties: {
    displayName: 'Claude (Anthropic Messages)'
    path: 'claude'
    protocols: [ 'https' ]
    serviceUrl: 'https://api.anthropic.com'
    subscriptionRequired: true
    subscriptionKeyParameterNames: {
      header: 'Ocp-Apim-Subscription-Key'
      query: 'subscription-key'
    }
    type: 'http'
  }
}

var operations = [
  { name: 'messages', method: 'POST', url: '/v1/messages', display: 'Create message' }
  { name: 'count-tokens', method: 'POST', url: '/v1/messages/count_tokens', display: 'Count tokens' }
  { name: 'passthrough-get', method: 'GET', url: '/*', display: 'Passthrough GET' }
  { name: 'passthrough-post', method: 'POST', url: '/*', display: 'Passthrough POST' }
]

resource ops 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = [for op in operations: {
  parent: claudeApi
  name: op.name
  properties: {
    displayName: op.display
    method: op.method
    urlTemplate: op.url
  }
}]

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: claudeApi
  name: 'policy'
  properties: {
    format: 'xml'
    value: loadTextContent('../policies/api-policy.xml')
  }
  dependsOn: [ nv, anthropicBackend, foundryBackend ]
}

resource messagesOp 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' existing = {
  parent: claudeApi
  name: 'messages'
}

resource messagesPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: messagesOp
  name: 'policy'
  properties: {
    format: 'xml'
    value: loadTextContent('../policies/messages-operation-policy.xml')
  }
  dependsOn: [ ops, nv, anthropicBackend, foundryBackend ]
}

// Metrics only, no bodies: keeps SSE streaming intact and prompts out of logs.
resource apiDiagnostics 'Microsoft.ApiManagement/service/apis/diagnostics@2024-05-01' = {
  parent: claudeApi
  name: 'applicationinsights'
  properties: {
    loggerId: aiLogger.id
    alwaysLog: 'allErrors'
    metrics: true
    verbosity: 'information'
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    frontend: {
      request: { body: { bytes: 0 } }
      response: { body: { bytes: 0 } }
    }
    backend: {
      request: { body: { bytes: 0 } }
      response: { body: { bytes: 0 } }
    }
  }
}

// Product: one subscription per user
resource product 'Microsoft.ApiManagement/service/products@2024-05-01' = {
  parent: apim
  name: 'claude-code'
  properties: {
    displayName: 'Claude Code'
    description: 'Claude Code via Team subscription with Foundry overflow. One subscription per user.'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
  }
}

resource productApi 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = {
  parent: product
  name: claudeApi.name
}

// Foundry access for the APIM managed identity
module foundryRole 'modules/foundry-role.bicep' = {
  name: 'foundry-role-${apimName}'
  scope: resourceGroup(effectiveFoundryRg)
  params: {
    // Referencing the module output makes the role assignment wait for the new account.
    foundryAccountName: deployFoundry ? foundry!.outputs.accountName : foundryAccountName
    principalId: apim.identity.principalId
  }
}

output gatewayUrl string = '${apim.properties.gatewayUrl}/claude'
output apimPrincipalId string = apim.identity.principalId
output foundryAccount string = foundryAccountName
output foundryModelMap string = effectiveModelMap
