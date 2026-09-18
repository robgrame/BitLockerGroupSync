#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $runbookPath = Join-Path $root 'runbook\Sync-BitLockerExtensionAttribute.ps1'
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
        Should -Invoke Invoke-GraphApi -Times 1 -ParameterFilter {
            $Uri -match "operatingSystem eq 'Windows'" -and $All
        }
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
                        AllowValueTakeover = $true
                        ClearManagedValuesForOutOfScopeDevices = $true
                    }
                }
            }
        }
    }

    It 'carica correttamente una Automation Variable restituita come Hashtable' {
        Import-RuntimeConfiguration

        $script:ExtensionAttributeName | Should -Be 'extensionAttribute9'
        $script:AllowValueTakeover | Should -BeTrue
        $script:ClearManagedValuesForOutOfScopeDevices | Should -BeTrue
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
                AllowValueTakeover = $false
                ClearManagedValuesForOutOfScopeDevices = $false
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
                AllowValueTakeover = $false
                ClearManagedValuesForOutOfScopeDevices = $false
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
        Should -Invoke Start-Sleep -Times 0
    }
}
