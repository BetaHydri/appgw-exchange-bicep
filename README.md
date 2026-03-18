# Application Gateway for Exchange – Bicep Deployment

![Bicep](https://img.shields.io/badge/Bicep-0.41.x-blue?logo=microsoftazure)
![Azure](https://img.shields.io/badge/Azure-Application%20Gateway%20WAF%20v2-0078D4?logo=microsoftazure)
![License](https://img.shields.io/badge/License-MIT-green)

Bicep modules to deploy an **Azure Application Gateway (WAF v2)** with HTTPS termination for on-premises Microsoft Exchange servers. Includes NSG hardening, dual-listener routing (mail + autodiscover), and diagnostic logging.

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
│  Subnet (e.g. 10.0.3.0/24)              │
│  ┌────────────────────────────────────┐  │
│  │  Application Gateway (WAF v2)     │  │
│  │  ├─ Listener: mail FQDN           │  │
│  │  ├─ Listener: autodiscover FQDN   │  │
│  │  ├─ WAF Policy (OWASP 3.2)        │  │
│  │  │   ├─ Allow /EWS/               │  │
│  │  │   └─ Allow /Autodiscover/      │  │
│  │  ├─ Probe: /EWS/Exchange.asmx     │  │
│  │  └─ Probe: /Autodiscover/...xml   │  │
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
| `appGW_custom_deployment_kv.bicep` | **Recommended.** Full deployment with Key Vault integration. Certificate is imported into Key Vault via deployment script and referenced by the App Gateway using a managed identity. |
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
- **Cross-resource-group** subnet deployment — the VNet can be in a different resource group
- **Subnet upsert** — the subnet is created if it doesn't exist, or updated if it does
- **Diagnostic logging** — WAF firewall and access logs sent to a Log Analytics Workspace
- **Certificate expiry notifications** — 30-day email alert (Key Vault variant only)

---

## Parameters

### Key Vault variant (`appGW_custom_deployment_kv.bicep`)

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `vnetName` | **Yes** | — | Name of the existing VNet |
| `vnetResourceGroupName` | **Yes** | — | Resource group of the VNet |
| `appGwSubnetAddressPrefix` | **Yes** | — | Subnet CIDR, e.g. `10.0.3.0/24` |
| `exchangeBackendIPs` | **Yes** | — | Array of backend server IPs |
| `mailFqdn` | **Yes** | — | Mail FQDN, e.g. `mail.contoso.com` |
| `autodiscoverFqdn` | **Yes** | — | Autodiscover FQDN |
| `sslCertData` | **Yes** | — | Base64-encoded PFX certificate |
| `sslCertPassword` | **Yes** | — | PFX password (secure) |
| `certExpiryNotificationEmail` | **Yes** | — | Email for cert expiry alerts |
| `location` | No | Resource group location | Azure region |
| `appGwName` | No | `appgw-exchange` | Application Gateway name |
| `appGwSubnetName` | No | `BYCLTE-appGW` | Subnet name |
| `nsgName` | No | `nsg-appgw` | NSG name |
| `publicIpName` | No | `pip-appgw` | Public IP name |
| `logAnalyticsWorkspaceName` | No | `law-appgw` | Log Analytics Workspace name |
| `keyVaultName` | No | `byclte-kv-appgw` | Key Vault name |
| `managedIdentityName` | No | `id-appgw` | Managed Identity name |
| `keyVaultCertificateName` | No | `exchange-cert` | Certificate name in Key Vault |
| `wafMode` | No | `Detection` | `Detection` or `Prevention` |

### Inline variant (`appGW_custom_deployment.bicep`)

Same as above except:
- No Key Vault, managed identity, or certificate expiry parameters
- Has `deployAppGateway` toggle (default: `true`) — set to `false` to deploy **only** the NSG and subnet

---

## Deployment

### Prerequisites

- An existing **VNet** (the subnet will be created automatically)
- A **PFX certificate** with SANs matching `mailFqdn` and `autodiscoverFqdn`
- **Contributor** role on the target resource group
- **Network Contributor** role on the VNet resource group (for cross-RG subnet deployment)

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
    sslCertPassword="YourPfxPassword" \
    certExpiryNotificationEmail="admin@contoso.com"
```

### 2b. Deploy via PowerShell (Key Vault variant)

```powershell
New-AzResourceGroupDeployment `
  -Name "appgw-deployment" `
  -ResourceGroupName "rg-appgw" `
  -TemplateFile "appGW_custom_deployment_kv.bicep" `
  -vnetName "vnet-hub" `
  -vnetResourceGroupName "rg-network" `
  -appGwSubnetAddressPrefix "10.0.3.0/24" `
  -exchangeBackendIPs @("10.0.1.10", "10.0.1.11") `
  -mailFqdn "mail.contoso.com" `
  -autodiscoverFqdn "autodiscover.contoso.com" `
  -sslCertData $certBase64 `
  -sslCertPassword (ConvertTo-SecureString "YourPfxPassword" -AsPlainText -Force) `
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
| Certificate storage | Azure Key Vault | Embedded in ARM deployment |
| Secret exposure | No secrets in parameter files | PFX data + password passed at deploy time |
| Certificate renewal | AppGW refreshes from KV every 4 hours | Requires redeployment |
| Expiry notification | 30-day email alert via Key Vault | Not available |
| Complexity | Higher (managed identity, RBAC, deployment script) | Lower |
| Recommendation | **Production** | Dev/test only |

---

## Rebuilding the ARM Templates

After editing any `.bicep` file, regenerate the compiled JSON:

```bash
bicep build appGW_custom_deployment_kv.bicep
bicep build appGW_custom_deployment.bicep
```

The `appGW_nsg_subnet_association.bicep` module is automatically inlined into both JSON outputs — no separate build needed.
