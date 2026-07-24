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

@description('Prefisso per il naming dei gruppi Entra gestiti dal runbook.')
param groupPrefix string = 'SG-Intune-BitLocker'

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
      TargetOperatingSystem: targetOperatingSystem
    }
  }
  dependsOn: [
    runbook
    schedule
  ]
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

@description('Principal Id della system-assigned managed identity: usarlo per assegnare i permessi Graph.')
output managedIdentityPrincipalId string = automationAccount.identity.principalId

@description('Nome dell\'Automation Account creato.')
output automationAccountName string = automationAccount.name

@description('Nome del runbook creato.')
output runbookName string = runbook.name
