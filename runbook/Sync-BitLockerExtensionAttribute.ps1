<#
.SYNOPSIS
    Sincronizza lo stato BitLocker Intune in un extension attribute dei device Entra.

.DESCRIPTION
    Per ogni device gestito da Intune con stato isEncrypted noto, aggiorna il device
    Entra corrispondente impostando extensionAttribute10 a:
      - enc    quando isEncrypted=true
      - notenc quando isEncrypted=false

    Il runbook e' idempotente: invia a Microsoft Graph solo gli aggiornamenti necessari.
    I device stale, senza azureADDeviceId, senza oggetto Entra o con isEncrypted nullo
    vengono ignorati e contabilizzati nel riepilogo.

.NOTES
    Version: 1.1.0

    Permessi Graph application richiesti:
      - DeviceManagementManagedDevices.Read.All
      - Device.ReadWrite.All

    Modulo richiesto nell'Automation Account:
      - Microsoft.Graph.Authentication
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()][bool]$WhatIfOnly = $false
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$VerbosePreference = 'Continue'

$script:GraphBase = 'https://graph.microsoft.com/v1.0'
$script:UpdateErrors = 0
$script:UpdatedDevices = 0
$script:ExtensionAttributeName = 'extensionAttribute10'
$script:EncryptedValue = 'enc'
$script:NotEncryptedValue = 'notenc'
$script:TargetOperatingSystem = 'Windows'
$script:AuthenticationMode = 'ManagedIdentity'
$script:ManagedIdentityClientId = ''
$script:AppTenantId = ''
$script:AppClientId = ''
$script:CertificateAssetName = 'GraphAuthCertificate'
$script:ClientSecretVariableName = 'GraphClientSecret'
$script:AllowValueTakeover = $false
$script:ClearManagedValuesForOutOfScopeDevices = $false

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )

    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-Verbose ("[{0}] [{1}] {2}" -f $timestamp, $Level, $Message)
}

function Import-RuntimeConfiguration {
    $variableName = 'BitLockerExtensionAttributeRuntimeConfig'
    try {
        $config = Get-AutomationVariable -Name $variableName -ErrorAction Stop
        if ($config -is [string]) {
            $config = $config | ConvertFrom-Json -ErrorAction Stop
        }
    }
    catch {
        throw "Automation Variable obbligatoria '$variableName' non disponibile o non valida. $($_.Exception.Message)"
    }

    $parameterNames = @(
        'ExtensionAttributeName',
        'EncryptedValue',
        'NotEncryptedValue',
        'TargetOperatingSystem',
        'AuthenticationMode',
        'ManagedIdentityClientId',
        'AppTenantId',
        'AppClientId',
        'CertificateAssetName',
        'ClientSecretVariableName'
        'AllowValueTakeover'
        'ClearManagedValuesForOutOfScopeDevices'
    )

    $imported = 0
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $parameterNames) {
        $hasValue = $false
        $value = $null
        if ($config -is [System.Collections.IDictionary]) {
            if ($config.Contains($name)) {
                $hasValue = $true
                $value = $config[$name]
            }
        }
        else {
            $property = $config.PSObject.Properties[$name]
            if ($null -ne $property) {
                $hasValue = $true
                $value = $property.Value
            }
        }
        if (-not $hasValue) {
            $missing.Add($name)
            continue
        }

        if ($name -in @('AllowValueTakeover', 'ClearManagedValuesForOutOfScopeDevices')) {
            $value = [System.Convert]::ToBoolean($value)
        }
        else {
            $value = [string]$value
        }
        Set-Variable -Name $name -Value $value -Scope Script
        $imported++
    }
    if ($missing.Count -gt 0) {
        throw "Automation Variable '$variableName' incompleta. Chiavi mancanti: $($missing -join ', ')."
    }
    Write-Log "Caricati $imported parametri runtime dalla Automation Variable '$variableName'."
}

function Connect-GraphSession {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingConvertToSecureStringWithPlainText',
        '',
        Justification = 'Il valore proviene da una Automation Variable cifrata.'
    )]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ManagedIdentity', 'AppRegistrationCertificate', 'AppRegistrationSecret')]
        [string]$Mode,
        [string]$ManagedIdentityClientId,
        [string]$TenantId,
        [string]$ApplicationClientId,
        [string]$CertificateName,
        [string]$SecretVariableName
    )

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        throw "Modulo 'Microsoft.Graph.Authentication' non disponibile nell'Automation Account."
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    switch ($Mode) {
        'ManagedIdentity' {
            if ([string]::IsNullOrWhiteSpace($ManagedIdentityClientId)) {
                throw 'ManagedIdentityClientId e obbligatorio per ManagedIdentity.'
            }
            Write-Log "Connessione a Graph con UAMI dedicata ($ManagedIdentityClientId)..."
            Connect-MgGraph -Identity -ClientId $ManagedIdentityClientId -NoWelcome
        }
        'AppRegistrationCertificate' {
            if ([string]::IsNullOrWhiteSpace($TenantId) -or [string]::IsNullOrWhiteSpace($ApplicationClientId)) {
                throw 'AppTenantId e AppClientId sono obbligatori per AppRegistrationCertificate.'
            }
            $certificate = Get-AutomationCertificate -Name $CertificateName -ErrorAction Stop
            if (-not $certificate.HasPrivateKey) {
                throw "L'Automation Certificate '$CertificateName' non contiene la private key."
            }
            Write-Log "Connessione a Graph con App Registration e certificato '$CertificateName'..."
            Connect-MgGraph -TenantId $TenantId -ClientId $ApplicationClientId -Certificate $certificate -NoWelcome
        }
        'AppRegistrationSecret' {
            if ([string]::IsNullOrWhiteSpace($TenantId) -or [string]::IsNullOrWhiteSpace($ApplicationClientId)) {
                throw 'AppTenantId e AppClientId sono obbligatori per AppRegistrationSecret.'
            }
            $clientSecret = Get-AutomationVariable -Name $SecretVariableName -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace([string]$clientSecret)) {
                throw "Automation Variable '$SecretVariableName' vuota o non disponibile."
            }
            try {
                $secureSecret = ConvertTo-SecureString -String ([string]$clientSecret) -AsPlainText -Force
                $credential = [pscredential]::new($ApplicationClientId, $secureSecret)
                Write-Log "Connessione a Graph con App Registration e client secret cifrato '$SecretVariableName'..."
                Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $credential -NoWelcome
            }
            finally {
                $clientSecret = $null
                $secureSecret = $null
                $credential = $null
            }
        }
    }

    $context = Get-MgContext
    if (-not $context) { throw 'Connessione a Microsoft Graph fallita.' }
    Write-Log ("Connesso al tenant {0} come app '{1}'." -f $context.TenantId, $context.AppName) 'OK'
}

function Invoke-GraphApi {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('GET', 'POST', 'PATCH')][string]$Method = 'GET',
        [object]$Body,
        [switch]$All
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $next = if ($Uri -match '^https?://') { $Uri } else { "$script:GraphBase/$($Uri.TrimStart('/'))" }

    do {
        $attempt = 0
        while ($true) {
            $attempt++
            try {
                $parameters = @{
                    Method = $Method
                    Uri = $next
                    OutputType = 'PSObject'
                    ErrorAction = 'Stop'
                }
                if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
                    $parameters.Body = $Body | ConvertTo-Json -Depth 10
                    $parameters.ContentType = 'application/json'
                }
                $response = Invoke-MgGraphRequest @parameters
                break
            }
            catch {
                $status = $null
                try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = $null }
                if (($status -eq 429 -or $status -ge 500) -and $attempt -le 5) {
                    $retryAfter = 0
                    try { $retryAfter = [int]$_.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds } catch { $retryAfter = 0 }
                    if ($retryAfter -le 0) {
                        $retryAfter = [math]::Min(60, [math]::Pow(2, $attempt))
                    }
                    Write-Log "Errore Graph transitorio ($status). Retry tra $retryAfter s (tentativo $attempt)." 'WARN'
                    Start-Sleep -Seconds $retryAfter
                    continue
                }
                throw
            }
        }

        if ($null -eq $response) {
            $next = $null
        }
        elseif ($response.PSObject.Properties.Name -contains 'value') {
            foreach ($item in $response.value) { $results.Add($item) }
            $next = if ($response.PSObject.Properties.Name -contains '@odata.nextLink') {
                $response.'@odata.nextLink'
            }
            else {
                $null
            }
        }
        else {
            $results.Add($response)
            $next = $null
        }
    } while ($All -and $next)

    return $results.ToArray()
}

function Invoke-DeviceUpdateBatch {
    param([Parameter()][AllowEmptyCollection()][object[]]$Requests = @())

    if ($Requests.Count -eq 0) { return }
    for ($i = 0; $i -lt $Requests.Count; $i += 20) {
        $chunk = @($Requests[$i..([math]::Min($i + 19, $Requests.Count - 1))])
        $pending = [ordered]@{}
        $requestNumber = 0
        foreach ($request in $chunk) {
            $requestNumber++
            $pending["$requestNumber"] = $request
        }

        for ($attempt = 1; $attempt -le 4; $attempt++) {
            $batchRequests = foreach ($id in $pending.Keys) {
                $request = $pending[$id]
                @{
                    id = $id
                    method = 'PATCH'
                    url = "/devices/$($request.objectId)"
                    headers = @{ 'Content-Type' = 'application/json' }
                    body = @{
                        extensionAttributes = @{
                            $ExtensionAttributeName = $request.desiredValue
                        }
                    }
                }
            }

            $response = @(Invoke-GraphApi `
                -Uri 'https://graph.microsoft.com/v1.0/$batch' `
                -Method POST `
                -Body @{ requests = @($batchRequests) })

            if ($response.Count -eq 0 -or $null -eq $response[0].responses) {
                throw 'Microsoft Graph non ha restituito una risposta valida per il batch di aggiornamento device.'
            }

            $retry = [ordered]@{}
            foreach ($result in $response[0].responses) {
                $request = $pending["$($result.id)"]
                if ($result.status -lt 400) {
                    $script:UpdatedDevices++
                    $updateEvent = [ordered]@{
                        deviceName = $request.deviceName
                        deviceId = $request.deviceId
                        objectId = $request.objectId
                        attribute = $ExtensionAttributeName
                        previousValue = $request.currentValue
                        value = $request.desiredValue
                    } | ConvertTo-Json -Compress
                    Write-Log "[EXTENSION_ATTRIBUTE_UPDATE] $updateEvent" 'OK'
                    continue
                }

                if (($result.status -eq 429 -or $result.status -ge 500) -and $attempt -lt 4) {
                    $retry["$($result.id)"] = $request
                    continue
                }

                $detail = try { $result.body | ConvertTo-Json -Depth 5 -Compress } catch { '' }
                Write-Log "Aggiornamento device '$($request.deviceName)' fallito con status $($result.status): $detail" 'ERROR'
                $script:UpdateErrors++
            }

            if ($retry.Count -eq 0) { break }
            $pending = $retry
            Start-Sleep -Seconds ([math]::Min(30, [math]::Pow(2, $attempt)))
        }
    }
}

function Get-ManagedDeviceState {
    param([Parameter(Mandatory)][string]$OperatingSystem)

    $select = 'deviceName,azureADDeviceId,isEncrypted,operatingSystem,managementState'
    $staleStates = @(
        'retirePending', 'retireIssued', 'retireFailed',
        'wipePending', 'wipeIssued', 'wipeFailed', 'deletePending'
    )
    $filter = "operatingSystem eq '$($OperatingSystem.Replace("'","''"))'"
    Write-Log "Recupero managed device Intune con filtro: $filter"
    $devices = Invoke-GraphApi `
        -Uri "deviceManagement/managedDevices?`$filter=$filter&`$select=$select" `
        -All

    $state = @{}
    $unknownEncryptionState = 0
    foreach ($device in $devices) {
        $deviceId = [string]$device.azureADDeviceId
        if ([string]::IsNullOrWhiteSpace($deviceId) -or $deviceId -eq '00000000-0000-0000-0000-000000000000') {
            continue
        }
        if ($staleStates -contains [string]$device.managementState) { continue }
        if ($null -eq $device.isEncrypted) {
            $unknownEncryptionState++
            continue
        }

        $state[$deviceId] = [pscustomobject]@{
            DeviceName = [string]$device.deviceName
            IsEncrypted = [bool]$device.isEncrypted
        }
    }

    return [pscustomobject]@{
        Devices = $state
        UnknownEncryptionState = $unknownEncryptionState
    }
}

try {
    Write-Log '=== Nimbus.BitLockerGroupSync - extension attribute sync - avvio ==='
    Import-RuntimeConfiguration
    if ($WhatIfPreference) { $WhatIfOnly = $true }
    if ($ExtensionAttributeName -notin @(
            'extensionAttribute1', 'extensionAttribute2', 'extensionAttribute3',
            'extensionAttribute4', 'extensionAttribute5', 'extensionAttribute6',
            'extensionAttribute7', 'extensionAttribute8', 'extensionAttribute9',
            'extensionAttribute10', 'extensionAttribute11', 'extensionAttribute12',
            'extensionAttribute13', 'extensionAttribute14', 'extensionAttribute15'
        )) {
        throw "ExtensionAttributeName non valido: '$ExtensionAttributeName'."
    }
    if ([string]::IsNullOrWhiteSpace($EncryptedValue) -or [string]::IsNullOrWhiteSpace($NotEncryptedValue)) {
        throw 'EncryptedValue e NotEncryptedValue non possono essere vuoti.'
    }
    if ($EncryptedValue -eq $NotEncryptedValue) {
        throw 'EncryptedValue e NotEncryptedValue devono essere diversi.'
    }
    if ($WhatIfOnly) {
        Write-Log 'Modalita WhatIf attiva: nessun device verra aggiornato.' 'WARN'
    }

    Connect-GraphSession `
        -Mode $AuthenticationMode `
        -ManagedIdentityClientId $ManagedIdentityClientId `
        -TenantId $AppTenantId `
        -ApplicationClientId $AppClientId `
        -CertificateName $CertificateAssetName `
        -SecretVariableName $ClientSecretVariableName

    $managedState = Get-ManagedDeviceState -OperatingSystem $TargetOperatingSystem
    $managedDevices = $managedState.Devices
    Write-Log "Device Intune validi con stato cifratura noto: $($managedDevices.Count)."
    if ($managedState.UnknownEncryptionState -gt 0) {
        Write-Log "$($managedState.UnknownEncryptionState) device con isEncrypted nullo sono stati ignorati." 'WARN'
    }

    Write-Log "Recupero device Entra e valore corrente di $ExtensionAttributeName..."
    $entraDevices = Invoke-GraphApi `
        -Uri 'devices?$select=id,deviceId,displayName,extensionAttributes' `
        -All

    $entraByDeviceId = @{}
    foreach ($device in $entraDevices) {
        if (-not [string]::IsNullOrWhiteSpace([string]$device.deviceId)) {
            $entraByDeviceId[[string]$device.deviceId] = $device
        }
    }

    $updates = [System.Collections.Generic.List[object]]::new()
    $conflicts = [System.Collections.Generic.List[object]]::new()
    $unresolved = 0
    $alreadyCompliant = 0
    foreach ($deviceId in $managedDevices.Keys) {
        $managedDevice = $managedDevices[$deviceId]
        $entraDevice = $entraByDeviceId[$deviceId]
        if ($null -eq $entraDevice) {
            $unresolved++
            continue
        }

        $desiredValue = if ($managedDevice.IsEncrypted) { $EncryptedValue } else { $NotEncryptedValue }
        $currentValue = ''
        if ($null -ne $entraDevice.extensionAttributes) {
            $attributeProperty = $entraDevice.extensionAttributes.PSObject.Properties[$ExtensionAttributeName]
            if ($null -ne $attributeProperty) {
                $currentValue = [string]$attributeProperty.Value
            }
        }

        if ($currentValue -eq $desiredValue) {
            $alreadyCompliant++
            continue
        }

        $deviceName = if ([string]::IsNullOrWhiteSpace([string]$entraDevice.displayName)) {
            $managedDevice.DeviceName
        }
        else {
            [string]$entraDevice.displayName
        }
        if (-not [string]::IsNullOrWhiteSpace($currentValue) -and
            $currentValue -notin @($EncryptedValue, $NotEncryptedValue) -and
            -not $AllowValueTakeover) {
            $conflicts.Add([pscustomobject]@{
                    deviceName = $deviceName
                    objectId = [string]$entraDevice.id
                    currentValue = $currentValue
                })
            continue
        }
        $updates.Add([pscustomobject]@{
                deviceName = $deviceName
                deviceId = $deviceId
                objectId = [string]$entraDevice.id
                currentValue = $currentValue
                desiredValue = $desiredValue
            })
    }

    if ($ClearManagedValuesForOutOfScopeDevices) {
        foreach ($entraDevice in $entraDevices) {
            $deviceId = [string]$entraDevice.deviceId
            if ([string]::IsNullOrWhiteSpace($deviceId) -or $managedDevices.ContainsKey($deviceId)) { continue }
            if ($null -eq $entraDevice.extensionAttributes) { continue }

            $attributeProperty = $entraDevice.extensionAttributes.PSObject.Properties[$ExtensionAttributeName]
            $currentValue = if ($null -ne $attributeProperty) { [string]$attributeProperty.Value } else { '' }
            if ($currentValue -notin @($EncryptedValue, $NotEncryptedValue)) { continue }

            $updates.Add([pscustomobject]@{
                    deviceName = [string]$entraDevice.displayName
                    deviceId = $deviceId
                    objectId = [string]$entraDevice.id
                    currentValue = $currentValue
                    desiredValue = ''
                })
        }
    }

    Write-Log ("Valutazione {0}: totali={1}, conformi={2}, da aggiornare={3}, conflitti={4}, non risolti={5}, stato ignoto={6}" -f `
            $ExtensionAttributeName,
            $managedDevices.Count,
            $alreadyCompliant,
            $updates.Count,
            $conflicts.Count,
            $unresolved,
            $managedState.UnknownEncryptionState)

    if ($conflicts.Count -gt 0) {
        foreach ($conflict in $conflicts | Select-Object -First 20) {
            Write-Log ("Conflitto su device '{0}' ({1}): {2} contiene '{3}'." -f `
                    $conflict.deviceName,
                    $conflict.objectId,
                    $ExtensionAttributeName,
                    $conflict.currentValue) 'ERROR'
        }
        throw "$($conflicts.Count) device contengono valori non gestiti in $ExtensionAttributeName. Nessuna modifica applicata; abilitare esplicitamente AllowValueTakeover dopo aver verificato l'ownership dell'attributo."
    }

    if ($WhatIfOnly) {
        foreach ($update in $updates) {
            Write-Log ("[WHATIF] Device '{0}' ({1}): {2} '{3}' -> '{4}'" -f `
                    $update.deviceName,
                    $update.objectId,
                    $ExtensionAttributeName,
                    $update.currentValue,
                    $update.desiredValue) 'WARN'
        }
    }
    else {
        if ($updates.Count -gt 0) {
            Invoke-DeviceUpdateBatch -Requests $updates.ToArray()
        }
    }

    $cycleEvent = [ordered]@{
        attribute = $ExtensionAttributeName
        evaluated = $managedDevices.Count
        compliant = $alreadyCompliant
        requested = $updates.Count
        updated = $script:UpdatedDevices
        conflicts = $conflicts.Count
        unresolved = $unresolved
        unknownEncryptionState = $managedState.UnknownEncryptionState
        errors = $script:UpdateErrors
    } | ConvertTo-Json -Compress
    Write-Log "[EXTENSION_ATTRIBUTE_CYCLE] $cycleEvent" 'OK'

    if ($script:UpdateErrors -gt 0) {
        throw "Sincronizzazione completata con $($script:UpdateErrors) errori: alcuni device non sono stati aggiornati."
    }
    Write-Log '=== Extension attribute sync completata ===' 'OK'
}
catch {
    Write-Log "ERRORE FATALE: $($_.Exception.Message)" 'ERROR'
    Write-Log $_.ScriptStackTrace 'ERROR'
    throw
}
finally {
    try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { $null = $_ }
}
