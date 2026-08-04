#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    $script:runbook = Join-Path $root 'runbook\Sync-BitLockerComplianceGroups.ps1'
    $script:grant = Join-Path $root 'scripts\Grant-GraphPermissions.ps1'
    $script:mailTemplate = Join-Path $root 'templates\Entra-Permissions-Request.eml'
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
    It 'Le funzioni helper del deploy sono definite nello scope dello script' {
        $ast = Get-Ast -Path $script:deploy
        $helper = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'ConvertTo-StringHashtable'
            }, $true)
        $helper | Should -Not -BeNullOrEmpty
        $helper.Parent.Parent | Should -BeOfType [System.Management.Automation.Language.ScriptBlockAst]
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
        @{ Name = 'EnableKeyEscrowCheck' }
        @{ Name = 'TargetOperatingSystem' }
        @{ Name = 'WhatIfOnly' }
        @{ Name = 'AuthenticationMode' }
        @{ Name = 'ManagedIdentityClientId' }
        @{ Name = 'AppTenantId' }
        @{ Name = 'AppClientId' }
        @{ Name = 'CertificateAssetName' }
        @{ Name = 'ClientSecretVariableName' }
        @{ Name = 'KeyMissingAlertThreshold' }
        @{ Name = 'AlertWebhookUrl' }
        @{ Name = 'NotifyWebhookUrl' }
        @{ Name = 'NotificationDetailLimit' }
        @{ Name = 'EnableMembershipDetailLogging' }
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
    It 'Il master switch EnableKeyEscrowCheck neutralizza il recupero chiavi' {
        $script:runbookText | Should -Match '\$escrowCheck\s*=\s*ConvertTo-Bool \$EnableKeyEscrowCheck'
        $script:runbookText | Should -Match '\$needKeys\s*=\s*\$escrowCheck -and'
    }
    It 'Gli insiemi KeyEscrowed/KeyMissing sono calcolati solo se needKeys' {
        $script:runbookText | Should -Match 'if \(\$needKeys\) \{[\s\S]*KeyEscrowed\.Add'
    }
    It 'L''alert di soglia richiede la verifica escrow attiva' {
        $script:runbookText | Should -Match 'if \(\$needKeys -and \$KeyMissingAlertThreshold'
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
    It 'Usa scope delegati minimi per assegnare gli app role' {
        $script:grantText | Should -Match 'Application\.Read\.All'
        $script:grantText | Should -Match 'AppRoleAssignment\.ReadWrite\.All'
        $script:grantText | Should -Not -Match 'Application\.ReadWrite\.All'
    }
    It 'Supporta la revoca controllata prima della rimozione della UAMI' {
        $script:grantText | Should -Match '\[switch\]\$Revoke'
        $script:grantText | Should -Match 'Remove-MgServicePrincipalAppRoleAssignment'
    }
    It 'Installa autonomamente i moduli Graph se mancanti' {
        $script:grantText | Should -Match 'Install-Module -Name \$moduleName'
        $script:grantText | Should -Match "MinimumVersion 2\.28\.0"
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
    It 'Registra il dettaglio strutturato delle modifiche membership riuscite' {
        $script:runbookText | Should -Match '\[MEMBERSHIP_ADD\]'
        $script:runbookText | Should -Match '\[MEMBERSHIP_REMOVE\]'
        $script:runbookText | Should -Match '\[MEMBERSHIP_CYCLE\]'
        $script:runbookText | Should -Match "operation = 'Add'"
        $script:runbookText | Should -Match "operation = 'Remove'"
        $script:runbookText | Should -Match 'MembershipAdds'
        $script:runbookText | Should -Match 'MembershipRemoves'
    }
    It 'Notifica solo modifiche membership o errori con dettaglio limitato' {
        $script:runbookText | Should -Match '\$script:MembershipChanges'
        $script:runbookText | Should -Match '\$script:MembershipChanges\.Count -lt \$NotificationDetailLimit'
        $script:runbookText | Should -Match '\$shouldNotify\s*=\s*\$membershipChangeCount -gt 0 -or \$script:ReconcileErrors -gt 0'
        $script:runbookText | Should -Match 'changesTruncated'
        $script:runbookText | Should -Match 'sync\.membership_changed_with_errors'
        $script:runbookText | Should -Match 'sync\.membership_changed'
        $script:runbookText | Should -Match 'deviceName'
        $script:runbookText | Should -Match 'LogMembershipDetails'
    }
}

Describe 'Orchestrazione del deployment' {
    BeforeAll { $script:deployText = Get-Content $script:deploy -Raw }
    It 'Verifica tenant e subscription espliciti' {
        $script:deployText | Should -Match '\$TenantId'
        $script:deployText | Should -Match '\$SubscriptionId'
        $script:deployText | Should -Match 'Set-AzContext'
    }
    It 'Esegue preflight e what-if prima del deployment' {
        $script:deployText | Should -Match 'Test-AzResourceGroupDeployment'
        $script:deployText | Should -Match 'Get-AzResourceGroupDeploymentWhatIfResult'
        $script:deployText | Should -Match 'New-AzResourceGroupDeployment'
    }
    It 'Accetta il webhook Teams come SecureString senza persisterlo' {
        $script:deployText | Should -Match '\[securestring\]\$TeamsWebhookUrl'
        $script:deployText | Should -Match '\$templateParams\.teamsWebhookUrl = \$TeamsWebhookUrl'
    }
    It 'Riusa i parametri runtime per avvio immediato e webhook' {
        $script:deployText | Should -Match 'Outputs\.runbookParameters'
        $script:deployText | Should -Match 'ConvertTo-StringHashtable'
        $script:deployText | Should -Match 'ConvertTo-DirectRunbookHashtable'
        $script:deployText | Should -Match 'Newtonsoft\.Json\.Linq\.JObject'
        $script:deployText | Should -Match "KeyMissingAlertThreshold'\] = \[int\]"
        $script:deployText | Should -Match 'New-AzAutomationWebhook[\s\S]*-Parameters \$directRunbookParameters'
        $script:deployText | Should -Match 'Start-AzAutomationRunbook[\s\S]*-Parameters \$directRunbookParameters'
    }
    It 'Installa Azure CLI, Bicep e i moduli PowerShell richiesti' {
        $script:deployText | Should -Match 'winget install --id Microsoft\.AzureCLI'
        $script:deployText | Should -Match 'https://aka\.ms/installazurecliwindowsx64'
        $script:deployText | Should -Match 'az bicep install'
        $script:deployText | Should -Match ([regex]::Escape("Join-Path `$HOME '.azure\bin'"))
        $script:deployText | Should -Match 'Get-Command bicep'
        $script:deployText | Should -Match 'Install-RequiredModule -Name Az\.Accounts'
        $script:deployText | Should -Match 'Install-RequiredModule -Name Az\.Resources'
        $script:deployText | Should -Match 'Install-RequiredModule -Name Az\.Automation'
    }
    It 'Rende Bicep disponibile anche quando il bootstrap viene saltato' {
        $script:deployText | Should -Match 'if \(-not \$SkipBootstrap\) \{ Initialize-DeploymentTooling \}\s+Add-BicepToProcessPath'
    }
    It 'Usa device code per il login Azure' {
        $script:deployText | Should -Match 'UseDeviceAuthentication'
    }
    It 'Registra automaticamente i resource provider richiesti' {
        $script:deployText | Should -Match 'Register-RequiredResourceProvider'
        $script:deployText | Should -Match 'Microsoft\.Automation'
        $script:deployText | Should -Match 'Microsoft\.OperationalInsights'
        $script:deployText | Should -Match 'Microsoft\.Insights'
        $script:deployText | Should -Match 'Microsoft\.Logic'
    }
    It 'Risolve automaticamente i conflitti di nome dell Automation Account' {
        $script:deployText | Should -Match 'Resolve-AutomationAccountName'
        $script:deployText | Should -Match 'Microsoft\.Automation/automationAccounts'
        $script:deployText | Should -Match 'SHA256'
        $script:deployText | Should -Match 'automationAccountName = \$configuredAutomationAccountName'
    }
    It 'Disabilita runtime e dead-man fino alla conferma delle permission' {
        $script:deployText | Should -Match '\$runtimeEnabled = \$GrantGraphPermissions -or \$PermissionsConfirmed'
        $script:deployText | Should -Match 'enableSchedule\s+= \$runtimeEnabled'
        $script:deployText | Should -Match 'enableDeadmanAlert\s+= \$runtimeEnabled'
    }
    It 'Mantiene le comunicazioni cliente separate dal deployment' {
        $script:deployText | Should -Not -Match 'New-EntraPermissionRequest\.ps1'
        $script:deployText | Should -Not -Match 'PermissionRequestSender'
        $script:deployText | Should -Not -Match 'PermissionRequestRecipient'
    }
    It 'Supporta managed identity, certificato e client secret' {
        $script:deployText | Should -Match 'parameterValues\.authenticationMode'
        $script:deployText | Should -Match 'New-AzAutomationCertificate'
        $script:deployText | Should -Match 'Set-AzAutomationCertificate'
        $script:deployText | Should -Match 'appClientSecret = \$AppClientSecret'
    }
    It 'Delega a Bicep la creazione della UAMI dedicata' {
        $script:deployText | Should -Match 'Get-BicepParameterValues'
        $script:deployText | Should -Match 'Outputs\.managedIdentityClientId'
        $script:deployText | Should -Match 'Outputs\.managedIdentityResourceId'
        $script:deployText | Should -Not -Match 'UserAssignedIdentityPrincipalId'
    }
    It 'Ricrea il jobSchedule per applicare tutti i parametri runtime' {
        $script:deployText | Should -Match 'Remove-ExistingJobScheduleLink'
        $script:deployText | Should -Match 'Unregister-AzAutomationScheduledRunbook'
        $script:deployText | Should -Match '\$_.ScheduleName -eq \$ScheduleName'
        $script:deployText | Should -Match 'Get-AzResource -ResourceId \$jobScheduleResourceId'
        $script:deployText | Should -Match 'Timeout durante la rimozione del jobSchedule'
    }
    It 'Usa una frequenza oraria anche come fallback del deploy' {
        $script:deployText | Should -Match '\$configuredScheduleIntervalHours[\s\S]*else \{\s*1\s*\}'
    }
    It 'Riusa certificato e secret esistenti nelle fasi successive' {
        $script:deployText | Should -Match 'Get-AzAutomationCertificate'
        $script:deployText | Should -Match 'Get-AzAutomationVariable'
        $script:deployText | Should -Match "non esistente: specificare"
    }
}

Describe 'Autenticazione Graph del runbook' {
    BeforeAll { $script:runbookText = Get-Content $script:runbook -Raw }
    It 'Usa Connect-MgGraph con managed identity' {
        $script:runbookText | Should -Match 'Connect-MgGraph -Identity -ClientId \$ManagedIdentityClientId'
        $script:runbookText | Should -Match 'ManagedIdentityClientId'
        $script:runbookText | Should -Not -Match 'Connect-MgGraph -Identity -NoWelcome'
    }
    It 'Usa un Automation Certificate con private key' {
        $script:runbookText | Should -Match 'Get-AutomationCertificate'
        $script:runbookText | Should -Match 'Connect-MgGraph -TenantId \$TenantId -ClientId \$ApplicationClientId -Certificate \$certificate'
        $script:runbookText | Should -Match 'HasPrivateKey'
    }
    It 'Usa una Automation Variable cifrata per il client secret' {
        $script:runbookText | Should -Match 'Get-AutomationVariable -Name \$SecretVariableName'
        $script:runbookText | Should -Match 'ClientSecretCredential'
        $script:runbookText | Should -Match '\$clientSecret = \$null'
    }
}

Describe 'Assegnazione permission Graph alla managed identity' {
    BeforeAll { $script:grantText = Get-Content $script:grant -Raw }

    It 'Documenta device code e tenant negli esempi' {
        $script:grantText | Should -Match "ManagedIdentityPrincipalId.*-TenantId.*-UseDeviceCode"
    }

    It 'Interrompe lo script se la prima chiamata Graph fallisce' {
        $script:grantText | Should -Match "Get-MgServicePrincipal -Filter .* -ErrorAction Stop"
    }
}

Describe 'Template richiesta permission Entra' {
    BeforeAll { $script:mailText = Get-Content $script:mailTemplate -Raw }
    It 'E una bozza EML con mittente e destinatario modificabili' {
        $script:mailText | Should -Match '^From: "MODIFICARE MITTENTE" <sender@example\.com>'
        $script:mailText | Should -Match '(?m)^To: "MODIFICARE DESTINATARIO" <entra-admin@example\.com>'
        $script:mailText | Should -Match '(?m)^X-Unsent: 1\r?$'
    }

    Describe 'Mail prerequisiti cliente' {
        BeforeAll {
            $script:prerequisitesMail = Join-Path $root 'docs\Customer-Deployment-Prerequisites.eml'
            $script:prerequisitesMailText = Get-Content $script:prerequisitesMail -Raw
        }

        Describe 'Mail istruzioni deployment cliente' {
            BeforeAll {
                $script:instructionsMail = Join-Path $root 'docs\Customer-Deployment-Instructions.eml'
                $script:instructionsMailText = Get-Content $script:instructionsMail -Raw
            }
            It 'È una bozza EML full-width modificabile' {
                Test-Path $script:instructionsMail | Should -BeTrue
                $script:instructionsMailText | Should -Match '(?m)^X-Unsent: 1\r?$'
                $script:instructionsMailText | Should -Match 'multipart/alternative'
                $script:instructionsMailText | Should -Match 'width="100%"'
            }
            It 'Documenta bootstrap, ruoli Azure e provider' {
                $script:instructionsMailText | Should -Match 'Azure CLI'
                $script:instructionsMailText | Should -Match 'Bicep'
                $script:instructionsMailText | Should -Match 'Contributor'
                $script:instructionsMailText | Should -Match 'providers/register/action'
                $script:instructionsMailText | Should -Match 'Microsoft\.ManagedIdentity'
            }
            It 'Contiene i comandi per deployment, grant e attivazione' {
                $script:instructionsMailText | Should -Match ([regex]::Escape(".\deploy.ps1 -ResourceGroupName '[RESOURCE GROUP]' -Location '[REGIONE]'"))
                $script:instructionsMailText | Should -Match 'Grant-GraphPermissions\.ps1'
                $script:instructionsMailText | Should -Match 'PermissionsConfirmed'
                $script:instructionsMailText | Should -Match 'StartJobNow'
            }
            It 'Elenca ruolo Entra e tutte le permission Graph' {
                $script:instructionsMailText | Should -Match 'Privileged Role Administrator'
                foreach ($role in @(
                    'DeviceManagementManagedDevices.Read.All',
                    'BitlockerKey.Read.All',
                    'Device.ReadWrite.All',
                    'Group.Create',
                    'GroupMember.ReadWrite.All'
                )) {
                    $script:instructionsMailText | Should -Match ([regex]::Escape($role))
                }
            }
        }
        It 'È una bozza EML modificabile con layout full-width' {
            Test-Path $script:prerequisitesMail | Should -BeTrue
            $script:prerequisitesMailText | Should -Match '(?m)^X-Unsent: 1\r?$'
            $script:prerequisitesMailText | Should -Match 'multipart/alternative'
            $script:prerequisitesMailText | Should -Match 'width="100%"'
        }
        It 'Documenta ruoli, provider e permission Graph richiesti' {
            $script:prerequisitesMailText | Should -Match 'Contributor'
            $script:prerequisitesMailText | Should -Match 'Privileged Role Administrator'
            $script:prerequisitesMailText | Should -Match 'Microsoft\.Automation'
            $script:prerequisitesMailText | Should -Match 'Microsoft\.ManagedIdentity'
            $script:prerequisitesMailText | Should -Match 'DeviceManagementManagedDevices\.Read\.All'
            $script:prerequisitesMailText | Should -Match 'GroupMember\.ReadWrite\.All'
        }
        It 'Avverte di non inviare credenziali via email' {
            $script:prerequisitesMailText | Should -Match 'Non rispondere.*PFX'
            $script:prerequisitesMailText | Should -Match 'canale sicuro'
        }
    }

    Describe 'Template richiesta App Registration' {
        BeforeAll {
            $script:appMailTemplate = Join-Path $root 'templates\Entra-AppRegistration-Permissions-Request.eml'
            $script:appMailText = Get-Content $script:appMailTemplate -Raw
        }
        It 'E una bozza EML full-width modificabile' {
            $script:appMailText | Should -Match '^From: "MODIFICARE MITTENTE" <sender@example\.com>'
            $script:appMailText | Should -Match '(?m)^To: "MODIFICARE DESTINATARIO" <entra-admin@example\.com>'
            $script:appMailText | Should -Match '(?m)^X-Unsent: 1\r?$'
            $script:appMailText | Should -Match 'width="100%"'
        }
        It 'Documenta il consenso dal portale Entra' {
            $script:appMailText | Should -Match 'Registrazioni app'
            $script:appMailText | Should -Match 'Autorizzazioni API'
            $script:appMailText | Should -Match 'Concedi consenso amministratore'
        }
    }
    It 'Contiene layout HTML full-width e fallback testuale' {
        $script:mailText | Should -Match 'multipart/alternative'
        $script:mailText | Should -Match 'width="100%"'
        $script:mailText | Should -Match 'Content-Type: text/plain'
        $script:mailText | Should -Match 'Content-Type: text/html'
    }
    It 'Elenca tutte le permission Graph richieste' {
        foreach ($role in @(
            'DeviceManagementManagedDevices.Read.All',
            'BitlockerKey.Read.All',
            'Device.ReadWrite.All',
            'Group.Create',
            'GroupMember.ReadWrite.All'
        )) {
            $script:mailText | Should -Match ([regex]::Escape($role))
        }
    }
}
