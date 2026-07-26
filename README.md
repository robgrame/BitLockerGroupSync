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
[![CI](https://img.shields.io/github/actions/workflow/status/robgrame/Nimbus.BitLockerGroupSync/ci.yml?branch=main&style=flat-square&logo=githubactions&logoColor=white&label=CI)](https://github.com/robgrame/Nimbus.BitLockerGroupSync/actions)
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

Il runbook crea (se assente) e riconcilia **in modo idempotente** il gruppo principale
**Encrypted**. Gli altri tre gruppi sono **opzionali** e disattivati di default: si abilitano
singolarmente tramite gli appositi flag.

| 🏷️ Gruppo | 📋 Contenuto | 🎯 Uso tipico | Stato |
|---|---|---|---|
| `…-Encrypted` | Device con `isEncrypted = true` | Conformità / reportistica | ✅ **Sempre attivo** |
| `…-NotEncrypted` | Device con `isEncrypted = false` | Remediation / policy di cifratura | ⚪ Opzionale (`EnableNotEncryptedGroup`) |
| `…-KeyEscrowed` | Device con recovery key salvata in Entra | Prova di escrow / audit | ⚪ Opzionale (`EnableKeyEscrowedGroup`) |
| `…-KeyMissing` | Device **cifrati** ma **senza** recovery key | ⚠️ Rischio: nessun recupero possibile | ⚪ Opzionale (`EnableKeyMissingGroup`) |

> Il prefisso (`SG-Intune-BitLocker` di default) è parametrico. In alternativa è possibile
> definire il **nome completo** di ciascun gruppo con i parametri `EncryptedGroupName`,
> `NotEncryptedGroupName`, `KeyEscrowedGroupName`, `KeyMissingGroupName` (se vuoti, il nome
> viene derivato dal prefisso).

> 💡 Il recupero delle recovery key da Graph avviene **solo** se almeno uno tra il gruppo
> `KeyEscrowed`, `KeyMissing` o l'alert soglia è attivo: con la sola configurazione di
> default (solo Encrypted) la chiamata viene saltata per efficienza.

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
| `Device.ReadWrite.All` | Risolvere `deviceId → objectId` **e** aggiungere i device come membri dei gruppi |
| `Group.Create` | Creare i gruppi di sicurezza gestiti |
| `GroupMember.ReadWrite.All` | Leggere/aggiornare la membership dei gruppi |

> 🔒 **Least privilege**: nessun `Group.ReadWrite.All`. Solo creazione gruppi + gestione membership.
> `Device.ReadWrite.All` è **richiesto da Graph** per aggiungere oggetti *device* a un gruppo (app-only).

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
| `encryptedGroupName` | *(vuoto → `<prefix>-Encrypted`)* | Nome esplicito gruppo Encrypted |
| `notEncryptedGroupName` | *(vuoto → `<prefix>-NotEncrypted`)* | Nome esplicito gruppo NotEncrypted |
| `keyEscrowedGroupName` | *(vuoto → `<prefix>-KeyEscrowed`)* | Nome esplicito gruppo KeyEscrowed |
| `keyMissingGroupName` | *(vuoto → `<prefix>-KeyMissing`)* | Nome esplicito gruppo KeyMissing |
| `enableNotEncryptedGroup` | `false` | Abilita il gruppo NotEncrypted (opzionale) |
| `enableKeyEscrowedGroup` | `false` | Abilita il gruppo KeyEscrowed (opzionale) |
| `enableKeyMissingGroup` | `false` | Abilita il gruppo KeyMissing (opzionale) |
| `targetOperatingSystem` | `Windows` | Filtro OS device |
| `scheduleIntervalHours` | `6` | Cadenza esecuzione |
| `deployLogAnalytics` | `true` | Crea LA + diagnostica |

---

## 🖥️ Runbook — parametri runtime

| Parametro | Default | Descrizione |
|---|---|---|
| `GroupPrefix` | `SG-Intune-BitLocker` | Prefisso dei gruppi |
| `EncryptedGroupName` | *(vuoto → `<prefix>-Encrypted`)* | Nome esplicito gruppo Encrypted |
| `NotEncryptedGroupName` | *(vuoto → `<prefix>-NotEncrypted`)* | Nome esplicito gruppo NotEncrypted |
| `KeyEscrowedGroupName` | *(vuoto → `<prefix>-KeyEscrowed`)* | Nome esplicito gruppo KeyEscrowed |
| `KeyMissingGroupName` | *(vuoto → `<prefix>-KeyMissing`)* | Nome esplicito gruppo KeyMissing |
| `EnableNotEncryptedGroup` | `false` | Abilita il gruppo NotEncrypted (opzionale) |
| `EnableKeyEscrowedGroup` | `false` | Abilita il gruppo KeyEscrowed (opzionale) |
| `EnableKeyMissingGroup` | `false` | Abilita il gruppo KeyMissing (opzionale) |
| `TargetOperatingSystem` | `Windows` | OS dei device valutati |
| `WhatIfOnly` | `$false` | Simulazione senza modifiche |
| `UserAssignedClientId` | *(vuoto)* | Client id di una UAMI (opz.) |
| `KeyMissingAlertThreshold` | `0` | Soglia device cifrati senza key oltre cui inviare alert (0 = off) |
| `AlertWebhookUrl` | *(vuoto)* | Webhook per l'alert soglia (fallback: variable `BitLockerSyncAlertWebhook`) |
| `NotifyWebhookUrl` | *(vuoto)* | Webhook di notifica a ogni run (fallback: variable `BitLockerSyncNotifyWebhook`) |

---

## 🔔 Webhook & notifiche

La soluzione supporta **tre** meccanismi (tutti opzionali):

| Tipo | Direzione | Scopo |
|---|---|---|
| 📣 **Notify webhook** | outbound | A **ogni run** invia il riepilogo JSON (`sync.completed`) ai subscriber (Teams/Logic App/SIEM) |
| 🚨 **Alert webhook** | outbound | Invia un alert solo quando `KeyMissing ≥ KeyMissingAlertThreshold` |
| ▶️ **Trigger webhook** | inbound | URL HTTP `POST` per **avviare** una sync on-demand |

Gli URL outbound si passano come parametro **oppure** come Automation variable cifrata
(`BitLockerSyncNotifyWebhook` / `BitLockerSyncAlertWebhook`), create automaticamente dal Bicep
se valorizzi `notifyWebhookUrl` / `alertWebhookUrl`.

Il **trigger webhook** si crea con:

```powershell
.\deploy.ps1 -ResourceGroupName rg-bitlocker -CreateTriggerWebhook
# L'URI viene mostrato UNA SOLA VOLTA: salvalo subito.
```

Esempio payload di notifica:

```json
{
  "solution": "Nimbus.BitLockerGroupSync",
  "event": "sync.completed",
  "encrypted": 812, "notEncrypted": 14,
  "keyEscrowed": 799, "keyMissing": 13,
  "timestamp": "2026-07-24T17:05:00.000Z"
}
```

---

## 📡 Monitoraggio & alerting (nativo Azure)

Oltre ai webhook applicativi (che scattano solo se il runbook **arriva in fondo**), la
soluzione include un monitoraggio **nativo Azure** indipendente dal runbook, che copre anche
i casi in cui il runbook **non parte** o **crasha**. Tutto è opt-in via `deployMonitoring`
(richiede `deployLogAnalytics = true`) e si basa sui diagnostic log (`JobLogs` + `JobStreams`)
già inviati al workspace Log Analytics.

```mermaid
flowchart LR
    RB["📜 Runbook"] --> LAW["📊 Log Analytics<br/>(JobLogs / JobStreams)"]
    LAW --> A1["🔴 Job Failed/Suspended"]
    LAW --> A2["🟠 Error nel runbook"]
    LAW --> A3["⚫ Dead-man's switch"]
    A1 & A2 & A3 --> AG["📢 Action Group"]
    AG --> MAIL["✉️ Email"]
    AG --> HOOK["🔗 Teams / Logic App"]
    LAW --> WB["📊 Workbook"]
```

### 🔔 Alert rules

| Alert | Trigger (KQL) | Finestra / Freq. | Severità |
|---|---|---|---|
| 🔴 **Job Failed/Suspended** | `JobLogs` con `ResultType in (Failed, Suspended, Stopped)` | 15 min / 5 min | Sev1 |
| 🟠 **Errore nel runbook** | `JobStreams` con `StreamType = Error` o messaggio `[ERROR]` | 15 min / 5 min | Sev2 |
| ⚫ **Dead-man's switch** | 0 job `Completed` nella finestra (schedule off, MI/Graph down, mai avviato) | 12 h / 1 h | Sev1 |

> 💡 Il **dead-man's switch** è la rete di sicurezza chiave: intercetta i problemi che i
> webhook applicativi **non** possono segnalare (perché il runbook non gira). La finestra
> accetta solo i valori supportati da Azure Monitor: `2, 3, 4, 5, 6, 12, 24, 48` ore.

### 📢 Action Group & Workbook

- **Action Group** `ag-bitlocker-sync`: invia gli alert a una o più **email** (`alertEmails`)
  e, se abilitata la Logic App Teams (o valorizzato `alertActionWebhookUrl`), a un **webhook**.
- **Workbook** *Nimbus.BitLockerGroupSync - Monitoring*: dashboard con trend degli esiti job,
  ultimi job, errori recenti e righe di riepilogo.

### 💬 Notifiche Teams (Logic App)

Una **Logic App (Consumption)** opzionale (`deployTeamsLogicApp`) fa da *traduttore* tra
l'Action Group e Teams: riceve il *common alert schema*, lo formatta in una **Adaptive Card**
e la posta al canale.

```mermaid
flowchart LR
    AG["📢 Action Group"] -->|common alert schema| LA["⚙️ Logic App<br/>logic-bitlocker-teams"]
    LA -->|Adaptive Card| TEAMS["💬 Canale Teams"]
```

- Il wiring **Action Group → Logic App** è automatico (`listCallbackUrl` → `serviceUri` del
  webhook): non serve incollare URL manualmente.
- L'unico valore da fornire è l'**URL di destinazione Teams** (`teamsWebhookUrl`), di tipo
  **Workflows / Power Automate** (in Teams: canale → *…* → **Workflows** → *"Post to a channel
  when a webhook request is received"*).
- Se `teamsWebhookUrl` è **vuoto**, la Logic App viene comunque distribuita ma **non invia**
  (una condizione salta il POST): puoi impostare l'URL in seguito con un redeploy, senza
  toccare il resto.

| Parametro | Default | Descrizione |
|---|---|---|
| `deployTeamsLogicApp` | `false` | Crea la Logic App di notifica Teams |
| `teamsLogicAppName` | `logic-bitlocker-teams` | Nome della Logic App |
| `teamsWebhookUrl` | *(vuoto)* | URL Workflows del canale Teams (vuoto = POST disabilitato) |

#### 🔗 Come ottenere l'URL del canale Teams (Workflows)

> [!NOTE]
> L'URL **non si genera via script**: è un endpoint legato al canale/tenant e all'identità
> di chi lo crea, quindi si ottiene una tantum dalla UI. Microsoft ha sostituito i vecchi
> *Incoming Webhook connector* (in ritiro) con i flussi **Workflows / Power Automate**.

1. In Teams apri il **canale** che deve ricevere le notifiche.
2. Clicca sui **⋯** (More options) accanto al nome del canale → **Workflows**
   (in alternativa: app **Workflows** dalla barra laterale, oppure *Power Automate*).
3. Cerca e seleziona il template **“Post to a channel when a webhook request is received”**
   (in italiano *“Pubblica in un canale quando viene ricevuta una richiesta webhook”*).
4. Conferma/accedi con l'account (serve il consenso), poi scegli **Team** e **Canale** di
   destinazione.
5. Completa la creazione: il flusso mostra un **URL HTTP POST** — è quello di `teamsWebhookUrl`.
   Copialo subito (puoi comunque recuperarlo riaprendo il flusso in Power Automate → trigger
   *“When a Teams webhook request is received”*).
6. Incolla l'URL in [`bicep/main.bicepparam`](bicep/main.bicepparam):

   ```bicep
   param deployTeamsLogicApp = true
   param teamsWebhookUrl = 'https://prod-XX.westeurope.logic.azure.com:443/workflows/.../triggers/manual/paths/invoke?...&sig=...'
   ```

7. Ridistribuisci lo stack (solo la Logic App viene aggiornata, il resto è idempotente):

   ```bash
   az deployment group create -g RG-BLKGM -f bicep/main.bicep -p bicep/main.bicepparam
   ```

> [!TIP]
> **Test rapido senza aspettare un alert reale**: invia un payload di esempio al trigger della
> Logic App (recuperi l'URL con `Get-AzLogicAppTriggerCallbackUrl -ResourceGroupName RG-BLKGM
> -Name logic-bitlocker-teams -TriggerName manual`) con un body in *common alert schema*
> (`{ "schemaId":"azureMonitorCommonAlertSchema", "data":{ "essentials":{ ... } } }`) e
> verifica che la card arrivi nel canale.

### ⚙️ Parametri di monitoraggio (Bicep)

| Parametro | Default | Descrizione |
|---|---|---|
| `deployMonitoring` | `true` | Crea Action Group + alert rules + workbook |
| `alertEmails` | `[]` | Email destinatarie degli alert |
| `alertActionWebhookUrl` | *(vuoto)* | Webhook Teams/Logic App per gli alert |
| `enableFailedAlert` | `true` | Alert job Failed/Suspended |
| `enableErrorAlert` | `true` | Alert errori nello stream |
| `enableDeadmanAlert` | `true` | Dead-man's switch |
| `deadmanWindowHours` | `12` | Finestra dead-man's switch (valori: 2,3,4,5,6,12,24,48) |
| `deployWorkbook` | `true` | Crea il workbook dashboard |

---

## ⚡ Ottimizzazioni per grandi tenant

- 🧮 **Scritture in `$batch`**: add via `PATCH members@odata.bind` (chunk da 20), remove via JSON `$batch` con **retry dei subrequest falliti**.
- 🧹 **Filtro stale/retired**: esclude device in `retirePending/retireIssued/wipePending/wipeIssued/...` prima della valutazione.
- 🔁 **Retry sulla replica**: ritenta il `400 Bad Request` dei gruppi appena creati e attende la propagazione.
- ⏱️ **Throttling-aware**: retry con backoff esponenziale e rispetto di `Retry-After`.
- 🧾 **Esito verificabile**: se una riconciliazione lascia errori, il job **fallisce** e la notifica riporta `sync.completed_with_errors`.

> ℹ️ La *delta query* è stata valutata ma **non adottata**: Intune non espone un endpoint delta
> supportato per `managedDevices` e il modello di riconciliazione richiede comunque lo stato completo
> a ogni run. Il full sync con `$select` + `$batch` è la scelta corretta e più robusta.

---

## 🤖 CI/CD & assegnazione permessi

- ✅ **GitHub Actions** (`.github/workflows/ci.yml`): `bicep build` + **PSScriptAnalyzer** + **Pester**.
- 🔐 **Assegnazione permessi automatica** (opt-in): `assignGraphPermissions=true` +
  `permissionGrantIdentityId`/`permissionGrantIdentityClientId` usa un `deploymentScript` per assegnare
  gli app role Graph (richiede una UAMI con `AppRoleAssignment.ReadWrite.All`). In alternativa, lo
  script manuale [`Grant-GraphPermissions.ps1`](scripts/Grant-GraphPermissions.ps1).

---

## 🛡️ Security

- ✅ **Zero segreti**: solo managed identity, nessuna app registration con client secret.
- ✅ **Least privilege**: nessun `Group.ReadWrite.All`; solo `Group.Create` + `GroupMember.ReadWrite.All` + i read scoperti.
- ✅ **Idempotente**: calcola il diff e applica solo le differenze.
- ✅ **Auditabile**: log verbosi + Log Analytics opzionale.

---

## 🔍 Troubleshooting

| Sintomo | Causa probabile | Rimedio |
|---|---|---|
| `Insufficient privileges` | Permessi Graph non propagati | Attendere qualche minuto / rilanciare lo script permessi |
| `403` su add device | Manca `Device.ReadWrite.All` | Assegnare l'app role e attendere la propagazione |
| `400` add su gruppo nuovo | Replica del gruppo in corso | Gestito automaticamente con retry; riprovare al run successivo |
| `Modulo Microsoft.Graph.Authentication non disponibile` | Modulo non importato | Verificare la risorsa `powerShell72Modules` |
| Device non aggiunti | `azureADDeviceId` assente o device non in Entra | Verificare Entra join / registrazione |
| Molti in `NonRisolti` | Mismatch deviceId ↔ objectId | Verificare sync Intune/Entra |
| Le run **schedulate** gestiscono solo il gruppo Encrypted dopo aver abilitato i gruppi opzionali | I jobSchedule di Azure Automation sono **immutabili**: un redeploy non aggiorna i `parameters` del link esistente | Rimuovere e ricreare il jobSchedule: `Unregister-AzAutomationScheduledRunbook -JobScheduleId <id> -Force` poi `Register-AzAutomationScheduledRunbook -RunbookName <rb> -ScheduleName <sch> -Parameters @{ EnableNotEncryptedGroup='true'; EnableKeyEscrowedGroup='true'; EnableKeyMissingGroup='true' }` |

---

## 💡 Advisory & miglioramenti futuri

- 📊 Emissione di metriche custom su Log Analytics + alert nativi su crescita di `KeyMissing`.
- 🗃️ Persistenza dello storico esiti (Storage Table) per trend e reportistica.
- 🔗 Trigger event-driven da Intune/Entra tramite Logic App verso il webhook di trigger.
- 🧪 Ampliamento della suite Pester con mock delle chiamate Graph.

---

## 📂 Struttura del repository

```
Nimbus.BitLockerGroupSync/
├── runbook/   Sync-BitLockerComplianceGroups.ps1   # 📜 Logica del runbook
├── bicep/     main.bicep + main.bicepparam         # 🧱 Infrastructure as Code
│              graphPermissions.bicep               # 🔐 Modulo deploymentScript (opt-in)
├── scripts/   Grant-GraphPermissions.ps1           # 🔐 Assegnazione app role Graph (manuale)
├── tests/     Solution.Tests.ps1                   # 🧪 Test Pester
├── .github/workflows/ci.yml                        # 🤖 CI (bicep + PSSA + Pester)
├── PSScriptAnalyzerSettings.psd1                   # 🔎 Regole linter
├── deploy.ps1                                       # 🚀 Orchestratore end-to-end
└── docs/                                            # 📚 Documentazione aggiuntiva
```

---

## 📜 License

Distribuito con licenza **MIT**. Vedi [`LICENSE`](LICENSE).

<div align="center">

Made with ❤️ for secure endpoints · **Nimbus** suite

</div>
