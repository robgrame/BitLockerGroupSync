#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    $script:runbook = Join-Path $root 'runbook\Sync-BitLockerComplianceGroups.ps1'
    $script:extensionAttributeRunbook = Join-Path $root 'runbook\Sync-BitLockerExtensionAttribute.ps1'
    $script:grant = Join-Path $root 'scripts\Grant-GraphPermissions.ps1'
    $script:mainBicep = Join-Path $root 'bicep\main.bicep'
    $script:monitoringBicep = Join-Path $root 'bicep\monitoring.bicep'
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
    It 'Il runbook extension attribute non ha errori di parsing' {
        (Test-PsSyntax -Path $script:extensionAttributeRunbook).Count | Should -Be 0
    }
    It 'Grant-GraphPermissions non ha errori di parsing' {
        (Test-PsSyntax -Path $script:grant).Count | Should -Be 0
    }

    Describe 'Runbook extension attribute' {
        BeforeAll {
            $script:extensionText = Get-Content $script:extensionAttributeRunbook -Raw
            $ast = Get-Ast -Path $script:extensionAttributeRunbook
            $script:extensionParamNames = $ast.ParamBlock.Parameters.Name.VariablePath.UserPath
        }

        It 'Espone solo il parametro sicuro WhatIfOnly' {
            $script:extensionParamNames | Should -Be @('WhatIfOnly')
        }

        It 'Usa extensionAttribute10 con i valori enc e notenc come default' {
            $script:extensionText | Should -Match "\`$script:ExtensionAttributeName = 'extensionAttribute10'"
            $script:extensionText | Should -Match "\`$script:EncryptedValue = 'enc'"
            $script:extensionText | Should -Match "\`$script:NotEncryptedValue = 'notenc'"
        }

        It 'Carica configurazione protetta senza consentire override dai parametri job' {
            $script:extensionText | Should -Match 'BitLockerExtensionAttributeRuntimeConfig'
            $script:extensionText | Should -Match '\$config -is \[System\.Collections\.IDictionary\]'
            $script:extensionText | Should -Match 'AllowValueTakeover'
            $script:extensionText | Should -Match 'Automation Variable obbligatoria'
            $script:extensionText | Should -Match 'Chiavi mancanti'
            $script:extensionText | Should -Match 'BitLockerExtensionAttributeName'
            $script:extensionText | Should -Match 'BitLockerExtensionAttributeEncryptedValue'
            $script:extensionText | Should -Match 'BitLockerExtensionAttributeNotEncryptedValue'
            $script:extensionText | Should -Not -Match '\[string\]\$ExtensionAttributeName'
        }

        It 'Legge isEncrypted da Intune e extensionAttributes da Entra' {
            $script:extensionText | Should -Match 'deviceManagement/managedDevices'
            $script:extensionText | Should -Match 'isEncrypted'
            $script:extensionText | Should -Match 'devices\?\`?\$select=id,deviceId,displayName,extensionAttributes'
        }

        It 'Aggiorna i device tramite batch PATCH idempotente' {
            $script:extensionText | Should -Match "method = 'PATCH'"
            $script:extensionText | Should -Match 'extensionAttributes'
            $script:extensionText | Should -Match '\$currentValue -eq \$desiredValue'
            $script:extensionText | Should -Match '\[EXTENSION_ATTRIBUTE_UPDATE\]'
            $script:extensionText | Should -Match '\[EXTENSION_ATTRIBUTE_CYCLE\]'
            $script:extensionText | Should -Match '\[AllowEmptyCollection\(\)\]'
            $script:extensionText | Should -Match 'if \(\$updates\.Count -gt 0\)'
        }

        It 'Ignora stati di cifratura null e device stale' {
            $script:extensionText | Should -Match '\$null -eq \$device\.isEncrypted'
            $script:extensionText | Should -Match 'retirePending'
            $script:extensionText | Should -Match 'wipePending'
        }

        It 'Supporta tutte le modalita di autenticazione esistenti' {
            $script:extensionText | Should -Match 'Connect-MgGraph -Identity -ClientId \$ManagedIdentityClientId'
            $script:extensionText | Should -Match 'Get-AutomationCertificate'
            $script:extensionText | Should -Match 'ClientSecretCredential'
        }

        It 'Rispetta sia WhatIfOnly sia il parametro comune WhatIf' {
            $script:extensionText | Should -Match 'if \(\$WhatIfPreference\) \{ \$WhatIfOnly = \$true \}'
        }

        It 'Blocca valori non gestiti senza consenso esplicito al takeover' {
            $script:extensionText | Should -Match '\$currentValue -notin @\(\$EncryptedValue, \$NotEncryptedValue\)'
            $script:extensionText | Should -Match '-not \$AllowValueTakeover'
            $script:extensionText | Should -Match 'Nessuna modifica applicata'
        }

        It 'Limita a 1024 caratteri i valori dell extension attribute' {
            $script:extensionText | Should -Match '\$EncryptedValue\.Length -gt 1024'
            $script:extensionText | Should -Match '\$NotEncryptedValue\.Length -gt 1024'
        }
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
    It 'Carica la configurazione runtime per gli avvii manuali' {
        $script:runbookText = Get-Content $script:runbook -Raw
        $script:runbookText | Should -Match 'Get-AutomationVariable -Name \$variableName'
        $script:runbookText | Should -Match "BitLockerSyncRuntimeConfig"
        $script:runbookText | Should -Match '\$script:ExplicitRuntimeParameters'
        $script:runbookText | Should -Match 'Set-Variable -Name \$name -Value \$value -Scope Script'
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
    BeforeAll {
        $script:grantText = Get-Content $script:grant -Raw
        $script:mainBicepText = Get-Content $script:mainBicep -Raw
        $script:deployText = Get-Content $script:deploy -Raw
    }
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
    It 'Riconcilia i ruoli gestiti revocando quelli non richiesti' {
        $script:grantText | Should -Match '\[switch\]\$Reconcile'
        $script:grantText | Should -Match '\$rolesToProcess = if \(\$Reconcile\)'
        $script:grantText | Should -Match '\$roleValue -notin \$GraphAppRoles'
        $script:grantText | Should -Match 'Revoke e Reconcile non possono essere usati insieme'
    }
    It 'Non espone un deploymentScript privilegiato configurabile via Bicep' {
        $script:mainBicepText | Should -Not -Match 'assignGraphPermissions'
        $script:mainBicepText | Should -Not -Match 'permissionGrantIdentity'
        Test-Path (Join-Path $script:root 'bicep\graphPermissions.bicep') | Should -BeFalse
    }
    It 'Installa autonomamente i moduli Graph se mancanti' {
        $script:grantText | Should -Match 'Install-Module -Name \$moduleName'
        $script:grantText | Should -Match "MinimumVersion 2\.40\.0"
        $script:deployText | Should -Match "Assert-Command -Name 'pwsh'"
        $script:deployText | Should -Match '& pwsh[\s\S]*Grant-GraphPermissions\.ps1'
        $script:deployText | Should -Match '-GraphAppRolesBase64 \$graphAppRolesBase64'
        $script:deployText | Should -Match 'Riconciliazione dei permessi Graph fallita'
    }
    It 'Ritenta la replica e il throttling della managed identity in Graph' {
        $script:grantText | Should -Match 'function Invoke-GraphWithRetry'
        $script:grantText | Should -Match '\$statusCode -eq 404'
        $script:grantText | Should -Match '\$statusCode -eq 429'
        $script:grantText | Should -Match '\$statusCode -ge 500'
        $script:grantText | Should -Match 'Service principal della managed identity'
        $script:grantText | Should -Match 'App role assignment della managed identity'
    }
    It 'Trasporta tutti i ruoli attraverso il processo pwsh figlio' {
        $roles = @(
            'DeviceManagementManagedDevices.Read.All'
            'BitlockerKey.Read.All'
            'Device.ReadWrite.All'
            'Group.Create'
            'GroupMember.ReadWrite.All'
        )
        $json = ConvertTo-Json -InputObject $roles -Compress
        $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
        $output = & pwsh `
            -NoProfile `
            -File $script:grant `
            -ManagedIdentityPrincipalId '00000000-0000-0000-0000-000000000000' `
            -GraphAppRolesBase64 $payload `
            -ValidateRolePayloadOnly
        $LASTEXITCODE | Should -Be 0
        @($output | ConvertFrom-Json) | Should -Be $roles
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
    BeforeAll {
        $script:deployText = Get-Content $script:deploy -Raw
        $script:monitoringBicepText = Get-Content $script:monitoringBicep -Raw
        $deployAst = Get-Ast -Path $script:deploy
        foreach ($functionName in @('Resolve-RunbookDeploymentSelection', 'Get-RequiredGraphAppRole')) {
            $functionAst = $deployAst.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $functionName
                }, $true)
            . ([scriptblock]::Create($functionAst.Extent.Text))
        }
    }
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
    It 'Importa e pubblica localmente i runbook per repository privati' {
        $script:deployText | Should -Match '\$deployRunbookContentLinks'
        $script:deployText | Should -Match 'function Import-LocalAutomationRunbook'
        $script:deployText | Should -Match 'Import-AzAutomationRunbook'
        $script:deployText | Should -Match '-Type PowerShell72'
        $script:deployText | Should -Match '-Published'
        $script:deployText | Should -Match '-Tags \$configuredTags'
        $script:deployText | Should -Match 'Copy-Item -LiteralPath \$Path -Destination \$importPath'
        $script:deployText | Should -Match 'Remove-Item -LiteralPath \$temporaryDirectory'
        $script:deployText | Should -Match "Nome runbook non valido per l'import locale"
        $script:deployText | Should -Match "\.State -ne 'Published'"
        $script:deployText | Should -Match 'Sync-BitLockerComplianceGroups\.ps1'
        $script:deployText | Should -Match 'Sync-BitLockerExtensionAttribute\.ps1'
        $script:deployText | Should -Match '\$requiresStagedActivation\s*=\s*\$GrantGraphPermissions -or\s*-not \$deployRunbookContentLinks -or\s*\$extensionMappingRequiresInitialization'
        $script:deployText | Should -Match 'if \(\$requiresStagedActivation -and \$runtimeEnabled\)'
    }
    It 'Inizializza una sola volta le Automation Variables globali del mapping' {
        $script:deployText | Should -Match 'function Initialize-ExtensionAttributeAutomationVariable'
        $script:deployText | Should -Match 'Automation Variable preservata'
        $script:deployText | Should -Match 'New-AzAutomationVariable'
        $script:deployText | Should -Match 'return \[string\]\$existing\.Value'
        $script:deployText | Should -Match 'Test-ExtensionAttributeMapping'
        $script:deployText | Should -Match '\$extensionMappingRequiresInitialization = \$existingMapping\.Count -lt 3'
        $script:deployText | Should -Match "deve essere una String non cifrata"
        $script:deployText | Should -Match "deve contenere un valore di tipo String"
        $script:deployText | Should -Match "Name 'BitLockerExtensionAttributeName'"
        $script:deployText | Should -Match "Name 'BitLockerExtensionAttributeEncryptedValue'"
        $script:deployText | Should -Match "Name 'BitLockerExtensionAttributeNotEncryptedValue'"
        $script:deployText | Should -Match '\$GrantGraphPermissions -or -not \$deployRunbookContentLinks -or \$extensionMappingRequiresInitialization'
        $script:deployText | Should -Not -Match "'BitLockerExtensionAttributeRuntimeConfig'\s*'BitLockerExtensionAttributeName'"
        $script:deployText | Should -Match 'if \(\$requiresStagedActivation\)[\s\S]*-ScheduleName \$configuredScheduleName[\s\S]*-ScheduleName \$configuredExtensionAttributeScheduleName'
    }
    It 'Persiste e ripristina i webhook disabilitati da un deployment fallito' {
        $script:deployText | Should -Match 'function Get-DeploymentDisabledWebhook'
        $script:deployText | Should -Match 'function Save-DeploymentDisabledWebhook'
        $script:deployText | Should -Match 'function Clear-DeploymentDisabledWebhook'
        $script:deployText | Should -Match "Name 'BitLockerDeploymentDisabledWebhooks'"
        $script:deployText | Should -Match 'Save-DeploymentDisabledWebhook[\s\S]*if \(\$runtimeEnabled -and \$disabledWebhooks\.Count -gt 0\)'
        $script:deployText | Should -Match 'Enable-RunbookWebhook[\s\S]*Clear-DeploymentDisabledWebhook'
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
    It 'Seleziona uno o entrambi i runbook dal deploy' {
        $script:deployText | Should -Match "ValidateSet\('All', 'GroupSync', 'ExtensionAttribute'\)"
        $script:deployText | Should -Match 'Resolve-RunbookDeploymentSelection'
        $script:deployText | Should -Match '\$parameterValues\.deployGroupSyncRunbook\.value'
        $script:deployText | Should -Match '\$parameterValues\.deployExtensionAttributeRunbook\.value'
        $script:deployText | Should -Match 'deployGroupSyncRunbook = \$deployGroupSyncRunbook'
        $script:deployText | Should -Match 'deployExtensionAttributeRunbook = \$deployExtensionAttributeRunbook'
    }
    It 'Risolve correttamente la selezione esplicita <Selection>' -ForEach @(
        @{ Selection = 'All'; GroupSync = $true; ExtensionAttribute = $true }
        @{ Selection = 'GroupSync'; GroupSync = $true; ExtensionAttribute = $false }
        @{ Selection = 'ExtensionAttribute'; GroupSync = $false; ExtensionAttribute = $true }
    ) {
        $result = Resolve-RunbookDeploymentSelection `
            -RunbookSelection $Selection `
            -SelectionWasSpecified $true `
            -ParameterDeployGroupSync $false `
            -ParameterDeployExtensionAttribute $false
        $result.DeployGroupSync | Should -Be $GroupSync
        $result.DeployExtensionAttribute | Should -Be $ExtensionAttribute
    }
    It 'Mantiene la selezione del file parametri quando lo switch e omesso' {
        $result = Resolve-RunbookDeploymentSelection `
            -SelectionWasSpecified $false `
            -ParameterDeployGroupSync $false `
            -ParameterDeployExtensionAttribute $true
        $result.DeployGroupSync | Should -BeFalse
        $result.DeployExtensionAttribute | Should -BeTrue
    }
    It 'Rifiuta un file parametri che disabilita entrambi i runbook' {
        {
            Resolve-RunbookDeploymentSelection `
                -SelectionWasSpecified $false `
                -ParameterDeployGroupSync $false `
                -ParameterDeployExtensionAttribute $false
        } | Should -Throw '*almeno un runbook*'
    }
    It 'Assegna i permessi Graph minimi per la selezione' {
        $script:deployText | Should -Match 'Get-RequiredGraphAppRole'
        $script:deployText | Should -Match 'ConvertTo-Json -InputObject @\(\$requiredGraphAppRoles\) -Compress'
        $script:deployText | Should -Match '-GraphAppRolesBase64 \$graphAppRolesBase64'
        $script:deployText | Should -Match '-Reconcile\s+`?'
    }
    It 'Non assegna BitlockerKey.Read.All quando escrow e disabilitato' {
        $roles = @(Get-RequiredGraphAppRole -DeployGroupSync $true -EnableKeyEscrowCheck $false)
        $roles | Should -Not -Contain 'BitlockerKey.Read.All'
        $roles | Should -Contain 'GroupMember.ReadWrite.All'
    }
    It 'Assegna BitlockerKey.Read.All quando escrow e abilitato' {
        $roles = @(Get-RequiredGraphAppRole -DeployGroupSync $true -EnableKeyEscrowCheck $true)
        $roles | Should -Contain 'BitlockerKey.Read.All'
    }
    It 'Assegna solo i due ruoli device per ExtensionAttribute' {
        $roles = @(Get-RequiredGraphAppRole -DeployGroupSync $false -EnableKeyEscrowCheck $true)
        $roles | Should -Be @(
            'DeviceManagementManagedDevices.Read.All'
            'Device.ReadWrite.All'
        )
        $script:deployText | Should -Match 'DeviceManagementManagedDevices\.Read\.All'
        $script:deployText | Should -Match 'Device\.ReadWrite\.All'
        $script:deployText | Should -Match 'GroupMember\.ReadWrite\.All'
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
        $script:deployText | Should -Match 'Get-AzResource -ResourceId \$jobScheduleResourceId'
        $script:deployText | Should -Match 'Timeout durante la rimozione del jobSchedule'
    }
    It 'Rimuove esplicitamente gli artefatti dei runbook non selezionati' {
        $script:deployText | Should -Match 'function Remove-DeselectedRunbookArtifact'
        $script:deployText | Should -Match 'Remove-AzAutomationRunbook'
        $script:deployText | Should -Match 'Remove-AzAutomationSchedule'
        $script:deployText | Should -Match 'Remove-AzAutomationVariable'
        $script:deployText | Should -Match 'Remove-AzAutomationWebhook'
        $script:deployText | Should -Match "Name 'alert-blkgm-extension-no-success'"
        $script:monitoringBicepText | Should -Match "name: 'alert-blkgm-extension-no-success'"
    }
    It 'Mantiene i job disabilitati fino al completamento del grant Graph' {
        $script:deployText | Should -Match '\$deploymentParams\.enableSchedule = \$false'
        $script:deployText | Should -Match '\$deploymentParams\.enableDeadmanAlert = \$false'
        $script:deployText | Should -Match 'Attivazione schedule e dead-man alert dopo la preparazione runtime'
        $script:deployText | Should -Match 'Disable-RunbookWebhook'
        $script:deployText | Should -Match 'Enable-RunbookWebhook'
        $script:deployText | Should -Match 'if \(-not \$PermissionsConfirmed\)'
    }
    It 'Dichiara gli helper webhook allo scope dello script' {
        $deployAst = Get-Ast -Path $script:deploy
        foreach ($functionName in @('Disable-RunbookWebhook', 'Enable-RunbookWebhook')) {
            $functionAst = $deployAst.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $functionName
                }, $true)
            $functionAst | Should -Not -BeNullOrEmpty
            $ancestor = $functionAst.Parent
            while ($ancestor) {
                $ancestor | Should -Not -BeOfType [System.Management.Automation.Language.FunctionDefinitionAst]
                $ancestor = $ancestor.Parent
            }
        }
    }
    It 'Valida i conflitti tra selezione e azioni prima del login Azure' {
        $selectionGuard = $script:deployText.IndexOf('Webhook e avvio GroupSync richiedono')
        $azureLogin = $script:deployText.IndexOf('Verifica login e contesto Azure')
        $selectionGuard | Should -BeGreaterOrEqual 0
        $selectionGuard | Should -BeLessThan $azureLogin
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
