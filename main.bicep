// Main infrastructure file for AKS environment with 6 applications
// This sets up: AKS, ACR, Application Insights, Log Analytics

targetScope = 'resourceGroup'

@description('The location for all resources')
param location string = resourceGroup().location

@description('The name prefix for all resources')
param projectName string = 'enrollment'

@description('AKS cluster node count')
@minValue(1)
@maxValue(10)
param nodeCount int = 3

@description('AKS cluster node VM size')
param nodeVmSize string = 'standard_d2ads_v7'

@description('User pool node VM size')
param userVmSize string = 'standard_d2ads_v7'

@description('Admin username for AKS nodes')
param adminUsername string = 'azureuser'

@description('Enable Azure Policy for AKS')
param enableAzurePolicy bool = true

@description('Enable monitoring and diagnostics')
param enableMonitoring bool = true

@description('Kubernetes version')
param kubernetesVersion string = '1.36.0'

@description('Managed Identity for enrollment-api')
param enrollmentApiManagedIdentityName string = 'uai-${projectName}-api'

@description('Managed Identity for enrollment-bsl')
param enrollmentBslManagedIdentityName string = 'uai-${projectName}-bsl'

@description('Managed Identity for enrollment-kendo-grid-api')
param enrollmentKendoGridApiManagedIdentityName string = 'uai-${projectName}-kendo-grid-api'

@description('Managed Identity for enrollment-kendo-grid-bsl')
param enrollmentKendoGridBslManagedIdentityName string = 'uai-${projectName}-kendo-grid-bsl'

@description('Managed Identity for enrollment-chat-hub')
param enrollmentChatHubManagedIdentityName string = 'uai-${projectName}-chat-hub'

@description('Managed Identity for enrollment-spa-api')
param enrollmentSpaApiManagedIdentityName string = 'uai-${projectName}-spa-api'

@description('Managed Identity for enrollment-api and enrollment-kendo-grid-api')
param enrollmentAngularManagedIdentityName string = 'uai-${projectName}-angular'

@description('Namespace for all Enrollment services in the cluster')
param k8sNamespace string = '${projectName}-apps'

@description('When the service account is assigned to sa-enrollment-api, they will receive the permissions assigned to the managed identity.')
param k8sEnrollmentApiServiceAccountName string = 'sa-${projectName}-api'

@description('When the service account is assigned to sa-enrollment-bsl, they will receive the permissions assigned to the managed identity.')
param k8sEnrollmentBslServiceAccountName string = 'sa-${projectName}-bsl'

@description('When the service account is assigned to sa-enrollment-kendo-grid-api, they will receive the permissions assigned to the managed identity.')
param k8sEnrollmentKendoGridApiServiceAccountName string = 'sa-${projectName}-kendo-grid-api'

@description('When the service account is assigned to sa-enrollment-kendo-grid-bsl, they will receive the permissions assigned to the managed identity.')
param k8sEnrollmentKendoGridBslServiceAccountName string = 'sa-${projectName}-kendo-grid-bsl'

@description('When the service account is assigned to sa-enrollment-chat-hub, they will receive the permissions assigned to the managed identity.')
param k8sEnrollmentChatHubServiceAccountName string = 'sa-${projectName}-chat-hub'

@description('When the service account is assigned to sa-enrollment-spa-api, they will receive the permissions assigned to the managed identity.')
param k8sEnrollmentSpaApiServiceAccountName string = 'sa-${projectName}-spa-api'

@description('When the service account is assigned to sa-enrollment-angular, they will receive the permissions assigned to the managed identity.')
param k8sEnrollmentAngularServiceAccountName string = 'sa-${projectName}-angular'

// Variables
var uniqueSuffix = uniqueString(resourceGroup().id)

var aksClusterName = '${projectName}-aks-${uniqueSuffix}'
var acrName = replace('${projectName}acr${uniqueSuffix}', '-', '')
var logAnalyticsName = '${projectName}-logs-${uniqueSuffix}'
var appInsightsName = '${projectName}-insights-${uniqueSuffix}'
var appConfigurationName = '${projectName}-config-${uniqueSuffix}'
var federatedCredentialAudience = 'api://AzureADTokenExchange'

var foundryResourceGroupName = 'rg-foundry-iq'
var foundrySuffix = uniqueString(subscription().subscriptionId, foundryResourceGroup.id)
var foundryAccountResourceName = 'bps-foundry-iq-${foundrySuffix}'
var foundryUserRoleDefinitionID string = '53ca6127-db72-4b80-b1b0-d745d6d5456d'

resource foundryAccountResource 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: foundryAccountResourceName
  scope: resourceGroup(foundryResourceGroupName)
}

resource foundryResourceGroup 'Microsoft.Resources/resourceGroups@2025-04-01' existing = {
  name: foundryResourceGroupName
  scope: subscription()
}

resource keyVault 'Microsoft.KeyVault/vaults@2026-02-01' existing = {
  name: 'enroll-kv-${uniqueString(resourceGroup().id)}' //enrollment-kv-<13 chars> exceeds 24 characters
  dependsOn: [createKeyVaultAndCertificate]
}

resource enrollmentAksSSHKey 'Microsoft.Compute/sshPublicKeys@2023-09-01' existing = {
  name: 'enrollmentAksSSHKey'
}

// Log Analytics Workspace
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

// Application Insights
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource appConfiguration 'Microsoft.AppConfiguration/configurationStores@2024-05-01' = {
  name: appConfigurationName
  location: location
  sku: {
    name: 'standard'
  }
  identity: {
    type: 'SystemAssigned'
  }
}

// Azure Container Registry
resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: acrName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    adminUserEnabled: false
    networkRuleBypassOptions: 'AzureServices'
    policies: {
      quarantinePolicy: {
        status: 'disabled'
      }
      trustPolicy: {
        type: 'Notary'
        status: 'disabled'
      }
      retentionPolicy: {
        days: 7
        status: 'disabled'
      }
    }
  }
}

// AKS Cluster
resource aksCluster 'Microsoft.ContainerService/managedClusters@2024-02-01' = {
  name: aksClusterName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    kubernetesVersion: kubernetesVersion
    dnsPrefix: '${aksClusterName}-dns'
    enableRBAC: true
    
    agentPoolProfiles: [
      {
        name: 'systempool'
        count: nodeCount
        vmSize: nodeVmSize
        osType: 'Linux'
        mode: 'System'
        type: 'VirtualMachineScaleSets'
        enableAutoScaling: true
        minCount: 1
        maxCount: 5
        maxPods: 110
      }
    ]
    
    linuxProfile: {
      adminUsername: adminUsername
      ssh: {
        publicKeys: [
          {
            keyData: enrollmentAksSSHKey.properties.publicKey
          }
        ]
      }
    }
    
    networkProfile: {
      networkPlugin: 'azure'
      networkPolicy: 'azure'
      serviceCidr: '10.2.0.0/16'
      dnsServiceIP: '10.2.0.10'
      loadBalancerSku: 'standard'
    }
    
    addonProfiles: {
      omsagent: {
        enabled: enableMonitoring
        config: {
          logAnalyticsWorkspaceResourceID: logAnalytics.id
        }
      }
      azurepolicy: {
        enabled: enableAzurePolicy
      }
      ingressApplicationGateway: {
        enabled: false
      }
    }
    
    autoUpgradeProfile: {
      upgradeChannel: 'patch'
    }
    
    oidcIssuerProfile: {
      enabled: true
    }
    
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }
  }
}

resource userNodePool 'Microsoft.ContainerService/managedClusters/agentPools@2024-02-01' = {
  parent: aksCluster
  name: 'userpool'
  properties: {
    count: 2
    vmSize: userVmSize
    osType: 'Linux'
    mode: 'User'
    type: 'VirtualMachineScaleSets'
    enableAutoScaling: true
    minCount: 1
    maxCount: 5
    nodeLabels: {
      workload: 'apps'
    }
  }
}

// Role assignment: AKS to pull images from ACR
resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: acr
  name: guid(resourceGroup().id, aksCluster.id, acr.id, 'AcrPull')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d') // AcrPull role
    principalId: aksCluster.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
  }
}

resource enrollmentApiManagedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: enrollmentApiManagedIdentityName
  location: location
}

resource enrollmentBslManagedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: enrollmentBslManagedIdentityName
  location: location
}

resource enrollmentKendoGridApiManagedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: enrollmentKendoGridApiManagedIdentityName
  location: location
}

resource enrollmentKendoGridBslManagedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: enrollmentKendoGridBslManagedIdentityName
  location: location
}

resource enrollmentChatHubManagedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: enrollmentChatHubManagedIdentityName
  location: location
}

resource enrollmentSpaApiManagedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: enrollmentSpaApiManagedIdentityName
  location: location
}

resource enrollmentAngularManagedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: enrollmentAngularManagedIdentityName
  location: location
}

resource enrollmentApiFederatedCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: enrollmentApiManagedIdentity
  name: 'fed-${enrollmentApiManagedIdentityName}'
  properties: {
    audiences: [
      federatedCredentialAudience
    ]
    issuer: aksCluster.properties.oidcIssuerProfile.issuerURL
    subject: 'system:serviceaccount:${k8sNamespace}:${k8sEnrollmentApiServiceAccountName}'
  }
}

resource enrollmentBslFederatedCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: enrollmentBslManagedIdentity
  name: 'fed-${enrollmentBslManagedIdentityName}'
  properties: {
    audiences: [
      federatedCredentialAudience
    ]
    issuer: aksCluster.properties.oidcIssuerProfile.issuerURL
    subject: 'system:serviceaccount:${k8sNamespace}:${k8sEnrollmentBslServiceAccountName}'
  }
}

resource enrollmentKendoGridApiFederatedCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: enrollmentKendoGridApiManagedIdentity
  name: 'fed-${enrollmentKendoGridApiManagedIdentityName}'
  properties: {
    audiences: [
      federatedCredentialAudience
    ]
    issuer: aksCluster.properties.oidcIssuerProfile.issuerURL
    subject: 'system:serviceaccount:${k8sNamespace}:${k8sEnrollmentKendoGridApiServiceAccountName}'
  }
}

resource enrollmentKendoGridBslFederatedCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: enrollmentKendoGridBslManagedIdentity
  name: 'fed-${enrollmentKendoGridBslManagedIdentityName}'
  properties: {
    audiences: [
      federatedCredentialAudience
    ]
    issuer: aksCluster.properties.oidcIssuerProfile.issuerURL
    subject: 'system:serviceaccount:${k8sNamespace}:${k8sEnrollmentKendoGridBslServiceAccountName}'
  }
}

resource enrollmentChatHubFederatedCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: enrollmentChatHubManagedIdentity
  name: 'fed-${enrollmentChatHubManagedIdentityName}'
  properties: {
    audiences: [
      federatedCredentialAudience
    ]
    issuer: aksCluster.properties.oidcIssuerProfile.issuerURL
    subject: 'system:serviceaccount:${k8sNamespace}:${k8sEnrollmentChatHubServiceAccountName}'
  }
}

resource enrollmentSpaApiFederatedCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: enrollmentSpaApiManagedIdentity
  name: 'fed-${enrollmentSpaApiManagedIdentityName}'
  properties: {
    audiences: [
      federatedCredentialAudience
    ]
    issuer: aksCluster.properties.oidcIssuerProfile.issuerURL
    subject: 'system:serviceaccount:${k8sNamespace}:${k8sEnrollmentSpaApiServiceAccountName}'
  }
}

resource enrollmentAngularFederatedCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: enrollmentAngularManagedIdentity
  name: 'fed-${enrollmentAngularManagedIdentityName}'
  properties: {
    audiences: [
      federatedCredentialAudience
    ]
    issuer: aksCluster.properties.oidcIssuerProfile.issuerURL
    subject: 'system:serviceaccount:${k8sNamespace}:${k8sEnrollmentAngularServiceAccountName}'
  }
}

// Diagnostic settings for AKS
resource aksDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (enableMonitoring) {
  scope: aksCluster
  name: '${aksClusterName}-diagnostics'
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        category: 'kube-apiserver'
        enabled: true
      }
      {
        category: 'kube-controller-manager'
        enabled: true
      }
      {
        category: 'kube-scheduler'
        enabled: true
      }
      {
        category: 'kube-audit'
        enabled: true
      }
      {
        category: 'cluster-autoscaler'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

module  createKeyVaultAndCertificate './create-key-vault-and-cert.bicep' = {
  name: 'createKeyVaultAndCertificate'
}

module apiManagedIdentityToKeyVaultCertificateUserRoleAssignment './assign-key-vault-certificate-user-role-to-managed-identity.bicep' = {
  name: 'apiManagedIdentityToKeyVaultRoleAssignment'
  params: {
    managedIdentityName: enrollmentApiManagedIdentity.name
    keyVaultName: keyVault.name
  }
  dependsOn: [createKeyVaultAndCertificate]
}

module kendoGridApiManagedIdentityToKeyVaultCertificateUserRoleAssignment './assign-key-vault-certificate-user-role-to-managed-identity.bicep' = {
  name: 'kendoGridApiManagedIdentityToKeyVaultRoleAssignment'
  params: {
    managedIdentityName: enrollmentKendoGridApiManagedIdentity.name
    keyVaultName: keyVault.name
  }
  dependsOn: [createKeyVaultAndCertificate]
}

module apiManagedIdentityToAppConfigDataReaderRoleAssignment './assign-app-config-data-reader-role-to-managed-identity.bicep' = {
  name: 'apiManagedIdentityToAppConfigRoleAssignment'
  params: {
    managedIdentityName: enrollmentApiManagedIdentity.name
    appConfigName: appConfiguration.name
  }
}

module kendoGridApiManagedIdentityToAppConfigDataReaderRoleAssignment './assign-app-config-data-reader-role-to-managed-identity.bicep' = {
  name: 'kendoGridApiManagedIdentityToAppConfigRoleAssignment'
  params: {
    managedIdentityName: enrollmentKendoGridApiManagedIdentity.name
    appConfigName: appConfiguration.name
  }
}

module bslManagedIdentityToAppConfigDataReaderRoleAssignment './assign-app-config-data-reader-role-to-managed-identity.bicep' = {
  name: 'bslManagedIdentityToAppConfigRoleAssignment'
  params: {
    managedIdentityName: enrollmentBslManagedIdentity.name
    appConfigName: appConfiguration.name
  }
}

module kendoGridBslManagedIdentityToAppConfigDataReaderRoleAssignment './assign-app-config-data-reader-role-to-managed-identity.bicep' = {
  name: 'kendoGridBslManagedIdentityToAppConfigRoleAssignment'
  params: {
    managedIdentityName: enrollmentKendoGridBslManagedIdentity.name
    appConfigName: appConfiguration.name
  }
}

module chatHubManagedIdentityToAppConfigDataReaderRoleAssignment './assign-app-config-data-reader-role-to-managed-identity.bicep' = {
  name: 'chatHubManagedIdentityToAppConfigRoleAssignment'
  params: {
    managedIdentityName: enrollmentChatHubManagedIdentity.name
    appConfigName: appConfiguration.name
  }
}

module spaApiManagedIdentityToAppConfigDataReaderRoleAssignment './assign-app-config-data-reader-role-to-managed-identity.bicep' = {
  name: 'spaApiManagedIdentityToAppConfigRoleAssignment'
  params: {
    managedIdentityName: enrollmentSpaApiManagedIdentity.name
    appConfigName: appConfiguration.name
  }
}

module angularManagedIdentityToAppConfigDataReaderRoleAssignment './assign-app-config-data-reader-role-to-managed-identity.bicep' = {
  name: 'angularManagedIdentityToAppConfigRoleAssignment'
  params: {
    managedIdentityName: enrollmentAngularManagedIdentity.name
    appConfigName: appConfiguration.name
  }
}

module chatHubManagedIdentityToFoundryRoleAssignment './assign-foundry-user-access-to-managed-identity.bicep' = {
  name: 'chatHubServiceToFoundryRoleAssignment'
  scope: resourceGroup(foundryResourceGroupName)
  params: {
    foundryAccountResourceName: foundryAccountResource.name
    managedIdentityPrincipalId: enrollmentChatHubManagedIdentity.properties.principalId
    managedIdentityToFoundryRoleAssignmentName: guid(enrollmentChatHubManagedIdentity.id, foundryUserRoleDefinitionID, foundryAccountResource.id)
  }
}

// Outputs
output aksClusterName string = aksCluster.name
output aksClusterId string = aksCluster.id
output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output keyVaultName string = keyVault.name
output appInsightsInstrumentationKey string = appInsights.properties.InstrumentationKey
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output appConfigurationEndPoint string = appConfiguration.properties.endpoint
output logAnalyticsWorkspaceId string = logAnalytics.id
output logAnalyticsWorkspaceName string = logAnalytics.name
output aksNodeResourceGroup string = aksCluster.properties.nodeResourceGroup
output aksApiServerAddress string = aksCluster.properties.fqdn
output enrollmentApiManagedIdentityClientId string = enrollmentApiManagedIdentity.properties.clientId
output enrollmentBslManagedIdentityClientId string = enrollmentBslManagedIdentity.properties.clientId
output enrollmentKendoGridApiManagedIdentityClientId string = enrollmentKendoGridApiManagedIdentity.properties.clientId
output enrollmentKendoGridBslManagedIdentityClientId string = enrollmentKendoGridBslManagedIdentity.properties.clientId
output enrollmentChatHubManagedIdentityClientId string = enrollmentChatHubManagedIdentity.properties.clientId
output enrollmentSpaApiManagedIdentityClientId string = enrollmentSpaApiManagedIdentity.properties.clientId
output enrollmentAngularManagedIdentityClientId string = enrollmentAngularManagedIdentity.properties.clientId
output enrollmentApiServiceAccountName string = k8sEnrollmentApiServiceAccountName
output enrollmentBslServiceAccountName string = k8sEnrollmentBslServiceAccountName
output enrollmentKendoGridApiServiceAccountName string = k8sEnrollmentKendoGridApiServiceAccountName
output enrollmentKendoGridBslServiceAccountName string = k8sEnrollmentKendoGridBslServiceAccountName
output enrollmentChatHubServiceAccountName string = k8sEnrollmentChatHubServiceAccountName
output enrollmentSpaApiServiceAccountName string = k8sEnrollmentSpaApiServiceAccountName
output enrollmentAngularServiceAccountName string = k8sEnrollmentAngularServiceAccountName
output kubernetesNamespace string = k8sNamespace
output enrollmentBslCertificateThumbprint string = createKeyVaultAndCertificate.outputs.certificateThumbprint
