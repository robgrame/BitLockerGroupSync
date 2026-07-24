// =============================================================================
//  graphPermissions.bicep
//  Assegna alla managed identity dell'Automation Account gli app role di
//  Microsoft Graph richiesti, tramite un deploymentScript (AzurePowerShell).
//
//  PREREQUISITO: la user-assigned managed identity indicata in
//  grantIdentityResourceId deve avere gia' l'app role Graph
//  'AppRoleAssignment.ReadWrite.All' (e tipicamente 'Application.Read.All'),
//  perche' e' con quella identita' che lo script si autentica a Graph.
// =============================================================================

@description('Region del deploymentScript.')
param location string

@description('Principal (object) id della MI a cui assegnare i permessi.')
param managedIdentityPrincipalId string

@description('Resource id della UAMI (con AppRoleAssignment.ReadWrite.All) usata dallo script.')
param grantIdentityResourceId string

@description('App role Graph (application) da assegnare.')
param graphAppRoles array = [
  'DeviceManagementManagedDevices.Read.All'
  'BitlockerKey.Read.All'
  'Device.ReadWrite.All'
  'Group.Create'
  'GroupMember.ReadWrite.All'
]

@description('Client id della UAMI usata dal deploymentScript (per Connect-MgGraph -Identity -ClientId).')
param grantIdentityClientId string

@description('Tag.')
param tags object = {}

resource assignRoles 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'grant-graph-permissions'
  location: location
  tags: tags
  kind: 'AzurePowerShell'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${grantIdentityResourceId}': {}
    }
  }
  properties: {
    azPowerShellVersion: '11.0'
    retentionInterval: 'PT1H'
    cleanupPreference: 'OnSuccess'
    timeout: 'PT30M'
    environmentVariables: [
      {
        name: 'PRINCIPAL_ID'
        value: managedIdentityPrincipalId
      }
      {
        name: 'ROLES'
        value: join(graphAppRoles, ',')
      }
      {
        name: 'MI_CLIENT_ID'
        value: grantIdentityClientId
      }
    ]
    scriptContent: '''
      $ErrorActionPreference = 'Stop'
      $graphAppId = '00000003-0000-0000-c000-000000000000'
      $principalId = $env:PRINCIPAL_ID
      $roles = $env:ROLES -split ','

      # I container dei deploymentScript AzurePowerShell non hanno i moduli Graph: installali.
      Install-Module Microsoft.Graph.Authentication -Force -Scope CurrentUser -AllowClobber
      Install-Module Microsoft.Graph.Applications -Force -Scope CurrentUser -AllowClobber
      Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
      Import-Module Microsoft.Graph.Applications -ErrorAction Stop

      # Autenticazione con la UAMI del deploymentScript (client id esplicito).
      Connect-MgGraph -Identity -ClientId $env:MI_CLIENT_ID -NoWelcome

      $graphSp = Get-MgServicePrincipal -Filter "appId eq '$graphAppId'"
      $existing = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $principalId

      foreach ($roleValue in $roles) {
        $appRole = $graphSp.AppRoles | Where-Object { $_.Value -eq $roleValue -and $_.AllowedMemberTypes -contains 'Application' }
        if (-not $appRole) { Write-Warning "App role '$roleValue' non trovato."; continue }
        if ($existing | Where-Object { $_.AppRoleId -eq $appRole.Id -and $_.ResourceId -eq $graphSp.Id }) {
          Write-Output "Gia' assegnato: $roleValue"; continue
        }
        New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $principalId -PrincipalId $principalId -ResourceId $graphSp.Id -AppRoleId $appRole.Id | Out-Null
        Write-Output "Assegnato: $roleValue"
      }
      $DeploymentScriptOutputs = @{ status = 'completed' }
    '''
  }
}

output status string = assignRoles.properties.outputs.status
