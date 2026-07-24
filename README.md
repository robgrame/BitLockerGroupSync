<div align="center">

# 🔐 Nimbus.BitLockerGroupSync

### Dynamic Entra ID security groups driven by Intune BitLocker encryption state & recovery-key escrow

[![PowerShell](https://img.shields.io/badge/PowerShell-7.2-5391FE?style=for-the-badge&logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/)
[![Bicep](https://img.shields.io/badge/Bicep-IaC-00BCF2?style=for-the-badge&logo=microsoftazure&logoColor=white)](https://learn.microsoft.com/azure/azure-resource-manager/bicep/)
[![Azure Automation](https://img.shields.io/badge/Azure_Automation-Runbook-0078D4?style=for-the-badge&logo=microsoftazure&logoColor=white)](https://learn.microsoft.com/azure/automation/)
[![Microsoft Graph](https://img.shields.io/badge/Microsoft_Graph-API-2C2C32?style=for-the-badge&logo=microsoft&logoColor=white)](https://learn.microsoft.com/graph/)
[![Microsoft Intune](https://img.shields.io/badge/Microsoft_Intune-MDM-0078D4?style=for-the-badge&logo=microsoft&logoColor=white)](https://learn.microsoft.com/mem/intune/)
[![Microsoft Entra ID](https://img.shields.io/badge/Microsoft_Entra_ID-Identity-0067B8?style=for-the-badge&logo=microsoftentraid&logoColor=white)](https://learn.microsoft.com/entra/)

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg?style=flat-square)](LICENSE)
[![Managed Identity](https://img.shields.io/badge/Auth-Managed_Identity-brightgreen?style=flat-square&logo=microsoftazure)](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/)
[![Zero Secrets](https://img.shields.io/badge/Secrets-Zero-success?style=flat-square&logo=keepassxc)](#-security)
[![IaC Ready](https://img.shields.io/badge/Deploy-One_Command-blueviolet?style=flat-square)](#-deployment)

</div>

---

## 📖 Overview

**Nimbus.BitLockerGroupSync** è un runbook di **Azure Automation** (PowerShell 7.2) che
crea e mantiene **dinamicamente** gruppi di sicurezza in **Microsoft Entra ID** basandosi su
proprietà dei device gestiti da **Microsoft Intune** che i gruppi dinamici nativi di Entra
**non** possono valutare:

- 💽 **`isEncrypted`** — il disco del device è cifrato con BitLocker.
- 🔑 **BitLocker recovery key** — esiste almeno una recovery key salvata (escrow) su Entra ID.

L'autenticazione a Microsoft Graph avviene **esclusivamente tramite la managed identity**
dell'Automation Account (app-only, **zero segreti**).

> [!NOTE]
> I gruppi dinamici di Entra ID non sanno leggere lo stato di cifratura Intune né la
> presenza di una recovery key. Questo runbook colma esattamente quel gap.

---

## 🧩 Gruppi gestiti

Il runbook crea (se assenti) e riconcilia **in modo idempotente** questi 4 gruppi:

| 🏷️ Gruppo | 📋 Contenuto | 🎯 Uso tipico |
|---|---|---|
| `…-Encrypted` | Device con `isEncrypted = true` | Conformità / reportistica |
| `…-NotEncrypted` | Device con `isEncrypted = false` | Remediation / policy di cifratura |
| `…-KeyEscrowed` | Device con recovery key salvata in Entra | Prova di escrow / audit |
| `…-KeyMissing` | Device **cifrati** ma **senza** recovery key | ⚠️ Rischio: nessun recupero possibile |

> Il prefisso (`SG-Intune-BitLocker` di default) è parametrico.

---

## 🏗️ Architettura

```mermaid
flowchart LR
    subgraph AZ["☁️ Azure"]
        SCH["⏰ Schedule (ogni 6h)"] --> RB["📜 Runbook PS 7.2"]
        MI(["🪪 Managed Identity"]) -.app-only.-> RB
        RB --> LAW["📊 Log Analytics"]
    end
    subgraph GRAPH["🌐 Microsoft Graph"]
        INT["📱 Intune managedDevices<br/>(isEncrypted)"]
        BLK["🔑 bitlocker/recoveryKeys"]
        DEV["💻 Entra devices"]
        GRP["👥 Entra groups"]
    end
    RB -->|read| INT
    RB -->|read| BLK
    RB -->|read| DEV
    RB -->|read/write membership| GRP
```

**Flusso:** la schedule avvia il runbook → il runbook si autentica con la managed identity →
legge i device Intune, le recovery key e gli oggetti device Entra → calcola gli insiemi
desiderati → riconcilia (add/remove) la membership dei gruppi.

---

## 🔐 Permessi Graph richiesti (application)

Assegnati alla managed identity dallo script [`Grant-GraphPermissions.ps1`](scripts/Grant-GraphPermissions.ps1):

| Permesso | Scopo |
|---|---|
| `DeviceManagementManagedDevices.Read.All` | Leggere i managed device Intune |
| `BitlockerKey.Read.All` | Elencare le BitLocker recovery key |
| `Device.Read.All` | Risolvere `deviceId → objectId` degli oggetti device Entra |
| `Group.ReadWrite.All` | Creare i gruppi e gestirne i membri |

> [!IMPORTANT]
> Gli **app role di Graph non sono RBAC di Azure** e non si assegnano via Bicep/ARM.
> Vanno concessi una tantum con lo script dedicato da un **Privileged Role Administrator**.

---

## 🚀 Deployment

### Prerequisiti

- 🧰 Azure CLI (`az`) **oppure** Azure PowerShell (`Az`)
- 🔑 Ruoli: *Contributor* sulla subscription + *Privileged Role Administrator* su Entra
- 📦 Moduli: `Microsoft.Graph.Authentication`, `Microsoft.Graph.Applications` (per lo script permessi)

### ⚡ One-command deploy

```powershell
.\deploy.ps1 -ResourceGroupName 'rg-bitlocker' -Location 'westeurope' -StartJobNow
```

Lo script: crea il resource group → deploya il Bicep → assegna i permessi Graph → (opz.) avvia un job.

### 🧱 Deploy manuale (Azure CLI)

```bash
az group create -n rg-bitlocker -l westeurope
az deployment group create \
  -g rg-bitlocker \
  -f bicep/main.bicep \
  -p bicep/main.bicepparam

# principalId dagli output, poi:
pwsh ./scripts/Grant-GraphPermissions.ps1 -ManagedIdentityPrincipalId <principalId>
```

---

## ⚙️ Parametri principali

| Parametro | Default | Descrizione |
|---|---|---|
| `location` | `westeurope` | Region delle risorse |
| `automationAccountName` | `aa-bitlocker-groupsync` | Nome Automation Account |
| `runbookContentUri` | *(raw GitHub URL)* | Sorgente del runbook `.ps1` |
| `groupPrefix` | `SG-Intune-BitLocker` | Prefisso naming gruppi |
| `targetOperatingSystem` | `Windows` | Filtro OS device |
| `scheduleIntervalHours` | `6` | Cadenza esecuzione |
| `deployLogAnalytics` | `true` | Crea LA + diagnostica |

---

## 🖥️ Runbook — parametri runtime

| Parametro | Default | Descrizione |
|---|---|---|
| `GroupPrefix` | `SG-Intune-BitLocker` | Prefisso dei gruppi |
| `TargetOperatingSystem` | `Windows` | OS dei device valutati |
| `WhatIfOnly` | `$false` | Simulazione senza modifiche |
| `UserAssignedClientId` | *(vuoto)* | Client id di una UAMI (opz.) |

---

## 🛡️ Security

- ✅ **Zero segreti**: solo managed identity, nessuna app registration con client secret.
- ✅ **Least privilege**: permessi di sola lettura tranne `Group.ReadWrite.All`.
- ✅ **Idempotente**: calcola il diff e applica solo le differenze.
- ✅ **Auditabile**: log verbosi + Log Analytics opzionale.

---

## 🔍 Troubleshooting

| Sintomo | Causa probabile | Rimedio |
|---|---|---|
| `Insufficient privileges` | Permessi Graph non propagati | Attendere qualche minuto / rilanciare lo script permessi |
| `Modulo Microsoft.Graph.Authentication non disponibile` | Modulo non importato | Verificare la risorsa `powerShell72Modules` |
| Device non aggiunti | `azureADDeviceId` assente o device non in Entra | Verificare Entra join / registrazione |
| Molti in `NonRisolti` | Mismatch deviceId ↔ objectId | Verificare sync Intune/Entra |

---

## 💡 Advisory & miglioramenti futuri

- 🔁 `$batch` di Graph e **delta query** per tenant di grandi dimensioni.
- 🧮 Batch membership (fino a 20 `members@odata.bind` per PATCH) per ridurre le chiamate.
- 🧹 Gestione device *stale/retired* con rimozione automatica.
- 📈 Alerting su crescita del gruppo `KeyMissing` (rischio compliance).
- 🧪 Test Pester + validazione `az bicep build` in CI (GitHub Actions).

---

## 📂 Struttura del repository

```
Nimbus.BitLockerGroupSync/
├── runbook/   Sync-BitLockerComplianceGroups.ps1   # 📜 Logica del runbook
├── bicep/     main.bicep + main.bicepparam         # 🧱 Infrastructure as Code
├── scripts/   Grant-GraphPermissions.ps1           # 🔐 Assegnazione app role Graph
├── deploy.ps1                                       # 🚀 Orchestratore end-to-end
└── docs/                                            # 📚 Documentazione aggiuntiva
```

---

## 📜 License

Distribuito con licenza **MIT**. Vedi [`LICENSE`](LICENSE).

<div align="center">

Made with ❤️ for secure endpoints · **Nimbus** suite

</div>
