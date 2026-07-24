using './main.bicep'

// ---------------------------------------------------------------------------
//  Parametri di deploy - personalizza questi valori.
// ---------------------------------------------------------------------------

param location = 'italynorth'
param automationAccountName = 'aa-bitlocker-groupsync'
param runbookName = 'Sync-BitLockerComplianceGroups'

// URL raw del runbook nel repo pubblico (branch main).
param runbookContentUri = 'https://raw.githubusercontent.com/robgrame/Nimbus.BitLockerGroupSync/main/runbook/Sync-BitLockerComplianceGroups.ps1'

param groupPrefix = 'SG-Intune-BitLocker'
param targetOperatingSystem = 'Windows'
param scheduleIntervalHours = 6
param deployLogAnalytics = true

// Ottimizzazioni opzionali
param keyMissingAlertThreshold = 0

// Webhook (secure): lasciare vuoti per non creare le variabili. Valorizzare per abilitarli.
param alertWebhookUrl = ''
param notifyWebhookUrl = ''

// Assegnazione automatica permessi Graph via deploymentScript (richiede UAMI pre-abilitata).
param assignGraphPermissions = false
param permissionGrantIdentityId = ''
param permissionGrantIdentityClientId = ''

param tags = {
  solution: 'Nimbus.BitLockerGroupSync'
  managedBy: 'bicep'
  environment: 'prod'
}
