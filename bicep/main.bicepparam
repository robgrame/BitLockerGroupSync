using './main.bicep'

// ---------------------------------------------------------------------------
//  Parametri di deploy - personalizza questi valori.
// ---------------------------------------------------------------------------

param location = 'italynorth'
param automationAccountName = 'aa-bitlocker-groupsync'
param logAnalyticsWorkspaceName = 'aa-bitlocker-groupsync-law'
param runbookName = 'Sync-BitLockerComplianceGroups'

// URL raw del runbook nel repo pubblico (branch main).
param runbookContentUri = 'https://raw.githubusercontent.com/robgrame/Nimbus.BitLockerGroupSync/main/runbook/Sync-BitLockerComplianceGroups.ps1'

param groupPrefix = ''

// Nomi gruppi: lasciare vuoti per derivarli da groupPrefix, oppure impostare nomi espliciti.
param encryptedGroupName = 'Intune - BitLocker Encrypted'
param notEncryptedGroupName = ''
param keyEscrowedGroupName = ''
param keyMissingGroupName = ''

// Gruppi opzionali (il gruppo Encrypted e' sempre attivo). Default: disabilitati.
param enableNotEncryptedGroup = false
param enableKeyEscrowedGroup = false
param enableKeyMissingGroup = false

// Master switch verifica escrow recovery key. true = comportamento attuale (recupero chiavi
// quando servono KeyEscrowed/KeyMissing/alert). Impostare a false per saltare del tutto il
// controllo puntuale delle recovery key (il gruppo Encrypted non e' influenzato).
param enableKeyEscrowCheck = false

param targetOperatingSystem = 'Windows'

// Autenticazione Graph:
// ManagedIdentity | AppRegistrationCertificate | AppRegistrationSecret
param authenticationMode = 'ManagedIdentity'
param managedIdentityName = 'id-blk-groupsync'
param appTenantId = ''
param appClientId = ''
param certificateAssetName = 'GraphAuthCertificate'
param graphCredentialVariableName = 'GraphClientSecret'
param appClientSecret = ''

param scheduleIntervalHours = 6
param deployLogAnalytics = true

// Monitoraggio nativo Azure (Action Group + alert rules + workbook).
param deployMonitoring = true
param alertEmails = [
]
param alertActionWebhookUrl = '' // valorizzare con l'URL del canale Teams / Logic App
param enableFailedAlert = true
param enableErrorAlert = true
param enableDeadmanAlert = true
param deadmanWindowHours = 12
param deployWorkbook = true

// Logic App di notifica Teams.
param deployTeamsLogicApp = false
param teamsLogicAppName = 'logic-bitlocker-teams'
param teamsWebhookUrl = '' // incollare qui l'URL Workflows del canale Teams

// Ottimizzazioni opzionali
param keyMissingAlertThreshold = 0
param enableMembershipDetailLogging = true

// Webhook (secure): lasciare vuoti per non creare le variabili. Valorizzare per abilitarli.
param alertWebhookUrl = ''
param notifyWebhookUrl = ''

// Assegnazione automatica permessi Graph via deploymentScript (richiede UAMI pre-abilitata).
param assignGraphPermissions = false
param permissionGrantIdentityId = ''
param permissionGrantIdentityClientId = ''

param tags = {
  solution: 'BitLockerGroupSync'
  managedBy: 'bicep'
  environment: 'prod'
}
