# Azure Application Gateway for Exchange (Free/Busy) – Bicep Deployment

![Bicep](https://img.shields.io/badge/Bicep-0.41.x-blue?logo=microsoftazure)
![Azure](https://img.shields.io/badge/Azure-Application%20Gateway%20WAF%20v2-0078D4?logo=microsoftazure)
![License](https://img.shields.io/badge/License-MIT-green)

Bicep modules to deploy an **Azure Application Gateway (WAF v2)** that enables **Microsoft Teams** to securely access **Exchange Free/Busy** (calendar availability) information via the **EWS endpoint** and **Autodiscover** to locate mailboxes and calendars on on-premises Exchange servers. Includes NSG hardening, dual-listener routing (mail + autodiscover), and diagnostic logging.

**Author:** Jan Tiedemann (Microsoft Germany)

---

## Deploy to Azure

| Variant | Deploy |
|---------|--------|
| **Key Vault** (recommended) | [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FBetaHydri%2Fappgw-exchange-bicep%2Fmain%2FappGW_custom_deployment_kv.json) |
| **Inline certificate** | [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FBetaHydri%2Fappgw-exchange-bicep%2Fmain%2FappGW_custom_deployment.json) |

> **Note:** The buttons link to the pre-compiled ARM (JSON) templates in this repository. The Azure Portal will prompt you for all required parameters.

---

## Architecture

```text
Internet
  │
  ▼
┌──────────────┐
│  Public IP   │
└──────┬───────┘
       │ :443
       ▼
┌──────────────────────────────────────────┐
│  NSG (nsg-appgw)                         │
│  ├─ Allow HTTPS 443 from Internet        │
│  ├─ Allow 65200-65535 from GatewayMgr    │
│  └─ Allow * from AzureLoadBalancer       │
├──────────────────────────────────────────┤
│  Subnet (e.g. 10.0.3.0/24)               │
│  ┌────────────────────────────────────┐  │
│  │  Application Gateway (WAF v2)      │  │
│  │  ├─ Listener: mail FQDN            │  │
│  │  ├─ Listener: autodiscover FQDN    │  │
│  │  ├─ WAF Policy (OWASP 3.2)         │  │
│  │  │   ├─ Allow /EWS/                │  │
│  │  │   └─ Allow /Autodiscover/       │  │
│  │  ├─ Probe: /EWS/Exchange.asmx      │  │
│  │  └─ Probe: /Autodiscover/...xml    │  │
│  └────────────────────────────────────┘  │
└──────────────────────────────────────────┘
       │ :443 (re-encrypt)
       ▼
┌──────────────────┐
│ Exchange Servers │
│ (backend pool)   │
└──────────────────┘
```

---

## Files

| File | Description |
|------|-------------|
| `appGW_custom_deployment_kv.bicep` | **Recommended.** Full deployment with Key Vault integration. Certificate is stored as a Key Vault secret and referenced by the App Gateway using a managed identity. No deployment script or storage account needed. |
| `appGW_custom_deployment.bicep` | Simpler variant with inline PFX certificate (no Key Vault). Includes `deployAppGateway` toggle to deploy only the NSG/subnet. |
| `appGW_nsg_subnet_association.bicep` | Shared module: creates the NSG with mandatory AppGW v2 rules and creates (or updates) the subnet. Used by both main templates. |
| `appGW_custom_deployment_kv.json` | Compiled ARM template of the Key Vault variant. |
| `appGW_custom_deployment.json` | Compiled ARM template of the inline variant. |

---

## Features

- **WAF v2** with OWASP 3.2 managed rule set
- **Custom WAF Allow rules** for `/EWS/` and `/Autodiscover/` paths (bypasses false positives)
- **Dual HTTPS listeners** with SNI for mail and autodiscover FQDNs
- **Dedicated health probes** per endpoint (EWS + Autodiscover)
- **NSG** with mandatory Application Gateway v2 inbound rules (port 443, GatewayManager, AzureLoadBalancer)
- **Cross-resource-group and cross-subscription** subnet deployment — the VNet can be in a different resource group or a different subscription
- **Subnet upsert** — the subnet is created if it doesn't exist, or updated if it does
- **Diagnostic logging** — WAF firewall and access logs sent to a Log Analytics Workspace
- **Certificate expiry notifications** — 30-day email alert (Key Vault variant only)

> **Note:** The Application Gateway itself is a Layer 7 load balancer. No separate Azure Load Balancer is deployed or required by this module.

---

## Parameters

### Key Vault variant (`appGW_custom_deployment_kv.bicep`)

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `vnetName` | **Yes** | — | Name of the existing VNet |
| `vnetResourceGroupName` | **Yes** | — | Resource group of the VNet |
| `vnetSubscriptionId` | No | Current subscription | Subscription ID where the VNet is located (for cross-subscription deployments) |
| `vnetLocation` | No | Same as `location` | Azure region of the VNet. Only needed when the App Gateway RG and VNet RG have different default locations (both must still be in the same region) |
| `appGwSubnetAddressPrefix` | **Yes** | — | Subnet CIDR, e.g. `10.0.3.0/24` |
| `exchangeBackendIPs` | **Yes** | — | Array of backend server IPs |
| `mailFqdn` | **Yes** | — | Mail FQDN, e.g. `mail.contoso.com` |
| `autodiscoverFqdn` | **Yes** | — | Autodiscover FQDN |
| `sslCertData` | **Yes** | — | Base64-encoded PFX certificate |
| `location` | No | Resource group location | Azure region |
| `appGwName` | No | `appgw-exchange` | Application Gateway name |
| `appGwSubnetName` | No | `netenv-appGW` | Subnet name |
| `nsgName` | No | `nsg-appgw` | NSG name |
| `publicIpName` | No | `pip-appgw` | Public IP name |
| `logAnalyticsWorkspaceName` | No | `law-appgw` | Log Analytics Workspace name |
| `keyVaultName` | No | `kv-appgw-xxxx` (auto) | Key Vault name (globally unique, auto-generated suffix) |
| `managedIdentityName` | No | `id-appgw` | Managed Identity name |
| `keyVaultCertificateName` | No | `exchange-cert` | Certificate name in Key Vault |
| `wafMode` | No | `Detection` | `Detection` or `Prevention` |
| `deployAppGateway` | No | `true` | Set to `false` to deploy **only** the NSG and subnet (no Key Vault, cert, App GW, or diagnostics) |

> **Tip:** When `deployAppGateway` is set to `false`, the following resources are **not** deployed: Key Vault, Managed Identity, RBAC role assignments, certificate secret, Log Analytics Workspace, Public IP, WAF Policy, Application Gateway, and diagnostic settings. Only the NSG and subnet association module runs.

> **Same-subscription usage:** All cross-subscription parameters default to the current subscription and region. You don't need to set `vnetSubscriptionId` or `vnetLocation` when everything is in the same subscription and region — they just work.

### Inline variant (`appGW_custom_deployment.bicep`)

Same as above except:
- No Key Vault, managed identity, or certificate expiry parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `vnetSubscriptionId` | No | Current subscription | Subscription ID where the VNet is located (for cross-subscription deployments) |
| `vnetLocation` | No | Same as `location` | Azure region of the VNet. Only needed when the App Gateway RG and VNet RG have different default locations (both must still be in the same region) |
| `deployAppGateway` | No | `true` | Set to `false` to deploy **only** the NSG and subnet (no Application Gateway) |

---

## Deployment

### Prerequisites

- An existing **VNet** in the **same Azure region** as the Application Gateway (the subnet will be created automatically)
- A **PFX certificate** with SANs matching `mailFqdn` and `autodiscoverFqdn`

> **Important — Region constraint:** The Application Gateway is a regional resource. The VNet/subnet used by the App Gateway **must be in the same Azure region** as the App Gateway itself. Cross-subscription deployments are supported, but cross-region is **not**. Make sure the resource group you deploy to and the VNet are in the same region.

#### Required RBAC Permissions

| Scope | Role | When needed |
|-------|------|-------------|
| App Gateway resource group | **Contributor** | Always |
| VNet resource group (same subscription) | **Network Contributor** | Cross-resource-group deployment |
| VNet resource group (different subscription) | **Network Contributor** | Cross-subscription deployment |
| App Gateway subscription | **User Access Administrator** or **Owner** | To create RBAC role assignments for Key Vault |

The Key Vault variant no longer uses deployment scripts or storage accounts. No Azure Policy exemptions are needed.

### 1. Base64-encode the PFX certificate

```powershell
$certBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\to\your-cert.pfx"))
```

### 2a. Deploy via Azure CLI (Key Vault variant — recommended)

```bash
az deployment group create \
  --name appgw-deployment \
  --resource-group rg-appgw \
  --template-file appGW_custom_deployment_kv.bicep \
  --parameters \
    vnetName="vnet-hub" \
    vnetResourceGroupName="rg-network" \
    appGwSubnetAddressPrefix="10.0.3.0/24" \
    exchangeBackendIPs='["10.0.1.10","10.0.1.11"]' \
    mailFqdn="mail.contoso.com" \
    autodiscoverFqdn="autodiscover.contoso.com" \
    sslCertData="$certBase64" \
    certExpiryNotificationEmail="admin@contoso.com"
```

> **Cross-subscription:** If the VNet is in a different subscription, add `vnetSubscriptionId="<subscription-id>"` to the parameters above.

### 2b. Deploy via PowerShell (Key Vault variant)

```powershell
New-AzResourceGroupDeployment `
  -Name "appgw-deployment" `
  -ResourceGroupName "rg-appgw" `
  -TemplateFile "appGW_custom_deployment_kv.bicep" `
  -vnetName "vnet-hub" `
  -vnetResourceGroupName "rg-network" `
  # -vnetSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" ` # uncomment for cross-subscription VNet
  -appGwSubnetAddressPrefix "10.0.3.0/24" `
  -exchangeBackendIPs @("10.0.1.10", "10.0.1.11") `
  -mailFqdn "mail.contoso.com" `
  -autodiscoverFqdn "autodiscover.contoso.com" `
  -sslCertData $certBase64 `
  -certExpiryNotificationEmail "admin@contoso.com"
```

### 2c. Deploy via Azure Portal

1. Go to **Deploy a custom template**
2. Click **Build your own template in the editor**
3. Click **Load file** → upload `appGW_custom_deployment_kv.json` (the compiled ARM template)
4. Click **Save**, fill in the parameters
5. Select your **Subscription** and **Resource Group**
6. Click **Review + Create** → **Create**

> **Note:** For portal deployment, use the pre-compiled `.json` file (not `.bicep`), because the module reference to `appGW_nsg_subnet_association.bicep` is already inlined in the JSON.

### 3. Deploy only the NSG and subnet (inline variant)

To prepare the subnet and NSG without deploying the Application Gateway:

```bash
az deployment group create \
  --name nsg-subnet-only \
  --resource-group rg-appgw \
  --template-file appGW_custom_deployment.bicep \
  --parameters \
    vnetName="vnet-hub" \
    vnetResourceGroupName="rg-network" \
    appGwSubnetAddressPrefix="10.0.3.0/24" \
    deployAppGateway=false
```

---

## NSG Rules

The NSG created on the Application Gateway subnet contains the following **mandatory** rules for WAF v2:

| Rule | Priority | Direction | Port(s) | Source | Protocol | Purpose |
|------|----------|-----------|---------|--------|----------|---------|
| Allow-HTTPS-Inbound | 100 | Inbound | 443 | `Internet` | TCP | Client HTTPS traffic |
| Allow-GatewayManager-Inbound | 110 | Inbound | 65200-65535 | `GatewayManager` | TCP | Azure health probes (mandatory) |
| Allow-AzureLoadBalancer-Inbound | 120 | Inbound | * | `AzureLoadBalancer` | * | Azure LB probes |

> **Why Internet → 443?** The Application Gateway runs as VM instances **inside** the subnet. The Public IP is a NAT mapping — Azure routes the packet into the subnet, where the NSG evaluates it before it reaches the AppGW. Without this rule, no client traffic gets through.

---

## Key Vault vs. Inline Certificate

| Aspect | Key Vault variant | Inline variant |
|--------|-------------------|----------------|
| Certificate storage | Azure Key Vault (secret) | Embedded in ARM deployment |
| Secret exposure | No secrets in parameter files | PFX data + password passed at deploy time |
| Certificate renewal | AppGW refreshes from KV every 4 hours | Requires redeployment |
| Expiry notification | Not built-in (can be added via KV monitoring) | Not available |
| Complexity | Moderate (managed identity, RBAC, KV secret) | Lower |
| Policy compatibility | No storage account needed — works with all policies | No restrictions |
| Recommendation | **Production** | Dev/test only |

---

## Rebuilding the ARM Templates

After editing any `.bicep` file, regenerate the compiled JSON:

```bash
bicep build appGW_custom_deployment_kv.bicep
bicep build appGW_custom_deployment.bicep
```

The `appGW_nsg_subnet_association.bicep` module is automatically inlined into both JSON outputs — no separate build needed.
