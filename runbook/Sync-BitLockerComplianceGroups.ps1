<#
.SYNOPSIS
    Crea e mantiene dinamicamente gruppi di sicurezza in Entra ID basandosi sullo stato
    di cifratura BitLocker dei device Intune e sulla presenza della recovery key in Entra.

.DESCRIPTION
    Runbook di Azure Automation (PowerShell 7.2) pensato per essere eseguito con la
    system-assigned managed identity dell'Automation Account (autenticazione app-only a
    Microsoft Graph, nessun segreto).

    Per ogni device Windows gestito da Intune valuta due condizioni:
      1. isEncrypted        -> disco cifrato (BitLocker attivo).
      2. recovery key        -> esiste almeno una BitLocker recovery key salvata su Entra.

    In base a queste condizioni popola (in modo idempotente) quattro gruppi di sicurezza:
      <Prefix>-Encrypted, <Prefix>-NotEncrypted, <Prefix>-KeyEscrowed, <Prefix>-KeyMissing.

.NOTES
    Permessi Graph (application) richiesti sulla managed identity:
      - DeviceManagementManagedDevices.Read.All
      - BitlockerKey.Read.All
      - Device.Read.All
      - Group.ReadWrite.All

    Modulo richiesto nell'Automation Account: Microsoft.Graph.Authentication.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Prefisso usato per il naming dei gruppi di sicurezza gestiti dal runbook.
    [Parameter()]
    [string]$GroupPrefix = 'SG-Intune-BitLocker',

    # Sistema operativo dei device da valutare (filtro su managedDevice.operatingSystem).
    [Parameter()]
    [string]$TargetOperatingSystem = 'Windows',

    # Se $true non applica modifiche: mostra soltanto cosa verrebbe fatto.
    [Parameter()]
    [bool]$WhatIfOnly = $false,

    # Client id di una user-assigned managed identity (facoltativo). Se vuoto usa la system-assigned.
    [Parameter()]
    [string]$UserAssignedClientId = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:GraphBase = 'https://graph.microsoft.com/v1.0'

#region Helper

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-Output ("[{0}] [{1}] {2}" -f $ts, $Level, $Message)
}

function Connect-Graph {
    param([string]$ClientId)

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        throw "Modulo 'Microsoft.Graph.Authentication' non disponibile nell'Automation Account."
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    if ([string]::IsNullOrWhiteSpace($ClientId)) {
        Write-Log 'Connessione a Graph con la system-assigned managed identity...'
        Connect-MgGraph -Identity -NoWelcome
    }
    else {
        Write-Log "Connessione a Graph con la user-assigned managed identity ($ClientId)..."
        Connect-MgGraph -Identity -ClientId $ClientId -NoWelcome
    }
    $ctx = Get-MgContext
    if (-not $ctx) { throw 'Connessione a Microsoft Graph fallita.' }
    Write-Log ("Connesso al tenant {0} come app '{1}'." -f $ctx.TenantId, $ctx.AppName) 'OK'
}

# Invoca Graph gestendo paging e throttling (429) con rispetto di Retry-After.
function Invoke-GraphRequest {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method = 'GET',
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
                $params = @{ Method = $Method; Uri = $next; OutputType = 'PSObject'; ErrorAction = 'Stop' }
                if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
                    $params.Body = ($Body | ConvertTo-Json -Depth 10)
                    $params.ContentType = 'application/json'
                }
                $response = Invoke-MgGraphRequest @params
                break
            }
            catch {
                $status = $null
                try { $status = [int]$_.Exception.Response.StatusCode } catch { }
                if (($status -eq 429 -or $status -ge 500) -and $attempt -le 5) {
                    $retryAfter = 0
                    try { $retryAfter = [int]$_.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds } catch { }
                    if ($retryAfter -le 0) { $retryAfter = [math]::Min(60, [math]::Pow(2, $attempt)) }
                    Write-Log "Throttling/errore transitorio ($status). Retry tra $retryAfter s (tentativo $attempt)." 'WARN'
                    Start-Sleep -Seconds $retryAfter
                    continue
                }
                throw
            }
        }

        if ($null -ne $response) {
            if ($response.PSObject.Properties.Name -contains 'value') {
                foreach ($item in $response.value) { $results.Add($item) }
                $next = $response.'@odata.nextLink'
            }
            else {
                $results.Add($response)
                $next = $null
            }
        }
        else { $next = $null }
    } while ($All -and $next)

    return $results
}

# Restituisce l'id del gruppo, creandolo se assente. mailNickname derivato dal displayName.
function Get-OrCreateGroup {
    param([Parameter(Mandatory)][string]$DisplayName, [string]$Description)

    $filter = "displayName eq '$($DisplayName.Replace("'","''"))'"
    $existing = Invoke-GraphRequest -Uri "groups?`$filter=$filter&`$select=id,displayName" -All
    if ($existing.Count -gt 0) {
        Write-Log "Gruppo gia' presente: $DisplayName ($($existing[0].id))"
        return $existing[0].id
    }

    $nickname = ($DisplayName -replace '[^a-zA-Z0-9]', '').ToLower()
    if ([string]::IsNullOrWhiteSpace($nickname)) { $nickname = "grp$([guid]::NewGuid().ToString('N').Substring(0,8))" }

    if ($WhatIfOnly) {
        Write-Log "[WHATIF] Creerei il gruppo '$DisplayName'." 'WARN'
        return $null
    }

    $body = @{
        displayName     = $DisplayName
        description     = $Description
        mailEnabled     = $false
        mailNickname    = $nickname
        securityEnabled = $true
    }
    $group = Invoke-GraphRequest -Uri 'groups' -Method POST -Body $body
    Write-Log "Creato gruppo '$DisplayName' ($($group.id))." 'OK'
    return $group.id
}

# Riconcilia la membership di un gruppo (add/remove) verso l'insieme desiderato di objectId.
function Sync-GroupMembership {
    param(
        [Parameter(Mandatory)][string]$GroupId,
        [Parameter(Mandatory)][string]$GroupName,
        [Parameter(Mandatory)][string[]]$DesiredObjectIds
    )

    if ([string]::IsNullOrWhiteSpace($GroupId)) {
        Write-Log "Salto '$GroupName' (nessun id gruppo, probabile modalita' WhatIf)." 'WARN'
        return
    }

    $current = Invoke-GraphRequest -Uri "groups/$GroupId/members?`$select=id" -All | ForEach-Object { $_.id }
    $currentSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$current, [System.StringComparer]::OrdinalIgnoreCase)
    $desiredSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$DesiredObjectIds, [System.StringComparer]::OrdinalIgnoreCase)

    $toAdd = $DesiredObjectIds | Where-Object { -not $currentSet.Contains($_) } | Select-Object -Unique
    $toRemove = $current | Where-Object { -not $desiredSet.Contains($_) } | Select-Object -Unique

    Write-Log ("Gruppo '{0}': correnti={1}, desiderati={2}, +add={3}, -remove={4}" -f `
            $GroupName, $currentSet.Count, $desiredSet.Count, ($toAdd | Measure-Object).Count, ($toRemove | Measure-Object).Count)

    foreach ($id in $toAdd) {
        if ($WhatIfOnly) { Write-Log "[WHATIF] Aggiungerei $id a '$GroupName'."; continue }
        try {
            $body = @{ '@odata.id' = "$script:GraphBase/directoryObjects/$id" }
            Invoke-GraphRequest -Uri "groups/$GroupId/members/`$ref" -Method POST -Body $body | Out-Null
        }
        catch { Write-Log "Errore add $id a '$GroupName': $($_.Exception.Message)" 'ERROR' }
    }
    foreach ($id in $toRemove) {
        if ($WhatIfOnly) { Write-Log "[WHATIF] Rimuoverei $id da '$GroupName'."; continue }
        try {
            Invoke-GraphRequest -Uri "groups/$GroupId/members/$id/`$ref" -Method DELETE | Out-Null
        }
        catch { Write-Log "Errore remove $id da '$GroupName': $($_.Exception.Message)" 'ERROR' }
    }
}

#endregion Helper

#region Main

$summary = [ordered]@{}
try {
    Write-Log '=== Nimbus.BitLockerGroupSync - avvio ==='
    if ($WhatIfOnly) { Write-Log 'Modalita WhatIf attiva: nessuna modifica verra applicata.' 'WARN' }

    Connect-Graph -ClientId $UserAssignedClientId

    # 1) Gruppi target
    $groupIds = @{
        Encrypted    = Get-OrCreateGroup -DisplayName "$GroupPrefix-Encrypted"    -Description 'Device Intune con disco cifrato (isEncrypted=true).'
        NotEncrypted = Get-OrCreateGroup -DisplayName "$GroupPrefix-NotEncrypted" -Description 'Device Intune con disco NON cifrato (isEncrypted=false).'
        KeyEscrowed  = Get-OrCreateGroup -DisplayName "$GroupPrefix-KeyEscrowed"  -Description 'Device con BitLocker recovery key salvata in Entra.'
        KeyMissing   = Get-OrCreateGroup -DisplayName "$GroupPrefix-KeyMissing"   -Description 'Device cifrati SENZA recovery key salvata in Entra.'
    }

    # 2) Managed device Intune
    Write-Log 'Recupero managed device da Intune...'
    $osFilter = "operatingSystem eq '$TargetOperatingSystem'"
    $select = 'id,deviceName,azureADDeviceId,isEncrypted,operatingSystem,complianceState'
    $devices = Invoke-GraphRequest -Uri "deviceManagement/managedDevices?`$filter=$osFilter&`$select=$select" -All
    Write-Log "Trovati $($devices.Count) managed device '$TargetOperatingSystem'."

    # 3) Recovery key BitLocker -> set di deviceId con almeno una chiave
    Write-Log 'Recupero BitLocker recovery key da Entra...'
    $keys = Invoke-GraphRequest -Uri "informationProtection/bitlocker/recoveryKeys?`$select=id,deviceId" -All
    $devicesWithKey = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($k in $keys) { if ($k.deviceId) { [void]$devicesWithKey.Add([string]$k.deviceId) } }
    Write-Log "Trovate $($keys.Count) recovery key su $($devicesWithKey.Count) device distinti."

    # 4) Mappa deviceId (Entra) -> objectId del device Entra
    Write-Log 'Costruzione mappa device Entra (deviceId -> objectId)...'
    $entraDevices = Invoke-GraphRequest -Uri "devices?`$select=id,deviceId" -All
    $deviceIdToObjectId = @{}
    foreach ($d in $entraDevices) { if ($d.deviceId) { $deviceIdToObjectId[[string]$d.deviceId] = [string]$d.id } }
    Write-Log "Mappati $($deviceIdToObjectId.Count) device Entra."

    # 5) Calcolo insiemi desiderati
    $desired = @{ Encrypted = [System.Collections.Generic.List[string]]::new(); NotEncrypted = [System.Collections.Generic.List[string]]::new(); KeyEscrowed = [System.Collections.Generic.List[string]]::new(); KeyMissing = [System.Collections.Generic.List[string]]::new() }
    $unresolved = 0

    foreach ($dev in $devices) {
        $aadId = [string]$dev.azureADDeviceId
        if ([string]::IsNullOrWhiteSpace($aadId) -or $aadId -eq '00000000-0000-0000-0000-000000000000') { continue }
        $objectId = $deviceIdToObjectId[$aadId]
        if ([string]::IsNullOrWhiteSpace($objectId)) { $unresolved++; continue }

        $isEncrypted = [bool]$dev.isEncrypted
        $hasKey = $devicesWithKey.Contains($aadId)

        if ($isEncrypted) { $desired.Encrypted.Add($objectId) } else { $desired.NotEncrypted.Add($objectId) }
        if ($hasKey) { $desired.KeyEscrowed.Add($objectId) }
        elseif ($isEncrypted) { $desired.KeyMissing.Add($objectId) }  # cifrato ma senza chiave = rischio
    }
    if ($unresolved -gt 0) { Write-Log "$unresolved device Intune senza corrispondente oggetto Entra (ignorati)." 'WARN' }

    # 6) Riconciliazione membership
    Sync-GroupMembership -GroupId $groupIds.Encrypted    -GroupName "$GroupPrefix-Encrypted"    -DesiredObjectIds $desired.Encrypted.ToArray()
    Sync-GroupMembership -GroupId $groupIds.NotEncrypted -GroupName "$GroupPrefix-NotEncrypted" -DesiredObjectIds $desired.NotEncrypted.ToArray()
    Sync-GroupMembership -GroupId $groupIds.KeyEscrowed  -GroupName "$GroupPrefix-KeyEscrowed"  -DesiredObjectIds $desired.KeyEscrowed.ToArray()
    Sync-GroupMembership -GroupId $groupIds.KeyMissing   -GroupName "$GroupPrefix-KeyMissing"   -DesiredObjectIds $desired.KeyMissing.ToArray()

    $summary['DeviceValutati'] = $devices.Count
    $summary['Encrypted'] = $desired.Encrypted.Count
    $summary['NotEncrypted'] = $desired.NotEncrypted.Count
    $summary['KeyEscrowed'] = $desired.KeyEscrowed.Count
    $summary['KeyMissing (rischio)'] = $desired.KeyMissing.Count
    $summary['NonRisolti'] = $unresolved

    Write-Log '=== Riepilogo ===' 'OK'
    $summary.GetEnumerator() | ForEach-Object { Write-Log ("  {0}: {1}" -f $_.Key, $_.Value) 'OK' }
    Write-Log '=== Nimbus.BitLockerGroupSync - completato ===' 'OK'
}
catch {
    Write-Log "ERRORE FATALE: $($_.Exception.Message)" 'ERROR'
    Write-Log $_.ScriptStackTrace 'ERROR'
    throw
}
finally {
    try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { }
}

#endregion Main
