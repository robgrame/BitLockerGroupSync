// =============================================================================
//  Nimbus.BitLockerGroupSync - main.bicep
//  Deploya un Azure Automation Account (system-assigned MI), il modulo Graph,
//  il runbook, una schedule ricorrente e (opzionale) Log Analytics.
// =============================================================================

targetScope = 'resourceGroup'

@description('Azure region per tutte le risorse.')
param location string = resourceGroup().location

@description('Nome dell\'Automation Account.')
param automationAccountName string = 'aa-bitlocker-groupsync'

@description('Nome del runbook.')
param runbookName string = 'Sync-BitLockerComplianceGroups'

@description('URL raw (pubblico) del file .ps1 del runbook. Es. raw.githubusercontent.com/.../Sync-BitLockerComplianceGroups.ps1')
param runbookContentUri string

@description('Prefisso per il naming dei gruppi Entra gestiti dal runbook (usato quando i nomi espliciti sono vuoti).')
param groupPrefix string = 'SG-Intune-BitLocker'

@description('Nome del gruppo PRINCIPALE (device cifrati). Vuoto = derivato da groupPrefix.')
param encryptedGroupName string = ''

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
param enableKeyEscrowCheck bool = true

@description('Sistema operativo target dei device Intune.')
param targetOperatingSystem string = 'Windows'

@description('Intervallo (in ore) tra le esecuzioni schedulate.')
@minValue(1)
@maxValue(24)
param scheduleIntervalHours int = 6

@description('Data/ora di primo avvio della schedule (UTC, ISO 8601). Default: +15 minuti.')
param scheduleStartTime string = dateTimeAdd(utcNow(), 'PT15M')

@description('Se true crea un workspace Log Analytics e collega la diagnostica.')
param deployLogAnalytics bool = true

@description('Se true crea il monitoraggio nativo (Action Group + alert rules + workbook). Richiede deployLogAnalytics=true.')
param deployMonitoring bool = true

@description('Indirizzi email a cui inviare gli alert di monitoraggio.')
param alertEmails array = []

@description('URL webhook (Teams/Logic App) a cui inoltrare gli alert. Vuoto = disabilitato.')
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

@description('Se true crea la Logic App che formatta e inoltra gli alert a Teams. Richiede deployMonitoring=true.')
param deployTeamsLogicApp bool = false

@description('Nome della Logic App di notifica Teams.')
param teamsLogicAppName string = 'logic-bitlocker-teams'

@description('URL del canale Teams (Workflows / Power Automate). Vuoto = la Logic App non invia (impostabile in seguito).')
param teamsWebhookUrl string = ''

@description('Soglia di device cifrati senza recovery key oltre la quale inviare alert. 0 = disabilitato.')
@minValue(0)
param keyMissingAlertThreshold int = 0

@description('URL webhook per gli alert soglia (Teams/Logic App). Se valorizzato viene salvato come Automation variable cifrata.')
@secure()
param alertWebhookUrl string = ''

@description('URL webhook di NOTIFICA a ogni run. Se valorizzato viene salvato come Automation variable cifrata.')
@secure()
param notifyWebhookUrl string = ''

@description('Se true assegna automaticamente i permessi Graph alla MI tramite deploymentScript (richiede una UAMI gia abilitata).')
param assignGraphPermissions bool = false

@description('Resource id della user-assigned managed identity (con AppRoleAssignment.ReadWrite.All) usata dal deploymentScript.')
param permissionGrantIdentityId string = ''

@description('Client id della UAMI usata dal deploymentScript.')
param permissionGrantIdentityClientId string = ''

@description('Tag applicati a tutte le risorse.')
param tags object = {
  solution: 'Nimbus.BitLockerGroupSync'
  managedBy: 'bicep'
}

var graphAuthModuleUri = 'https://www.powershellgallery.com/api/v2/package/Microsoft.Graph.Authentication'
var scheduleName = '${runbookName}-every${scheduleIntervalHours}h'

resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: automationAccountName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
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

resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
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
    }
  }
}

resource schedule 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = {
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

// ATTENZIONE: i jobSchedule di Azure Automation sono IMMUTABILI. Il nome è un GUID
// deterministico (runbook+schedule), quindi un redeploy che cambia SOLO i `parameters`
// qui sotto NON aggiorna il link esistente: le run schedulate continueranno a usare i
// parametri con cui il jobSchedule fu creato la prima volta. Per applicare nuovi parametri
// (es. abilitare i gruppi opzionali) bisogna rimuovere e ricreare il jobSchedule, es.:
//   Unregister-AzAutomationScheduledRunbook -JobScheduleId <id> -Force
//   Register-AzAutomationScheduledRunbook -RunbookName <rb> -ScheduleName <sch> -Parameters @{...}
resource jobSchedule 'Microsoft.Automation/automationAccounts/jobSchedules@2023-11-01' = {
  parent: automationAccount
  name: guid(automationAccount.id, runbookName, scheduleName)
  properties: {
    runbook: {
      name: runbookName
    }
    schedule: {
      name: scheduleName
    }
    parameters: {
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
    }
  }
  dependsOn: [
    runbook
    schedule
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

resource notifyWebhookVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (!empty(notifyWebhookUrl)) {
  parent: automationAccount
  name: 'BitLockerSyncNotifyWebhook'
  properties: {
    isEncrypted: true
    value: '"${notifyWebhookUrl}"'
  }
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (deployLogAnalytics) {
  name: '${automationAccountName}-law'
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

// Assegnazione automatica (opt-in) dei permessi Graph alla MI tramite deploymentScript.
module graphPermissions 'graphPermissions.bicep' = if (assignGraphPermissions) {
  name: 'assign-graph-permissions'
  params: {
    location: location
    managedIdentityPrincipalId: automationAccount.identity.principalId
    grantIdentityResourceId: permissionGrantIdentityId
    grantIdentityClientId: permissionGrantIdentityClientId
    tags: tags
  }
}

// Logic App di notifica Teams (opt-in). Formatta il common alert schema in una
// Adaptive Card e la posta al canale Teams.
module teamsLogicApp 'teams-logicapp.bicep' = if (deployMonitoring && deployTeamsLogicApp) {
  name: 'blkgm-teams-logicapp'
  params: {
    location: location
    name: teamsLogicAppName
    teamsWebhookUrl: teamsWebhookUrl
    tags: tags
  }
}

// Monitoraggio nativo: Action Group + alert rules + workbook (opt-in).
module monitoring 'monitoring.bicep' = if (deployMonitoring && deployLogAnalytics) {
  name: 'blkgm-monitoring'
  params: {
    location: location
    logAnalyticsWorkspaceId: logAnalytics.id
    runbookName: runbookName
    alertEmails: alertEmails
    alertActionWebhookUrl: (deployMonitoring && deployTeamsLogicApp) ? teamsLogicApp!.outputs.triggerUrl : alertActionWebhookUrl
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

@description('Principal Id della system-assigned managed identity: usarlo per assegnare i permessi Graph.')
output managedIdentityPrincipalId string = automationAccount.identity.principalId

@description('Nome dell\'Automation Account creato.')
output automationAccountName string = automationAccount.name

@description('Nome del runbook creato.')
output runbookName string = runbook.name
