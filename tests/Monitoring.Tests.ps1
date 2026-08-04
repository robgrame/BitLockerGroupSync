#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    $script:bicepDir = Join-Path $root 'bicep'
    $script:mainBicep = Join-Path $bicepDir 'main.bicep'
    $script:parameterFile = Join-Path $bicepDir 'main.bicepparam'
    $script:monitoring = Join-Path $bicepDir 'monitoring.bicep'
    $script:teams = Join-Path $bicepDir 'teams-logicapp.bicep'
    $script:workbook = Join-Path $bicepDir 'workbooks\runbook-monitoring.workbook.json'
}

Describe 'File di monitoraggio presenti' {
    It 'Esiste <Name>' -ForEach @(
        @{ Name = 'monitoring.bicep'; Path = { $script:monitoring } }
        @{ Name = 'teams-logicapp.bicep'; Path = { $script:teams } }
        @{ Name = 'workbook JSON'; Path = { $script:workbook } }
    ) {
        Test-Path (& $Path) | Should -BeTrue
    }
}

Describe 'Default cliente dei parametri Bicep' {
    BeforeAll { $script:parameterText = Get-Content $script:parameterFile -Raw }

    It 'Disabilita gruppi opzionali e verifica escrow' {
        foreach ($parameterName in @(
                'enableNotEncryptedGroup',
                'enableKeyEscrowedGroup',
                'enableKeyMissingGroup',
                'enableKeyEscrowCheck'
            )) {
            $script:parameterText | Should -Match "param $parameterName = false"
        }
    }

    It 'Usa il nome esplicito del gruppo cifrato senza prefisso' {
        $script:parameterText | Should -Match "param groupPrefix = ''"
        $script:parameterText | Should -Match "param encryptedGroupName = 'Intune - BitLocker Encrypted'"
    }

    It 'Pianifica il runbook ogni ora' {
        $script:parameterText | Should -Match 'param scheduleIntervalHours = 1'
    }

    It 'Usa nomi di asset e tag senza branding Nimbus' {
        $parameterWithoutSourceUri = $script:parameterText -replace "(?m)^param runbookContentUri = .*\r?\n", ''
        $parameterWithoutSourceUri | Should -Not -Match 'Nimbus'
        $script:parameterText | Should -Match "certificateAssetName = 'GraphAuthCertificate'"
        $script:parameterText | Should -Match "graphCredentialVariableName = 'GraphClientSecret'"
    }
}

Describe 'Modulo monitoring.bicep' {
    BeforeAll { $script:text = Get-Content $script:monitoring -Raw }

    It 'Crea un Action Group' {
        $script:text | Should -Match "Microsoft\.Insights/actionGroups"
    }
    It 'Crea le scheduled query rules' {
        ([regex]::Matches($script:text, 'Microsoft\.Insights/scheduledQueryRules')).Count | Should -BeGreaterOrEqual 3
    }
    It 'Definisce la regola <Rule>' -ForEach @(
        @{ Rule = 'alert-blkgm-job-failed' }
        @{ Rule = 'alert-blkgm-runbook-error' }
        @{ Rule = 'alert-blkgm-no-successful-run' }
    ) {
        $script:text | Should -Match ([regex]::Escape($Rule))
    }
    It 'La regola Failed filtra ResultType Failed/Suspended/Stopped' {
        $script:text | Should -Match 'ResultType in \("Failed", "Suspended", "Stopped"\)'
    }
    It 'La regola Error filtra lo stream Error' {
        $script:text | Should -Match 'StreamType_s == "Error"'
    }
    It 'Il dead-man''s switch usa metricMeasureColumn Completed con LessThan 1' {
        $script:text | Should -Match "metricMeasureColumn: 'Completed'"
        $script:text | Should -Match "operator: 'LessThan'"
    }
    It 'Il dead-man''s switch si auto-risolve (autoMitigate)' {
        $script:text | Should -Match 'autoMitigate: true'
    }
    It 'deadmanWindowHours limita ai valori supportati da Azure Monitor' {
        $script:text | Should -Match '@allowed\('
        $script:text | Should -Match ([regex]::Escape("windowSize: 'PT`${deadmanWindowHours}H'"))
    }
    It 'Crea il workbook via loadTextContent' {
        $script:text | Should -Match "Microsoft\.Insights/workbooks"
        $script:text | Should -Match "loadTextContent\('workbooks/runbook-monitoring.workbook.json'\)"
    }
    It 'Inietta nel workbook il nome parametrico del runbook' {
        $script:text | Should -Match "replace\(loadTextContent\('workbooks/runbook-monitoring.workbook.json'\), '__RUNBOOK_NAME__', runbookName\)"
    }
    It 'Le email ricevitori usano il common alert schema' {
        $script:text | Should -Match 'useCommonAlertSchema: true'
    }
}

Describe 'Modulo teams-logicapp.bicep' {
    BeforeAll { $script:text = Get-Content $script:teams -Raw }

    It 'Crea una Logic App (workflow)' {
        $script:text | Should -Match "Microsoft\.Logic/workflows"
    }
    It 'Espone un trigger HTTP manual (Request)' {
        $script:text | Should -Match "manual:"
        $script:text | Should -Match "type: 'Request'"
        $script:text | Should -Match "kind: 'Http'"
    }
    It 'Salta il POST quando l''URL Teams e vuoto (condizione If)' {
        $script:text | Should -Match "type: 'If'"
        $script:text | Should -Match "not:"
    }
    It 'Posta una Adaptive Card' {
        $script:text | Should -Match ([regex]::Escape('application/vnd.microsoft.card.adaptive'))
        $script:text | Should -Match "type: 'AdaptiveCard'"
        $script:text | Should -Match 'Post_runbook_adaptive_card'
        $script:text | Should -Match 'Post_monitor_adaptive_card'
        ([regex]::Matches($script:text, 'Post_adaptive_card')).Count | Should -Be 0
    }
    It 'Distingue notifiche runbook e alert Azure Monitor' {
        $script:text | Should -Match 'Post_Runbook_Notification'
        $script:text | Should -Match 'Post_Azure_Monitor_Alert'
        $script:text | Should -Match 'Nimbus\.BitLockerGroupSync'
        $script:text | Should -Match 'changeText'
        $script:text | Should -Match "triggerBody\(\)\?\[\\'data\\'\]\?\[\\'essentials\\'\]"
    }
    It 'Tratta l URL Teams come parametro sicuro del workflow' {
        $script:text | Should -Match "type: 'SecureString'"
    }
    It 'Esporta il callback URL del trigger' {
        $script:text | Should -Match "listCallbackUrl\("
        $script:text | Should -Match 'output triggerUrl string'
    }
    It 'Sopprime il lint sul segreto in output' {
        $script:text | Should -Match '#disable-next-line outputs-should-not-contain-secrets'
    }
}

Describe 'Wiring in main.bicep' {
    BeforeAll { $script:text = Get-Content $script:mainBicep -Raw }

    It 'Espone il parametro <Name>' -ForEach @(
        @{ Name = 'deployMonitoring' }
        @{ Name = 'logAnalyticsWorkspaceName' }
        @{ Name = 'alertEmails' }
        @{ Name = 'enableFailedAlert' }
        @{ Name = 'enableErrorAlert' }
        @{ Name = 'enableDeadmanAlert' }
        @{ Name = 'deadmanWindowHours' }
        @{ Name = 'deployWorkbook' }
        @{ Name = 'deployTeamsLogicApp' }
        @{ Name = 'teamsLogicAppName' }
        @{ Name = 'teamsWebhookUrl' }
        @{ Name = 'enableKeyEscrowCheck' }
        @{ Name = 'enableMembershipDetailLogging' }
        @{ Name = 'notificationDetailLimit' }
        @{ Name = 'enableSchedule' }
        @{ Name = 'authenticationMode' }
        @{ Name = 'managedIdentityName' }
        @{ Name = 'appTenantId' }
        @{ Name = 'appClientId' }
        @{ Name = 'certificateAssetName' }
        @{ Name = 'graphCredentialVariableName' }
        @{ Name = 'appClientSecret' }
    ) {
        $script:text | Should -Match "param $Name "
    }
    It 'Passa EnableKeyEscrowCheck alla jobSchedule' {
        $script:text | Should -Match 'EnableKeyEscrowCheck: string\(enableKeyEscrowCheck\)'
    }
    It 'Invoca il monitoraggio solo quando Log Analytics e attivo' {
        $script:text | Should -Match "module monitoring 'monitoring.bicep' = if \(deployMonitoring && deployLogAnalytics && !deployTeamsLogicApp\)"
        $script:text | Should -Match "module monitoringWithTeams 'monitoring.bicep' = if \(deployMonitoring && deployLogAnalytics && deployTeamsLogicApp\)"
    }
    It 'Usa un nome workspace indipendente dall Automation Account' {
        $script:text | Should -Match 'name: logAnalyticsWorkspaceName'
    }
    It 'Invoca la Logic App Teams gated da deployTeamsLogicApp' {
        $script:text | Should -Match "module teamsLogicApp 'teams-logicapp.bicep' = if \(deployTeamsLogicApp\)"
    }
    It 'Collega automaticamente il callback della Logic App all Action Group' {
        $script:text | Should -Match '#disable-next-line BCP318'
        $script:text | Should -Match 'teamsLogicApp\.outputs\.triggerUrl'
    }
    It 'Passa EnableMembershipDetailLogging alla jobSchedule' {
        $script:text | Should -Match 'EnableMembershipDetailLogging: string\(enableMembershipDetailLogging\)'
    }
    It 'Collega automaticamente il callback della Logic App al notify webhook cifrato' {
        $script:text | Should -Match "name: 'BitLockerSyncNotifyWebhook'"
        $script:text | Should -Match 'deployTeamsLogicApp \? .*teamsLogicApp\.outputs\.triggerUrl'
        $script:text | Should -Match 'NotificationDetailLimit: string\(notificationDetailLimit\)'
    }
    It 'Crea schedule e jobSchedule solo quando il runtime e abilitato' {
        $script:text | Should -Match "resource schedule .* = if \(enableSchedule\)"
        $script:text | Should -Match "resource jobSchedule .* = if \(enableSchedule\)"
    }
    It 'Crea e collega una UAMI dedicata all Automation Account' {
        $script:text | Should -Match "Microsoft\.ManagedIdentity/userAssignedIdentities@2024-11-30"
        $script:text | Should -Match "type: 'UserAssigned'"
        $script:text | Should -Match 'userAssignedIdentities:'
        $script:text | Should -Match 'runtimeIdentity!\.properties\.clientId'
        $script:text | Should -Not -Match "'SystemAssigned, UserAssigned'"
    }
    It 'Omette identity dall Automation Account quando usa App Registration' {
        $script:text | Should -Match "identity: authenticationMode == 'ManagedIdentity' \? \{"
        $script:text | Should -Match '\}\s*:\s*null'
        $script:text | Should -Not -Match "type: 'None'"
    }
    It 'Passa solo riferimenti non segreti alla schedule' {
        $script:text | Should -Match 'AuthenticationMode: authenticationMode'
        $script:text | Should -Match 'CertificateAssetName: certificateAssetName'
        $script:text | Should -Match 'ClientSecretVariableName: graphCredentialVariableName'
        $runtimeParams = [regex]::Match($script:text, 'var runbookParameters = \{(?<body>[\s\S]*?)\r?\n\}')
        $runtimeParams.Success | Should -BeTrue
        $runtimeParams.Groups['body'].Value | Should -Not -Match 'appClientSecret'
    }

    It 'Forza il refresh del contenuto pubblicato del runbook a ogni deployment' {
        $script:text | Should -Match 'publishContentLink:\s*\{[\s\S]*version:\s*deployment\(\)\.name'
    }

    It 'Usa un nuovo ID jobSchedule a ogni deployment' {
        $script:text | Should -Match 'name:\s*guid\(automationAccount\.id, runbookName, scheduleName, deployment\(\)\.name\)'
    }
    It 'Salva il client secret in una Automation Variable cifrata' {
        $script:text | Should -Match "authenticationMode == 'AppRegistrationSecret'"
        $script:text | Should -Match 'isEncrypted: true'
    }
}

Describe 'Workbook JSON' {
    BeforeAll { $script:raw = Get-Content $script:workbook -Raw }

    It 'E un JSON valido' {
        { $script:raw | ConvertFrom-Json } | Should -Not -Throw
    }
    It 'Contiene item con query KQL sul runbook' {
        $json = $script:raw | ConvertFrom-Json
        $json.items | Should -Not -BeNullOrEmpty
        $script:raw | Should -Match 'RunbookName_s'
        $script:raw | Should -Match '__RUNBOOK_NAME__'
    }
    It 'Contiene il trend a linee di aggiunte e rimozioni per ciclo' {
        $script:raw | Should -Match '\[MEMBERSHIP_ADD\]'
        $script:raw | Should -Match '\[MEMBERSHIP_REMOVE\]'
        $script:raw | Should -Match '\[MEMBERSHIP_CYCLE\]'
        $script:raw | Should -Match 'render timechart'
        $script:raw | Should -Match 'Aggiunte = toint\(Payload\.added\)'
        $script:raw | Should -Match 'Rimozioni = toint\(Payload\.removed\)'
    }
    It 'Contiene la tabella delle operazioni per device' {
        $script:raw | Should -Match 'membership-change-details'
        $script:raw | Should -Match 'Payload\.deviceName'
        $script:raw | Should -Match 'Operazione'
        $script:raw | Should -Match 'Aggiunta'
        $script:raw | Should -Match 'Rimozione'
    }
}
