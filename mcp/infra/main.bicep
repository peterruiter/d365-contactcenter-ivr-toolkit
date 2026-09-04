// Container App hosting the toolkit MCP server.
//
// Only needed if you are using the MCP route. The Dataverse connector path needs no
// Azure at all, so check docs/12-mcp-server.md before deploying this.
//
// Deliberately small. This is a stateless proxy in front of Dataverse, not a workload.

@description('Base name for every resource. Keep it short, resource names are derived from it.')
param name string = 'pwrp-ivr-mcp'

@description('Region. Put it in the same region as the Dataverse environment to save a hop.')
param location string = resourceGroup().location

@description('Dataverse environment url, for example https://contoso.crm4.dynamics.com')
param dataverseEnvironmentUrl string

@description('Shared secret Copilot Studio sends in the x-pwrp-key header.')
@secure()
param mcpApiKey string

@description('Container image, for example myregistry.azurecr.io/pwrp-ivr-mcp:1.0.0')
param containerImage string

@description('Comma separated tool names to expose. Empty uses the default nine.')
param exposedTools string = ''

resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${name}-logs'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource insights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${name}-ai'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logs.id
  }
}

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: '${name}-env'
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
  }
}

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: name
  location: location
  identity: {
    // Managed identity, so no Dataverse secret exists to leak.
    // Create the application user in Dataverse for this identity and give it
    // the Power Pete IVR Reader role. Nothing more.
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: environment.id
    configuration: {
      ingress: {
        external: true
        targetPort: 8080
        transport: 'http'
        allowInsecure: false
      }
      secrets: [
        { name: 'mcp-api-key', value: mcpApiKey }
      ]
    }
    template: {
      containers: [
        {
          name: 'mcp'
          image: containerImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            { name: 'Dataverse__EnvironmentUrl', value: dataverseEnvironmentUrl }
            { name: 'Mcp__ApiKey', secretRef: 'mcp-api-key' }
            { name: 'Mcp__ExposedTools', value: exposedTools }
            { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: insights.properties.ConnectionString }
          ]
          probes: [
            {
              type: 'Liveness'
              httpGet: { path: '/health', port: 8080 }
              periodSeconds: 30
            }
          ]
        }
      ]
      scale: {
        // One replica always warm. A cold start on a live call is unacceptable,
        // and this is cheap enough that scale to zero is a false economy.
        minReplicas: 1
        maxReplicas: 5
        rules: [
          {
            name: 'http'
            http: { metadata: { concurrentRequests: '40' } }
          }
        ]
      }
    }
  }
}

output mcpEndpoint string = 'https://${app.properties.configuration.ingress.fqdn}/mcp'
output principalId string = app.identity.principalId
