using './main.bicep'

// ---------------------------------------------------------------------------
//  Parametri di deploy - personalizza questi valori.
// ---------------------------------------------------------------------------

param location = 'westeurope'
param automationAccountName = 'aa-bitlocker-groupsync'
param runbookName = 'Sync-BitLockerComplianceGroups'

// URL raw del runbook nel repo pubblico (branch main).
param runbookContentUri = 'https://raw.githubusercontent.com/robgrame/Nimbus.BitLockerGroupSync/main/runbook/Sync-BitLockerComplianceGroups.ps1'

param groupPrefix = 'SG-Intune-BitLocker'
param targetOperatingSystem = 'Windows'
param scheduleIntervalHours = 6
param deployLogAnalytics = true

param tags = {
  solution: 'Nimbus.BitLockerGroupSync'
  managedBy: 'bicep'
  environment: 'prod'
}
