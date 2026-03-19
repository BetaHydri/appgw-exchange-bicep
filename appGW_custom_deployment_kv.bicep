// ------------------------------------------------------------------------------
// Application Gateway deployment Bicep module (Key Vault variant)
// This module deploys an Application Gateway (WAF v2) with the following features:
// - Subnet creation (or update) with NSG inside an existing VNet (cross-resource-group)
// - Public IP for frontend access
// - Azure Key Vault to store the SSL/TLS certificate
// - User-Assigned Managed Identity with Key Vault access for the App Gateway
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

@description('Subscription ID where the existing VNet is located. Defaults to the current subscription.')
param vnetSubscriptionId string = subscription().subscriptionId

@description('Azure region of the VNet resource group. The NSG must be created in the same region as the VNet. Defaults to the App Gateway location.')
param vnetLocation string = location

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

@description('Name of the Azure Key Vault to store the SSL certificate.')
param keyVaultName string = 'netenv-kv-appgw'

@description('Name of the User-Assigned Managed Identity for the Application Gateway.')
param managedIdentityName string = 'id-appgw'

@description('Name of the certificate stored in Key Vault (used as the secret identifier).')
param keyVaultCertificateName string = 'exchange-cert'

@description('Base64-encoded PFX certificate to import into Key Vault.')
param sslCertData string = ''

@description('Password for the PFX certificate.')
@secure()
param sslCertPassword string = ''

@description('WAF firewall mode. Use Detection for pre-prod, Prevention for production.')
@allowed(['Detection', 'Prevention'])
param wafMode string = 'Detection'

@description('Email address to receive certificate expiry notifications (30 days before expiration).')
param certExpiryNotificationEmail string = ''

@description('Set to true to deploy the full Application Gateway stack (Key Vault, cert, App GW, diagnostics). Set to false to deploy only the NSG and subnet association.')
param deployAppGateway bool = true

@description('Name of the storage account used by the deployment script. Must be globally unique (3-24 lowercase alphanumeric). Required because some subscriptions block key-based auth on auto-created storage accounts.')
@maxLength(24)
param scriptStorageAccountName string = 'stscript${uniqueString(resourceGroup().id)}'

// ─── User-Assigned Managed Identity ─────────────────────────────────────────
// The App Gateway uses this identity to retrieve the SSL certificate from Key Vault.

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = if (deployAppGateway) {
  name: managedIdentityName
  location: location
}

// ─── Key Vault ──────────────────────────────────────────────────────────────
// Stores the SSL/TLS certificate. enabledForDeployment and enableSoftDelete are configured.

// ─── Storage Account for the deployment script ──────────────────────────────
// The deployment script needs a storage account. If the subscription has a policy
// blocking key-based auth on auto-created storage accounts, this explicit resource
// with allowSharedKeyAccess ensures the script can run.

resource scriptStorage 'Microsoft.Storage/storageAccounts@2025-01-01' = if (deployAppGateway) {
  name: scriptStorageAccountName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    allowSharedKeyAccess: true
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

// ─── RBAC: Storage Blob Data Contributor for the Managed Identity ───────────
// Required so the deployment script can write its output to the storage account.

resource storageBlobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployAppGateway) {
  name: guid(scriptStorage.id, managedIdentity.id, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  scope: scriptStorage
  properties: {
    principalId: managedIdentity!.properties.principalId
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
    )
    principalType: 'ServicePrincipal'
  }
}

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
// This allows the App Gateway (via its managed identity) to read the certificate secret.

resource kvRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployAppGateway) {
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

// ─── RBAC: Key Vault Certificates Officer for the deployment script identity ─
// Role definition ID for "Key Vault Certificates Officer" = a4417e6f-fecd-4de8-b567-7b0420556985
// Required so the deployment script can import the PFX certificate.

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

// ─── Import the password-protected PFX certificate into Key Vault ───────────
// Uses a deployment script with Azure CLI to run 'az keyvault certificate import',
// which properly handles the PFX password. The script outputs the certificate's
// secret URI that the Application Gateway will reference.

resource importCert 'Microsoft.Resources/deploymentScripts@2023-08-01' = if (deployAppGateway) {
  name: 'import-appgw-cert'
  location: location
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    azCliVersion: '2.67.0'
    retentionInterval: 'PT1H'
    timeout: 'PT10M'
    storageAccountSettings: {
      storageAccountName: scriptStorage.name
      storageAccountKey: scriptStorage!.listKeys().keys[0].value
    }
    environmentVariables: [
      { name: 'KV_NAME', value: kv.name }
      { name: 'CERT_NAME', value: keyVaultCertificateName }
      { name: 'PFX_BASE64', value: sslCertData }
      { name: 'PFX_PASSWORD', secureValue: sslCertPassword }
      { name: 'NOTIFY_EMAIL', value: certExpiryNotificationEmail }
    ]
    scriptContent: '''
      set -e
      echo "$PFX_BASE64" | base64 -d > /tmp/cert.pfx
      az keyvault certificate import \
        --vault-name "$KV_NAME" \
        --name "$CERT_NAME" \
        --file /tmp/cert.pfx \
        --password "$PFX_PASSWORD"
      rm -f /tmp/cert.pfx

      # Configure lifetime action: email notification 30 days before expiry
      POLICY=$(az keyvault certificate show \
        --vault-name "$KV_NAME" \
        --name "$CERT_NAME" \
        --query policy -o json)
      UPDATED_POLICY=$(echo "$POLICY" | jq '.lifetime_actions = [{"action":{"action_type":"EmailContacts"},"trigger":{"days_before_expiry":30}}]')
      az keyvault certificate set-attributes \
        --vault-name "$KV_NAME" \
        --name "$CERT_NAME" \
        --policy "$UPDATED_POLICY"

      # Add notification contact (ignore error if contact already exists)
      az keyvault certificate contact add \
        --vault-name "$KV_NAME" \
        --email "$NOTIFY_EMAIL" 2>/dev/null || true

      SECRET_URI=$(az keyvault certificate show \
        --vault-name "$KV_NAME" \
        --name "$CERT_NAME" \
        --query sid -o tsv)
      echo "{\"secretUri\": \"$SECRET_URI\"}" > $AZ_SCRIPTS_OUTPUT_PATH
    '''
  }
  dependsOn: [
    kvRoleAssignment
    kvCertOfficerRole
    storageBlobRole
  ]
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
  scope: resourceGroup(vnetSubscriptionId, vnetResourceGroupName)
  params: {
    nsgName: nsgName
    location: vnetLocation
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
    // The secret URI comes from the deployment script that imported the PFX
    sslCertificates: [
      {
        name: 'exchange-cert'
        properties: {
          keyVaultSecretId: importCert!.properties.outputs.secretUri
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
    kvRoleAssignment
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
