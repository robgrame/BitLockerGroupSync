#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    $script:bicepDir = Join-Path $root 'bicep'
    $script:mainBicep = Join-Path $bicepDir 'main.bicep'
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
        @{ Name = 'alertEmails' }
        @{ Name = 'enableFailedAlert' }
        @{ Name = 'enableErrorAlert' }
        @{ Name = 'enableDeadmanAlert' }
        @{ Name = 'deadmanWindowHours' }
        @{ Name = 'deployWorkbook' }
        @{ Name = 'deployTeamsLogicApp' }
        @{ Name = 'teamsLogicAppName' }
        @{ Name = 'teamsWebhookUrl' }
    ) {
        $script:text | Should -Match "param $Name "
    }
    It 'Invoca il modulo monitoring gated da deployLogAnalytics' {
        $script:text | Should -Match "module monitoring 'monitoring.bicep' = if \(deployMonitoring && deployLogAnalytics\)"
    }
    It 'Invoca la Logic App Teams gated da deployTeamsLogicApp' {
        $script:text | Should -Match "module teamsLogicApp 'teams-logicapp.bicep' = if \(deployMonitoring && deployTeamsLogicApp\)"
    }
    It 'Collega automaticamente il callback della Logic App all Action Group' {
        $script:text | Should -Match 'teamsLogicApp!\.outputs\.triggerUrl'
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
    }
}
