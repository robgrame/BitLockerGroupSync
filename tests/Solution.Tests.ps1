#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    $script:runbook = Join-Path $root 'runbook\Sync-BitLockerComplianceGroups.ps1'
    $script:grant = Join-Path $root 'scripts\Grant-GraphPermissions.ps1'
    $script:deploy = Join-Path $root 'deploy.ps1'

    function Test-PsSyntax {
        param([string]$Path)
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
        return $errs
    }

    function Get-Ast {
        param([string]$Path)
        return [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    }
}

Describe 'Sintassi PowerShell' {
    It 'Il runbook non ha errori di parsing' {
        (Test-PsSyntax -Path $script:runbook).Count | Should -Be 0
    }
    It 'Grant-GraphPermissions non ha errori di parsing' {
        (Test-PsSyntax -Path $script:grant).Count | Should -Be 0
    }
    It 'deploy.ps1 non ha errori di parsing' {
        (Test-PsSyntax -Path $script:deploy).Count | Should -Be 0
    }
}

Describe 'Parametri del runbook' {
    BeforeAll {
        $ast = Get-Ast -Path $script:runbook
        $script:paramNames = $ast.ParamBlock.Parameters.Name.VariablePath.UserPath
    }
    It 'Espone il parametro <Name>' -ForEach @(
        @{ Name = 'GroupPrefix' }
        @{ Name = 'EncryptedGroupName' }
        @{ Name = 'NotEncryptedGroupName' }
        @{ Name = 'KeyEscrowedGroupName' }
        @{ Name = 'KeyMissingGroupName' }
        @{ Name = 'EnableNotEncryptedGroup' }
        @{ Name = 'EnableKeyEscrowedGroup' }
        @{ Name = 'EnableKeyMissingGroup' }
        @{ Name = 'TargetOperatingSystem' }
        @{ Name = 'WhatIfOnly' }
        @{ Name = 'KeyMissingAlertThreshold' }
        @{ Name = 'AlertWebhookUrl' }
        @{ Name = 'NotifyWebhookUrl' }
    ) {
        $script:paramNames | Should -Contain $Name
    }
}

Describe 'Gruppi opzionali' {
    BeforeAll { $script:runbookText = Get-Content $script:runbook -Raw }
    It 'Il gruppo Encrypted e sempre creato (fuori da condizioni Enable)' {
        $script:runbookText | Should -Match 'Encrypted = Get-OrCreateGroup'
    }
    It 'I gruppi opzionali sono condizionati dagli switch Enable' {
        $script:runbookText | Should -Match 'if \(\$useNotEncrypted\)'
        $script:runbookText | Should -Match 'if \(\$useKeyEscrowed\)'
        $script:runbookText | Should -Match 'if \(\$useKeyMissing\)'
    }
    It 'ConvertTo-Bool gestisce le stringhe delle jobSchedule' {
        $script:runbookText | Should -Match 'function ConvertTo-Bool'
    }
}

Describe 'Permessi least-privilege' {
    BeforeAll { $script:grantText = Get-Content $script:grant -Raw }
    It 'Include <Role>' -ForEach @(
        @{ Role = 'DeviceManagementManagedDevices.Read.All' }
        @{ Role = 'BitlockerKey.Read.All' }
        @{ Role = 'Device.ReadWrite.All' }
        @{ Role = 'Group.Create' }
        @{ Role = 'GroupMember.ReadWrite.All' }
    ) {
        $script:grantText | Should -Match ([regex]::Escape($Role))
    }
    It 'NON usa piu Group.ReadWrite.All' {
        $script:grantText | Should -Not -Match 'Group\.ReadWrite\.All'
    }
}

Describe 'Logica di batching' {
    BeforeAll { $script:runbookText = Get-Content $script:runbook -Raw }
    It 'Usa members@odata.bind per gli add' {
        $script:runbookText | Should -Match 'members@odata.bind'
    }
    It 'Usa l endpoint $batch per le rimozioni' {
        $script:runbookText | Should -Match '\$batch'
    }
    It 'Filtra i device stale/retired' {
        $script:runbookText | Should -Match 'retirePending'
    }
}
