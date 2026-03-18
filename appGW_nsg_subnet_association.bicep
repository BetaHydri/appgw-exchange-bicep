// ------------------------------------------------------------------------------
// Module: NSG and subnet for Application Gateway v2
// Creates an NSG with the mandatory inbound rules for Application Gateway v2
// and creates (or updates) the subnet with the NSG associated.
//
// Required rules:
//   - HTTPS (443) from Internet – client traffic
//   - Ports 65200-65535 from GatewayManager – Azure infrastructure health probes
//   - Any from AzureLoadBalancer – Azure Load Balancer health probes
//
// NOTE: The subnet PUT is an upsert – it creates the subnet if it doesn't exist,
//       or updates it if it does. Redeploying will overwrite existing subnet properties.
//       If the subnet has a route table or other properties, add matching parameters.
// Author: Jan Tiedemann (Microsoft Germany) - 2024-06
// ------------------------------------------------------------------------------

targetScope = 'resourceGroup'

@description('Name of the NSG for the Application Gateway subnet.')
param nsgName string

@description('Azure region for the NSG resource.')
param location string

@description('Name of the existing VNet that contains the Application Gateway subnet.')
param vnetName string

@description('Name of the Application Gateway subnet. Will be created if it does not exist.')
param subnetName string

@description('Address prefix (CIDR) of the Application Gateway subnet, e.g. 10.0.1.0/24.')
param subnetAddressPrefix string

// ─── NSG with rules required for Application Gateway v2 ─────────────────────

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-HTTPS-Inbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Allow-GatewayManager-Inbound'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '65200-65535'
          sourceAddressPrefix: 'GatewayManager'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Allow-AzureLoadBalancer-Inbound'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// ─── Create (or update) the Application Gateway subnet with NSG ─────────────

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: subnetName
  properties: {
    addressPrefix: subnetAddressPrefix
    networkSecurityGroup: {
      id: nsg.id
    }
  }
}

// ─── Outputs ─────────────────────────────────────────────────────────────────

output nsgId string = nsg.id
output subnetId string = subnet.id
