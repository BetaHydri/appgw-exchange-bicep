// ------------------------------------------------------------------------------
// Application Gateway deployment Bicep module (inline certificate variant)
// This module deploys an Application Gateway (WAF v2) with the following features:
// - Subnet creation (or update) with NSG inside an existing VNet (cross-resource-group)
// - Public IP for frontend access
// - HTTPS listeners with SNI for mail and autodiscover FQDNs (inline PFX certificate)
// - Backend pool with Exchange server IPs
// - Health probes for EWS and Autodiscover endpoints
// - WAF policy with custom Allow rules for EWS and Autodiscover paths
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
param appGwSubnetName string = 'snet-appgw'

@description('Address prefix (CIDR) of the Application Gateway subnet, e.g. 10.0.5.0/24.')
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

@description('Base64-encoded PFX certificate for HTTPS termination.')
param sslCertData string = ''

@description('Password for the PFX certificate.')
@secure()
param sslCertPassword string = ''

@description('WAF firewall mode. Use Detection for pre-prod, Prevention for production.')
@allowed(['Detection', 'Prevention'])
param wafMode string = 'Detection'

@description('Set to true to deploy the full Application Gateway stack (App GW, WAF, PIP, LAW, diagnostics). Set to false to deploy only the NSG and subnet association.')
param deployAppGateway bool = true

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

// ─── Application Gateway (WAF v2) with inline certificate ───────────────────

resource appGw 'Microsoft.Network/applicationGateways@2024-05-01' = if (deployAppGateway) {
  name: appGwName
  location: location

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

    // SSL/TLS certificate for HTTPS termination (inline PFX)
    sslCertificates: [
      {
        name: 'exchange-cert'
        properties: {
          data: sslCertData
          password: sslCertPassword
        }
      }
    ]

    // HTTPS listeners for mail and autodiscover FQDNs with SNI
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

    // Backend HTTPS settings for mail and autodiscover (re-encrypt traffic to Exchange servers)
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
