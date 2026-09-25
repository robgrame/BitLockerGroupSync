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
    Version: 1.6.6

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
$script:UpdateErrorDetails = [System.Collections.Generic.List[object]]::new()
$script:UpdateErrorStatusCounts = @{}
$script:UpdateAbortReason = ''
$script:GraphOperationErrors = 0
$script:SafetyErrors = 0
$script:CycleEventWritten = $false
$script:CycleEvaluated = 0
$script:CycleCompliant = 0
$script:CycleRequested = 0
$script:CycleConflicts = 0
$script:CycleUnresolved = 0
$script:CycleUnknownEncryptionState = 0
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

    $entry = "[{0}] [{1}] {2}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'ERROR' { Write-Error -Message $entry -ErrorAction Continue }
        'WARN' { Write-Warning $entry }
        default { Write-Verbose $entry }
    }
}

function ConvertTo-Bool {
    param(
        [Parameter(Mandatory)][object]$Value,
        [Parameter(Mandatory)][string]$Name
    )

    if ($Value -is [bool]) { return $Value }
    switch (("$Value").Trim().ToLowerInvariant()) {
        { $_ -in @('true', '1', 'yes', 'y', 'on') } { return $true }
        { $_ -in @('false', '0', 'no', 'n', 'off', '') } { return $false }
        default { throw "Automation Variable 'BitLockerSyncRuntimeConfig' contiene un valore booleano non valido per '$Name': '$Value'." }
    }
}

function Get-GraphErrorStatusCode {
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        $sources = [System.Collections.Generic.List[object]]::new()
        $sources.Add($exception)
        $responseProperty = $exception.PSObject.Properties['Response']
        if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) {
            $sources.Add($responseProperty.Value)
        }

        foreach ($source in $sources) {
            $statusProperty = $source.PSObject.Properties['StatusCode']
            if ($null -eq $statusProperty -or $null -eq $statusProperty.Value) { continue }
            try { return [int]$statusProperty.Value } catch { $null = $_ }
        }

        $match = [regex]::Match(
            [string]$exception.Message,
            '(?i)(?:response\s+)?status(?:\s+code)?[^0-9]{0,80}(?<status>[1-5]\d{2})(?!\d)'
        )
        if ($match.Success) { return [int]$match.Groups['status'].Value }
        $exception = $exception.InnerException
    }
    return $null
}

function Test-GraphTransientError {
    param(
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [AllowNull()][Nullable[int]]$StatusCode
    )

    if ($null -ne $StatusCode) {
        return $StatusCode -in @(408, 423, 425, 429) -or $StatusCode -ge 500
    }

    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        if ($exception -is [System.TimeoutException] -or
            $exception -is [System.Net.Http.HttpRequestException] -or
            $exception -is [System.Threading.Tasks.TaskCanceledException] -or
            $exception -is [System.Net.WebException]) {
            return $true
        }
        $exception = $exception.InnerException
    }
    return $false
}

function Get-GraphRetryDelay {
    param(
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [Parameter(Mandatory)][ValidateRange(1, 10)][int]$Attempt
    )

    $retryAfter = 0
    try {
        $retryAfter = [int]$ErrorRecord.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds
    }
    catch { $retryAfter = 0 }

    if ($retryAfter -le 0) {
        try {
            $rawRetryAfter = $ErrorRecord.Exception.Response.Headers.GetValues('Retry-After') | Select-Object -First 1
            $retryAfter = [int]$rawRetryAfter
        }
        catch { $retryAfter = 0 }
    }
    if ($retryAfter -le 0) {
        $retryAfter = [math]::Pow(2, $Attempt)
    }
    return [math]::Min(30, $retryAfter)
}

function Import-RuntimeConfiguration {
    $variableName = 'BitLockerSyncRuntimeConfig'
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
        'TargetOperatingSystem',
        'AuthenticationMode',
        'ManagedIdentityClientId',
        'AppTenantId',
        'AppClientId',
        'CertificateAssetName',
        'ClientSecretVariableName'
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

        $value = [string]$value
        Set-Variable -Name $name -Value $value -Scope Script
        $imported++
    }
    if ($missing.Count -gt 0) {
        throw "Automation Variable '$variableName' incompleta. Chiavi mancanti: $($missing -join ', ')."
    }

    $optionalBooleanNames = @(
        'AllowValueTakeover'
        'ClearManagedValuesForOutOfScopeDevices'
    )
    foreach ($name in $optionalBooleanNames) {
        $property = if ($config -is [System.Collections.IDictionary]) {
            if ($config.Contains($name)) { $config[$name] }
        }
        else {
            $configProperty = $config.PSObject.Properties[$name]
            if ($null -ne $configProperty) { $configProperty.Value }
        }
        if ($null -ne $property) {
            Set-Variable -Name $name -Value (ConvertTo-Bool -Value $property -Name $name) -Scope Script
            $imported++
        }
    }
    $attributeVariables = [ordered]@{
        ExtensionAttributeName = 'BitLockerExtensionAttributeName'
        EncryptedValue         = 'BitLockerExtensionAttributeEncryptedValue'
        NotEncryptedValue      = 'BitLockerExtensionAttributeNotEncryptedValue'
    }
    foreach ($entry in $attributeVariables.GetEnumerator()) {
        try {
            $value = Get-AutomationVariable -Name $entry.Value -ErrorAction Stop
        }
        catch {
            throw "Automation Variable obbligatoria '$($entry.Value)' non disponibile: $($_.Exception.Message)"
        }
        if ($value -isnot [string]) {
            throw "Automation Variable obbligatoria '$($entry.Value)' deve essere di tipo String."
        }
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "Automation Variable obbligatoria '$($entry.Value)' vuota."
        }
        Set-Variable -Name $entry.Key -Value $value -Scope Script
        $imported++
    }
    Write-Log "Opzioni di sicurezza extension: AllowValueTakeover=$AllowValueTakeover; ClearManagedValuesForOutOfScopeDevices=$ClearManagedValuesForOutOfScopeDevices."
    Write-Log "Caricati $imported parametri dalle Automation Variables del runbook."
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
        $maxAttempts = 5
        while ($attempt -lt $maxAttempts) {
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
                $status = Get-GraphErrorStatusCode -ErrorRecord $_
                $isTransient = Test-GraphTransientError -ErrorRecord $_ -StatusCode $status
                if ($isTransient -and $attempt -lt $maxAttempts) {
                    $retryAfter = Get-GraphRetryDelay -ErrorRecord $_ -Attempt $attempt
                    $statusLabel = if ($null -eq $status) { $_.Exception.GetType().Name } else { "HTTP $status" }
                    Write-Log "Errore Graph transitorio durante $Method $next ($statusLabel). Retry tra $retryAfter s (tentativo $attempt/$maxAttempts)." 'WARN'
                    Start-Sleep -Seconds $retryAfter
                    continue
                }
                $_.Exception.Data['BitLockerGroupSync.GraphOperation'] = $true
                $_.Exception.Data['BitLockerGroupSync.GraphMethod'] = $Method
                $_.Exception.Data['BitLockerGroupSync.GraphUri'] = $next
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

function Get-BatchRetryDelay {
    param(
        [Parameter(Mandatory)][object]$Result,
        [Parameter(Mandatory)][ValidateRange(1, 10)][int]$Attempt
    )

    $delaySeconds = [math]::Min(30, [math]::Pow(2, $Attempt))
    $headersProperty = $Result.PSObject.Properties['headers']
    if ($null -eq $headersProperty -or $null -eq $headersProperty.Value) {
        return $delaySeconds
    }

    $headers = $headersProperty.Value
    $retryAfter = $null
    $retryAfterMilliseconds = $null
    if ($headers -is [System.Collections.IDictionary]) {
        foreach ($key in $headers.Keys) {
            if ([string]$key -ieq 'Retry-After') { $retryAfter = $headers[$key] }
            if ([string]$key -ieq 'x-ms-retry-after-ms') { $retryAfterMilliseconds = $headers[$key] }
        }
    }
    else {
        foreach ($property in $headers.PSObject.Properties) {
            if ($property.Name -ieq 'Retry-After') { $retryAfter = $property.Value }
            if ($property.Name -ieq 'x-ms-retry-after-ms') { $retryAfterMilliseconds = $property.Value }
        }
    }

    $parsed = 0
    if ([int]::TryParse([string]$retryAfterMilliseconds, [ref]$parsed) -and $parsed -gt 0) {
        return [math]::Min(30, [math]::Ceiling($parsed / 1000))
    }
    if ([int]::TryParse([string]$retryAfter, [ref]$parsed) -and $parsed -gt 0) {
        return [math]::Min(30, $parsed)
    }
    return $delaySeconds
}

function Register-DeviceUpdateError {
    param(
        [Parameter(Mandatory)][object]$Request,
        [Parameter(Mandatory)][object]$Result
    )

    $status = [int]$Result.status
    $statusKey = [string]$status
    if (-not $script:UpdateErrorStatusCounts.ContainsKey($statusKey)) {
        $script:UpdateErrorStatusCounts[$statusKey] = 0
    }
    $script:UpdateErrorStatusCounts[$statusKey]++

    $errorCode = ''
    $errorMessage = ''
    $bodyProperty = $Result.PSObject.Properties['body']
    if ($null -ne $bodyProperty -and $null -ne $bodyProperty.Value) {
        $body = $bodyProperty.Value
        $graphError = if ($body -is [System.Collections.IDictionary]) {
            if ($body.Contains('error')) { $body['error'] }
        }
        else {
            $errorProperty = $body.PSObject.Properties['error']
            if ($null -ne $errorProperty) { $errorProperty.Value }
        }

        if ($null -ne $graphError) {
            if ($graphError -is [System.Collections.IDictionary]) {
                if ($graphError.Contains('code')) { $errorCode = [string]$graphError['code'] }
                if ($graphError.Contains('message')) { $errorMessage = [string]$graphError['message'] }
            }
            else {
                $codeProperty = $graphError.PSObject.Properties['code']
                $messageProperty = $graphError.PSObject.Properties['message']
                if ($null -ne $codeProperty) { $errorCode = [string]$codeProperty.Value }
                if ($null -ne $messageProperty) { $errorMessage = [string]$messageProperty.Value }
            }
        }
        elseif ($body -is [string]) {
            $errorMessage = [string]$body
        }
    }

    $detail = [ordered]@{
        deviceName = [string]$Request.deviceName
        deviceId = [string]$Request.deviceId
        objectId = [string]$Request.objectId
        status = $status
        code = $errorCode
        message = $errorMessage
        guidance = if ($status -eq 403 -and $errorCode -eq 'Authorization_RequestDenied') {
            "Verificare l'application permission Microsoft Graph Device.ReadWrite.All e il relativo admin consent sull'identita usata dal job."
        }
        else {
            ''
        }
    }
    $script:UpdateErrorDetails.Add([pscustomobject]$detail)
    $script:UpdateErrors++

    Write-Log ("[EXTENSION_ATTRIBUTE_ERROR] {0}" -f ($detail | ConvertTo-Json -Compress)) 'ERROR'
}

function Write-ExtensionCycleEvent {
    param(
        [Parameter(Mandatory)][int]$Evaluated,
        [Parameter(Mandatory)][int]$Compliant,
        [Parameter(Mandatory)][int]$Requested,
        [Parameter(Mandatory)][int]$Conflicts,
        [Parameter(Mandatory)][int]$Unresolved,
        [Parameter(Mandatory)][int]$UnknownEncryptionState
    )

    $aborted = -not [string]::IsNullOrWhiteSpace($script:UpdateAbortReason)
    $totalErrors = $script:UpdateErrors + $script:GraphOperationErrors + $script:SafetyErrors
    $cycleEvent = [ordered]@{
        attribute = $ExtensionAttributeName
        evaluated = $Evaluated
        compliant = $Compliant
        requested = $Requested
        updated = $script:UpdatedDevices
        conflicts = $Conflicts
        unresolved = $Unresolved
        unknownEncryptionState = $UnknownEncryptionState
        errors = $totalErrors
        errorStatusCounts = $script:UpdateErrorStatusCounts
        errorSamples = @($script:UpdateErrorDetails | Select-Object -First 5)
        aborted = $aborted
        skipped = [math]::Max(0, $Requested - $script:UpdatedDevices - $script:UpdateErrors)
    } | ConvertTo-Json -Compress
    $script:CycleEventWritten = $true
    Write-Output "[EXTENSION_ATTRIBUTE_CYCLE] $cycleEvent"
    $healthEvent = [ordered]@{
        aborted = $aborted
        errors = $totalErrors
        evaluated = $Evaluated
        updated = $script:UpdatedDevices
        compliant = $Compliant
    } | ConvertTo-Json -Compress
    Write-Output "[EXTENSION_ATTRIBUTE_HEALTH] $healthEvent"
}

function Get-OutOfScopeClearRequest {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$EntraDevices,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$AuthoritativeDeviceIds,
        [Parameter(Mandatory)][bool]$CleanupSafe
    )

    if (-not $CleanupSafe) {
        return [pscustomobject]@{
            Requests = @()
            BlockReason = 'L inventario Intune non e sufficientemente completo per una pulizia sicura.'
        }
    }

    $requests = [System.Collections.Generic.List[object]]::new()
    foreach ($entraDevice in $EntraDevices) {
        $deviceId = [string]$entraDevice.deviceId
        if ([string]::IsNullOrWhiteSpace($deviceId) -or $AuthoritativeDeviceIds.Contains($deviceId)) { continue }
        if ($null -eq $entraDevice.extensionAttributes) { continue }

        $attributeProperty = $entraDevice.extensionAttributes.PSObject.Properties[$ExtensionAttributeName]
        $currentValue = if ($null -ne $attributeProperty) { [string]$attributeProperty.Value } else { '' }
        if ($currentValue -notin @($EncryptedValue, $NotEncryptedValue)) { continue }

        $requests.Add([pscustomobject]@{
                deviceName = [string]$entraDevice.displayName
                deviceId = $deviceId
                objectId = [string]$entraDevice.id
                currentValue = $currentValue
                desiredValue = ''
            })
    }

    $maxClearsPerCycle = [math]::Max(1, [math]::Ceiling($AuthoritativeDeviceIds.Count * 0.25))
    if ($requests.Count -gt $maxClearsPerCycle) {
        return [pscustomobject]@{
            Requests = @()
            BlockReason = "Pulizia bloccata dal limite di sicurezza: candidati=$($requests.Count), massimoPerCiclo=$maxClearsPerCycle, inventarioAutorevole=$($AuthoritativeDeviceIds.Count)."
        }
    }

    return [pscustomobject]@{
        Requests = $requests.ToArray()
        BlockReason = ''
    }
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

        $maxAttempts = 4
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
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

            $responsesProperty = if ($response.Count -gt 0 -and $null -ne $response[0]) {
                $response[0].PSObject.Properties['responses']
            }
            else {
                $null
            }
            $batchResponses = if ($null -ne $responsesProperty -and $null -ne $responsesProperty.Value) {
                @($responsesProperty.Value)
            }
            else {
                @()
            }
            $expectedIds = @($pending.Keys | ForEach-Object { [string]$_ })
            $actualIds = @(
                $batchResponses | ForEach-Object {
                    $idProperty = $_.PSObject.Properties['id']
                    if ($null -ne $idProperty -and $null -ne $idProperty.Value) {
                        [string]$idProperty.Value
                    }
                    else {
                        ''
                    }
                }
            )
            $uniqueActualIds = @($actualIds | Sort-Object -Unique)
            $missingIds = @($expectedIds | Where-Object { $_ -notin $uniqueActualIds })
            $unknownIds = @($uniqueActualIds | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -notin $expectedIds })
            $duplicateIds = @(
                $actualIds |
                    Group-Object |
                    Where-Object Count -gt 1 |
                    ForEach-Object Name
            )
            if ($missingIds.Count -gt 0 -or $unknownIds.Count -gt 0 -or $duplicateIds.Count -gt 0) {
                $integrityMessage = "Risposta Graph batch incompleta o incoerente: attese=$($expectedIds.Count), ricevute=$($actualIds.Count), mancanti=$($missingIds -join ','), sconosciute=$($unknownIds -join ','), duplicate=$($duplicateIds -join ',')."
                foreach ($id in $expectedIds) {
                    Register-DeviceUpdateError `
                        -Request $pending[$id] `
                        -Result ([pscustomobject]@{
                            status = 0
                            body = @{
                                error = @{
                                    code = 'IncompleteBatchResponse'
                                    message = $integrityMessage
                                }
                            }
                        })
                }
                $script:UpdateAbortReason = "$integrityMessage Il ciclo viene interrotto e verra riconciliato dalla prossima esecuzione."
                Write-Log $script:UpdateAbortReason 'ERROR'
                return
            }

            $retry = [ordered]@{}
            $retryDelaySeconds = [math]::Min(30, [math]::Pow(2, $attempt))
            $authorizationFailures = [System.Collections.Generic.List[object]]::new()
            foreach ($result in $batchResponses) {
                $request = $pending["$($result.id)"]
                $statusProperty = $result.PSObject.Properties['status']
                $status = 0
                $hasValidStatus = $null -ne $statusProperty -and
                    $null -ne $statusProperty.Value -and
                    [int]::TryParse([string]$statusProperty.Value, [ref]$status) -and
                    $status -ge 100 -and
                    $status -le 599
                if (-not $hasValidStatus) {
                    Register-DeviceUpdateError `
                        -Request $request `
                        -Result ([pscustomobject]@{
                            status = 0
                            body = @{
                                error = @{
                                    code = 'InvalidBatchStatus'
                                    message = "La risposta Graph per la richiesta $($result.id) non contiene uno status HTTP valido."
                                }
                            }
                        })
                    $script:UpdateAbortReason = 'Risposta Graph batch con status HTTP mancante o non valido. Il ciclo viene interrotto e verra riconciliato dalla prossima esecuzione.'
                    Write-Log $script:UpdateAbortReason 'ERROR'
                    return
                }

                if ($status -ge 300 -and $status -le 399) {
                    Register-DeviceUpdateError `
                        -Request $request `
                        -Result ([pscustomobject]@{
                            status = $status
                            body = @{
                                error = @{
                                    code = 'InvalidBatchStatus'
                                    message = "Microsoft Graph ha restituito uno status redirect HTTP $status non valido per un update batch."
                                }
                            }
                        })
                    $script:UpdateAbortReason = "Risposta Graph batch con status redirect HTTP $status. Il ciclo viene interrotto e verra riconciliato dalla prossima esecuzione."
                    Write-Log $script:UpdateAbortReason 'ERROR'
                    return
                }

                if ($status -ge 200 -and $status -le 299) {
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

                $isTransient = $status -in @(408, 423, 425, 429) -or $status -ge 500
                if ($isTransient -and $attempt -lt $maxAttempts) {
                    $retry["$($result.id)"] = $request
                    $retryDelaySeconds = [math]::Max(
                        $retryDelaySeconds,
                        (Get-BatchRetryDelay -Result $result -Attempt $attempt)
                    )
                    continue
                }

                Register-DeviceUpdateError -Request $request -Result $result
                if ($status -in @(401, 403)) {
                    $authorizationFailures.Add($result)
                }
            }

            if ($script:UpdatedDevices -eq 0 -and
                $pending.Count -gt 1 -and
                $authorizationFailures.Count -eq $pending.Count) {
                $statuses = @($authorizationFailures | ForEach-Object { [int]$_.status } | Sort-Object -Unique)
                $statusSummary = ($statuses | ForEach-Object { "HTTP $_" }) -join '/'
                $guidance = if ($statuses -contains 403) {
                    "Verificare che l'identita usata dal job disponga dell'application permission Microsoft Graph Device.ReadWrite.All con admin consent."
                }
                else {
                    "Verificare configurazione e validita dell'identita usata dal job."
                }
                $script:UpdateAbortReason = "Microsoft Graph ha rifiutato tutti i $($pending.Count) update del batch corrente con $statusSummary. $guidance"
                Write-Log $script:UpdateAbortReason 'ERROR'
                return
            }

            if ($retry.Count -eq 0) { break }
            $pending = $retry
            Write-Log "$($pending.Count) update device temporaneamente falliti; retry tra $retryDelaySeconds s (tentativo $attempt/$maxAttempts)." 'WARN'
            Start-Sleep -Seconds $retryDelaySeconds
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
    $authoritativeDeviceIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $unknownEncryptionState = 0
    $uncorrelatedDevices = 0
    foreach ($device in $devices) {
        $deviceId = [string]$device.azureADDeviceId
        if ([string]::IsNullOrWhiteSpace($deviceId) -or $deviceId -eq '00000000-0000-0000-0000-000000000000') {
            $uncorrelatedDevices++
            continue
        }
        [void]$authoritativeDeviceIds.Add($deviceId)
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
        AuthoritativeDeviceIds = $authoritativeDeviceIds
        CleanupSafe = $uncorrelatedDevices -eq 0 -and $authoritativeDeviceIds.Count -gt 0
        UncorrelatedDevices = $uncorrelatedDevices
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
    if ($EncryptedValue.Length -gt 1024 -or $NotEncryptedValue.Length -gt 1024) {
        throw 'EncryptedValue e NotEncryptedValue non possono superare 1024 caratteri.'
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
    $script:CycleEvaluated = $managedDevices.Count
    $script:CycleUnknownEncryptionState = $managedState.UnknownEncryptionState
    Write-Log "Device Intune validi con stato cifratura noto: $($managedDevices.Count)."
    if ($managedState.UnknownEncryptionState -gt 0) {
        Write-Log "$($managedState.UnknownEncryptionState) device con isEncrypted nullo sono stati ignorati." 'WARN'
    }
    if ($managedState.UncorrelatedDevices -gt 0) {
        Write-Log "$($managedState.UncorrelatedDevices) device Intune senza azureADDeviceId valido non possono essere correlati a Entra." 'WARN'
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
        $cleanup = Get-OutOfScopeClearRequest `
            -EntraDevices $entraDevices `
            -AuthoritativeDeviceIds $managedState.AuthoritativeDeviceIds `
            -CleanupSafe $managedState.CleanupSafe
        if (-not [string]::IsNullOrWhiteSpace($cleanup.BlockReason)) {
            $script:SafetyErrors++
            Write-Log "[EXTENSION_ATTRIBUTE_SAFETY] $($cleanup.BlockReason)" 'ERROR'
        }
        else {
            foreach ($request in $cleanup.Requests) {
                $updates.Add($request)
            }
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
    $script:CycleCompliant = $alreadyCompliant
    $script:CycleRequested = $updates.Count
    $script:CycleConflicts = $conflicts.Count
    $script:CycleUnresolved = $unresolved

    if ($conflicts.Count -gt 0) {
        $script:UpdateAbortReason = "$($conflicts.Count) device contengono valori non gestiti in $ExtensionAttributeName."
        $conflictEvent = [ordered]@{
            attribute = $ExtensionAttributeName
            evaluated = $managedDevices.Count
            conflicts = $conflicts.Count
            unresolved = $unresolved
            unknownEncryptionState = $managedState.UnknownEncryptionState
        } | ConvertTo-Json -Compress
        Write-Log "[EXTENSION_ATTRIBUTE_CONFLICT] $conflictEvent" 'ERROR'

        foreach ($conflict in $conflicts | Select-Object -First 20) {
            Write-Log ("Conflitto su device '{0}' ({1}): {2} contiene '{3}'." -f `
                    $conflict.deviceName,
                    $conflict.objectId,
                    $ExtensionAttributeName,
                    $conflict.currentValue) 'ERROR'
        }
        Write-ExtensionCycleEvent `
            -Evaluated $managedDevices.Count `
            -Compliant $alreadyCompliant `
            -Requested $updates.Count `
            -Conflicts $conflicts.Count `
            -Unresolved $unresolved `
            -UnknownEncryptionState $managedState.UnknownEncryptionState
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

    Write-ExtensionCycleEvent `
        -Evaluated $managedDevices.Count `
        -Compliant $alreadyCompliant `
        -Requested $updates.Count `
        -Conflicts $conflicts.Count `
        -Unresolved $unresolved `
        -UnknownEncryptionState $managedState.UnknownEncryptionState

    if ($script:UpdateErrors -gt 0) {
        $statusSummary = @(
            $script:UpdateErrorStatusCounts.GetEnumerator() |
                Sort-Object Name |
                ForEach-Object {
                    if ($_.Name -eq '0') { "GraphResponse=$($_.Value)" } else { "HTTP $($_.Name)=$($_.Value)" }
                }
        ) -join ', '
        $sampleSummary = @(
            $script:UpdateErrorDetails |
                Select-Object -First 3 |
                ForEach-Object {
                    $reason = if (-not [string]::IsNullOrWhiteSpace($_.code)) {
                        "$($_.code): $($_.message)"
                    }
                    elseif (-not [string]::IsNullOrWhiteSpace($_.message)) {
                        $_.message
                    }
                    else {
                        'nessun dettaglio Graph'
                    }
                    $guidance = if ([string]::IsNullOrWhiteSpace($_.guidance)) { '' } else { " $($_.guidance)" }
                    "$($_.deviceName) [HTTP $($_.status)] $reason$guidance"
                }
        ) -join ' | '
        $abortSummary = if ([string]::IsNullOrWhiteSpace($script:UpdateAbortReason)) {
            ''
        }
        else {
            " $script:UpdateAbortReason"
        }
        Write-Log "Sincronizzazione completata con $($script:UpdateErrors) errori gestiti ($statusSummary). Esempi: $sampleSummary.$abortSummary" 'ERROR'
        Write-Log 'Il job prosegue come Completed; verificare lo stream Error e il workbook prima della prossima esecuzione.' 'WARN'
    }
    Write-Log '=== Extension attribute sync completata ===' 'OK'
}
catch {
    $isHandledGraphFailure = $_.Exception.Data.Contains('BitLockerGroupSync.GraphOperation')
    if ($isHandledGraphFailure) {
        $script:GraphOperationErrors++
        $method = [string]$_.Exception.Data['BitLockerGroupSync.GraphMethod']
        $uri = [string]$_.Exception.Data['BitLockerGroupSync.GraphUri']
        $status = Get-GraphErrorStatusCode -ErrorRecord $_
        $statusLabel = if ($null -eq $status) { 'status non disponibile' } else { "HTTP $status" }
        $script:UpdateAbortReason = "Operazione Graph $method non completata ($statusLabel). La sincronizzazione e stata interrotta in sicurezza senza applicare ulteriori modifiche."
        Write-Log "[GRAPH_OPERATION_ERROR] method=$method uri=$uri status=$statusLabel message=$($_.Exception.Message)" 'ERROR'

        if (-not $script:CycleEventWritten) {
            Write-ExtensionCycleEvent `
                -Evaluated $script:CycleEvaluated `
                -Compliant $script:CycleCompliant `
                -Requested $script:CycleRequested `
                -Conflicts $script:CycleConflicts `
                -Unresolved $script:CycleUnresolved `
                -UnknownEncryptionState $script:CycleUnknownEncryptionState
        }
        Write-Log 'Errore Graph gestito: il job termina Completed con evidenza negli stream Error/Output e nel workbook.' 'WARN'
    }
    else {
        Write-Log "ERRORE FATALE: $($_.Exception.Message)" 'ERROR'
        Write-Log $_.ScriptStackTrace 'ERROR'
        throw
    }
}
finally {
    try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { $null = $_ }
}
