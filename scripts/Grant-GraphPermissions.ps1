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

.EXAMPLE
    .\Grant-GraphPermissions.ps1 -ManagedIdentityPrincipalId '00000000-0000-0000-0000-000000000000'
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
    [switch]$UseDeviceCode,

    [Parameter()]
    [string]$TenantId
)

$ErrorActionPreference = 'Stop'
$GraphAppId = '00000003-0000-0000-c000-000000000000' # Microsoft Graph

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
Import-Module Microsoft.Graph.Applications -ErrorAction Stop

Write-Host 'Connessione a Microsoft Graph (serve consenso admin)...' -ForegroundColor Cyan
$connectParams = @{ Scopes = 'Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All'; NoWelcome = $true }
if ($UseDeviceCode) { $connectParams['UseDeviceCode'] = $true }
if ($TenantId)      { $connectParams['TenantId'] = $TenantId }
Connect-MgGraph @connectParams

# Service principal di Microsoft Graph nel tenant.
$graphSp = Get-MgServicePrincipal -Filter "appId eq '$GraphAppId'"
if (-not $graphSp) { throw 'Service principal di Microsoft Graph non trovato.' }

# Verifica esistenza della managed identity (service principal).
$miSp = Get-MgServicePrincipal -ServicePrincipalId $ManagedIdentityPrincipalId -ErrorAction Stop
Write-Host "Managed identity: $($miSp.DisplayName) ($ManagedIdentityPrincipalId)" -ForegroundColor Green

# Assegnazioni gia' presenti (per idempotenza).
$existing = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $ManagedIdentityPrincipalId

foreach ($roleValue in $GraphAppRoles) {
    $appRole = $graphSp.AppRoles | Where-Object { $_.Value -eq $roleValue -and $_.AllowedMemberTypes -contains 'Application' }
    if (-not $appRole) {
        Write-Warning "App role '$roleValue' non trovato su Microsoft Graph. Salto."
        continue
    }

    if ($existing | Where-Object { $_.AppRoleId -eq $appRole.Id -and $_.ResourceId -eq $graphSp.Id }) {
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

Write-Host 'Completato. La propagazione dei permessi puo richiedere alcuni minuti.' -ForegroundColor Cyan
Disconnect-MgGraph | Out-Null
