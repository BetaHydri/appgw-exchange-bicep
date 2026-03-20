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
| `appGW_custom_deployment_kv.bicep` | **Recommended.** Full deployment with Key Vault integration. Certificate is imported as a proper KV certificate via a deployment script (using `az keyvault certificate import`). The App Gateway retrieves the certificate's backing secret via a managed identity. No storage account is defined in the template — Azure automatically provisions a temporary managed storage account behind the scenes for the deployment script container (see [Known Limitations](#known-limitations)). |
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
- **Cross-resource-group** subnet deployment — the VNet can be in a different resource group (same subscription)
- **Subnet upsert** — the subnet is created if it doesn't exist, or updated if it does
- **Diagnostic logging** — WAF firewall and access logs sent to a Log Analytics Workspace
- **Deployment script certificate import** — PFX imported as a proper KV certificate (expiry tracking, Event Grid, easy renewal)
- **Certificate expiry email notification** (optional) — When `certExpiryNotificationEmail` is provided, the template deploys three additional resources to deliver email alerts 30 days before the certificate expires:
  - **Action Group** (`ag-cert-expiry`) — defines the email receiver
  - **Event Grid System Topic** (`<kvName>-evgt`) — listens for events on the Key Vault
  - **Event Grid Subscription** (`cert-near-expiry`) — filters for `Microsoft.KeyVault.CertificateNearExpiry` events and routes them as Azure Monitor alerts to the action group, which sends the email

  These resources are only deployed when `certExpiryNotificationEmail` is set. Without them, Key Vault fires the expiry event internally but no notification is delivered.

> **Note:** The Application Gateway itself is a Layer 7 load balancer. No separate Azure Load Balancer is deployed or required by this module.

---

## Parameters

### Key Vault variant (`appGW_custom_deployment_kv.bicep`)

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `vnetName` | **Yes** | — | Name of the existing VNet |
| `vnetResourceGroupName` | **Yes** | — | Resource group of the VNet (can be different from the App GW resource group) |
| `appGwSubnetAddressPrefix` | **Yes** | — | Subnet CIDR, e.g. `10.0.3.0/24` |
| `exchangeBackendIPs` | **Yes** | — | Array of backend server IPs |
| `mailFqdn` | **Yes** | — | Mail FQDN, e.g. `mail.contoso.com` |
| `autodiscoverFqdn` | **Yes** | — | Autodiscover FQDN |
| `sslCertData` | **Yes** | — | Base64-encoded PFX certificate |
| `sslCertPassword` | No | _(empty)_ | PFX password. Leave empty if re-exported without password |
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
| `certExpiryNotificationEmail` | No | _(empty)_ | Email to receive certificate expiry notifications (30 days before). Leave empty to skip |
| `deployAppGateway` | No | `true` | Set to `false` to deploy **only** the NSG and subnet (no Key Vault, cert, App GW, or diagnostics) |

> **Tip:** When `deployAppGateway` is set to `false`, the following resources are **not** deployed: Key Vault, Managed Identity, RBAC role assignments, deployment script, Event Grid topic, Log Analytics Workspace, Public IP, WAF Policy, Application Gateway, and diagnostic settings. Only the NSG and subnet association module runs.

### Inline variant (`appGW_custom_deployment.bicep`)

Same as above except:
- No Key Vault, managed identity, or certificate expiry parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `deployAppGateway` | No | `true` | Set to `false` to deploy **only** the NSG and subnet (no Application Gateway) |

---

## Deployment

### Prerequisites

- An existing **VNet** in the **same subscription and Azure region** as the Application Gateway (the subnet will be created automatically)
- A **PFX certificate** with SANs matching `mailFqdn` and `autodiscoverFqdn`

> **Important — Subscription and Region constraints:**
> - The Application Gateway **must be in the same subscription** as its VNet/subnet. Cross-subscription VNet references are **not supported** by the Application Gateway resource provider.
> - The Application Gateway **must be in the same Azure region** as the VNet.
> - The App GW resource group and VNet resource group can be **different** (cross-resource-group is supported within the same subscription).

#### What about cross-subscription backends?

While the App Gateway and its subnet must be in the **same subscription**, backend servers can be in a **different subscription** as long as:

- The VNets are **peered** (same region)
- The backend pool references **private IPs** or **FQDNs** reachable via the peered VNet
- Network routing between the subnets is configured correctly

```text
Subscription A                    Subscription B
├─ RG: rg-appgw                  ├─ RG: rg-servers
│  ├─ VNet-AppGW (peered) ◄────► │  ├─ VNet-Backend (peered)
│  │  └─ snet-appgw              │  │  └─ snet-servers
│  │     └─ Application Gateway  │  │     ├─ Exchange Server 1
│  │                             │  │     └─ Exchange Server 2
│  ├─ Key Vault                  │
│  ├─ Public IP                  │
│  └─ WAF Policy                 │
```

#### Required RBAC Permissions

| Scope | Role | When needed |
|-------|------|-------------|
| App Gateway resource group | **Contributor** | Always |
| VNet resource group (same subscription) | **Network Contributor** | When VNet is in a different resource group |
| App Gateway subscription | **User Access Administrator** or **Owner** | To create RBAC role assignments for Key Vault |

The Key Vault variant uses a deployment script (`Microsoft.Resources/deploymentScripts`) to import the PFX as a proper Key Vault certificate. No storage account is defined in the Bicep template itself — however, Azure automatically provisions a temporary managed storage account behind the scenes for the deployment script's container (Azure Container Instances). This auto-provisioned storage account can conflict with Azure Policies that enforce `allowSharedKeyAccess: false` (see [Known Limitations](#known-limitations)).

### 1. Base64-encode the PFX certificate

The Key Vault variant uses a deployment script to import the PFX as a proper Key Vault certificate via `az keyvault certificate import`. You can pass either a **password-protected** or **password-free** PFX — the deployment script handles both cases.

> **Note:** If you pass a password-protected PFX, provide the password via the `sslCertPassword` parameter. If the PFX has no password, leave `sslCertPassword` empty (the default).

#### Base64-encode the PFX

**PowerShell:**

```powershell
$certBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\to\your-cert.pfx"))
```

**Linux / macOS:**

```bash
certBase64=$(base64 -w 0 your-cert.pfx)
# On macOS: certBase64=$(base64 -i your-cert.pfx)
```

#### (Optional) Re-export without password

If you prefer not to pass the PFX password as a deployment parameter, you can re-export the certificate without a password first:

#### Option A: PowerShell (Windows)

```powershell
$pfxPassword = ConvertTo-SecureString -String "YourPfxPassword" -Force -AsPlainText
$collection = [System.Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
$collection.Import("C:\path\to\your-cert.pfx", $pfxPassword, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
$pfxBytes = $collection.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx)
$certBase64 = [Convert]::ToBase64String($pfxBytes)
```

#### Option B: OpenSSL (Linux / macOS / Windows with OpenSSL)

```bash
# Step 1: Extract cert + key to PEM (enter the PFX password when prompted)
openssl pkcs12 -in your-cert.pfx -out temp.pem -nodes

# Step 2: Re-package as password-free PFX
openssl pkcs12 -in temp.pem -export -out no-password.pfx -passout pass:

# Step 3: Base64-encode
certBase64=$(base64 -w 0 no-password.pfx)

# Clean up
rm -f temp.pem
```

> On macOS, use `base64 -i no-password.pfx` instead of `base64 -w 0`.

#### Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `Schlüssel ist im angegebenen Status nicht gültig` / `Key is not valid in the specified state` | Private key was imported as **non-exportable** | Import the PFX with `-Exportable` flag: `Import-PfxCertificate -FilePath cert.pfx -CertStoreLocation Cert:\CurrentUser\My -Password $pwd -Exportable`, then export from the cert store |
| `Das angegebene Netzwerkkennwort ist falsch` / `The specified network password is incorrect` | Wrong PFX password | Verify the password. Use `ConvertTo-SecureString` instead of `Read-Host -AsSecureString` to avoid terminal encoding issues with special characters |
| `certBase64` length is **116 chars** or less | Export produced an empty PFX (no private key) | The Import failed silently. Check for errors in the previous step. Ensure the password is correct and the `Exportable` flag is set |
| OpenSSL: `unable to load private key` | PFX uses a newer encryption algorithm not supported by older OpenSSL | Upgrade OpenSSL to 3.x, or add `-legacy` flag: `openssl pkcs12 -in cert.pfx -out temp.pem -nodes -legacy` |

> **Note:** The private key must be loaded with the `Exportable` flag so it can be re-exported without a password. The resulting `$certBase64` contains a password-free PFX that the Application Gateway can consume directly from Key Vault.
>
> If you're using the **inline variant** (`appGW_custom_deployment.bicep`), you can pass the original password-protected PFX with `sslCertPassword` instead — no re-export needed.

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
  -sslCertPassword "YourPfxPassword" `
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

### 4. Post-deployment: Verify the certificate in Key Vault

The deployment script automatically imports the PFX as a proper Key Vault **certificate**. After deployment, verify it in the Azure Portal under **Key Vault → Certificates**, or via CLI:

```powershell
az keyvault certificate show --vault-name "kv-appgw-xxxx" --name "exchange-cert" --query "{name:name, expires:attributes.expires, thumbprint:x509ThumbprintHex}"
```

**Benefits of the deployment script approach:**
- Certificate expiry date visible in the Azure Portal under **Certificates** (not just Secrets)
- Event Grid events: `Microsoft.KeyVault.CertificateNearExpiry` (30 days before expiry)
- Easy renewal workflow (see below)

#### Manual import fallback (if the deployment script fails)

If the deployment script fails (e.g., due to an Azure Policy blocking shared key access on storage accounts — see [Known Limitations](#known-limitations)), the deployment will **stop before creating the Application Gateway**. All prerequisite resources (Key Vault, Managed Identity, RBAC assignments, NSG, subnet, PIP, WAF policy) will already exist.

**Recovery steps:**

1. Grant yourself **Key Vault Certificates Officer** on the Key Vault (see [Grant yourself Key Vault access](#grant-yourself-key-vault-access)).

2. Import the certificate manually into the Key Vault that was created:

```powershell
az keyvault certificate import `
  --vault-name "kv-appgw-xxxx" `
  --name "exchange-cert" `
  --file "C:\path\to\your-cert.pfx" `
  --password "YourPfxPassword"
```

3. **Redeploy the same template without providing `sslCertData`** (leave it empty). Since `sslCertData` is empty, the deployment script is **automatically skipped**, so the `allowSharedKeyAccess` policy will not block the deployment. The Application Gateway and all remaining resources will be created using the certificate you imported manually.

> **Note:** If the deployment script partially ran and created a Key Vault **secret** (not certificate) with the same name, you must delete and purge it first:
>
> ```powershell
> az keyvault secret delete --vault-name "kv-appgw-xxxx" --name "exchange-cert"
> Start-Sleep -Seconds 10
> az keyvault secret purge --vault-name "kv-appgw-xxxx" --name "exchange-cert"
> ```
>
> Then import the certificate (step 2 above).

> You need **Key Vault Secrets Officer** and **Key Vault Certificates Officer** roles to perform these steps.

#### Grant yourself Key Vault access

The deployment only grants the **managed identity** access. To view or manage certificates in the portal:

```powershell
$kvName = "kv-appgw-xxxx"  # replace with your actual Key Vault name
$kv = Get-AzKeyVault -VaultName $kvName
$userId = (Get-AzADUser -SignedIn).Id
New-AzRoleAssignment -ObjectId $userId -RoleDefinitionName "Key Vault Certificates Officer" -Scope $kv.ResourceId
```

> **Note:** RBAC role assignments can take up to **5 minutes** to propagate.

### 5. Certificate renewal

When the certificate is near expiry, renew it by importing the new PFX with the **same name**:

```powershell
az keyvault certificate import `
  --vault-name "kv-appgw-xxxx" `
  --name "exchange-cert" `
  --file "C:\path\to\new-cert.pfx" `
  --password "NewPfxPassword"
```

Key Vault creates a **new version** of the certificate (and its backing secret). The Application Gateway **automatically picks up the new certificate within 4 hours** — no redeployment, no restart, no listener changes needed.

```text
Timeline:
  ┌─────────────────────────────────────────────────────────┐
  │  1. Import new PFX → KV creates new cert version        │
  │  2. Wait up to 4 hours (App GW polling interval)        │
  │  3. App GW automatically binds new cert to listeners    │
  │  4. Old cert version remains in KV (can be purged)      │
  └─────────────────────────────────────────────────────────┘
```

> **Tip:** If you need the new certificate applied immediately (not wait 4 hours), you can trigger an App Gateway restart via the Azure Portal or `az network application-gateway stop/start`.

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
| Certificate storage | Azure Key Vault (proper certificate) | Embedded in ARM deployment |
| Certificate import | Deployment script (`az keyvault certificate import`) | Inline PFX in App GW config |
| Secret exposure | No secrets in parameter files (secure params) | PFX data + password passed at deploy time |
| Certificate renewal | AppGW refreshes from KV every 4 hours | Requires redeployment |
| Expiry notification | Built-in via Event Grid + email (if `certExpiryNotificationEmail` set) | Not available |
| Complexity | Moderate (managed identity, RBAC, deployment script) | Lower |
| Policy compatibility | May conflict with `allowSharedKeyAccess: false` policy (see below) | No restrictions |
| Recommendation | **Production** | Dev/test only |

---

## Known Limitations

### Deployment script and `allowSharedKeyAccess` policy

The Key Vault variant uses a `Microsoft.Resources/deploymentScripts` resource to import the PFX certificate into Key Vault. The deployment script service automatically provisions a managed storage account for its execution container (Azure Container Instances).

**If your subscription or resource group has an Azure Policy that enforces `allowSharedKeyAccess: false` on storage accounts**, the deployment script will fail because the auto-provisioned storage account uses shared key access.

**Symptoms:**
- Deployment fails at the `import-pfx-to-keyvault` deployment script resource.
- Error message references `allowSharedKeyAccess` or storage account creation failure.

**Workarounds (choose one):**

1. **Option A — Exempt the resource group** from the `allowSharedKeyAccess` policy during deployment, then re-enable it after the deployment completes. This allows the deployment script to run normally.
2. **Option B — Manual import + redeploy without `sslCertData`** (no policy change needed):
   1. Import the certificate manually into Key Vault:
      ```powershell
      az keyvault certificate import `
        --vault-name "kv-appgw-xxxx" `
        --name "exchange-cert" `
        --file "C:\path\to\your-cert.pfx" `
        --password "YourPfxPassword"
      ```
      > You may need to grant yourself **Key Vault Certificates Officer** first (see [Grant yourself Key Vault access](#grant-yourself-key-vault-access)).
   2. **Redeploy the same template without providing `sslCertData`** (leave it empty). The deployment script is automatically skipped when `sslCertData` is empty, so the `allowSharedKeyAccess` policy will not block the deployment. All other resources (App Gateway, WAF, diagnostics, Event Grid notifications) will be created normally, using the certificate you imported manually.
3. **Option C — Use the inline variant** (`appGW_custom_deployment.bicep`) which does not use deployment scripts or storage accounts.

---

## Rebuilding the ARM Templates

After editing any `.bicep` file, regenerate the compiled JSON:

```bash
bicep build appGW_custom_deployment_kv.bicep
bicep build appGW_custom_deployment.bicep
```

The `appGW_nsg_subnet_association.bicep` module is automatically inlined into both JSON outputs — no separate build needed.
