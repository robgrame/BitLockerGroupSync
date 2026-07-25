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

// Nomi gruppi: lasciare vuoti per derivarli da groupPrefix, oppure impostare nomi espliciti.
param encryptedGroupName = ''
param notEncryptedGroupName = ''
param keyEscrowedGroupName = ''
param keyMissingGroupName = ''

// Gruppi opzionali (il gruppo Encrypted e' sempre attivo). Default: disabilitati.
param enableNotEncryptedGroup = true
param enableKeyEscrowedGroup = true
param enableKeyMissingGroup = true

param targetOperatingSystem = 'Windows'
param scheduleIntervalHours = 6
param deployLogAnalytics = true

// Monitoraggio nativo Azure (Action Group + alert rules + workbook).
param deployMonitoring = true
param alertEmails = [
  'roberto@gramellini.net'
]
param alertActionWebhookUrl = '' // valorizzare con l'URL del canale Teams / Logic App
param enableFailedAlert = true
param enableErrorAlert = true
param enableDeadmanAlert = true
param deadmanWindowHours = 12
param deployWorkbook = true

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
