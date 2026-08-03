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
    [switch]$UseDeviceCode,

    [Parameter()]
    [switch]$Revoke,

    [Parameter()]
    [string]$TenantId
)

$ErrorActionPreference = 'Stop'
$GraphAppId = '00000003-0000-0000-c000-000000000000' # Microsoft Graph

foreach ($moduleName in @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Applications')) {
    if (-not (Get-Module -ListAvailable -Name $moduleName | Where-Object Version -ge '2.28.0')) {
        Write-Host "Installazione modulo $moduleName..." -ForegroundColor Cyan
        Install-Module -Name $moduleName -MinimumVersion 2.28.0 -Repository PSGallery `
            -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module $moduleName -MinimumVersion 2.28.0 -ErrorAction Stop
}

Write-Host 'Connessione a Microsoft Graph (serve consenso admin)...' -ForegroundColor Cyan
$connectParams = @{ Scopes = 'Application.Read.All', 'AppRoleAssignment.ReadWrite.All'; NoWelcome = $true }
if ($UseDeviceCode) { $connectParams['UseDeviceCode'] = $true }
if ($TenantId)      { $connectParams['TenantId'] = $TenantId }
Connect-MgGraph @connectParams

try {
    # Service principal di Microsoft Graph nel tenant.
    $graphSp = Get-MgServicePrincipal -Filter "appId eq '$GraphAppId'" -ErrorAction Stop
    if (-not $graphSp) { throw 'Service principal di Microsoft Graph non trovato.' }

    # Verifica esistenza della managed identity (service principal).
    $miSp = Get-MgServicePrincipal -ServicePrincipalId $ManagedIdentityPrincipalId -ErrorAction Stop
    Write-Host "Managed identity: $($miSp.DisplayName) ($ManagedIdentityPrincipalId)" -ForegroundColor Green

    # Assegnazioni gia' presenti (per idempotenza).
    $existing = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $ManagedIdentityPrincipalId

    foreach ($roleValue in $GraphAppRoles) {
        $appRole = $graphSp.AppRoles | Where-Object { $_.Value -eq $roleValue -and $_.AllowedMemberTypes -contains 'Application' }
        if (-not $appRole) { throw "App role '$roleValue' non trovato su Microsoft Graph." }

        $assignment = $existing | Where-Object {
            $_.AppRoleId -eq $appRole.Id -and $_.ResourceId -eq $graphSp.Id
        } | Select-Object -First 1

        if ($Revoke) {
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

    $operation = if ($Revoke) { 'revoca' } else { 'assegnazione' }
    Write-Host "Completata $operation. La propagazione puo richiedere alcuni minuti." -ForegroundColor Cyan
}
finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}
