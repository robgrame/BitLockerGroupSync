<#
.SYNOPSIS
    Assegna alla managed identity dell'Automation Account i permessi applicativi Microsoft
    Graph necessari a Nimbus.BitLockerGroupSync.

.DESCRIPTION
    Gli app role di Microsoft Graph NON sono RBAC di Azure e non possono essere assegnati
    tramite Bicep/ARM. Questo script va eseguito una tantum da un utente con privilegi
    sufficienti (Privileged Role Administrator / Global Administrator) dopo il deploy Bicep.

    Richiede il modulo Microsoft.Graph (o almeno Microsoft.Graph.Authentication +
    Microsoft.Graph.Applications).

.PARAMETER ManagedIdentityPrincipalId
    Object (principal) id della managed identity. E' l'output 'managedIdentityPrincipalId'
    del deploy Bicep.

.PARAMETER Revoke
    Revoca dalla managed identity i soli app role Graph gestiti da questo script.
    Usare prima di eliminare o sostituire una UAMI.

.PARAMETER Reconcile
    Assegna i ruoli elencati in GraphAppRoles e revoca gli altri ruoli gestiti da
    questo script. Mantiene il least privilege quando cambia la selezione runbook.

.EXAMPLE
    .\Grant-GraphPermissions.ps1 -ManagedIdentityPrincipalId '00000000-0000-0000-0000-000000000000' -TenantId '00000000-0000-0000-0000-000000000000' -UseDeviceCode

.EXAMPLE
    .\Grant-GraphPermissions.ps1 -ManagedIdentityPrincipalId '00000000-0000-0000-0000-000000000000' -TenantId '00000000-0000-0000-0000-000000000000' -UseDeviceCode -Revoke
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]
    [string]$ManagedIdentityPrincipalId,

    [Parameter()]
    [string[]]$GraphAppRoles = @(
        'DeviceManagementManagedDevices.Read.All',
        'BitlockerKey.Read.All',
        'Device.ReadWrite.All',
        'Group.Create',
        'GroupMember.ReadWrite.All'
    ),

    [Parameter()]
    [string]$GraphAppRolesBase64,

    [Parameter()]
    [switch]$UseDeviceCode,

    [Parameter()]
    [switch]$Revoke,

    [Parameter()]
    [switch]$Reconcile,

    [Parameter()]
    [string]$TenantId,

    [Parameter()]
    [switch]$ValidateRolePayloadOnly
)

$ErrorActionPreference = 'Stop'
$GraphAppId = '00000003-0000-0000-c000-000000000000' # Microsoft Graph
$ManagedGraphAppRoles = @(
    'DeviceManagementManagedDevices.Read.All',
    'BitlockerKey.Read.All',
    'Device.ReadWrite.All',
    'Group.Create',
    'GroupMember.ReadWrite.All'
)

if (-not [string]::IsNullOrWhiteSpace($GraphAppRolesBase64)) {
    try {
        $rolesJson = [Text.Encoding]::UTF8.GetString(
            [Convert]::FromBase64String($GraphAppRolesBase64)
        )
        $GraphAppRoles = @($rolesJson | ConvertFrom-Json)
    }
    catch {
        throw "GraphAppRolesBase64 non contiene un payload JSON Base64 valido: $($_.Exception.Message)"
    }
}
$unsupportedRoles = @($GraphAppRoles | Where-Object { $_ -notin $ManagedGraphAppRoles })
if ($unsupportedRoles.Count -gt 0) {
    throw "GraphAppRoles contiene ruoli non gestiti: $($unsupportedRoles -join ', ')."
}
if ($Revoke -and $Reconcile) {
    throw 'Revoke e Reconcile non possono essere usati insieme.'
}
if ($ValidateRolePayloadOnly) {
    ConvertTo-Json -InputObject @($GraphAppRoles) -Compress
    return
}

function Get-GraphStatusCode {
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    foreach ($candidate in @(
            $ErrorRecord.Exception.ResponseStatusCode,
            $ErrorRecord.Exception.StatusCode,
            $ErrorRecord.Exception.Response.StatusCode
        )) {
        if ($null -ne $candidate) {
            return [int]$candidate
        }
    }
    return $null
}

function Invoke-GraphWithRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$Operation,
        [Parameter(Mandatory)][string]$Description,
        [Parameter()][int]$MaxAttempts = 6
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return & $Operation
        }
        catch {
            $statusCode = Get-GraphStatusCode -ErrorRecord $_
            $isTransient = $statusCode -eq 404 -or $statusCode -eq 429 -or $statusCode -ge 500
            if (-not $isTransient -or $attempt -eq $MaxAttempts) {
                throw
            }
            $delaySeconds = [Math]::Min(30, [Math]::Pow(2, $attempt))
            Write-Warning "$Description non disponibile (HTTP $statusCode), nuovo tentativo tra $delaySeconds secondi."
            Start-Sleep -Seconds $delaySeconds
        }
    }
}

foreach ($moduleName in @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Applications')) {
    if (-not (Get-Module -ListAvailable -Name $moduleName | Where-Object Version -ge '2.40.0')) {
        Write-Host "Installazione modulo $moduleName..." -ForegroundColor Cyan
        Install-Module -Name $moduleName -MinimumVersion 2.40.0 -Repository PSGallery `
            -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module $moduleName -MinimumVersion 2.40.0 -ErrorAction Stop
}

Write-Host 'Connessione a Microsoft Graph (serve consenso admin)...' -ForegroundColor Cyan
$connectParams = @{ Scopes = 'Application.Read.All', 'AppRoleAssignment.ReadWrite.All'; NoWelcome = $true }
if ($UseDeviceCode) { $connectParams['UseDeviceCode'] = $true }
if ($TenantId)      { $connectParams['TenantId'] = $TenantId }
Connect-MgGraph @connectParams

try {
    # Service principal di Microsoft Graph nel tenant.
    $graphSp = Invoke-GraphWithRetry `
        -Description 'Service principal Microsoft Graph' `
        -Operation { Get-MgServicePrincipal -Filter "appId eq '$GraphAppId'" -ErrorAction Stop }
    if (-not $graphSp) { throw 'Service principal di Microsoft Graph non trovato.' }

    # Verifica esistenza della managed identity (service principal).
    $miSp = Invoke-GraphWithRetry `
        -Description 'Service principal della managed identity' `
        -Operation {
            Get-MgServicePrincipal `
                -ServicePrincipalId $ManagedIdentityPrincipalId `
                -ErrorAction Stop
        }
    Write-Host "Managed identity: $($miSp.DisplayName) ($ManagedIdentityPrincipalId)" -ForegroundColor Green

    # Assegnazioni gia' presenti (per idempotenza).
    $existing = Invoke-GraphWithRetry `
        -Description 'App role assignment della managed identity' `
        -Operation {
            Get-MgServicePrincipalAppRoleAssignment `
                -ServicePrincipalId $ManagedIdentityPrincipalId `
                -ErrorAction Stop
        }

    $rolesToProcess = if ($Reconcile) {
        @($GraphAppRoles) + @($ManagedGraphAppRoles | Where-Object { $_ -notin $GraphAppRoles })
    }
    else {
        $GraphAppRoles
    }
    foreach ($roleValue in $rolesToProcess) {
        $appRole = $graphSp.AppRoles | Where-Object { $_.Value -eq $roleValue -and $_.AllowedMemberTypes -contains 'Application' }
        if (-not $appRole) { throw "App role '$roleValue' non trovato su Microsoft Graph." }

        $assignment = $existing | Where-Object {
            $_.AppRoleId -eq $appRole.Id -and $_.ResourceId -eq $graphSp.Id
        } | Select-Object -First 1

        $shouldRevoke = $Revoke -or ($Reconcile -and $roleValue -notin $GraphAppRoles)
        if ($shouldRevoke) {
            if (-not $assignment) {
                Write-Host "  [=] Non assegnato: $roleValue" -ForegroundColor DarkGray
                continue
            }
            if ($PSCmdlet.ShouldProcess($roleValue, 'Revoca app role')) {
                Remove-MgServicePrincipalAppRoleAssignment `
                    -ServicePrincipalId $ManagedIdentityPrincipalId `
                    -AppRoleAssignmentId $assignment.Id
                Write-Host "  [-] Revocato: $roleValue" -ForegroundColor Yellow
            }
            continue
        }

        if ($assignment) {
            Write-Host "  [=] Gia' assegnato: $roleValue" -ForegroundColor DarkGray
            continue
        }

        if ($PSCmdlet.ShouldProcess($roleValue, 'Assegna app role')) {
            New-MgServicePrincipalAppRoleAssignment `
                -ServicePrincipalId $ManagedIdentityPrincipalId `
                -PrincipalId $ManagedIdentityPrincipalId `
                -ResourceId $graphSp.Id `
                -AppRoleId $appRole.Id | Out-Null
            Write-Host "  [+] Assegnato: $roleValue" -ForegroundColor Green
        }
    }

    $operation = if ($Revoke) { 'revoca' } elseif ($Reconcile) { 'riconciliazione' } else { 'assegnazione' }
    Write-Host "Completata $operation. La propagazione puo richiedere alcuni minuti." -ForegroundColor Cyan
}
finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}
