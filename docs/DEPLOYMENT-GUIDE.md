# Guida di deployment Azure + Microsoft Entra

Questa guida descrive il deployment riproducibile di **Nimbus.BitLockerGroupSync**
tramite `deploy.ps1`, inclusi prerequisiti, ruoli, configurazione, verifica e handover.

## 1. Architettura distribuita

Lo script crea o configura:

- Azure CLI, Bicep CLI e moduli PowerShell richiesti, se mancanti;
- resource group Azure;
- UAMI dedicata alla soluzione e collegata all'Automation Account;
- modulo `Microsoft.Graph.Authentication`;
- runbook PowerShell 7.2 e schedule;
- Log Analytics e diagnostic settings;
- Action Group, alert rules e workbook, se abilitati;
- Logic App per Teams, se abilitata;
- bozza email EML per la richiesta controllata degli app role Microsoft Graph;
- webhook di avvio e prima esecuzione, se richiesti.

L'autenticazione runtime è selezionabile: UAMI dedicata oppure App Registration
con certificato o client secret.

## 2. Ruoli e separazione delle responsabilita

La mail cliente pronta per la raccolta dei prerequisiti è disponibile in
[`Customer-Deployment-Prerequisites.eml`](Customer-Deployment-Prerequisites.eml).
Aprirla come bozza, compilare i campi contrassegnati e aggiornare mittente,
destinatario e firma prima dell'invio.

La procedura operativa completa da inviare agli amministratori è disponibile in
[`Customer-Deployment-Instructions.eml`](Customer-Deployment-Instructions.eml).

| Soggetto | Ruolo minimo | Ambito | Utilizzo |
|---|---|---|---|
| Operatore Azure | `Contributor` | Subscription | Necessario se `deploy.ps1` deve creare il resource group |
| Operatore Azure | `Contributor` | Resource group esistente | Sufficiente con resource provider già registrati e `-SkipProviderRegistration` |
| Amministratore Entra | `Privileged Role Administrator` | Tenant Entra | Approva e assegna gli app role Microsoft Graph con procedura controllata |
| Creatore workflow Teams | Permesso di creare Workflows/Power Automate nel Team e canale | Teams/Power Platform | Necessario solo per le notifiche Teams |
| Managed identity runtime | App role Graph elencati sotto | Microsoft Graph | Esecuzione del runbook |
| App Registration runtime | Application permission Graph elencate sotto | Microsoft Graph | Alternativa alla managed identity |

`Global Administrator` puo eseguire le operazioni Entra, ma non e necessario.
Per il principio di minimo privilegio usare `Privileged Role Administrator`.

### App role Graph della managed identity runtime

- `DeviceManagementManagedDevices.Read.All`
- `BitlockerKey.Read.All`
- `Device.ReadWrite.All`
- `Group.Create`
- `GroupMember.ReadWrite.All`

`Device.ReadWrite.All` e richiesto da Microsoft Graph per aggiungere oggetti device
ai gruppi con autorizzazione application.

## 3. Modalità di autenticazione Graph

| `AuthenticationMode` | Credenziale runtime | Collocazione credenziale | Indicazione |
|---|---|---|---|
| `ManagedIdentity` | UAMI dedicata creata dal deployment | Azure Instance Metadata Service | Modalità raccomandata: identità stabile, isolata e senza credenziali |
| `AppRegistrationCertificate` | Certificato PFX | Automation Certificate cifrato e non esportabile | Modalità App Registration raccomandata |
| `AppRegistrationSecret` | Client secret | Automation Variable cifrata | Compatibilità; richiede rotazione periodica |

La schedule contiene soltanto identificatori, nomi degli asset e modalità di
autenticazione. Non contiene PFX, password o client secret.

Per gli esempi completi di configurazione del file `.bicepparam`, vedere
[`AUTHENTICATION-PARAMETERS.md`](AUTHENTICATION-PARAMETERS.md).

### Managed Identity

La modalità standard usa una **UAMI dedicata alla soluzione**, creata da Bicep e
collegata automaticamente all'Automation Account. È preferita alla
system-assigned managed identity perché:

- mantiene client ID e principal ID stabili se l'Automation Account viene
  sostituito o ricreato;
- separa il ciclo di vita dell'identità da quello del workload;
- permette di assegnare e verificare le permission prima dell'attivazione del
  runbook;
- non introduce secret o certificati;
- resta isolata dalla altre applicazioni perché non deve essere condivisa.

Il runbook riceve automaticamente il client ID della UAMI e usa
`Connect-MgGraph -Identity -ClientId`. Le permission Graph vengono assegnate al
principal ID restituito dal deployment.

### App Registration con certificato

Prerequisiti:

1. App Registration esistente nel tenant;
2. certificato pubblico caricato in **Certificati e segreti → Certificati**;
3. PFX corrispondente con private key, consegnato tramite canale sicuro;
4. password PFX disponibile come `SecureString`.

Lo script importa o aggiorna il PFX come Automation Certificate non esportabile.

### App Registration con client secret

Il valore viene passato a `deploy.ps1` come `SecureString` e trasferito a Bicep
come parametro sicuro. Bicep lo salva in una Automation Variable con
`isEncrypted=true`. Il valore non viene inserito nella schedule o nella mail.

### Scope delegati della procedura amministrativa Managed Identity

Quando l'amministratore esegue `Grant-GraphPermissions.ps1`, vengono richiesti:

- `Application.Read.All`
- `AppRoleAssignment.ReadWrite.All`

Questi scope sono usati solo durante l'assegnazione iniziale degli app role. Il
deployment standard non li richiede all'operatore Azure.

## 4. Prerequisiti tecnici

### Tenant e licenze

- tenant Microsoft Entra con device registrati;
- Microsoft Intune attivo e device gestiti;
- BitLocker e recovery key disponibili in Entra per le viste escrow;
- subscription Azure attiva;
- accesso a Microsoft Graph, Azure Resource Manager e PowerShell Gallery.

### Postazione di deployment

- Windows 10/11 o Windows Server con Windows PowerShell;
- diritto di installare applicazioni per Azure CLI;
- Git, solo se la repository deve ancora essere clonata;
- accesso HTTPS verso:
  - `management.azure.com`;
  - `login.microsoftonline.com`;
  - `graph.microsoft.com`;
  - `www.powershellgallery.com` e `aka.ms`;
  - endpoint WinGet, se disponibile;
  - host configurato in `runbookContentUri`.

Non è necessario installare manualmente Azure CLI, Bicep o i moduli Az: per
impostazione predefinita `deploy.ps1` esegue il bootstrap seguente:

1. installa Azure CLI con WinGet;
2. usa il pacchetto MSI ufficiale Microsoft se WinGet non è disponibile;
3. installa o aggiorna Bicep tramite `az bicep install`;
4. installa da PowerShell Gallery `Az.Accounts`, `Az.Resources` e `Az.Automation`;
5. installa i moduli Microsoft Graph solo se si usa `-GrantGraphPermissions`.

`-SkipBootstrap` è riservato a workstation già predisposte e gestite.

### Resource provider

Lo script registra automaticamente:

- `Microsoft.Automation`
- `Microsoft.ManagedIdentity`
- `Microsoft.OperationalInsights`
- `Microsoft.Insights`
- `Microsoft.Logic`, se si usa Teams
- `Microsoft.Resources`

La registrazione richiede autorizzazione a livello subscription. In ambienti dove
i provider sono già registrati e l'operatore dispone solo di accesso al resource
group, usare `-SkipProviderRegistration`.

## 5. Preparazione dei parametri cliente

Clonare la repository e creare un file locale non versionato:

```powershell
git clone https://github.com/robgrame/Nimbus.BitLockerGroupSync.git
Set-Location .\Nimbus.BitLockerGroupSync

Copy-Item .\bicep\main.bicepparam .\bicep\customer.local.bicepparam
```

I file `bicep/*.local.bicepparam` sono esclusi da Git.

Personalizzare almeno:

| Parametro | Indicazione |
|---|---|
| `location` | Region approvata dal cliente |
| `automationAccountName` | Nome univoco nel resource group |
| `runbookContentUri` | URL HTTPS raggiungibile da Azure Automation |
| `groupPrefix` o nomi espliciti | Naming convention Entra del cliente |
| `enable*Group` | Gruppi effettivamente richiesti |
| `enableKeyEscrowCheck` | `false` se il controllo recovery key non deve essere eseguito |
| `scheduleIntervalHours` | Frequenza concordata |
| `alertEmails` | Destinatari operativi |
| `deployTeamsLogicApp` | Abilitare solo dopo aver ottenuto il webhook Teams |
| `teamsWebhookUrl` | URL Workflows del canale Teams |
| `enableMembershipDetailLogging` | Abilita la vista workbook dei device aggiunti |
| `tags` | Cost center, owner, environment e classificazione cliente |
| `authenticationMode` | Managed Identity, certificato o secret |
| `managedIdentityName` | Nome della UAMI dedicata creata dal deployment |
| `appTenantId` / `appClientId` | Identificatori App Registration |
| `certificateAssetName` | Nome Automation Certificate |
| `graphCredentialVariableName` | Nome Automation Variable cifrata |

### Sorgente del runbook

`runbookContentUri` deve essere raggiungibile pubblicamente dal servizio Azure
Automation. Per produzione non usare un branch mutabile come `main`.

Usare uno dei seguenti modelli:

1. repository cliente con tag di release immutabile;
2. URL raw vincolato a un commit SHA;
3. storage account cliente con artefatto versionato e accesso controllato.

La versione del runbook deve essere registrata nel verbale di handover.

### Gestione dei webhook

Gli URL Teams, Logic App e Automation webhook sono segreti operativi:

- non inserirli nel file `main.bicepparam` versionato;
- usare esclusivamente il file `customer.local.bicepparam`;
- non copiarli in ticket, log o documentazione condivisa;
- salvare l'Automation trigger webhook al momento della creazione: l'URI viene
  mostrato una sola volta.

## 6. Deployment assistito in due fasi

Raccogliere:

```powershell
$TenantId = '<tenant-guid>'
$SubscriptionId = '<subscription-guid>'
$ResourceGroupName = 'rg-bitlocker-groupsync-prod'
$Location = 'westeurope'
```

### Fase 1 - Provisioning

Eseguire da PowerShell:

```powershell
.\deploy.ps1 `
    -ResourceGroupName $ResourceGroupName `
    -Location $Location `
    -TenantId $TenantId `
    -SubscriptionId $SubscriptionId `
    -ParameterFile .\bicep\customer.local.bicepparam
```

Lo script:

1. installa automaticamente Azure CLI, Bicep e moduli PowerShell mancanti;
2. richiede un unico login Azure con device code;
3. seleziona e verifica tenant e subscription;
4. crea il resource group, se assente;
5. esegue validazione ARM/Bicep e `what-if`;
6. distribuisce l'infrastruttura con schedule e dead-man alert disabilitati;
7. blocca webhook e avvio runbook finché le permission non sono confermate.

`-SkipWhatIf` deve essere usato solo in procedure di emergenza approvate.

Le mail per il cliente sono documenti di consegna separati, disponibili nella
cartella `templates`. Non vengono generate né modificate dal deployment.
Aprendo il file EML appropriato in Outlook è possibile aggiornare mittente,
destinatario, campi contrassegnati, testo e firma prima dell'invio.

### Esempio con UAMI dedicata

```powershell
.\deploy.ps1 `
    -ResourceGroupName $ResourceGroupName `
    -Location $Location `
    -TenantId $TenantId `
    -SubscriptionId $SubscriptionId `
    -ParameterFile .\bicep\customer.local.bicepparam
```

Bicep crea la UAMI, la collega all'Automation Account e restituisce resource ID,
client ID e principal ID. La modalità e il nome della UAMI vengono sempre letti
dal file `.bicepparam`, che costituisce l'unica fonte di configurazione per
entrambe le fasi.

### Esempio App Registration con certificato

```powershell
$pfxPassword = Read-Host 'Password PFX' -AsSecureString

.\deploy.ps1 `
    -ResourceGroupName $ResourceGroupName `
    -Location $Location `
    -TenantId $TenantId `
    -SubscriptionId $SubscriptionId `
    -ParameterFile .\bicep\customer.local.bicepparam `
    -AppCertificatePfxPath 'C:\Secure\NimbusGraphAuth.pfx' `
    -AppCertificatePfxPassword $pfxPassword
```

### Esempio App Registration con client secret

```powershell
$appSecret = Read-Host 'Client secret App Registration' -AsSecureString

.\deploy.ps1 `
    -ResourceGroupName $ResourceGroupName `
    -Location $Location `
    -TenantId $TenantId `
    -SubscriptionId $SubscriptionId `
    -ParameterFile .\bicep\customer.local.bicepparam `
    -AppClientSecret $appSecret
```

### Fase 2 - Attivazione dopo approvazione Entra

Dopo la conferma scritta dell'amministratore:

```powershell
.\deploy.ps1 `
    -ResourceGroupName $ResourceGroupName `
    -Location $Location `
    -TenantId $TenantId `
    -SubscriptionId $SubscriptionId `
    -ParameterFile .\bicep\customer.local.bicepparam `
    -SkipBootstrap `
    -PermissionsConfirmed `
    -StartJobNow
```

Il secondo passaggio abilita schedule e dead-man alert, quindi avvia il primo job
con gli stessi parametri runtime della schedule.

### Webhook di avvio opzionale

Crearlo solo nella seconda fase:

```powershell
.\deploy.ps1 `
    -ResourceGroupName $ResourceGroupName `
    -Location $Location `
    -TenantId $TenantId `
    -SubscriptionId $SubscriptionId `
    -ParameterFile .\bicep\customer.local.bicepparam `
    -SkipBootstrap `
    -PermissionsConfirmed `
    -CreateTriggerWebhook
```

Il webhook eredita gli stessi parametri runtime configurati per la schedule.

## 7. Procedura controllata Microsoft Entra

### App Registration: procedura interamente dal portale

La bozza `Entra-AppRegistration-Permissions-Request.eml` guida
l'amministratore attraverso:

1. **Identità → Applicazioni → Registrazioni app → Tutte le applicazioni**;
2. ricerca tramite Application client ID;
3. **Autorizzazioni API → Aggiungi un'autorizzazione**;
4. **Microsoft Graph → Autorizzazioni applicazione**;
5. selezione delle cinque permission;
6. **Concedi consenso amministratore**;
7. verifica dello stato **Concesso**.

Per il certificato, il file pubblico `.cer` deve essere caricato in
**Certificati e segreti → Certificati**. Il PFX e la relativa password non devono
essere inviati via email.

Per il client secret, il valore deve essere consegnato tramite il canale sicuro
concordato e inserito direttamente nella variabile `SecureString` usata dal
deployment.

### Managed Identity: procedura ibrida

#### Limite del portale

Microsoft documenta che non è attualmente possibile aggiungere application
permission Microsoft Graph a una managed identity esclusivamente dal Microsoft
Entra admin center. Il processo supportato è quindi:

1. identificazione della managed identity dal portale Entra;
2. assegnazione esplicita via Microsoft Graph PowerShell da parte del PRA;
3. verifica finale delle permission dal portale Entra;
4. conferma formale via email.

#### Identificazione nel portale Entra

1. Aprire [Microsoft Entra admin center](https://entra.microsoft.com).
2. Selezionare **Identità → Applicazioni → Applicazioni aziendali**.
3. Impostare **Tipo applicazione = Identità gestite**.
4. Cercare il nome dell'Automation Account.
5. Verificare che **ID oggetto** coincida con quello riportato nella mail EML.

#### Assegnazione amministrativa

Da una postazione amministrativa o da Azure Cloud Shell PowerShell, il
`Privileged Role Administrator` esegue dal pacchetto consegnato:

```powershell
.\scripts\Grant-GraphPermissions.ps1 `
    -ManagedIdentityPrincipalId '<object-id-dalla-mail>' `
    -TenantId $TenantId `
    -UseDeviceCode
```

Lo script è idempotente e non crea secret. Dopo alcuni minuti, tornare
all'applicazione aziendale e verificare in **Sicurezza → Autorizzazioni** le
cinque permission richieste.

#### Alternativa integrata

Solo quando policy e ruoli lo consentono, l'operatore può eseguire provisioning e
grant nello stesso flusso con `-GrantGraphPermissions`. Questa modalità richiede
un secondo login device-code con privilegi Entra e non è il percorso cliente
predefinito.

## 8. Verifica post-deployment

### Azure

Verificare:

- deployment ARM in stato `Succeeded`;
- Automation Account con managed identity abilitata;
- runbook pubblicato come PowerShell 7.2;
- modulo Graph disponibile;
- schedule abilitata;
- diagnostic settings collegati a Log Analytics;
- alert rules e Action Group abilitati;
- workbook accessibile.

### Microsoft Entra

Per Managed Identity, verificare nel service principal i cinque app role Graph.
Per App Registration, verificare in **Autorizzazioni API** che le cinque
application permission risultino concesse. Se si usa un certificato, controllare
thumbprint e scadenza; se si usa un secret, registrarene owner e data di rotazione.

### Esecuzione funzionale

Avviare un job con gli stessi parametri della configurazione cliente:

```powershell
.\deploy.ps1 `
    -ResourceGroupName $ResourceGroupName `
    -Location $Location `
    -TenantId $TenantId `
    -SubscriptionId $SubscriptionId `
    -ParameterFile .\bicep\customer.local.bicepparam `
    -SkipBootstrap `
    -PermissionsConfirmed `
    -StartJobNow
```

Il job deve terminare `Completed` e i gruppi Entra devono contenere i device attesi.

### Workbook

Dopo il tempo di ingestion di Log Analytics, verificare:

- esito job nel tempo;
- ultimi job;
- errori recenti;
- righe di riepilogo;
- **Device aggiunti ai gruppi**, con data/ora, gruppo, nome device, object ID e job.

La vista di dettaglio contiene solo aggiunte realmente eseguite dopo l'abilitazione di
`enableMembershipDetailLogging`.

## 9. Aggiornamenti e redeploy

I `jobSchedule` di Azure Automation sono immutabili. Dopo preflight e `what-if`,
`deploy.ps1` rimuove automaticamente il collegamento esistente e Bicep lo ricrea
con l'intero set aggiornato di parametri runtime, incluso il client ID della UAMI.
Non è quindi richiesta una procedura manuale durante upgrade o migrazione.

## 10. Rollback e dismissione

### Rollback applicativo

1. ripristinare il precedente `runbookContentUri`;
2. ripristinare il precedente file parametri;
3. rieseguire `deploy.ps1`;
4. ricreare il collegamento schedule se sono cambiati parametri runtime;
5. avviare un job controllato e verificare i gruppi.

### Dismissione

Prima di eliminare il resource group:

- disabilitare schedule e webhook;
- esportare log e workbook richiesti dalla retention cliente;
- rimuovere gli app role Graph dalla managed identity;
- decidere se mantenere o eliminare i gruppi Entra creati;
- revocare o eliminare i workflow Teams;
- ottenere approvazione formale del cliente.

Per revocare esclusivamente gli app role gestiti dalla soluzione prima di
eliminare o sostituire la UAMI:

```powershell
.\scripts\Grant-GraphPermissions.ps1 `
    -ManagedIdentityPrincipalId '<uami-principal-id>' `
    -TenantId $TenantId `
    -UseDeviceCode `
    -Revoke
```

Dopo la revoca, scollegare la UAMI dall'Automation Account ed eliminare la
risorsa. Un deployment incrementale non elimina automaticamente una UAMI
precedente quando cambia il nome dell'identità o la modalità di autenticazione.

## 11. Checklist di handover

- tenant ID e subscription ID registrati;
- resource group, region e naming approvati;
- file parametri cliente archiviato in posizione sicura;
- URI e versione immutabile del runbook registrati;
- matrice ruoli Azure/Entra approvata;
- modalità di autenticazione registrata;
- owner e scadenza di certificato/secret registrati, se applicabile;
- bozza EML compilata, inviata e archiviata;
- app role Graph verificati;
- primo job completato;
- membership dei gruppi campionata;
- alert email testato;
- Teams testato, se abilitato;
- workbook e vista device aggiunti verificati;
- owner operativo e owner Entra nominati;
- procedura di aggiornamento schedule consegnata;
- rollback e dismissione approvati;
- webhook e segreti consegnati tramite canale sicuro.

## Riferimenti Microsoft

- [Deploy Bicep con Azure PowerShell](https://learn.microsoft.com/azure/azure-resource-manager/bicep/deploy-powershell)
- [ARM/Bicep what-if](https://learn.microsoft.com/azure/azure-resource-manager/bicep/deploy-what-if)
- [Managed identity in Azure Automation](https://learn.microsoft.com/azure/automation/enable-managed-identity-for-automation)
- [Installare Azure CLI su Windows](https://learn.microsoft.com/cli/azure/install-azure-cli-windows)
- [Installare Bicep](https://learn.microsoft.com/azure/azure-resource-manager/bicep/install)
- [Aggiungere membri device a un gruppo con Microsoft Graph](https://learn.microsoft.com/graph/api/group-post-members)
- [App role assignment per service principal](https://learn.microsoft.com/graph/api/serviceprincipal-post-approleassignments)
- [Microsoft Graph da managed identity: assegnazione permission](https://learn.microsoft.com/entra/identity-platform/tutorial-v2-javascript-auth-code)
