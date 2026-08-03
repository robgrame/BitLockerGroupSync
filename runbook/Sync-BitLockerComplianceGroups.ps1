<#
.SYNOPSIS
    Crea e mantiene dinamicamente gruppi di sicurezza in Entra ID basandosi sullo stato
    di cifratura BitLocker dei device Intune e sulla presenza della recovery key in Entra.

.DESCRIPTION
    Runbook di Azure Automation (PowerShell 7.2) pensato per essere eseguito con
    una user-assigned managed identity dedicata collegata all'Automation Account
    (autenticazione app-only a Microsoft Graph, nessun segreto).

    Per ogni device Windows gestito da Intune valuta due condizioni:
      1. isEncrypted        -> disco cifrato (BitLocker attivo).
      2. recovery key        -> esiste almeno una BitLocker recovery key salvata su Entra.

    In base a queste condizioni popola (in modo idempotente) fino a quattro gruppi di sicurezza:
      - <Encrypted>     (PRINCIPALE, sempre attivo): device con disco cifrato (isEncrypted=true).
      - <NotEncrypted>  (opzionale): device con disco NON cifrato.
      - <KeyEscrowed>   (opzionale): device con recovery key salvata in Entra.
      - <KeyMissing>    (opzionale): device cifrati SENZA recovery key (rischio compliance).

    I gruppi opzionali si abilitano con EnableNotEncryptedGroup / EnableKeyEscrowedGroup /
    EnableKeyMissingGroup. Il nome di ciascun gruppo e' personalizzabile tramite i parametri
    *GroupName; se non specificato viene derivato da GroupPrefix.

    La verifica dell'escrow della recovery key (controllo "puntuale" su Entra) e' governata dal
    master switch EnableKeyEscrowCheck (default 'true'). Impostandolo a 'false' il runbook salta
    del tutto il recupero delle recovery key e disabilita i gruppi/alert che ne dipendono
    (KeyEscrowed, KeyMissing, alert di soglia); il gruppo Encrypted non e' influenzato.

    Ottimizzazioni:
      - Scritture di membership in $batch (chunk da 20) per ridurre le chiamate.
      - Filtro dei device retired/wiped (stale) prima della valutazione.
      - Retry con backoff su throttling (429/5xx) e sul 400 di replica dei gruppi appena creati.
      - Alert opzionale (webhook) quando i device cifrati SENZA recovery key superano una soglia.
      - Notifica opzionale (webhook) del riepilogo a ogni run.

.NOTES
    Permessi Graph (application) richiesti sulla managed identity (least privilege):
      - DeviceManagementManagedDevices.Read.All
      - BitlockerKey.Read.All
      - Device.ReadWrite.All   (necessario per aggiungere oggetti device ai gruppi)
      - Group.Create
      - GroupMember.ReadWrite.All

    Modulo richiesto nell'Automation Account: Microsoft.Graph.Authentication.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Prefisso usato per il naming dei gruppi quando non ne viene specificato il nome esplicito.
    [Parameter()]
    [string]$GroupPrefix = 'SG-Intune-BitLocker',

    # --- Nomi dei gruppi (personalizzabili). Se lasciati vuoti vengono derivati da GroupPrefix. ---
    # Gruppo PRINCIPALE: device con disco cifrato (isEncrypted=true). Sempre creato/gestito.
    [Parameter()]
    [string]$EncryptedGroupName = '',

    # Gruppo OPZIONALE: device con disco NON cifrato (isEncrypted=false).
    [Parameter()]
    [string]$NotEncryptedGroupName = '',

    # Gruppo OPZIONALE: device con BitLocker recovery key salvata in Entra.
    [Parameter()]
    [string]$KeyEscrowedGroupName = '',

    # Gruppo OPZIONALE: device cifrati SENZA recovery key salvata in Entra (rischio compliance).
    [Parameter()]
    [string]$KeyMissingGroupName = '',

    # --- Abilitazione dei gruppi opzionali (il gruppo Encrypted e' sempre attivo). ---
    # Valori accettati: 'true'/'false' (case-insensitive). Stringa per compatibilita' con le
    # jobSchedule di Azure Automation, che passano i parametri come stringhe.
    [Parameter()]
    [string]$EnableNotEncryptedGroup = 'false',

    [Parameter()]
    [string]$EnableKeyEscrowedGroup = 'false',

    [Parameter()]
    [string]$EnableKeyMissingGroup = 'false',

    # --- Verifica dell'escrow della recovery key (controllo "puntuale" su Entra). ---
    # Master switch: quando 'false' salta COMPLETAMENTE il recupero/verifica delle recovery key
    # e neutralizza i gruppi/alert che ne dipendono (KeyEscrowed, KeyMissing, alert di soglia),
    # a prescindere dai rispettivi flag. Il gruppo Encrypted (basato solo su isEncrypted) non e'
    # influenzato. Default 'true' per non alterare il comportamento esistente.
    [Parameter()]
    [string]$EnableKeyEscrowCheck = 'true',

    # Sistema operativo dei device da valutare (filtro su managedDevice.operatingSystem).
    [Parameter()]
    [string]$TargetOperatingSystem = 'Windows',

    # Se $true non applica modifiche: mostra soltanto cosa verrebbe fatto.
    [Parameter()]
    [bool]$WhatIfOnly = $false,

    # Modalita di autenticazione Microsoft Graph.
    [Parameter()]
    [ValidateSet('ManagedIdentity', 'AppRegistrationCertificate', 'AppRegistrationSecret')]
    [string]$AuthenticationMode = 'ManagedIdentity',

    # Client id della UAMI dedicata collegata all'Automation Account.
    [Parameter()]
    [Alias('UserAssignedClientId')]
    [string]$ManagedIdentityClientId = '',

    # Tenant e client id dell'App Registration.
    [Parameter()]
    [string]$AppTenantId = '',

    [Parameter()]
    [string]$AppClientId = '',

    # Nome dell'Automation Certificate contenente il PFX con private key.
    [Parameter()]
    [string]$CertificateAssetName = 'NimbusGraphAuth',

    # Nome dell'Automation Variable cifrata contenente il client secret.
    [Parameter()]
    [string]$ClientSecretVariableName = 'NimbusGraphClientSecret',

    # Soglia di device cifrati SENZA recovery key oltre la quale inviare un alert. 0 = disabilitato.
    [Parameter()]
    [int]$KeyMissingAlertThreshold = 0,

    # URL webhook (Teams/Logic App) per l'alert soglia. Se vuoto tenta la Automation variable 'BitLockerSyncAlertWebhook'.
    [Parameter()]
    [string]$AlertWebhookUrl = '',

    # URL webhook di NOTIFICA: se valorizzato riceve il riepilogo a OGNI run. Fallback: Automation variable 'BitLockerSyncNotifyWebhook'.
    [Parameter()]
    [string]$NotifyWebhookUrl = '',

    # Registra un evento strutturato per ogni device aggiunto con successo a un gruppo.
    [Parameter()]
    [string]$EnableMembershipDetailLogging = 'true'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$VerbosePreference = 'Continue'

$script:GraphBase = 'https://graph.microsoft.com/v1.0'
$script:ReconcileErrors = 0

#region Helper

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-Verbose ("[{0}] [{1}] {2}" -f $ts, $Level, $Message)
}

# Converte in bool i valori passati come stringa (robusto ai parametri stringa delle jobSchedule:
# [bool]'false' in PowerShell varrebbe erroneamente $true).
function ConvertTo-Bool {
    param([object]$Value)
    if ($Value -is [bool]) { return $Value }
    return ("$Value").Trim().ToLower() -in @('true', '1', 'yes', 'y', 'on')
}

function Connect-GraphSession {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingConvertToSecureStringWithPlainText',
        '',
        Justification = 'Il valore proviene da una Automation Variable cifrata e deve essere convertito nel PSCredential richiesto da Connect-MgGraph.'
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
                throw 'ManagedIdentityClientId e obbligatorio: il runbook richiede la UAMI dedicata.'
            }
            Write-Log "Connessione a Graph con la user-assigned managed identity dedicata ($ManagedIdentityClientId)..."
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
    $ctx = Get-MgContext
    if (-not $ctx) { throw 'Connessione a Microsoft Graph fallita.' }
    Write-Log ("Connesso al tenant {0} come app '{1}'." -f $ctx.TenantId, $ctx.AppName) 'OK'
}

# Invoca Graph gestendo paging e throttling (429) con rispetto di Retry-After.
function Invoke-GraphApi {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method = 'GET',
        [object]$Body,
        [switch]$All
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $next = if ($Uri -match '^https?://') { $Uri } else { "$script:GraphBase/$($Uri.TrimStart('/'))" }
    $deltaLink = $null

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
                try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = $null }
                if (($status -eq 429 -or $status -ge 500) -and $attempt -le 5) {
                    $retryAfter = 0
                    try { $retryAfter = [int]$_.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds } catch { $retryAfter = 0 }
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
                $next = if ($response.PSObject.Properties.Name -contains '@odata.nextLink') { $response.'@odata.nextLink' } else { $null }
                if ($response.PSObject.Properties.Name -contains '@odata.deltaLink') { $deltaLink = $response.'@odata.deltaLink' }
            }
            else {
                $results.Add($response)
                $next = $null
            }
        }
        else { $next = $null }
    } while ($All -and $next)

    return [pscustomobject]@{ Value = $results; DeltaLink = $deltaLink }
}

# Esegue un JSON $batch (max 20 richieste) con retry dei subrequest falliti (429/5xx e 400 di replica).
function Invoke-GraphBatch {
    param([Parameter(Mandatory)][object[]]$Requests)

    if ($Requests.Count -eq 0) { return }
    $chunks = for ($i = 0; $i -lt $Requests.Count; $i += 20) { , ($Requests[$i..([math]::Min($i + 19, $Requests.Count - 1))]) }

    foreach ($chunk in $chunks) {
        # Mappa id-subrequest -> richiesta originale, per poter ritentare i falliti.
        $pending = @{}
        $n = 0
        foreach ($r in $chunk) { $n++; $pending["$n"] = $r }

        for ($attempt = 1; $attempt -le 4; $attempt++) {
            $batchRequests = foreach ($key in $pending.Keys) {
                $r = $pending[$key]
                $entry = @{ id = $key; method = $r.method; url = $r.url }
                if ($r.ContainsKey('body')) {
                    $entry.body = $r.body
                    $entry.headers = @{ 'Content-Type' = 'application/json' }
                }
                $entry
            }
            $body = @{ requests = @($batchRequests) }
            $resp = Invoke-GraphApi -Uri 'https://graph.microsoft.com/v1.0/$batch' -Method POST -Body $body

            $retry = @{}
            foreach ($res in $resp.Value[0].responses) {
                if ($res.status -lt 400 -or $res.status -eq 404) { continue }  # 404 su DELETE = gia' assente
                $isTransient = ($res.status -eq 429 -or $res.status -ge 500 -or $res.status -eq 400)
                if ($isTransient -and $attempt -lt 4) {
                    $retry["$($res.id)"] = $pending["$($res.id)"]
                }
                else {
                    $detail = try { ($res.body | ConvertTo-Json -Depth 5 -Compress) } catch { '' }
                    Write-Log "Batch req $($res.id) status $($res.status) (definitivo): $detail" 'ERROR'
                    $script:ReconcileErrors++
                }
            }

            if ($retry.Count -eq 0) { break }
            $pending = $retry
            Start-Sleep -Seconds ([math]::Min(30, [math]::Pow(2, $attempt)))
        }
    }
}

# Restituisce l'id del gruppo, creandolo se assente. mailNickname derivato dal displayName.
function Get-OrCreateGroup {
    param([Parameter(Mandatory)][string]$DisplayName, [string]$Description)

    $filter = "displayName eq '$($DisplayName.Replace("'","''"))'"
    $existing = (Invoke-GraphApi -Uri "groups?`$filter=$filter&`$select=id,displayName" -All).Value
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
    $group = (Invoke-GraphApi -Uri 'groups' -Method POST -Body $body).Value[0]
    Write-Log "Creato gruppo '$DisplayName' ($($group.id))." 'OK'
    $script:NewGroupCreated = $true
    return $group.id
}

# Riconcilia la membership di un gruppo (add/remove) verso l'insieme desiderato di objectId, in $batch.
function Sync-GroupMembership {
    param(
        [Parameter(Mandatory)][string]$GroupId,
        [Parameter(Mandatory)][string]$GroupName,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$DesiredObjectIds,
        [Parameter()][hashtable]$DeviceNamesByObjectId = @{},
        [Parameter()][bool]$LogMembershipDetails = $true
    )

    if ([string]::IsNullOrWhiteSpace($GroupId)) {
        Write-Log "Salto '$GroupName' (nessun id gruppo, probabile modalita' WhatIf)." 'WARN'
        return
    }

    $current = @((Invoke-GraphApi -Uri "groups/$GroupId/members/microsoft.graph.device?`$select=id" -All).Value | ForEach-Object { $_.id })
    $currentSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$current, [System.StringComparer]::OrdinalIgnoreCase)
    $desiredSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($DesiredObjectIds), [System.StringComparer]::OrdinalIgnoreCase)

    $toAdd = @($DesiredObjectIds | Where-Object { -not $currentSet.Contains($_) } | Select-Object -Unique)
    $toRemove = @($current | Where-Object { -not $desiredSet.Contains($_) } | Select-Object -Unique)

    Write-Log ("Gruppo '{0}': correnti={1}, desiderati={2}, +add={3}, -remove={4}" -f `
            $GroupName, $currentSet.Count, $desiredSet.Count, $toAdd.Count, $toRemove.Count)

    if ($WhatIfOnly) {
        foreach ($id in $toAdd) { Write-Log "[WHATIF] Aggiungerei $id a '$GroupName'." }
        foreach ($id in $toRemove) { Write-Log "[WHATIF] Rimuoverei $id da '$GroupName'." }
        return
    }

    # ADD: PATCH /groups/{id} con members@odata.bind (max 20 per richiesta), con retry su errori transitori/replica.
    for ($i = 0; $i -lt $toAdd.Count; $i += 20) {
        $slice = $toAdd[$i..([math]::Min($i + 19, $toAdd.Count - 1))]
        $binds = @($slice | ForEach-Object { "$script:GraphBase/directoryObjects/$_" })
        $body = @{ 'members@odata.bind' = $binds }
        $done = $false
        for ($attempt = 1; $attempt -le 4 -and -not $done; $attempt++) {
            try {
                Invoke-GraphApi -Uri "groups/$GroupId" -Method PATCH -Body $body | Out-Null
                $done = $true
                if ($LogMembershipDetails) {
                    foreach ($id in $slice) {
                        $deviceName = if ($DeviceNamesByObjectId.ContainsKey($id)) { $DeviceNamesByObjectId[$id] } else { $id }
                        $eventData = [ordered]@{
                            groupName = $GroupName
                            deviceName = $deviceName
                            objectId = $id
                        } | ConvertTo-Json -Compress
                        Write-Log "[MEMBERSHIP_ADD] $eventData" 'OK'
                    }
                }
            }
            catch {
                if ($attempt -ge 4) {
                    Write-Log "Errore add batch a '$GroupName' (definitivo): $($_.Exception.Message)" 'ERROR'
                    $script:ReconcileErrors++
                }
                else {
                    Write-Log "Errore add batch a '$GroupName' (tentativo $attempt), ritento: $($_.Exception.Message)" 'WARN'
                    Start-Sleep -Seconds ([math]::Min(30, [math]::Pow(2, $attempt)))
                }
            }
        }
    }

    # REMOVE: JSON $batch di DELETE members/{id}/$ref.
    if ($toRemove.Count -gt 0) {
        $reqs = foreach ($id in $toRemove) { @{ method = 'DELETE'; url = "/groups/$GroupId/members/$id/`$ref" } }
        Invoke-GraphBatch -Requests @($reqs)
    }
}

# Invia un alert JSON a un webhook (best-effort).
function Send-Alert {
    param([Parameter(Mandatory)][string]$WebhookUrl, [Parameter(Mandatory)][object]$Payload)
    try {
        Invoke-RestMethod -Method POST -Uri $WebhookUrl -ContentType 'application/json' -Body ($Payload | ConvertTo-Json -Depth 6) | Out-Null
        Write-Log 'Alert inviato al webhook.' 'OK'
    }
    catch { Write-Log "Invio alert fallito: $($_.Exception.Message)" 'WARN' }
}

# Restituisce la mappa dei device gestiti Windows validi: azureADDeviceId -> isEncrypted (bool).
# Esclude i device in stato retired/wiped (stale) e senza azureADDeviceId.
function Get-ManagedDeviceState {
    param([Parameter(Mandatory)][string]$OsFilter)

    $select = 'id,deviceName,azureADDeviceId,isEncrypted,operatingSystem,managementState,managedDeviceOwnerType'
    # Stati che indicano device dismessi/in dismissione: da ignorare.
    $staleStates = @('retirePending', 'retireIssued', 'retireFailed', 'wipePending', 'wipeIssued', 'wipeFailed', 'deletePending')

    Write-Log 'Recupero tutti i managed device (full sync)...'
    $resp = Invoke-GraphApi -Uri "deviceManagement/managedDevices?`$filter=$OsFilter&`$select=$select" -All

    $map = @{}
    foreach ($d in $resp.Value) {
        $aad = [string]$d.azureADDeviceId
        if ([string]::IsNullOrWhiteSpace($aad) -or $aad -eq '00000000-0000-0000-0000-000000000000') { continue }
        $mgmt = if ($d.PSObject.Properties.Name -contains 'managementState') { [string]$d.managementState } else { '' }
        if ($staleStates -contains $mgmt) { continue }
        $map[$aad] = [bool]$d.isEncrypted
    }
    return $map
}

#endregion Helper

#region Main

$summary = [ordered]@{}
try {
    Write-Log '=== Nimbus.BitLockerGroupSync - avvio ==='
    if ($WhatIfOnly) { Write-Log 'Modalita WhatIf attiva: nessuna modifica verra applicata.' 'WARN' }

    Connect-GraphSession `
        -Mode $AuthenticationMode `
        -ManagedIdentityClientId $ManagedIdentityClientId `
        -TenantId $AppTenantId `
        -ApplicationClientId $AppClientId `
        -CertificateName $CertificateAssetName `
        -SecretVariableName $ClientSecretVariableName

    # Nomi effettivi dei gruppi: se non specificati, derivati da GroupPrefix.
    if ([string]::IsNullOrWhiteSpace($EncryptedGroupName))    { $EncryptedGroupName    = "$GroupPrefix-Encrypted" }
    if ([string]::IsNullOrWhiteSpace($NotEncryptedGroupName)) { $NotEncryptedGroupName = "$GroupPrefix-NotEncrypted" }
    if ([string]::IsNullOrWhiteSpace($KeyEscrowedGroupName))  { $KeyEscrowedGroupName  = "$GroupPrefix-KeyEscrowed" }
    if ([string]::IsNullOrWhiteSpace($KeyMissingGroupName))   { $KeyMissingGroupName   = "$GroupPrefix-KeyMissing" }

    # Abilitazione gruppi opzionali (conversione robusta da stringa).
    $useNotEncrypted = ConvertTo-Bool $EnableNotEncryptedGroup
    $escrowCheck     = ConvertTo-Bool $EnableKeyEscrowCheck
    $useKeyEscrowed  = ConvertTo-Bool $EnableKeyEscrowedGroup
    $useKeyMissing   = ConvertTo-Bool $EnableKeyMissingGroup
    $logMembershipDetails = ConvertTo-Bool $EnableMembershipDetailLogging

    # Master switch: se la verifica escrow e' disabilitata, i gruppi/alert che dipendono
    # dalle recovery key vengono neutralizzati (con warning se erano stati richiesti).
    if (-not $escrowCheck) {
        if ($useKeyEscrowed -or $useKeyMissing -or ($KeyMissingAlertThreshold -gt 0)) {
            Write-Log 'EnableKeyEscrowCheck=false: verifica escrow disabilitata; gruppi KeyEscrowed/KeyMissing e alert di soglia ignorati.' 'WARN'
        }
        $useKeyEscrowed = $false
        $useKeyMissing  = $false
    }

    # Le recovery key servono solo se la verifica escrow e' attiva E serve valutare KeyEscrowed/KeyMissing (gruppi o alert soglia).
    $needKeys = $escrowCheck -and ($useKeyEscrowed -or $useKeyMissing -or ($KeyMissingAlertThreshold -gt 0))

    Write-Log ("Gruppi attivi: Encrypted (principale)" + `
        $($useNotEncrypted ? ', NotEncrypted' : '') + `
        $($useKeyEscrowed  ? ', KeyEscrowed'  : '') + `
        $($useKeyMissing   ? ', KeyMissing'   : ''))
    Write-Log ("Verifica escrow recovery key: " + ($escrowCheck ? 'ABILITATA' : 'DISABILITATA') + `
        ($needKeys ? ' (recupero chiavi necessario)' : ' (recupero chiavi saltato)'))

    # 1) Gruppi target (Encrypted sempre; gli altri solo se abilitati).
    $script:NewGroupCreated = $false
    $groupIds = @{
        Encrypted = Get-OrCreateGroup -DisplayName $EncryptedGroupName -Description 'Device Intune con disco cifrato (isEncrypted=true).'
    }
    if ($useNotEncrypted) {
        $groupIds.NotEncrypted = Get-OrCreateGroup -DisplayName $NotEncryptedGroupName -Description 'Device Intune con disco NON cifrato (isEncrypted=false).'
    }
    if ($useKeyEscrowed) {
        $groupIds.KeyEscrowed = Get-OrCreateGroup -DisplayName $KeyEscrowedGroupName -Description 'Device con BitLocker recovery key salvata in Entra.'
    }
    if ($useKeyMissing) {
        $groupIds.KeyMissing = Get-OrCreateGroup -DisplayName $KeyMissingGroupName -Description 'Device cifrati SENZA recovery key salvata in Entra.'
    }
    # I gruppi appena creati possono avere ritardi di replica: attendo prima di gestirne la membership.
    if ($script:NewGroupCreated -and -not $WhatIfOnly) {
        Write-Log 'Gruppo/i appena creati: attendo 20s per la replica prima della riconciliazione.'
        Start-Sleep -Seconds 20
    }

    # 2) Managed device Intune (full sync), gia' filtrati per stale/retired e OS.
    $osFilter = "operatingSystem eq '$TargetOperatingSystem'"
    $deviceMap = Get-ManagedDeviceState -OsFilter $osFilter
    Write-Log "Device validi (post-filtro stale): $($deviceMap.Count)."

    # 3) Recovery key BitLocker -> set di deviceId con almeno una chiave (solo se necessario)
    $devicesWithKey = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($needKeys) {
        Write-Log 'Recupero BitLocker recovery key da Entra...'
        $keys = (Invoke-GraphApi -Uri "informationProtection/bitlocker/recoveryKeys?`$select=id,deviceId" -All).Value
        foreach ($k in $keys) { if ($k.deviceId) { [void]$devicesWithKey.Add([string]$k.deviceId) } }
        Write-Log "Trovate $($keys.Count) recovery key su $($devicesWithKey.Count) device distinti."
    }
    else {
        Write-Log 'Nessun gruppo/alert basato su recovery key: salto il recupero delle chiavi.'
    }

    # 4) Mappa deviceId (Entra) -> objectId del device Entra
    Write-Log 'Costruzione mappa device Entra (deviceId -> objectId)...'
    $entraDevices = (Invoke-GraphApi -Uri "devices?`$select=id,deviceId,displayName" -All).Value
    $deviceIdToObjectId = @{}
    $deviceNamesByObjectId = @{}
    foreach ($d in $entraDevices) {
        if ($d.deviceId) {
            $objectId = [string]$d.id
            $deviceIdToObjectId[[string]$d.deviceId] = $objectId
            $deviceNamesByObjectId[$objectId] = if ([string]::IsNullOrWhiteSpace([string]$d.displayName)) { $objectId } else { [string]$d.displayName }
        }
    }
    Write-Log "Mappati $($deviceIdToObjectId.Count) device Entra."

    # 5) Calcolo insiemi desiderati
    $desired = @{ Encrypted = [System.Collections.Generic.List[string]]::new(); NotEncrypted = [System.Collections.Generic.List[string]]::new(); KeyEscrowed = [System.Collections.Generic.List[string]]::new(); KeyMissing = [System.Collections.Generic.List[string]]::new() }
    $unresolved = 0

    foreach ($aadId in $deviceMap.Keys) {
        $objectId = $deviceIdToObjectId[$aadId]
        if ([string]::IsNullOrWhiteSpace($objectId)) { $unresolved++; continue }

        $isEncrypted = [bool]$deviceMap[$aadId]
        $hasKey = $devicesWithKey.Contains($aadId)

        if ($isEncrypted) { $desired.Encrypted.Add($objectId) } else { $desired.NotEncrypted.Add($objectId) }
        # Insiemi basati sulle recovery key: popolati SOLO se la verifica escrow e' attiva,
        # altrimenti KeyMissing conterrebbe erroneamente tutti i device cifrati (devicesWithKey vuoto).
        if ($needKeys) {
            if ($hasKey) { $desired.KeyEscrowed.Add($objectId) }
            elseif ($isEncrypted) { $desired.KeyMissing.Add($objectId) }  # cifrato ma senza chiave = rischio
        }
    }
    if ($unresolved -gt 0) { Write-Log "$unresolved device Intune senza corrispondente oggetto Entra (ignorati)." 'WARN' }

    # 6) Riconciliazione membership (solo gruppi abilitati)
    Sync-GroupMembership -GroupId $groupIds.Encrypted -GroupName $EncryptedGroupName -DesiredObjectIds $desired.Encrypted.ToArray() -DeviceNamesByObjectId $deviceNamesByObjectId -LogMembershipDetails $logMembershipDetails
    if ($useNotEncrypted) {
        Sync-GroupMembership -GroupId $groupIds.NotEncrypted -GroupName $NotEncryptedGroupName -DesiredObjectIds $desired.NotEncrypted.ToArray() -DeviceNamesByObjectId $deviceNamesByObjectId -LogMembershipDetails $logMembershipDetails
    }
    if ($useKeyEscrowed) {
        Sync-GroupMembership -GroupId $groupIds.KeyEscrowed -GroupName $KeyEscrowedGroupName -DesiredObjectIds $desired.KeyEscrowed.ToArray() -DeviceNamesByObjectId $deviceNamesByObjectId -LogMembershipDetails $logMembershipDetails
    }
    if ($useKeyMissing) {
        Sync-GroupMembership -GroupId $groupIds.KeyMissing -GroupName $KeyMissingGroupName -DesiredObjectIds $desired.KeyMissing.ToArray() -DeviceNamesByObjectId $deviceNamesByObjectId -LogMembershipDetails $logMembershipDetails
    }

    $summary['DeviceValutati'] = $deviceMap.Count
    $summary['Encrypted'] = $desired.Encrypted.Count
    if ($useNotEncrypted) { $summary['NotEncrypted'] = $desired.NotEncrypted.Count }
    if ($useKeyEscrowed)  { $summary['KeyEscrowed'] = $desired.KeyEscrowed.Count }
    if ($needKeys)        { $summary['KeyMissing (rischio)'] = $desired.KeyMissing.Count }
    $summary['NonRisolti'] = $unresolved
    $summary['ErroriRiconciliazione'] = $script:ReconcileErrors

    Write-Log '=== Riepilogo ===' 'OK'
    $summary.GetEnumerator() | ForEach-Object { Write-Log ("  {0}: {1}" -f $_.Key, $_.Value) 'OK' }

    # 7a) Notifica di riepilogo a OGNI run (subscribers via webhook)
    $notifyHook = $NotifyWebhookUrl
    if ([string]::IsNullOrWhiteSpace($notifyHook)) {
        try { $notifyHook = Get-AutomationVariable -Name 'BitLockerSyncNotifyWebhook' -ErrorAction Stop } catch { $notifyHook = '' }
    }
    if (-not [string]::IsNullOrWhiteSpace($notifyHook) -and -not $WhatIfOnly) {
        Write-Log 'Invio notifica di riepilogo ai subscriber.'
        Send-Alert -WebhookUrl $notifyHook -Payload ([ordered]@{
                solution     = 'Nimbus.BitLockerGroupSync'
                event        = ($script:ReconcileErrors -gt 0 ? 'sync.completed_with_errors' : 'sync.completed')
                severity     = ($script:ReconcileErrors -gt 0 ? 'warning' : 'info')
                deviceCount  = $deviceMap.Count
                encrypted    = $desired.Encrypted.Count
                notEncrypted = $desired.NotEncrypted.Count
                keyEscrowed  = $desired.KeyEscrowed.Count
                keyMissing   = $desired.KeyMissing.Count
                unresolved   = $unresolved
                errors       = $script:ReconcileErrors
                timestamp    = (Get-Date).ToString('o')
            })
    }

    # 7b) Alert opzionale su device cifrati senza recovery key (solo se la verifica escrow e' attiva)
    if ($needKeys -and $KeyMissingAlertThreshold -gt 0 -and $desired.KeyMissing.Count -ge $KeyMissingAlertThreshold) {
        $hook = $AlertWebhookUrl
        if ([string]::IsNullOrWhiteSpace($hook)) {
            try { $hook = Get-AutomationVariable -Name 'BitLockerSyncAlertWebhook' -ErrorAction Stop } catch { $hook = '' }
        }
        if (-not [string]::IsNullOrWhiteSpace($hook)) {
            Write-Log "Soglia KeyMissing superata ($($desired.KeyMissing.Count) >= $KeyMissingAlertThreshold): invio alert." 'WARN'
            Send-Alert -WebhookUrl $hook -Payload ([ordered]@{
                    solution     = 'Nimbus.BitLockerGroupSync'
                    severity     = 'warning'
                    message      = "Device cifrati SENZA recovery key: $($desired.KeyMissing.Count) (soglia $KeyMissingAlertThreshold)"
                    keyMissing   = $desired.KeyMissing.Count
                    encrypted    = $desired.Encrypted.Count
                    notEncrypted = $desired.NotEncrypted.Count
                    timestamp    = (Get-Date).ToString('o')
                })
        }
        else { Write-Log 'Soglia KeyMissing superata ma nessun webhook configurato.' 'WARN' }
    }

    if ($script:ReconcileErrors -gt 0) {
        throw "Riconciliazione completata con $($script:ReconcileErrors) errori di membership: alcuni gruppi potrebbero non riflettere lo stato desiderato."
    }
    Write-Log '=== Nimbus.BitLockerGroupSync - completato ===' 'OK'
}
catch {
    Write-Log "ERRORE FATALE: $($_.Exception.Message)" 'ERROR'
    Write-Log $_.ScriptStackTrace 'ERROR'
    throw
}
finally {
    try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { $null = $_ }
}

#endregion Main
