using './main.bicep'

// ---------------------------------------------------------------------------
//  Parametri di deploy - personalizza questi valori.
// ---------------------------------------------------------------------------

param location = 'italynorth'
param automationAccountName = 'aa-encrypted-devices'
param automationAccountPublicNetworkAccess = true
param logAnalyticsWorkspaceName = 'aa-bitlocker-groupsync-law'
param runbookName = 'Sync-BitLockerComplianceGroups'

// URL raw fissati a un commit immutabile. Aggiornare lo SHA quando cambia il contenuto dei runbook.
param runbookContentUri = 'https://raw.githubusercontent.com/robgrame/BitLockerGroupSync/a00e704595be69f4c8a26dd53b72a9126be5d34e/runbook/Sync-BitLockerComplianceGroups.ps1'
param deployRunbookContentLinks = true
param deployGroupSyncRunbook = true
param deployExtensionAttributeRunbook = true
param extensionAttributeRunbookContentUri = 'https://raw.githubusercontent.com/robgrame/BitLockerGroupSync/a00e704595be69f4c8a26dd53b72a9126be5d34e/runbook/Sync-BitLockerExtensionAttribute.ps1'
param extensionAttributeName = 'extensionAttribute10'
param extensionAttributeEncryptedValue = 'enc'
param extensionAttributeNotEncryptedValue = 'notenc'
param extensionAttributeAllowValueTakeover = false
param clearManagedValuesForOutOfScopeDevices = false
param extensionAttributeScheduleIntervalHours = 1

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

// Master switch verifica escrow recovery key.
param enableKeyEscrowCheck = false

param targetOperatingSystem = 'Windows'

// Autenticazione Graph tramite App Registration e client secret.
param authenticationMode = 'AppRegistrationSecret'
param managedIdentityName = 'id-blk-groupsync'
param appTenantId = '46b06a5e-8f7a-467b-bc9a-e776011fbb57'
param appClientId = 'f9d6d647-2555-400a-8c27-fbbc7bd3ffcd'
param certificateAssetName = 'GraphAuthCertificate'
param graphCredentialVariableName = 'GraphClientSecret'
param appClientSecret = '' // passare il valore a deploy.ps1 tramite -AppClientSecret

param scheduleIntervalHours = 1
param deployLogAnalytics = true

// Monitoraggio nativo Azure (Action Group + alert rules + workbook).
param deployMonitoring = true
param alertEmails = []
param alertActionWebhookUrl = ''
param enableFailedAlert = true
param enableErrorAlert = true
param enableDeadmanAlert = true
param deadmanWindowHours = 12
param deployWorkbook = true

// Logic App di notifica Teams.
param deployTeamsLogicApp = true
param teamsLogicAppName = 'logic-bitlocker-teams'
param teamsWebhookUrl = '' // passare il valore a deploy.ps1 tramite -TeamsWebhookUrl

// Ottimizzazioni opzionali.
param keyMissingAlertThreshold = 0
param enableMembershipDetailLogging = true
param notificationDetailLimit = 50

// Webhook outbound opzionali.
param alertWebhookUrl = ''
param notifyWebhookUrl = ''

param tags = {
  solution: 'BitLockerGroupSync'
  managedBy: 'bicep'
  environment: 'prod'
  version: '1.6.6'
}
