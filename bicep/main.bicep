// =============================================================================
//  Nimbus.BitLockerGroupSync - main.bicep
//  Deploya un Azure Automation Account con UAMI dedicata, il modulo Graph,
//  il runbook, una schedule ricorrente e (opzionale) Log Analytics.
// =============================================================================

targetScope = 'resourceGroup'

@description('Azure region per tutte le risorse.')
param location string = resourceGroup().location

@description('Nome dell\'Automation Account.')
param automationAccountName string = 'aa-bitlocker-groupsync'

@description('Nome del workspace Log Analytics. Separato dall\'Automation Account per consentire rename controllati.')
param logAnalyticsWorkspaceName string = '${automationAccountName}-law'

@description('Nome del runbook.')
param runbookName string = 'Sync-BitLockerComplianceGroups'

@description('URL raw (pubblico) del file .ps1 del runbook. Es. raw.githubusercontent.com/.../Sync-BitLockerComplianceGroups.ps1')
param runbookContentUri string

@description('Se true distribuisce il runbook di sincronizzazione dei gruppi Entra.')
param deployGroupSyncRunbook bool = true

@description('Se true distribuisce il runbook che sincronizza lo stato BitLocker in un extension attribute Entra.')
param deployExtensionAttributeRunbook bool = false

@description('URL raw (pubblico) del runbook di sincronizzazione extension attribute.')
param extensionAttributeRunbookContentUri string = 'https://raw.githubusercontent.com/robgrame/Nimbus.BitLockerGroupSync/main/runbook/Sync-BitLockerExtensionAttribute.ps1'

@description('Extension attribute Entra aggiornato dal secondo runbook.')
@allowed([
  'extensionAttribute1'
  'extensionAttribute2'
  'extensionAttribute3'
  'extensionAttribute4'
  'extensionAttribute5'
  'extensionAttribute6'
  'extensionAttribute7'
  'extensionAttribute8'
  'extensionAttribute9'
  'extensionAttribute10'
  'extensionAttribute11'
  'extensionAttribute12'
  'extensionAttribute13'
  'extensionAttribute14'
  'extensionAttribute15'
])
param extensionAttributeName string = 'extensionAttribute10'

@description('Valore assegnato ai device cifrati.')
param extensionAttributeEncryptedValue string = 'enc'

@description('Valore assegnato ai device non cifrati.')
param extensionAttributeNotEncryptedValue string = 'notenc'

@description('Consente di sovrascrivere valori non vuoti diversi da quelli gestiti. Abilitare solo dopo verifica ownership dell\'attributo.')
param extensionAttributeAllowValueTakeover bool = false

@description('Se true azzera i valori gestiti sui device che non rientrano piu nel perimetro Intune/OS.')
param clearManagedValuesForOutOfScopeDevices bool = false

@description('Intervallo in ore del runbook extension attribute.')
@minValue(1)
@maxValue(24)
param extensionAttributeScheduleIntervalHours int = 1

@description('Prefisso per il naming dei gruppi Entra gestiti dal runbook (usato quando i nomi espliciti sono vuoti).')
param groupPrefix string = ''

@description('Nome del gruppo PRINCIPALE (device cifrati). Vuoto = derivato da groupPrefix.')
param encryptedGroupName string = 'Intune - BitLocker Encrypted'

@description('Nome del gruppo opzionale device NON cifrati. Vuoto = derivato da groupPrefix.')
param notEncryptedGroupName string = ''

@description('Nome del gruppo opzionale device con recovery key in Entra. Vuoto = derivato da groupPrefix.')
param keyEscrowedGroupName string = ''

@description('Nome del gruppo opzionale device cifrati senza recovery key. Vuoto = derivato da groupPrefix.')
param keyMissingGroupName string = ''

@description('Abilita il gruppo opzionale device NON cifrati.')
param enableNotEncryptedGroup bool = false

@description('Abilita il gruppo opzionale device con recovery key in Entra.')
param enableKeyEscrowedGroup bool = false

@description('Abilita il gruppo opzionale device cifrati senza recovery key.')
param enableKeyMissingGroup bool = false

@description('Master switch della verifica escrow recovery key. false = salta il recupero chiavi e disabilita KeyEscrowed/KeyMissing/alert soglia (il gruppo Encrypted non e\' influenzato).')
param enableKeyEscrowCheck bool = false

@description('Sistema operativo target dei device Intune.')
param targetOperatingSystem string = 'Windows'

@description('Autenticazione Microsoft Graph del runbook.')
@allowed([
  'ManagedIdentity'
  'AppRegistrationCertificate'
  'AppRegistrationSecret'
])
param authenticationMode string = 'ManagedIdentity'

@description('Nome della UAMI dedicata creata e collegata all\'Automation Account in modalita ManagedIdentity.')
param managedIdentityName string = '${automationAccountName}-identity'

@description('Tenant id dell\'App Registration.')
param appTenantId string = ''

@description('Application (client) id dell\'App Registration.')
param appClientId string = ''

@description('Nome dell\'Automation Certificate usato per AppRegistrationCertificate.')
param certificateAssetName string = 'GraphAuthCertificate'

@description('Nome dell\'Automation Variable cifrata usata per AppRegistrationSecret.')
param graphCredentialVariableName string = 'GraphClientSecret'

@description('Client secret dell\'App Registration. Usato solo per creare la Automation Variable cifrata.')
@secure()
param appClientSecret string = ''

@description('Intervallo (in ore) tra le esecuzioni schedulate.')
@minValue(1)
@maxValue(24)
param scheduleIntervalHours int = 1

@description('Data/ora di primo avvio della schedule (UTC, ISO 8601). Default: +15 minuti.')
param scheduleStartTime string = dateTimeAdd(utcNow(), 'PT15M')

@description('Se true crea e collega la schedule. Il deploy assistito la abilita solo dopo la conferma delle permission Entra.')
param enableSchedule bool = true

@description('Se true crea un workspace Log Analytics e collega la diagnostica.')
param deployLogAnalytics bool = true

@description('Se true crea il monitoraggio nativo (Action Group + alert rules + workbook). Richiede deployLogAnalytics=true.')
param deployMonitoring bool = true

@description('Indirizzi email a cui inviare gli alert di monitoraggio.')
param alertEmails array = []

@description('URL webhook (Teams/Logic App) a cui inoltrare gli alert. Vuoto = disabilitato.')
@secure()
param alertActionWebhookUrl string = ''

@description('Abilita l\'alert sui job Failed/Suspended/Stopped.')
param enableFailedAlert bool = true

@description('Abilita l\'alert sugli errori nello stream del runbook.')
param enableErrorAlert bool = true

@description('Abilita il dead-man\'s switch (nessun job completato nella finestra).')
param enableDeadmanAlert bool = true

@description('Finestra (in ore) del dead-man\'s switch. Solo valori supportati da Azure Monitor.')
@allowed([
  2
  3
  4
  5
  6
  12
  24
  48
])
param deadmanWindowHours int = 12

@description('Se true crea il workbook di Azure Monitor.')
param deployWorkbook bool = true

@description('Se true crea la Logic App che formatta e inoltra a Teams sia gli alert Azure Monitor sia le modifiche membership del runbook.')
param deployTeamsLogicApp bool = false

@description('Nome della Logic App di notifica Teams.')
param teamsLogicAppName string = 'logic-bitlocker-teams'

@description('URL del canale Teams (Workflows / Power Automate). Vuoto = la Logic App non invia (impostabile in seguito).')
@secure()
param teamsWebhookUrl string = ''

@description('Soglia di device cifrati senza recovery key oltre la quale inviare alert. 0 = disabilitato.')
@minValue(0)
param keyMissingAlertThreshold int = 0

@description('Se true registra nei JobStreams il dettaglio dei device aggiunti ai gruppi, usato dal workbook.')
param enableMembershipDetailLogging bool = true

@description('URL webhook per gli alert soglia (Teams/Logic App). Se valorizzato viene salvato come Automation variable cifrata.')
@secure()
param alertWebhookUrl string = ''

@description('URL webhook di NOTIFICA a ogni run. Se valorizzato viene salvato come Automation variable cifrata.')
@secure()
param notifyWebhookUrl string = ''

@description('Numero massimo di modifiche membership incluse in una notifica del runbook.')
@minValue(0)
@maxValue(200)
param notificationDetailLimit int = 50

@description('Tag applicati a tutte le risorse.')
param tags object = {
  solution: 'BitLockerGroupSync'
  managedBy: 'bicep'
  version: '1.2.1'
}

var graphAuthModuleUri = 'https://www.powershellgallery.com/api/v2/package/Microsoft.Graph.Authentication'
var scheduleName = '${runbookName}-every${scheduleIntervalHours}h'
var extensionAttributeRunbookName = 'Sync-BitLockerExtensionAttribute'
var extensionAttributeScheduleName = '${extensionAttributeRunbookName}-every${extensionAttributeScheduleIntervalHours}h'
var monitoringPrimaryRunbookName = deployGroupSyncRunbook ? runbookName : extensionAttributeRunbookName
var monitoringSecondaryRunbookName = deployGroupSyncRunbook && deployExtensionAttributeRunbook ? extensionAttributeRunbookName : ''
var runbookParameters = {
  AuthenticationMode: authenticationMode
  ManagedIdentityClientId: authenticationMode == 'ManagedIdentity' ? runtimeIdentity!.properties.clientId : ''
  AppTenantId: appTenantId
  AppClientId: appClientId
  CertificateAssetName: certificateAssetName
  ClientSecretVariableName: graphCredentialVariableName
  GroupPrefix: groupPrefix
  EncryptedGroupName: encryptedGroupName
  NotEncryptedGroupName: notEncryptedGroupName
  KeyEscrowedGroupName: keyEscrowedGroupName
  KeyMissingGroupName: keyMissingGroupName
  EnableNotEncryptedGroup: string(enableNotEncryptedGroup)
  EnableKeyEscrowedGroup: string(enableKeyEscrowedGroup)
  EnableKeyMissingGroup: string(enableKeyMissingGroup)
  EnableKeyEscrowCheck: string(enableKeyEscrowCheck)
  TargetOperatingSystem: targetOperatingSystem
  KeyMissingAlertThreshold: string(keyMissingAlertThreshold)
  NotificationDetailLimit: string(notificationDetailLimit)
  EnableMembershipDetailLogging: string(enableMembershipDetailLogging)
}
var extensionAttributeRunbookParameters = {}
var extensionAttributeRuntimeConfig = {
  AuthenticationMode: authenticationMode
  ManagedIdentityClientId: authenticationMode == 'ManagedIdentity' ? runtimeIdentity!.properties.clientId : ''
  AppTenantId: appTenantId
  AppClientId: appClientId
  CertificateAssetName: certificateAssetName
  ClientSecretVariableName: graphCredentialVariableName
  ExtensionAttributeName: extensionAttributeName
  EncryptedValue: extensionAttributeEncryptedValue
  NotEncryptedValue: extensionAttributeNotEncryptedValue
  TargetOperatingSystem: targetOperatingSystem
  AllowValueTakeover: extensionAttributeAllowValueTakeover
  ClearManagedValuesForOutOfScopeDevices: clearManagedValuesForOutOfScopeDevices
}

resource runtimeIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = if (authenticationMode == 'ManagedIdentity') {
  name: managedIdentityName
  location: location
  tags: tags
}

resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: automationAccountName
  location: location
  tags: tags
  // Il provider Automation interpreta identity.type=None come rimozione di
  // un'identita e fallisce se l'account non esiste ancora. In modalita App
  // Registration la proprieta identity deve quindi essere omessa del tutto.
  identity: authenticationMode == 'ManagedIdentity' ? {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${runtimeIdentity!.id}': {}
    }
  } : null
  properties: {
    sku: {
      name: 'Basic'
    }
    publicNetworkAccess: true
  }
}

resource graphAuthModule 'Microsoft.Automation/automationAccounts/powerShell72Modules@2023-11-01' = {
  parent: automationAccount
  name: 'Microsoft.Graph.Authentication'
  properties: {
    contentLink: {
      uri: graphAuthModuleUri
    }
  }
}

resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = if (deployGroupSyncRunbook) {
  parent: automationAccount
  name: runbookName
  location: location
  tags: tags
  properties: {
    runbookType: 'PowerShell72'
    logProgress: true
    logVerbose: true
    description: 'Sincronizza gruppi Entra in base a isEncrypted (Intune) e presenza recovery key BitLocker.'
    publishContentLink: {
      uri: runbookContentUri
      // Forza Azure Automation a recuperare nuovamente il contenuto anche se l'URI raw non cambia.
      version: deployment().name
    }
  }
}

resource extensionAttributeRunbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = if (deployExtensionAttributeRunbook) {
  parent: automationAccount
  name: extensionAttributeRunbookName
  location: location
  tags: tags
  properties: {
    runbookType: 'PowerShell72'
    logProgress: true
    logVerbose: true
    description: 'Sincronizza isEncrypted di Intune in un extension attribute dei device Entra.'
    publishContentLink: {
      uri: extensionAttributeRunbookContentUri
      version: deployment().name
    }
  }
}

resource schedule 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = if (enableSchedule && deployGroupSyncRunbook) {
  parent: automationAccount
  name: scheduleName
  properties: {
    description: 'Esecuzione ricorrente di ${runbookName}.'
    startTime: scheduleStartTime
    interval: scheduleIntervalHours
    frequency: 'Hour'
    timeZone: 'UTC'
  }
}

resource extensionAttributeSchedule 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = if (enableSchedule && deployExtensionAttributeRunbook) {
  parent: automationAccount
  name: extensionAttributeScheduleName
  properties: {
    description: 'Esecuzione ricorrente di ${extensionAttributeRunbookName}.'
    startTime: dateTimeAdd(scheduleStartTime, 'PT30M')
    interval: extensionAttributeScheduleIntervalHours
    frequency: 'Hour'
    timeZone: 'UTC'
  }
}

// ATTENZIONE: i jobSchedule di Azure Automation sono IMMUTABILI. Il nome è un GUID
// deterministico (runbook+schedule), quindi un redeploy che cambia SOLO i `parameters`
// qui sotto NON aggiorna il link esistente: le run schedulate continueranno a usare i
// parametri con cui il jobSchedule fu creato la prima volta. Per applicare nuovi parametri
// (es. abilitare i gruppi opzionali) bisogna rimuovere e ricreare il jobSchedule, es.:
//   Unregister-AzAutomationScheduledRunbook -JobScheduleId <id> -Force
//   Register-AzAutomationScheduledRunbook -RunbookName <rb> -ScheduleName <sch> -Parameters @{...}
resource jobSchedule 'Microsoft.Automation/automationAccounts/jobSchedules@2023-11-01' = if (enableSchedule && deployGroupSyncRunbook) {
  parent: automationAccount
  // Un ID nuovo evita i conflitti con la tombstone del collegamento appena eliminato.
  name: guid(automationAccount.id, runbookName, scheduleName, deployment().name)
  properties: {
    runbook: {
      name: runbookName
    }
    schedule: {
      name: scheduleName
    }
    parameters: runbookParameters
  }
  dependsOn: [
    runbook
    schedule
  ]
}

resource extensionAttributeJobSchedule 'Microsoft.Automation/automationAccounts/jobSchedules@2023-11-01' = if (enableSchedule && deployExtensionAttributeRunbook) {
  parent: automationAccount
  name: guid(automationAccount.id, extensionAttributeRunbookName, extensionAttributeScheduleName, deployment().name)
  properties: {
    runbook: {
      name: extensionAttributeRunbookName
    }
    schedule: {
      name: extensionAttributeScheduleName
    }
    parameters: extensionAttributeRunbookParameters
  }
  dependsOn: [
    extensionAttributeRunbook
    extensionAttributeSchedule
  ]
}

// Automation variables (cifrate) per i webhook.
resource alertWebhookVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (!empty(alertWebhookUrl)) {
  parent: automationAccount
  name: 'BitLockerSyncAlertWebhook'
  properties: {
    isEncrypted: true
    value: '"${alertWebhookUrl}"'
  }
}

resource notifyWebhookVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (deployTeamsLogicApp || !empty(notifyWebhookUrl)) {
  parent: automationAccount
  name: 'BitLockerSyncNotifyWebhook'
  properties: {
    isEncrypted: true
    // Quando la Logic App e' attiva, il callback firmato viene collegato automaticamente.
    #disable-next-line BCP318
    value: deployTeamsLogicApp ? '"${teamsLogicApp.outputs.triggerUrl}"' : '"${notifyWebhookUrl}"'
  }
}

resource graphClientSecretVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (authenticationMode == 'AppRegistrationSecret' && !empty(appClientSecret)) {
  parent: automationAccount
  name: graphCredentialVariableName
  properties: {
    isEncrypted: true
    value: '"${appClientSecret}"'
  }
}

// Configurazione non sensibile usata dagli avvii manuali. I parametri passati
// esplicitamente (schedule, webhook o Start-AzAutomationRunbook) hanno precedenza.
resource runtimeConfigVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (deployGroupSyncRunbook) {
  parent: automationAccount
  name: 'BitLockerSyncRuntimeConfig'
  properties: {
    isEncrypted: false
    value: string(runbookParameters)
  }
}

resource extensionAttributeRuntimeConfigVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (deployExtensionAttributeRunbook) {
  parent: automationAccount
  name: 'BitLockerExtensionAttributeRuntimeConfig'
  properties: {
    isEncrypted: false
    value: string(extensionAttributeRuntimeConfig)
  }
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (deployLogAnalytics) {
  name: logAnalyticsWorkspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (deployLogAnalytics) {
  name: 'diag-to-law'
  scope: automationAccount
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        category: 'JobLogs'
        enabled: true
      }
      {
        category: 'JobStreams'
        enabled: true
      }
    ]
  }
}

// Logic App di notifica Teams (opt-in). Gestisce sia il common alert schema di
// Azure Monitor sia il payload delle modifiche membership emesso dal runbook.
module teamsLogicApp 'teams-logicapp.bicep' = if (deployTeamsLogicApp) {
  name: 'blkgm-teams-logicapp'
  params: {
    location: location
    name: teamsLogicAppName
    teamsWebhookUrl: teamsWebhookUrl
    tags: tags
  }
}

// Monitoraggio nativo senza Logic App Teams.
module monitoring 'monitoring.bicep' = if (deployMonitoring && deployLogAnalytics && !deployTeamsLogicApp && (deployGroupSyncRunbook || deployExtensionAttributeRunbook)) {
  name: 'blkgm-monitoring'
  params: {
    location: location
    logAnalyticsWorkspaceId: logAnalytics.id
    runbookName: monitoringPrimaryRunbookName
    extensionAttributeRunbookName: monitoringSecondaryRunbookName
    alertEmails: alertEmails
    alertActionWebhookUrl: alertActionWebhookUrl
    enableFailedAlert: enableFailedAlert
    enableErrorAlert: enableErrorAlert
    enableDeadmanAlert: enableDeadmanAlert
    deadmanWindowHours: deadmanWindowHours
    deployWorkbook: deployWorkbook
    tags: tags
  }
  dependsOn: [
    diagnostics
  ]
}

// Monitoraggio nativo con callback protetto della Logic App Teams.
module monitoringWithTeams 'monitoring.bicep' = if (deployMonitoring && deployLogAnalytics && deployTeamsLogicApp && (deployGroupSyncRunbook || deployExtensionAttributeRunbook)) {
  name: 'blkgm-monitoring'
  params: {
    location: location
    logAnalyticsWorkspaceId: logAnalytics.id
    runbookName: monitoringPrimaryRunbookName
    extensionAttributeRunbookName: monitoringSecondaryRunbookName
    alertEmails: alertEmails
    // Le condizioni dei due moduli sono allineate: la Logic App esiste sempre in questo ramo.
    #disable-next-line BCP318
    alertActionWebhookUrl: teamsLogicApp.outputs.triggerUrl
    enableFailedAlert: enableFailedAlert
    enableErrorAlert: enableErrorAlert
    enableDeadmanAlert: enableDeadmanAlert
    deadmanWindowHours: deadmanWindowHours
    deployWorkbook: deployWorkbook
    tags: tags
  }
  dependsOn: [
    diagnostics
  ]
}

@description('Principal Id della UAMI dedicata: usarlo per assegnare i permessi Graph. Vuoto per le modalita App Registration.')
output managedIdentityPrincipalId string = authenticationMode == 'ManagedIdentity' ? runtimeIdentity!.properties.principalId : ''

@description('Client Id della UAMI dedicata usato dal runbook. Vuoto per le modalita App Registration.')
output managedIdentityClientId string = authenticationMode == 'ManagedIdentity' ? runtimeIdentity!.properties.clientId : ''

@description('Resource Id della UAMI dedicata. Vuoto per le modalita App Registration.')
output managedIdentityResourceId string = authenticationMode == 'ManagedIdentity' ? runtimeIdentity!.id : ''

@description('Nome dell\'Automation Account creato.')
output automationAccountName string = automationAccount.name

@description('Nome del runbook creato.')
output runbookName string = deployGroupSyncRunbook ? runbookName : ''

@description('Nome della schedule creata.')
output scheduleName string = deployGroupSyncRunbook ? scheduleName : ''

@description('Parametri runtime usati dalla schedule e dagli avvii orchestrati.')
output runbookParameters object = runbookParameters

@description('Nome del runbook di sincronizzazione extension attribute.')
output extensionAttributeRunbookName string = deployExtensionAttributeRunbook ? extensionAttributeRunbookName : ''

@description('Nome della schedule del runbook extension attribute.')
output extensionAttributeScheduleName string = deployExtensionAttributeRunbook ? extensionAttributeScheduleName : ''

@description('Parametri runtime del runbook extension attribute.')
output extensionAttributeRunbookParameters object = extensionAttributeRunbookParameters
