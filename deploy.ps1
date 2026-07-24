<#
.SYNOPSIS
    Orchestratore end-to-end per il deploy di Nimbus.BitLockerGroupSync.

.DESCRIPTION
    1. Crea (se necessario) il resource group.
    2. Deploya l'infrastruttura via Bicep.
    3. Assegna i permessi Graph alla managed identity.
    4. (Opzionale) avvia subito un job del runbook.

.EXAMPLE
    .\deploy.ps1 -ResourceGroupName 'rg-bitlocker' -Location 'westeurope'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter()][string]$Location = 'westeurope',
    [Parameter()][string]$ParameterFile = "$PSScriptRoot\bicep\main.bicepparam",
    [Parameter()][switch]$StartJobNow,
    [Parameter()][switch]$CreateTriggerWebhook
)

$ErrorActionPreference = 'Stop'

Write-Host '==> Verifica login Azure...' -ForegroundColor Cyan
if (-not (Get-AzContext)) { Connect-AzAccount | Out-Null }

Write-Host "==> Resource group '$ResourceGroupName'..." -ForegroundColor Cyan
if (-not (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue)) {
    New-AzResourceGroup -Name $ResourceGroupName -Location $Location | Out-Null
}

Write-Host '==> Deploy Bicep...' -ForegroundColor Cyan
$deployment = New-AzResourceGroupDeployment `
    -ResourceGroupName $ResourceGroupName `
    -TemplateParameterFile $ParameterFile `
    -Name "nimbus-bitlocker-$(Get-Date -Format 'yyyyMMddHHmmss')" `
    -Verbose

$principalId = $deployment.Outputs.managedIdentityPrincipalId.Value
$aaName = $deployment.Outputs.automationAccountName.Value
$rbName = $deployment.Outputs.runbookName.Value
Write-Host "    Managed identity principalId: $principalId" -ForegroundColor Green

Write-Host '==> Assegnazione permessi Graph alla managed identity...' -ForegroundColor Cyan
& "$PSScriptRoot\scripts\Grant-GraphPermissions.ps1" -ManagedIdentityPrincipalId $principalId

if ($CreateTriggerWebhook) {
    Write-Host '==> Creazione webhook di trigger inbound...' -ForegroundColor Cyan
    $expiry = (Get-Date).AddYears(1)
    $wh = New-AzAutomationWebhook `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $aaName `
        -Name "$rbName-trigger" `
        -RunbookName $rbName `
        -IsEnabled $true `
        -ExpiryTime $expiry `
        -Force
    Write-Host '    [!] Copia SUBITO questo URI: non sara piu recuperabile!' -ForegroundColor Yellow
    Write-Host "    Webhook URI: $($wh.WebhookURI)" -ForegroundColor Green
}

if ($StartJobNow) {
    Write-Host '==> Avvio job del runbook...' -ForegroundColor Cyan
    Start-AzAutomationRunbook -AutomationAccountName $aaName -ResourceGroupName $ResourceGroupName -Name $rbName | Out-Null
}

Write-Host '==> Deploy completato.' -ForegroundColor Green
