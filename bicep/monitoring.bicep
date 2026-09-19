// =============================================================================
//  Nimbus.BitLockerGroupSync - monitoring.bicep
//  Monitoraggio nativo Azure per il runbook: Action Group (email + webhook),
//  scheduled query rules (job falliti, errori nello stream, dead-man's switch)
//  e (opzionale) un workbook di Azure Monitor.
//  Richiede un workspace Log Analytics con la diagnostica dell'Automation
//  Account (JobLogs + JobStreams) gia' collegata.
// =============================================================================

targetScope = 'resourceGroup'

@description('Region delle risorse di monitoraggio (di norma quella del workspace).')
param location string

@description('Resource id del workspace Log Analytics con i diagnostic log dell\'Automation Account.')
param logAnalyticsWorkspaceId string

@description('Nome del runbook da monitorare (usato nei filtri KQL).')
param runbookName string

@description('Secondo runbook opzionale da includere negli alert.')
param extensionAttributeRunbookName string = ''

@description('Runbook extension attribute da visualizzare nel workbook dedicato.')
param extensionAttributeWorkbookRunbookName string = ''

@description('Nome dell\'extension attribute visualizzato nel workbook dedicato.')
param extensionAttributeName string = 'extensionAttribute10'

@description('Indirizzi email a cui inviare gli alert.')
param alertEmails array

@description('URL webhook (Teams/Logic App) a cui inoltrare gli alert. Vuoto = disabilitato.')
@secure()
param alertActionWebhookUrl string = ''

@description('Abilita l\'alert sui job Failed/Suspended/Stopped.')
param enableFailedAlert bool = true

@description('Abilita l\'alert sugli errori nello stream del runbook.')
param enableErrorAlert bool = true

@description('Abilita il dead-man\'s switch (nessun job completato nella finestra).')
param enableDeadmanAlert bool = true

@description('Finestra (in ore) del dead-man\'s switch: allerta se non ci sono run completate. Solo valori supportati da Azure Monitor.')
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

@description('Nome breve dell\'Action Group (max 12 caratteri).')
@maxLength(12)
param actionGroupShortName string = 'BLKGMSync'

@description('Tag applicati alle risorse.')
param tags object = {}

// ---------------------------------------------------------------------------
//  Action Group: destinazione centralizzata delle notifiche.
// ---------------------------------------------------------------------------
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-bitlocker-sync'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: actionGroupShortName
    enabled: true
    emailReceivers: [
      for (email, i) in alertEmails: {
        name: 'email${i}'
        emailAddress: email
        useCommonAlertSchema: true
      }
    ]
    webhookReceivers: empty(alertActionWebhookUrl) ? [] : [
      {
        name: 'action-webhook'
        serviceUri: alertActionWebhookUrl
        useCommonAlertSchema: true
      }
    ]
  }
}

// ---------------------------------------------------------------------------
//  Alert 1: job Failed / Suspended / Stopped (fallimenti infrastrutturali).
// ---------------------------------------------------------------------------
resource failedAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = if (enableFailedAlert) {
  name: 'alert-blkgm-job-failed'
  location: location
  tags: tags
  kind: 'LogAlert'
  properties: {
    displayName: '[BitLockerSync] Job Failed/Suspended'
    description: 'Il runbook ${runbookName} ha registrato un job Failed, Suspended o Stopped.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    scopes: [ logAnalyticsWorkspaceId ]
    criteria: {
      allOf: [
        {
          query: '''
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION"
| where Category == "JobLogs"
| where RunbookName_s in ("${runbookName}", "${extensionAttributeRunbookName}")
| where ResultType in ("Failed", "Suspended", "Stopped")
'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: false
    actions: {
      actionGroups: [ actionGroup.id ]
    }
  }
}

// ---------------------------------------------------------------------------
//  Alert 2: errori nello stream del runbook (errori applicativi/riconciliazione).
// ---------------------------------------------------------------------------
resource errorAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = if (enableErrorAlert) {
  name: 'alert-blkgm-runbook-error'
  location: location
  tags: tags
  kind: 'LogAlert'
  properties: {
    displayName: '[BitLockerSync] Errore nel runbook'
    description: 'Il runbook ${runbookName} ha emesso record sullo stream Error.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    scopes: [ logAnalyticsWorkspaceId ]
    criteria: {
      allOf: [
        {
          query: '''
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION"
| where Category == "JobStreams"
| where RunbookName_s in ("${runbookName}", "${extensionAttributeRunbookName}")
| where StreamType_s == "Error" or ResultDescription contains "[ERROR]"
'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: false
    actions: {
      actionGroups: [ actionGroup.id ]
    }
  }
}

// ---------------------------------------------------------------------------
//  Alert 3: dead-man's switch. Allerta se NON ci sono job "Completed" nella
//  finestra: intercetta schedule disabilitata, MI/Graph down, runbook mai
//  avviato. La summarize restituisce sempre una riga (Completed=0 se nessun
//  job), quindi la regola valuta anche l'assenza di dati.
//  Design: query scalare `summarize count()` (pattern corretto per un dead-man,
//  perche' restituisce sempre una riga con Completed=0 quando non c'e' nulla).
//  L'API richiede numberOfEvaluationPeriods=1 per query scalari senza colonna
//  TimeGenerated proiettata. autoMitigate=true: se dopo il fire arriva una run
//  completata, l'alert si risolve da solo. NOTA: alla prima valutazione dopo la
//  creazione/redeploy la regola puo' emettere una singola attivazione transitoria
//  (latenza di ingestion dei JobLogs) che si auto-risolve: e' un comportamento
//  noto di Azure Monitor, non un problema del runbook.
// ---------------------------------------------------------------------------
resource deadmanAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = if (enableDeadmanAlert) {
  name: 'alert-blkgm-no-successful-run'
  location: location
  tags: tags
  kind: 'LogAlert'
  properties: {
    displayName: '[BitLockerSync] Nessuna run completata (dead-man\'s switch)'
    description: 'Nessun job Completed del runbook ${runbookName} nelle ultime ${deadmanWindowHours} ore.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT1H'
    windowSize: 'PT${deadmanWindowHours}H'
    scopes: [ logAnalyticsWorkspaceId ]
    criteria: {
      allOf: [
        {
          query: '''
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION"
| where Category == "JobLogs"
| where RunbookName_s == "${runbookName}"
| where ResultType == "Completed"
| summarize Completed = count()
'''
          timeAggregation: 'Total'
          metricMeasureColumn: 'Completed'
          operator: 'LessThan'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [ actionGroup.id ]
    }
  }
}

resource extensionAttributeDeadmanAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = if (enableDeadmanAlert && !empty(extensionAttributeRunbookName)) {
  name: 'alert-blkgm-extension-no-success'
  location: location
  tags: tags
  kind: 'LogAlert'
  properties: {
    displayName: '[BitLockerSync] Extension attribute: nessuna run completata'
    description: 'Nessun job Completed del runbook ${extensionAttributeRunbookName} nelle ultime ${deadmanWindowHours} ore.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT1H'
    windowSize: 'PT${deadmanWindowHours}H'
    scopes: [ logAnalyticsWorkspaceId ]
    criteria: {
      allOf: [
        {
          query: '''
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION"
| where Category == "JobLogs"
| where RunbookName_s == "${extensionAttributeRunbookName}"
| where ResultType == "Completed"
| summarize Completed = count()
'''
          timeAggregation: 'Total'
          metricMeasureColumn: 'Completed'
          operator: 'LessThan'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [ actionGroup.id ]
    }
  }
}

// ---------------------------------------------------------------------------
//  Workbook: dashboard attività runbook.
// ---------------------------------------------------------------------------
resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = if (deployWorkbook) {
  name: guid(logAnalyticsWorkspaceId, 'blkgm-monitoring-workbook')
  location: location
  tags: tags
  kind: 'shared'
  properties: {
    displayName: 'Nimbus.BitLockerGroupSync - Monitoring'
    serializedData: replace(loadTextContent('workbooks/runbook-monitoring.workbook.json'), '__RUNBOOK_NAME__', runbookName)
    category: 'workbook'
    sourceId: logAnalyticsWorkspaceId
    version: '1.0'
  }
}

resource extensionAttributeWorkbook 'Microsoft.Insights/workbooks@2023-06-01' = if (deployWorkbook && !empty(extensionAttributeWorkbookRunbookName)) {
  name: guid(logAnalyticsWorkspaceId, 'blkgm-extension-attribute-monitoring-v2')
  location: location
  tags: union(tags, {
    workbook: 'extension-attribute'
    workbookVersion: '2.0'
  })
  kind: 'shared'
  properties: {
    displayName: 'BitLocker Extension Attribute - Operations Overview v2'
    serializedData: replace(
      replace(loadTextContent('workbooks/extension-attribute-monitoring-v2.workbook.json'), '__EXTENSION_RUNBOOK_NAME__', extensionAttributeWorkbookRunbookName),
      '__EXTENSION_ATTRIBUTE_NAME__',
      extensionAttributeName
    )
    category: 'workbook'
    sourceId: logAnalyticsWorkspaceId
    version: '2.0'
  }
}

@description('Resource id dell\'Action Group creato.')
output actionGroupId string = actionGroup.id

@description('Resource id del workbook extension attribute, se distribuito.')
output extensionAttributeWorkbookId string = deployWorkbook && !empty(extensionAttributeWorkbookRunbookName) ? extensionAttributeWorkbook.id : ''
