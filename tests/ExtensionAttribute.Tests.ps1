#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $runbookPath = Join-Path $root 'runbook\Sync-BitLockerExtensionAttribute.ps1'
    $script:extensionRunbookText = Get-Content $runbookPath -Raw
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $runbookPath,
        [ref]$null,
        [ref]$null
    )

    $functions = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true)
    foreach ($function in $functions) {
        . ([scriptblock]::Create($function.Extent.Text))
    }

    if (-not (Get-Command Get-AutomationVariable -ErrorAction SilentlyContinue)) {
        function Get-AutomationVariable {
            param([string]$Name)
        }
    }
}

Describe 'Get-ManagedDeviceState' {
    BeforeEach {
        Mock Write-Log {}
    }

    It 'restituisce solo device validi con stato cifratura noto' {
        Mock Invoke-GraphApi {
            @(
                [pscustomobject]@{
                    deviceName = 'Encrypted'
                    azureADDeviceId = 'device-1'
                    isEncrypted = $true
                    managementState = 'managed'
                }
                [pscustomobject]@{
                    deviceName = 'Not encrypted'
                    azureADDeviceId = 'device-2'
                    isEncrypted = $false
                    managementState = 'managed'
                }
                [pscustomobject]@{
                    deviceName = 'Unknown'
                    azureADDeviceId = 'device-3'
                    isEncrypted = $null
                    managementState = 'managed'
                }
                [pscustomobject]@{
                    deviceName = 'Retired'
                    azureADDeviceId = 'device-4'
                    isEncrypted = $true
                    managementState = 'retirePending'
                }
                [pscustomobject]@{
                    deviceName = 'Missing Entra id'
                    azureADDeviceId = '00000000-0000-0000-0000-000000000000'
                    isEncrypted = $true
                    managementState = 'managed'
                }
            )
        }

        $result = Get-ManagedDeviceState -OperatingSystem 'Windows'

        $result.Devices.Count | Should -Be 2
        $result.Devices['device-1'].IsEncrypted | Should -BeTrue
        $result.Devices['device-2'].IsEncrypted | Should -BeFalse
        $result.UnknownEncryptionState | Should -Be 1
        $result.AuthoritativeDeviceIds.Count | Should -Be 4
        $result.AuthoritativeDeviceIds.Contains('device-3') | Should -BeTrue
        $result.AuthoritativeDeviceIds.Contains('device-4') | Should -BeTrue
        $result.CleanupSafe | Should -BeFalse
        $result.UncorrelatedDevices | Should -Be 1
        Should -Invoke Invoke-GraphApi -Times 1 -ParameterFilter {
            $Uri -match "operatingSystem eq 'Windows'" -and $All
        }
    }

    It 'non considera sicuro per la pulizia un inventario Intune vuoto' {
        Mock Invoke-GraphApi { @() }

        $result = Get-ManagedDeviceState -OperatingSystem 'Windows'

        $result.Devices.Count | Should -Be 0
        $result.AuthoritativeDeviceIds.Count | Should -Be 0
        $result.CleanupSafe | Should -BeFalse
    }
}

Describe 'Write-Log' {
    It 'scrive i livelli ERROR nello stream Error di Azure Automation' {
        $capturedErrors = @()
        Write-Log -Message 'Graph denied the update' -Level ERROR -ErrorVariable +capturedErrors 2>$null
        $capturedErrors.Count | Should -Be 1
        $capturedErrors[0].ToString() | Should -Match 'Graph denied the update'
    }

    It 'scrive il riepilogo ciclo nello stream Output anche senza verbose logging' {
        $script:ExtensionAttributeName = 'extensionAttribute10'
        $script:UpdatedDevices = 0
        $script:UpdateErrors = 0
        $script:UpdateErrorDetails = [System.Collections.Generic.List[object]]::new()
        $script:UpdateErrorStatusCounts = @{}
        $script:UpdateAbortReason = ''
        $script:GraphOperationErrors = 0
        $script:SafetyErrors = 0

        $output = Write-ExtensionCycleEvent `
            -Evaluated 10 `
            -Compliant 8 `
            -Requested 2 `
            -Conflicts 0 `
            -Unresolved 0 `
            -UnknownEncryptionState 0

        $joinedOutput = $output -join "`n"
        $joinedOutput | Should -Match '\[EXTENSION_ATTRIBUTE_CYCLE\]'
        $joinedOutput | Should -Match '\[EXTENSION_ATTRIBUTE_HEALTH\]'
        $joinedOutput | Should -Match '"evaluated":10'
    }

    It 'mantiene il job Completed per errori Graph gestiti ma non per errori di configurazione' {
        $script:extensionRunbookText | Should -Match "BitLockerGroupSync\.GraphOperation"
        $script:extensionRunbookText | Should -Match "Errore Graph gestito: il job termina Completed"
        $script:extensionRunbookText | Should -Match 'else \{\s*Write-Log "ERRORE FATALE:[\s\S]*?\s+throw\s*\}'
    }
}

Describe 'Get-OutOfScopeClearRequest' {
    BeforeEach {
        $script:ExtensionAttributeName = 'extensionAttribute10'
        $script:EncryptedValue = 'enc'
        $script:NotEncryptedValue = 'notenc'
    }

    It 'blocca la pulizia con inventario autorevole vuoto' {
        $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $result = Get-OutOfScopeClearRequest `
            -EntraDevices @(
                [pscustomobject]@{
                    id = 'object-1'
                    deviceId = 'device-1'
                    displayName = 'Protected'
                    extensionAttributes = [pscustomobject]@{ extensionAttribute10 = 'enc' }
                }
            ) `
            -AuthoritativeDeviceIds $ids `
            -CleanupSafe $false

        $result.Requests.Count | Should -Be 0
        $result.BlockReason | Should -Match 'non e sufficientemente completo'
    }

    It 'blocca una pulizia che supera il venticinque percento dell inventario' {
        $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        1..4 | ForEach-Object { [void]$ids.Add("managed-$_") }
        $result = Get-OutOfScopeClearRequest `
            -EntraDevices @(
                1..2 | ForEach-Object {
                    [pscustomobject]@{
                        id = "object-$_"
                        deviceId = "out-$_"
                        displayName = "Out-$_"
                        extensionAttributes = [pscustomobject]@{ extensionAttribute10 = 'enc' }
                    }
                }
            ) `
            -AuthoritativeDeviceIds $ids `
            -CleanupSafe $true

        $result.Requests.Count | Should -Be 0
        $result.BlockReason | Should -Match 'limite di sicurezza'
    }
}

Describe 'Invoke-GraphApi resilience' {
    BeforeEach {
        Mock Write-Log {}
        Mock Start-Sleep {}
    }

    It 'ritenta un errore transitorio e restituisce la risposta successiva' {
        $script:graphAttempt = 0
        Mock Invoke-MgGraphRequest {
            $script:graphAttempt++
            if ($script:graphAttempt -eq 1) {
                throw [System.Net.Http.HttpRequestException]::new('Temporary network failure')
            }
            [pscustomobject]@{ value = @([pscustomobject]@{ id = 'device-1' }) }
        }

        $result = Invoke-GraphApi -Uri 'devices?$select=id'

        $result.Count | Should -Be 1
        $result[0].id | Should -Be 'device-1'
        Should -Invoke Invoke-MgGraphRequest -Times 2
        Should -Invoke Start-Sleep -Times 1
    }

    It 'marca un errore Graph definitivo affinche il chiamante lo gestisca senza Failed' {
        Mock Invoke-MgGraphRequest {
            throw [System.Exception]::new('Response status code does not indicate success: 403 (Forbidden).')
        }

        $caught = $null
        try {
            Invoke-GraphApi -Uri 'devices?$select=id' | Out-Null
        }
        catch {
            $caught = $_
        }

        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Data['BitLockerGroupSync.GraphOperation'] | Should -BeTrue
        $caught.Exception.Data['BitLockerGroupSync.GraphMethod'] | Should -Be 'GET'
        $caught.Exception.Data['BitLockerGroupSync.GraphUri'] | Should -Match '/devices'
        Should -Invoke Invoke-MgGraphRequest -Times 1
    }
}

Describe 'Import-RuntimeConfiguration' {
    BeforeEach {
        $script:ExtensionAttributeName = 'extensionAttribute10'
        $script:AllowValueTakeover = $false
        $script:ClearManagedValuesForOutOfScopeDevices = $false
        Mock Write-Log {}
        Mock Get-AutomationVariable {
            switch ($Name) {
                'BitLockerExtensionAttributeName' { 'extensionAttribute9' }
                'BitLockerExtensionAttributeEncryptedValue' { 'encrypted' }
                'BitLockerExtensionAttributeNotEncryptedValue' { 'not-encrypted' }
                default {
                    @{
                        TargetOperatingSystem = 'Windows'
                        AuthenticationMode = 'ManagedIdentity'
                        ManagedIdentityClientId = 'client-id'
                        AppTenantId = ''
                        AppClientId = ''
                        CertificateAssetName = 'GraphAuthCertificate'
                        ClientSecretVariableName = 'GraphClientSecret'
                        GroupPrefix = 'Intune'
                        EncryptedGroupName = 'Encrypted'
                        EnableKeyEscrowCheck = 'false'
                    }
                }
            }
        }
    }

    It 'carica identita e autenticazione dalla configurazione GroupSync ignorando le chiavi aggiuntive' {
        Import-RuntimeConfiguration

        $script:ExtensionAttributeName | Should -Be 'extensionAttribute9'
        $script:ManagedIdentityClientId | Should -Be 'client-id'
        $script:AllowValueTakeover | Should -BeFalse
        $script:ClearManagedValuesForOutOfScopeDevices | Should -BeFalse
        Should -Invoke Get-AutomationVariable -Times 1 -ParameterFilter {
            $Name -eq 'BitLockerSyncRuntimeConfig'
        }
    }

    It 'applica le opzioni extension quando sono presenti nella configurazione condivisa' {
        Mock Get-AutomationVariable {
            switch ($Name) {
                'BitLockerExtensionAttributeName' { 'extensionAttribute9' }
                'BitLockerExtensionAttributeEncryptedValue' { 'encrypted' }
                'BitLockerExtensionAttributeNotEncryptedValue' { 'not-encrypted' }
                default {
                    @{
                        TargetOperatingSystem = 'Windows'
                        AuthenticationMode = 'ManagedIdentity'
                        ManagedIdentityClientId = 'client-id'
                        AppTenantId = ''
                        AppClientId = ''
                        CertificateAssetName = 'GraphAuthCertificate'
                        ClientSecretVariableName = 'GraphClientSecret'
                        AllowValueTakeover = 'true'
                        ClearManagedValuesForOutOfScopeDevices = 'true'
                    }
                }
            }
        }

        Import-RuntimeConfiguration

        $script:AllowValueTakeover | Should -BeTrue
        $script:ClearManagedValuesForOutOfScopeDevices | Should -BeTrue
    }

    It 'rifiuta un valore booleano non valido nella configurazione condivisa' {
        Mock Get-AutomationVariable {
            switch ($Name) {
                'BitLockerExtensionAttributeName' { 'extensionAttribute9' }
                'BitLockerExtensionAttributeEncryptedValue' { 'encrypted' }
                'BitLockerExtensionAttributeNotEncryptedValue' { 'not-encrypted' }
                default {
                    @{
                        TargetOperatingSystem = 'Windows'
                        AuthenticationMode = 'ManagedIdentity'
                        ManagedIdentityClientId = 'client-id'
                        AppTenantId = ''
                        AppClientId = ''
                        CertificateAssetName = 'GraphAuthCertificate'
                        ClientSecretVariableName = 'GraphClientSecret'
                        AllowValueTakeover = 'sometimes'
                    }
                }
            }
        }

        { Import-RuntimeConfiguration } | Should -Throw '*valore booleano non valido*'
    }

    It 'fallisce se la Automation Variable non e disponibile' {
        Mock Get-AutomationVariable { throw 'missing' }

        { Import-RuntimeConfiguration } | Should -Throw '*obbligatoria*'
    }

    It 'fallisce se la Automation Variable e incompleta' {
        Mock Get-AutomationVariable {
            @{ ExtensionAttributeName = 'extensionAttribute10' }
        }

        { Import-RuntimeConfiguration } | Should -Throw '*Chiavi mancanti*'
    }

    It 'fallisce se una Automation Variable del mapping non e disponibile' {
        Mock Get-AutomationVariable {
            if ($Name -eq 'BitLockerExtensionAttributeEncryptedValue') { throw 'missing' }
            if ($Name -eq 'BitLockerExtensionAttributeName') { return 'extensionAttribute10' }
            if ($Name -eq 'BitLockerExtensionAttributeNotEncryptedValue') { return 'notenc' }
            @{
                TargetOperatingSystem = 'Windows'
                AuthenticationMode = 'ManagedIdentity'
                ManagedIdentityClientId = 'client-id'
                AppTenantId = ''
                AppClientId = ''
                CertificateAssetName = 'GraphAuthCertificate'
                ClientSecretVariableName = 'GraphClientSecret'
            }
        }

        { Import-RuntimeConfiguration } | Should -Throw '*BitLockerExtensionAttributeEncryptedValue*'
    }

    It 'rifiuta una Automation Variable del mapping che non sia String' {
        Mock Get-AutomationVariable {
            if ($Name -eq 'BitLockerExtensionAttributeName') { return 'extensionAttribute10' }
            if ($Name -eq 'BitLockerExtensionAttributeEncryptedValue') { return @{ invalid = $true } }
            if ($Name -eq 'BitLockerExtensionAttributeNotEncryptedValue') { return 'notenc' }
            @{
                TargetOperatingSystem = 'Windows'
                AuthenticationMode = 'ManagedIdentity'
                ManagedIdentityClientId = 'client-id'
                AppTenantId = ''
                AppClientId = ''
                CertificateAssetName = 'GraphAuthCertificate'
                ClientSecretVariableName = 'GraphClientSecret'
            }
        }

        { Import-RuntimeConfiguration } | Should -Throw '*deve essere di tipo String*'
    }
}

Describe 'Invoke-DeviceUpdateBatch' {
    BeforeEach {
        $script:ExtensionAttributeName = 'extensionAttribute10'
        $script:UpdatedDevices = 0
        $script:UpdateErrors = 0
        $script:UpdateErrorDetails = [System.Collections.Generic.List[object]]::new()
        $script:UpdateErrorStatusCounts = @{}
        $script:UpdateAbortReason = ''
        $script:GraphOperationErrors = 0
        $script:SafetyErrors = 0
        $script:capturedBatchBody = $null
        Mock Write-Log {}
        Mock Start-Sleep {}
    }

    It 'invia PATCH batch con enc e notenc e conta gli aggiornamenti riusciti' {
        Mock Invoke-GraphApi {
            $script:capturedBatchBody = $Body
            return [pscustomobject]@{
                responses = @(
                    [pscustomobject]@{ id = '1'; status = 204 }
                    [pscustomobject]@{ id = '2'; status = 204 }
                )
            }
        }

        $requests = @(
            [pscustomobject]@{
                deviceName = 'Encrypted'
                deviceId = 'device-1'
                objectId = 'object-1'
                currentValue = ''
                desiredValue = 'enc'
            }
            [pscustomobject]@{
                deviceName = 'Not encrypted'
                deviceId = 'device-2'
                objectId = 'object-2'
                currentValue = 'enc'
                desiredValue = 'notenc'
            }
        )

        Invoke-DeviceUpdateBatch -Requests $requests

        $script:UpdatedDevices | Should -Be 2
        $script:UpdateErrors | Should -Be 0
        Should -Invoke Invoke-GraphApi -Times 1
        $script:capturedBatchBody.requests.Count | Should -Be 2
        $script:capturedBatchBody.requests[0].method | Should -Be 'PATCH'
        $script:capturedBatchBody.requests[0].url | Should -Be '/devices/object-1'
        $script:capturedBatchBody.requests[0].body.extensionAttributes.extensionAttribute10 |
            Should -Be 'enc'
        $script:capturedBatchBody.requests[1].body.extensionAttributes.extensionAttribute10 |
            Should -Be 'notenc'
    }

    It 'contabilizza come errore una risposta Graph definitiva' {
        Mock Invoke-GraphApi {
            return [pscustomobject]@{
                responses = @(
                    [pscustomobject]@{
                        id = '1'
                        status = 403
                        body = [pscustomobject]@{ error = 'Forbidden' }
                    }
                )
            }
        }

        Invoke-DeviceUpdateBatch -Requests @(
            [pscustomobject]@{
                deviceName = 'Denied'
                deviceId = 'device-1'
                objectId = 'object-1'
                currentValue = ''
                desiredValue = 'enc'
            }
        )

        $script:UpdatedDevices | Should -Be 0
        $script:UpdateErrors | Should -Be 1
        $script:UpdateErrorStatusCounts['403'] | Should -Be 1
        $script:UpdateErrorDetails[0].deviceName | Should -Be 'Denied'
        $script:UpdateErrorDetails[0].status | Should -Be 403
        $script:UpdateAbortReason | Should -BeNullOrEmpty
        Should -Invoke Start-Sleep -Times 0
    }

    It 'ritenta i risultati batch transitori e aggiorna il device al tentativo successivo' {
        $script:batchAttempt = 0
        Mock Invoke-GraphApi {
            $script:batchAttempt++
            if ($script:batchAttempt -eq 1) {
                return [pscustomobject]@{
                    responses = @(
                        [pscustomobject]@{
                            id = '1'
                            status = 429
                            headers = @{ 'Retry-After' = '120' }
                            body = [pscustomobject]@{ error = [pscustomobject]@{ code = 'TooManyRequests'; message = 'Retry later' } }
                        }
                    )
                }
            }
            return [pscustomobject]@{
                responses = @([pscustomobject]@{ id = '1'; status = 204 })
            }
        }

        Invoke-DeviceUpdateBatch -Requests @(
            [pscustomobject]@{
                deviceName = 'Throttled'
                deviceId = 'device-2'
                objectId = 'object-2'
                currentValue = ''
                desiredValue = 'enc'
            }
        )

        $script:UpdatedDevices | Should -Be 1
        $script:UpdateErrors | Should -Be 0
        Should -Invoke Invoke-GraphApi -Times 2
        Should -Invoke Start-Sleep -Times 1 -ParameterFilter { $Seconds -eq 30 }
    }

    It 'interrompe i batch successivi quando il primo batch e interamente non autorizzato' {
        Mock Invoke-GraphApi {
            [pscustomobject]@{
                responses = @(
                    1..2 | ForEach-Object {
                        [pscustomobject]@{
                            id = [string]$_
                            status = 403
                            body = @{
                                error = @{
                                    code = 'Authorization_RequestDenied'
                                    message = 'Insufficient privileges to complete the operation.'
                                }
                            }
                        }
                    }
                )
            }
        }

        $requests = @(
            1..2 | ForEach-Object {
                [pscustomobject]@{
                    deviceName = "Denied-$_"
                    deviceId = "device-$_"
                    objectId = "object-$_"
                    currentValue = ''
                    desiredValue = 'enc'
                }
            }
        )
        Invoke-DeviceUpdateBatch -Requests $requests

        $script:UpdateErrors | Should -Be 2
        $script:UpdateAbortReason | Should -Match 'Device.ReadWrite.All'
        $script:UpdateErrorDetails[0].code | Should -Be 'Authorization_RequestDenied'
        $script:UpdateErrorDetails[0].message | Should -Match 'Insufficient privileges'
        $script:UpdateErrorDetails[0].guidance | Should -Match 'Device.ReadWrite.All'
    }

    It 'non interpreta un singolo 403 dopo un successo come errore globale di autorizzazione' {
        $script:UpdatedDevices = 1
        Mock Invoke-GraphApi {
            [pscustomobject]@{
                responses = @(
                    [pscustomobject]@{
                        id = '1'
                        status = 403
                        body = @{ error = @{ code = 'Forbidden'; message = 'Device-specific denial' } }
                    }
                )
            }
        }

        Invoke-DeviceUpdateBatch -Requests @(
            [pscustomobject]@{
                deviceName = 'Single denied'
                deviceId = 'device-3'
                objectId = 'object-3'
                currentValue = ''
                desiredValue = 'enc'
            }
        )

        $script:UpdateErrors | Should -Be 1
        $script:UpdateAbortReason | Should -BeNullOrEmpty
    }

    It 'marca come errore ogni richiesta quando Graph restituisce un batch incompleto' {
        Mock Invoke-GraphApi {
            [pscustomobject]@{
                responses = @(
                    [pscustomobject]@{ id = '1'; status = 204 }
                )
            }
        }
        $requests = @(
            1..2 | ForEach-Object {
                [pscustomobject]@{
                    deviceName = "Incomplete-$_"
                    deviceId = "device-$_"
                    objectId = "object-$_"
                    currentValue = ''
                    desiredValue = 'enc'
                }
            }
        )

        Invoke-DeviceUpdateBatch -Requests $requests

        $script:UpdatedDevices | Should -Be 0
        $script:UpdateErrors | Should -Be 2
        $script:UpdateErrorStatusCounts['0'] | Should -Be 2
        $script:UpdateErrorDetails[0].code | Should -Be 'IncompleteBatchResponse'
        $script:UpdateAbortReason | Should -Match 'incompleta o incoerente'
    }

    It 'gestisce una risposta batch priva di id senza errore StrictMode' {
        Mock Invoke-GraphApi {
            [pscustomobject]@{
                responses = @(
                    [pscustomobject]@{ status = 204 }
                )
            }
        }
        Invoke-DeviceUpdateBatch -Requests @(
            [pscustomobject]@{
                deviceName = 'Malformed'
                deviceId = 'device-1'
                objectId = 'object-1'
                currentValue = ''
                desiredValue = 'enc'
            }
        )

        $script:UpdateErrors | Should -Be 1
        $script:UpdateAbortReason | Should -Match 'incompleta o incoerente'
    }

    It 'non considera riuscita una risposta con status mancante o non 2xx' -ForEach @(
        @{ Status = $null; ExpectedCode = 'InvalidBatchStatus' }
        @{ Status = 0; ExpectedCode = 'InvalidBatchStatus' }
        @{ Status = 302; ExpectedCode = 'InvalidBatchStatus' }
    ) {
        Mock Invoke-GraphApi {
            $result = [ordered]@{ id = '1' }
            if ($null -ne $Status) { $result.status = $Status }
            [pscustomobject]@{ responses = @([pscustomobject]$result) }
        }

        Invoke-DeviceUpdateBatch -Requests @(
            [pscustomobject]@{
                deviceName = 'Malformed status'
                deviceId = 'device-1'
                objectId = 'object-1'
                currentValue = ''
                desiredValue = 'enc'
            }
        )

        $script:UpdatedDevices | Should -Be 0
        $script:UpdateErrors | Should -Be 1
        $script:UpdateAbortReason | Should -Not -BeNullOrEmpty
        if ($ExpectedCode) {
            $script:UpdateErrorDetails[0].code | Should -Be $ExpectedCode
        }
    }
}
