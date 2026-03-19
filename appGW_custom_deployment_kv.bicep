// ------------------------------------------------------------------------------
// Application Gateway deployment Bicep module (Key Vault variant)
// This module deploys an Application Gateway (WAF v2) with the following features:
// - Subnet creation (or update) with NSG inside an existing VNet (cross-resource-group)
// - Public IP for frontend access
// - Azure Key Vault with certificate imported via deployment script (proper KV certificate)
// - User-Assigned Managed Identity with Key Vault access for the App Gateway
// - Deployment script to import PFX as a KV certificate (no explicit storage account)
// - Certificate expiry notification via Event Grid + email action group
// - HTTPS listeners with SNI for mail and autodiscover FQDNs (cert retrieved from Key Vault)
// - Backend pool with Exchange server IPs
// - Health probe for the EWS endpoint
// - WAF configuration in Detection mode with exclusions for EWS and Autodiscover
// - Diagnostic settings to send WAF and Access logs to a Log Analytics Workspace
//
// Note: If the VNet is not pre-created, this module will create it automatically.
// Author: Jan Tiedemann (Microsoft Germany) - 2026-06
// ------------------------------------------------------------------------------

// ─── Parameters ───────────────────────────────────────────────────────────────

@description('Azure region for all resources. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Name of the Application Gateway.')
param appGwName string = 'appgw-exchange'

@description('Name of the existing VNet to deploy into.')
param vnetName string

@description('Name of the resource group where the existing VNet is located.')
param vnetResourceGroupName string

@description('Name of the subnet for the Application Gateway. Will be created (or updated) in the VNet during deployment.')
param appGwSubnetName string = 'netenv-appGW'

@description('Address prefix (CIDR) of the Application Gateway subnet, e.g. 10.0.3.0/24.')
param appGwSubnetAddressPrefix string

@description('Name of the NSG for the Application Gateway subnet.')
param nsgName string = 'nsg-appgw'

@description('Name of the public IP resource for the Application Gateway frontend.')
param publicIpName string = 'pip-appgw'

@description('Array of private IP addresses of the Exchange backend servers, e.g. 10.0.3.10, 10.0.3.11.')
param exchangeBackendIPs array = []

@description('Public FQDN for mail access, e.g. mail.contoso.com. Must match the SSL certificate (SAN).')
param mailFqdn string = ''

@description('Public FQDN for Autodiscover, e.g. autodiscover.contoso.com. Must match the SSL certificate (SAN).')
param autodiscoverFqdn string = ''

@description('Name of the Log Analytics Workspace for WAF diagnostics.')
param logAnalyticsWorkspaceName string = 'law-appgw'

@description('Name of the Azure Key Vault to store the SSL certificate. Must be globally unique (3-24 alphanumeric characters and hyphens).')
@maxLength(24)
param keyVaultName string = 'kv-appgw-${substring(uniqueString(resourceGroup().id), 0, 4)}'

@description('Name of the User-Assigned Managed Identity for the Application Gateway.')
param managedIdentityName string = 'id-appgw'

@description('Name of the certificate stored in Key Vault (used as the secret identifier).')
param keyVaultCertificateName string = 'exchange-cert'

@description('Base64-encoded PFX certificate to import into Key Vault.')
@secure()
param sslCertData string = ''

@description('Password for the PFX certificate. Leave empty if the PFX was exported without a password.')
@secure()
param sslCertPassword string = ''

@description('Email address to receive certificate expiry notifications (30 days before expiry). Leave empty to skip notification setup.')
param certExpiryNotificationEmail string = ''

@description('WAF firewall mode. Use Detection for pre-prod, Prevention for production.')
@allowed(['Detection', 'Prevention'])
param wafMode string = 'Detection'

@description('Set to true to deploy the full Application Gateway stack (Key Vault, cert, App GW, diagnostics). Set to false to deploy only the NSG and subnet association.')
param deployAppGateway bool = true

// ─── User-Assigned Managed Identity ─────────────────────────────────────────
// The App Gateway uses this identity to retrieve the SSL certificate from Key Vault.

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = if (deployAppGateway) {
  name: managedIdentityName
  location: location
}

// ─── Key Vault ──────────────────────────────────────────────────────────────
// Stores the SSL/TLS certificate. enabledForDeployment and enableSoftDelete are configured.

resource kv 'Microsoft.KeyVault/vaults@2024-11-01' = if (deployAppGateway) {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenant().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enabledForDeployment: true
    enabledForTemplateDeployment: true
  }
}

// ─── RBAC: Key Vault Secrets User role for the Managed Identity ─────────────
// Role definition ID for "Key Vault Secrets User" = 4633458b-17de-408a-b874-0445c86b69e6
// This allows the App Gateway (via its managed identity) to read the certificate's backing secret.

resource kvSecretsUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployAppGateway) {
  name: guid(kv.id, managedIdentity.id, '4633458b-17de-408a-b874-0445c86b69e6')
  scope: kv
  properties: {
    principalId: managedIdentity!.properties.principalId
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4633458b-17de-408a-b874-0445c86b69e6'
    )
    principalType: 'ServicePrincipal'
  }
}

// ─── RBAC: Key Vault Certificates Officer role for the Managed Identity ─────
// Role definition ID for "Key Vault Certificates Officer" = a4417e6f-fecd-4de8-b567-7b0420556985
// This allows the deployment script (via the managed identity) to import the PFX as a certificate.

resource kvCertOfficerRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployAppGateway) {
  name: guid(kv.id, managedIdentity.id, 'a4417e6f-fecd-4de8-b567-7b0420556985')
  scope: kv
  properties: {
    principalId: managedIdentity!.properties.principalId
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'a4417e6f-fecd-4de8-b567-7b0420556985'
    )
    principalType: 'ServicePrincipal'
  }
}

// ─── Import PFX as a Key Vault certificate via deployment script ─────────────
// Uses `az keyvault certificate import` to store the PFX as a proper KV certificate
// (not just a secret). This gives expiry tracking, Event Grid notifications, and
// easy renewal. No explicit storage account is created — the deployment script
// service provisions a managed one automatically.
//
// Known limitation: If your subscription has an Azure Policy that enforces
// `allowSharedKeyAccess: false` on storage accounts, the deployment script will
// fail because the auto-provisioned storage account uses shared key access.
// Workaround: See README for workarounds.

resource importCertScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = if (deployAppGateway && !empty(sslCertData)) {
  name: 'import-pfx-to-keyvault'
  location: location
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    azCliVersion: '2.63.0'
    retentionInterval: 'PT1H'
    timeout: 'PT10M'
    environmentVariables: [
      { name: 'KEYVAULT_NAME', value: kv.name }
      { name: 'CERT_NAME', value: keyVaultCertificateName }
      { name: 'PFX_BASE64', secureValue: sslCertData }
      { name: 'PFX_PASSWORD', secureValue: sslCertPassword }
    ]
    scriptContent: '''#!/bin/bash
      set -e
      echo "$PFX_BASE64" | base64 -d > /tmp/cert.pfx
      if [ -n "$PFX_PASSWORD" ]; then
        az keyvault certificate import \
          --vault-name "$KEYVAULT_NAME" \
          --name "$CERT_NAME" \
          --file /tmp/cert.pfx \
          --password "$PFX_PASSWORD"
      else
        az keyvault certificate import \
          --vault-name "$KEYVAULT_NAME" \
          --name "$CERT_NAME" \
          --file /tmp/cert.pfx
      fi
      rm -f /tmp/cert.pfx
    '''
  }
  dependsOn: [
    kvSecretsUserRole
    kvCertOfficerRole
  ]
}

// ─── Certificate Expiry Notification ─────────────────────────────────────
// Event Grid system topic on the Key Vault + subscription that sends an email
// when the certificate is within 30 days of expiry (CertificateNearExpiry event).
// Only deployed if certExpiryNotificationEmail is provided.

resource certExpiryActionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = if (deployAppGateway && !empty(certExpiryNotificationEmail)) {
  name: 'ag-cert-expiry'
  location: 'global'
  properties: {
    enabled: true
    groupShortName: 'CertExpiry'
    emailReceivers: [
      {
        name: 'CertExpiryEmail'
        emailAddress: certExpiryNotificationEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

resource kvEventGridTopic 'Microsoft.EventGrid/systemTopics@2025-02-15' = if (deployAppGateway && !empty(certExpiryNotificationEmail)) {
  name: '${keyVaultName}-evgt'
  location: location
  properties: {
    source: kv.id
    topicType: 'Microsoft.KeyVault.vaults'
  }
}

resource certExpirySubscription 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2025-02-15' = if (deployAppGateway && !empty(certExpiryNotificationEmail)) {
  parent: kvEventGridTopic
  name: 'cert-near-expiry'
  properties: {
    deliveryWithResourceIdentity: null
    eventDeliverySchema: 'CloudEventSchemaV1_0'
    destination: {
      endpointType: 'MonitorAlert'
      properties: {
        severity: 'Sev3'
        description: 'SSL certificate in Key Vault is near expiry'
        actionGroups: [
          certExpiryActionGroup.id
        ]
      }
    }
    filter: {
      includedEventTypes: [
        'Microsoft.KeyVault.CertificateNearExpiry'
      ]
    }
  }
}

// ─── Log Analytics Workspace for WAF diagnostics ────────────────────────────

resource law 'Microsoft.OperationalInsights/workspaces@2025-02-01' = if (deployAppGateway) {
  name: logAnalyticsWorkspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 31
  }
}

// ─── Public IP for the Application Gateway frontend ──────────────────────────

resource pip 'Microsoft.Network/publicIPAddresses@2025-05-01' = if (deployAppGateway) {
  name: publicIpName
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// ─── WAF Policy with custom Allow rules for EWS/Autodiscover paths ──────────
// URL-path exclusions are not supported via managed rule exclusions.
// Instead, custom rules with Allow action bypass WAF inspection for those paths.

resource wafPolicy 'Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies@2024-05-01' = if (deployAppGateway) {
  name: '${appGwName}-waf-policy'
  location: location
  properties: {
    policySettings: {
      state: 'Enabled'
      mode: wafMode
      requestBodyCheck: true
      maxRequestBodySizeInKb: 128
      fileUploadLimitInMb: 100
    }
    customRules: [
      {
        name: 'AllowEWS'
        priority: 10
        ruleType: 'MatchRule'
        action: 'Allow'
        matchConditions: [
          {
            matchVariables: [
              {
                variableName: 'RequestUri'
              }
            ]
            operator: 'Contains'
            matchValues: [
              '/EWS/'
            ]
            transforms: [
              'Lowercase'
            ]
          }
        ]
      }
      {
        name: 'AllowAutodiscover'
        priority: 20
        ruleType: 'MatchRule'
        action: 'Allow'
        matchConditions: [
          {
            matchVariables: [
              {
                variableName: 'RequestUri'
              }
            ]
            operator: 'Contains'
            matchValues: [
              '/Autodiscover/'
            ]
            transforms: [
              'Lowercase'
            ]
          }
        ]
      }
    ]
    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'OWASP'
          ruleSetVersion: '3.2'
        }
      ]
    }
  }
}

// ─── NSG and subnet for the Application Gateway ────────────────────────────
// Creates an NSG with rules required for Application Gateway v2, then creates
// (or updates) the subnet with the NSG associated. Deploys to the VNet's resource group.

module nsgSubnetAssociation 'appGW_nsg_subnet_association.bicep' = {
  name: 'deploy-appgw-nsg'
  scope: resourceGroup(vnetResourceGroupName)
  params: {
    nsgName: nsgName
    location: location
    vnetName: vnetName
    subnetName: appGwSubnetName
    subnetAddressPrefix: appGwSubnetAddressPrefix
  }
}

// The subnet ID is taken from the module output so the Application Gateway
// deployment waits until the NSG association is complete.
var appGwSubnetId = nsgSubnetAssociation.outputs.subnetId

// ─── Application Gateway (WAF v2) with Key Vault integration ────────────────

resource appGw 'Microsoft.Network/applicationGateways@2024-05-01' = if (deployAppGateway) {
  name: appGwName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }

  properties: {
    sku: {
      name: 'WAF_v2'
      tier: 'WAF_v2'
      capacity: 2
    }

    // Bind the App Gateway to the dedicated subnet
    gatewayIPConfigurations: [
      {
        name: 'gw-ipcfg'
        properties: {
          subnet: {
            id: appGwSubnetId
          }
        }
      }
    ]

    // Frontend public IP configuration
    frontendIPConfigurations: [
      {
        name: 'frontend-public'
        properties: {
          publicIPAddress: { id: pip.id }
        }
      }
    ]

    // Listen on HTTPS port 443
    frontendPorts: [
      {
        name: 'https-443'
        properties: { port: 443 }
      }
    ]

    // SSL/TLS certificate retrieved from Key Vault via Managed Identity
    // The unversioned secret URI ensures the App Gateway auto-picks up renewed certificates.
    sslCertificates: [
      {
        name: 'exchange-cert'
        properties: {
          keyVaultSecretId: '${kv!.properties.vaultUri}secrets/${keyVaultCertificateName}'
        }
      }
    ]

    // HTTPS listener for mail FQDN with SNI
    httpListeners: [
      {
        name: 'listener-mail'
        properties: {
          frontendIPConfiguration: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/frontendIPConfigurations',
              appGwName,
              'frontend-public'
            )
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', appGwName, 'https-443')
          }
          protocol: 'Https'
          sslCertificate: {
            id: resourceId('Microsoft.Network/applicationGateways/sslCertificates', appGwName, 'exchange-cert')
          }
          hostName: mailFqdn
          requireServerNameIndication: true
        }
      }
      {
        name: 'listener-autodiscover'
        properties: {
          frontendIPConfiguration: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/frontendIPConfigurations',
              appGwName,
              'frontend-public'
            )
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', appGwName, 'https-443')
          }
          protocol: 'Https'
          sslCertificate: {
            id: resourceId('Microsoft.Network/applicationGateways/sslCertificates', appGwName, 'exchange-cert')
          }
          hostName: autodiscoverFqdn
          requireServerNameIndication: true
        }
      }
    ]

    // Backend pool with Exchange server IPs
    backendAddressPools: [
      {
        name: 'exchange-backend'
        properties: {
          backendAddresses: [for ip in exchangeBackendIPs: { ipAddress: ip }]
        }
      }
    ]

    // Backend HTTPS settings for mail (re-encrypt traffic to Exchange servers)
    backendHttpSettingsCollection: [
      {
        name: 'https-backend-mail'
        properties: {
          protocol: 'Https'
          port: 443
          requestTimeout: 120
          pickHostNameFromBackendAddress: false
          hostName: mailFqdn
          cookieBasedAffinity: 'Disabled'
          probe: {
            id: resourceId('Microsoft.Network/applicationGateways/probes', appGwName, 'probe-mail')
          }
        }
      }
      {
        name: 'https-backend-autodiscover'
        properties: {
          protocol: 'Https'
          port: 443
          requestTimeout: 120
          pickHostNameFromBackendAddress: false
          hostName: autodiscoverFqdn
          cookieBasedAffinity: 'Disabled'
          probe: {
            id: resourceId('Microsoft.Network/applicationGateways/probes', appGwName, 'probe-autodiscover')
          }
        }
      }
    ]

    // Health probes for mail (EWS) and autodiscover endpoints
    probes: [
      {
        name: 'probe-mail'
        properties: {
          protocol: 'Https'
          path: '/EWS/Exchange.asmx'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          host: mailFqdn
          match: {
            statusCodes: ['200-401']
          }
        }
      }
      {
        name: 'probe-autodiscover'
        properties: {
          protocol: 'Https'
          path: '/Autodiscover/Autodiscover.xml'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          host: autodiscoverFqdn
          match: {
            statusCodes: ['200-401']
          }
        }
      }
    ]

    // Routing rules: forward HTTPS traffic per FQDN to Exchange backend pool
    requestRoutingRules: [
      {
        name: 'rule-mail'
        properties: {
          priority: 100
          ruleType: 'Basic'
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', appGwName, 'listener-mail')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', appGwName, 'exchange-backend')
          }
          backendHttpSettings: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/backendHttpSettingsCollection',
              appGwName,
              'https-backend-mail'
            )
          }
        }
      }
      {
        name: 'rule-autodiscover'
        properties: {
          priority: 200
          ruleType: 'Basic'
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', appGwName, 'listener-autodiscover')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', appGwName, 'exchange-backend')
          }
          backendHttpSettings: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/backendHttpSettingsCollection',
              appGwName,
              'https-backend-autodiscover'
            )
          }
        }
      }
    ]

    // WAF Policy reference (replaces inline webApplicationFirewallConfiguration)
    firewallPolicy: {
      id: wafPolicy.id
    }
  }
  dependsOn: [
    importCertScript
  ]
}

// ─── Diagnostic Settings: WAF & Access logs ─────────────────────────────────

#disable-next-line use-recent-api-versions
resource appGwDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (deployAppGateway) {
  scope: appGw
  name: 'appgw-waf-diagnostics'
  properties: {
    workspaceId: law.id
    logs: [
      {
        category: 'ApplicationGatewayFirewallLog'
        enabled: true
      }
      {
        category: 'ApplicationGatewayAccessLog'
        enabled: true
      }
    ]
  }
}
