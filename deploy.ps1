<#
.SYNOPSIS
    Orchestratore end-to-end per il deploy di Nimbus.BitLockerGroupSync.

.DESCRIPTION
    Installa i prerequisiti mancanti, verifica il contesto Azure, crea il resource
    group se necessario, esegue preflight e what-if e distribuisce il Bicep.
    Le comunicazioni per il cliente sono artefatti separati dal deployment.

.PARAMETER ResourceGroupName
    Nome del Resource Group Azure che conterra la soluzione. Se non esiste, lo
    script lo crea nella location indicata. Parametro obbligatorio.

.PARAMETER Location
    Regione Azure usata per il Resource Group e per le risorse che supportano la
    localizzazione configurabile. Valore predefinito: westeurope.

.PARAMETER ParameterFile
    Percorso del file .bicepparam contenente la configurazione della soluzione.
    Il valore predefinito e bicep\main.bicepparam nella repository.

.PARAMETER TenantId
    ID GUID del tenant Microsoft Entra atteso. Se specificato, lo script forza o
    verifica il contesto sul tenant indicato. Se omesso, usa il tenant del
    contesto Az PowerShell corrente.

.PARAMETER SubscriptionId
    ID GUID della subscription Azure di destinazione. Se specificato, lo script
    seleziona e verifica la subscription. Se omesso, usa la subscription del
    contesto Az PowerShell corrente.

.PARAMETER AppCertificatePfxPath
    Percorso locale del certificato PFX con private key da importare in Azure
    Automation. Obbligatorio con AppRegistrationCertificate.

.PARAMETER AppCertificatePfxPassword
    Password del file PFX come SecureString. Obbligatoria con
    AppRegistrationCertificate. Non viene salvata nella schedule.

.PARAMETER AppClientSecret
    Client secret dell'App Registration come SecureString. Obbligatorio nel
    primo deployment con AppRegistrationSecret; viene archiviato in una
    Automation Variable cifrata e non viene inserito nella schedule.

.PARAMETER TeamsWebhookUrl
    URL Workflows del canale Teams come SecureString. Viene passato direttamente
    al deployment e non deve essere persistito nel file dei parametri.

.PARAMETER SkipBootstrap
    Evita installazione e aggiornamento automatici di Azure CLI, Bicep e moduli
    PowerShell. Usare solo quando tutti i prerequisiti sono gia disponibili.

.PARAMETER SkipProviderRegistration
    Evita la registrazione automatica dei Resource Provider Azure richiesti.
    Usare solo se risultano gia registrati o la registrazione e gestita
    centralmente.

.PARAMETER GrantGraphPermissions
    Assegna le permission Graph alla managed identity nello stesso flusso,
    richiedendo un login device-code con privilegi Entra. Supportato solo con
    AuthenticationMode ManagedIdentity. Per impostazione predefinita aggiunge
    gli app role richiesti dai runbook selezionati senza revocare quelli esistenti.
    Con FullReconcile revoca anche gli app role gestiti non piu necessari.

.PARAMETER RunbookSelection
    Seleziona i runbook da distribuire o aggiornare in modalita delta:
      - All: entrambi i runbook;
      - GroupSync: solo la riconciliazione dei gruppi;
      - ExtensionAttribute: solo la sincronizzazione extensionAttribute10.
    I runbook non selezionati, le relative schedule e la configurazione runtime
    esistente non vengono modificati. Se omesso, usa la selezione dichiarata nel
    file .bicepparam.

.PARAMETER FullReconcile
    Applica la selezione come stato finale esclusivo. Rimuove gli artefatti
    gestiti dei runbook non selezionati e, con GrantGraphPermissions, revoca gli
    app role Graph gestiti non piu necessari. Usare solo per nuovi deployment o
    riconciliazioni complete esplicitamente approvate.

.PARAMETER PermissionsConfirmed
    Dichiara che le permission Microsoft Graph richieste sono state assegnate e
    verificate. Abilita schedule e dead-man alert e consente webhook e avvio
    immediato del runbook.

.PARAMETER SkipWhatIf
    Salta l'anteprima ARM what-if. Da usare esclusivamente in procedure
    controllate, poiche riduce la visibilita sulle modifiche del deployment.

.PARAMETER StartJobNow
    Avvia immediatamente un job del runbook dopo il deployment. Richiede
    PermissionsConfirmed oppure GrantGraphPermissions.

.PARAMETER CreateTriggerWebhook
    Crea un webhook Azure Automation per l'avvio esterno del runbook. Richiede
    PermissionsConfirmed oppure GrantGraphPermissions. L'URI viene mostrato una
    sola volta e deve essere conservato come segreto.

.EXAMPLE
    .\deploy.ps1 -ResourceGroupName 'rg-bitlocker-prod' -Location 'westeurope' `
        -TenantId '<tenant-id>' -SubscriptionId '<subscription-id>'
    Esegue la prima fase creando una UAMI dedicata, lasciando
    disabilitata la schedule finche le permission Graph non sono confermate.

.EXAMPLE
    .\deploy.ps1 -ResourceGroupName 'rg-bitlocker-prod' -Location 'westeurope' `
        -TenantId '<tenant-id>' -SubscriptionId '<subscription-id>' `
        -SkipBootstrap -PermissionsConfirmed -StartJobNow
    Esegue la seconda fase, abilita il runtime e avvia il primo job.

.EXAMPLE
    $pfxPassword = Read-Host 'Password PFX' -AsSecureString
    .\deploy.ps1 -ResourceGroupName 'rg-bitlocker-prod' `
        -ParameterFile '.\bicep\customer.local.bicepparam' `
        -AppCertificatePfxPath 'C:\Secure\GraphAuthCertificate.pfx' `
        -AppCertificatePfxPassword $pfxPassword
    Distribuisce la soluzione usando la modalita AppRegistrationCertificate
    configurata nel file .bicepparam.

.NOTES
    Version: 1.5.3

    Per visualizzare la guida completa:
        Get-Help .\deploy.ps1 -Full
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter()][string]$Location = 'westeurope',
    [Parameter()][string]$ParameterFile = "$PSScriptRoot\bicep\main.bicepparam",
    [Parameter()][string]$TenantId,
    [Parameter()][string]$SubscriptionId,
    [Parameter()][string]$AppCertificatePfxPath,
    [Parameter()][securestring]$AppCertificatePfxPassword,
    [Parameter()][securestring]$AppClientSecret,
    [Parameter()][securestring]$TeamsWebhookUrl,
    [Parameter()][switch]$SkipBootstrap,
    [Parameter()][switch]$SkipProviderRegistration,
    [Parameter()][ValidateSet('All', 'GroupSync', 'ExtensionAttribute')]
    [string]$RunbookSelection,
    [Parameter()][switch]$FullReconcile,
    [Parameter()][switch]$GrantGraphPermissions,
    [Parameter()][switch]$PermissionsConfirmed,
    [Parameter()][switch]$SkipWhatIf,
    [Parameter()][switch]$StartJobNow,
    [Parameter()][switch]$StartExtensionAttributeJobNow,
    [Parameter()][switch]$CreateTriggerWebhook
)

$ErrorActionPreference = 'Stop'

function Update-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machinePath;$userPath"
}

function Add-BicepToProcessPath {
    $azureBicepPath = Join-Path $HOME '.azure\bin'
    if (Test-Path -LiteralPath $azureBicepPath) {
        $pathEntries = $env:Path -split [System.IO.Path]::PathSeparator
        if ($azureBicepPath -notin $pathEntries) {
            $env:Path = "$azureBicepPath$([System.IO.Path]::PathSeparator)$env:Path"
        }
    }

    if (-not (Get-Command bicep -ErrorAction SilentlyContinue)) {
        throw "Bicep installato da Azure CLI ma non disponibile nel PATH del processo: '$azureBicepPath'."
    }
}

function Install-AzureCli {
    if (Get-Command az -ErrorAction SilentlyContinue) { return }

    Write-Host '==> Installazione Azure CLI...' -ForegroundColor Cyan
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        & winget install --id Microsoft.AzureCLI --exact --silent `
            --accept-package-agreements --accept-source-agreements --disable-interactivity
        if ($LASTEXITCODE -ne 0) { throw "Installazione Azure CLI con winget fallita (exit code $LASTEXITCODE)." }
    }
    else {
        $installer = Join-Path ([System.IO.Path]::GetTempPath()) 'AzureCLI.msi'
        try {
            Invoke-WebRequest -Uri 'https://aka.ms/installazurecliwindowsx64' -OutFile $installer -UseBasicParsing
            $process = Start-Process msiexec.exe `
                -ArgumentList '/i', "`"$installer`"", '/qn', '/norestart' `
                -Wait -PassThru
            if ($process.ExitCode -notin @(0, 3010)) {
                throw "Installazione Azure CLI MSI fallita (exit code $($process.ExitCode))."
            }
        }
        finally {
            Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
        }
    }

    Update-ProcessPath
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        $azureCliPath = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin'
        if (Test-Path $azureCliPath) { $env:Path = "$azureCliPath;$env:Path" }
    }
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI installata ma non rilevata. Chiudere il terminale e rilanciare deploy.ps1.'
    }
}

function Install-RequiredModule {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][version]$MinimumVersion
    )

    $available = Get-Module -ListAvailable -Name $Name |
        Where-Object Version -ge $MinimumVersion |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($available) { return }

    Write-Host "==> Installazione modulo $Name >= $MinimumVersion..." -ForegroundColor Cyan
    Install-Module -Name $Name -MinimumVersion $MinimumVersion -Repository PSGallery `
        -Scope CurrentUser -Force -AllowClobber
}

function Initialize-DeploymentTooling {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
    }
    if (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue) {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    }

    Install-AzureCli
    Write-Host '==> Installazione/aggiornamento Bicep tramite Azure CLI...' -ForegroundColor Cyan
    & az bicep install
    if ($LASTEXITCODE -ne 0) { throw "Installazione Bicep fallita (exit code $LASTEXITCODE)." }
    Add-BicepToProcessPath

    Install-RequiredModule -Name Az.Accounts -MinimumVersion 5.0.0
    Install-RequiredModule -Name Az.Resources -MinimumVersion 8.0.0
    Install-RequiredModule -Name Az.Automation -MinimumVersion 1.11.0

    if ($GrantGraphPermissions) {
        Install-RequiredModule -Name Microsoft.Graph.Authentication -MinimumVersion 2.40.0
        Install-RequiredModule -Name Microsoft.Graph.Applications -MinimumVersion 2.40.0
    }
}

function Assert-Command {
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Comando '$Name' non disponibile dopo il bootstrap."
    }
}

function Register-RequiredResourceProvider {
    param([Parameter(Mandatory)][string]$ProviderNamespace)

    $provider = Get-AzResourceProvider -ProviderNamespace $ProviderNamespace -ErrorAction Stop
    if ($provider.RegistrationState -contains 'Registered') { return }

    Write-Host "==> Registrazione resource provider $ProviderNamespace..." -ForegroundColor Cyan
    Register-AzResourceProvider -ProviderNamespace $ProviderNamespace | Out-Null
    $deadline = (Get-Date).AddMinutes(10)
    do {
        Start-Sleep -Seconds 5
        $provider = Get-AzResourceProvider -ProviderNamespace $ProviderNamespace -ErrorAction Stop
    } until (($provider.RegistrationState -contains 'Registered') -or (Get-Date) -ge $deadline)

    if ($provider.RegistrationState -notcontains 'Registered') {
        throw "Registrazione del resource provider '$ProviderNamespace' non completata entro 10 minuti."
    }
}

function Get-BicepParameterValues {
    param([Parameter(Mandatory)][string]$Path)

    $compiledPath = Join-Path ([System.IO.Path]::GetTempPath()) "nimbus-params-$([guid]::NewGuid()).json"
    try {
        & az bicep build-params --file $Path --outfile $compiledPath
        if ($LASTEXITCODE -ne 0) {
            throw "Compilazione del file parametri Bicep fallita (exit code $LASTEXITCODE)."
        }
        return (Get-Content -LiteralPath $compiledPath -Raw | ConvertFrom-Json).parameters
    }
    finally {
        Remove-Item -LiteralPath $compiledPath -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-RunbookDeploymentSelection {
    param(
        [Parameter()][AllowEmptyString()][string]$RunbookSelection,
        [Parameter(Mandatory)][bool]$SelectionWasSpecified,
        [Parameter(Mandatory)][bool]$ParameterDeployGroupSync,
        [Parameter(Mandatory)][bool]$ParameterDeployExtensionAttribute
    )

    $deployGroupSync = if ($SelectionWasSpecified) {
        $RunbookSelection -in @('All', 'GroupSync')
    }
    else {
        $ParameterDeployGroupSync
    }
    $deployExtensionAttribute = if ($SelectionWasSpecified) {
        $RunbookSelection -in @('All', 'ExtensionAttribute')
    }
    else {
        $ParameterDeployExtensionAttribute
    }
    if (-not ($deployGroupSync -or $deployExtensionAttribute)) {
        throw 'Il deployment deve includere almeno un runbook.'
    }

    [pscustomobject]@{
        DeployGroupSync          = $deployGroupSync
        DeployExtensionAttribute = $deployExtensionAttribute
    }
}

function Resolve-RunbookMonitoringSelection {
    param(
        [Parameter(Mandatory)][bool]$DeployGroupSync,
        [Parameter(Mandatory)][bool]$DeployExtensionAttribute,
        [Parameter(Mandatory)][bool]$FullReconcile,
        [Parameter()][string[]]$ExistingRunbookName = @(),
        [Parameter(Mandatory)][string]$GroupSyncRunbookName,
        [Parameter(Mandatory)][string]$ExtensionAttributeRunbookName
    )

    [pscustomobject]@{
        MonitorGroupSync = $DeployGroupSync -or (
            -not $FullReconcile -and
            $GroupSyncRunbookName -in $ExistingRunbookName
        )
        MonitorExtensionAttribute = $DeployExtensionAttribute -or (
            -not $FullReconcile -and
            $ExtensionAttributeRunbookName -in $ExistingRunbookName
        )
    }
}

function ConvertTo-UserAssignedIdentityMap {
    param([Parameter()][AllowNull()][object]$UserAssignedIdentities)

    $result = @{}
    if ($null -eq $UserAssignedIdentities) {
        return $result
    }

    if ($UserAssignedIdentities -is [System.Collections.IDictionary]) {
        foreach ($resourceId in $UserAssignedIdentities.Keys) {
            $result[[string]$resourceId] = @{}
        }
        return $result
    }

    foreach ($property in $UserAssignedIdentities.PSObject.Properties) {
        $result[[string]$property.Name] = @{}
    }
    return $result
}

function Get-RequiredGraphAppRole {
    param(
        [Parameter(Mandatory)][bool]$DeployGroupSync,
        [Parameter(Mandatory)][bool]$EnableKeyEscrowCheck
    )

    if (-not $DeployGroupSync) {
        return @(
            'DeviceManagementManagedDevices.Read.All'
            'Device.ReadWrite.All'
        )
    }

    @(
        'DeviceManagementManagedDevices.Read.All'
        'Device.ReadWrite.All'
        'Group.Create'
        'GroupMember.ReadWrite.All'
    )
    if ($EnableKeyEscrowCheck) {
        'BitlockerKey.Read.All'
    }
}

function Remove-ExistingJobScheduleLink {
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$AutomationAccountName,
        [Parameter(Mandatory)][string]$RunbookName,
        [Parameter()][string]$ScheduleName
    )

    $account = Get-AzAutomationAccount `
        -ResourceGroupName $ResourceGroupName `
        -Name $AutomationAccountName `
        -ErrorAction SilentlyContinue
    if (-not $account) { return }

    $links = @(Get-AzAutomationScheduledRunbook `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -ErrorAction Stop |
            Where-Object {
                $_.RunbookName -eq $RunbookName -and
                ([string]::IsNullOrWhiteSpace($ScheduleName) -or $_.ScheduleName -eq $ScheduleName)
            })

    foreach ($link in $links) {
        Write-Host "==> Rimozione jobSchedule esistente '$($link.JobScheduleId)' per aggiornare i parametri runtime..." -ForegroundColor Cyan
        Unregister-AzAutomationScheduledRunbook `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -JobScheduleId $link.JobScheduleId `
            -Force

        $deadline = (Get-Date).AddMinutes(2)
        do {
            $remaining = @(
                Get-AzAutomationScheduledRunbook `
                    -ResourceGroupName $ResourceGroupName `
                    -AutomationAccountName $AutomationAccountName `
                    -ErrorAction Stop |
                    Where-Object JobScheduleId -eq $link.JobScheduleId
            )
            if (-not $remaining) { break }
            if ((Get-Date) -ge $deadline) {
                throw "Timeout durante la rimozione del jobSchedule '$($link.JobScheduleId)'."
            }
            Start-Sleep -Seconds 2
        } while ($true)
    }
}

function Remove-DeselectedRunbookArtifact {
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$AutomationAccountName,
        [Parameter(Mandatory)][string]$RunbookName,
        [Parameter(Mandatory)][string[]]$RuntimeVariableName
    )

    Remove-ExistingJobScheduleLink `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -RunbookName $RunbookName

    $webhooks = @(Get-AzAutomationWebhook `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -ErrorAction Stop |
        Where-Object RunbookName -eq $RunbookName)
    foreach ($webhook in $webhooks) {
        Write-Warning "Rimozione webhook del runbook non selezionato '$($webhook.Name)'."
        Remove-AzAutomationWebhook `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $webhook.Name `
            -Confirm:$false
    }

    $schedules = @(Get-AzAutomationSchedule `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -ErrorAction Stop |
        Where-Object Name -Like "$RunbookName-every*h")
    foreach ($schedule in $schedules) {
        Write-Warning "Rimozione schedule non selezionata '$($schedule.Name)'."
        Remove-AzAutomationSchedule `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $schedule.Name `
            -Force
    }

    $runbook = @(Get-AzAutomationRunbook `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -ErrorAction Stop |
        Where-Object Name -eq $RunbookName |
        Select-Object -First 1)
    if ($runbook) {
        Write-Warning "Rimozione runbook non selezionato '$RunbookName'."
        Remove-AzAutomationRunbook `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $RunbookName `
            -Force
    }

    $automationVariables = @(Get-AzAutomationVariable `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -ErrorAction Stop)
    foreach ($variableName in $RuntimeVariableName) {
        if ($automationVariables.Name -contains $variableName) {
            Write-Warning "Rimozione configurazione runtime non selezionata '$variableName'."
            Remove-AzAutomationVariable `
                -ResourceGroupName $ResourceGroupName `
                -AutomationAccountName $AutomationAccountName `
                -Name $variableName `
                -Confirm:$false
        }
    }
}

function Disable-RunbookWebhook {
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$AutomationAccountName,
        [Parameter(Mandatory)][string]$RunbookName
    )

    $account = @(Get-AzAutomationAccount `
            -ResourceGroupName $ResourceGroupName `
            -ErrorAction Stop |
        Where-Object AutomationAccountName -eq $AutomationAccountName |
        Select-Object -First 1)
    if (-not $account) { return }

    $webhooks = @(Get-AzAutomationWebhook `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -ErrorAction Stop |
        Where-Object { $_.RunbookName -eq $RunbookName -and $_.IsEnabled })
    foreach ($webhook in $webhooks) {
        Write-Warning "Disabilitazione temporanea webhook '$($webhook.Name)' durante la riconciliazione Graph."
        Set-AzAutomationWebhook `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $webhook.Name `
            -IsEnabled $false |
            Out-Null
        [pscustomobject]@{
            Name        = $webhook.Name
            RunbookName = $RunbookName
        }
    }
}

function Enable-RunbookWebhook {
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$AutomationAccountName,
        [Parameter(Mandatory)][object[]]$Webhook,
        [Parameter(Mandatory)][string[]]$SelectedRunbookName
    )

    foreach ($item in $Webhook | Where-Object RunbookName -in $SelectedRunbookName) {
        Write-Host "==> Riabilitazione webhook '$($item.Name)' dopo il grant Graph..." -ForegroundColor Cyan
        try {
            Set-AzAutomationWebhook `
                -ResourceGroupName $ResourceGroupName `
                -AutomationAccountName $AutomationAccountName `
                -Name $item.Name `
                -IsEnabled $true `
                -ErrorAction Stop |
                Out-Null
            [pscustomobject]@{
                Name        = $item.Name
                RunbookName = $item.RunbookName
                Restored    = $true
                Error       = $null
            }
        }
        catch {
            [pscustomobject]@{
                Name        = $item.Name
                RunbookName = $item.RunbookName
                Restored    = $false
                Error       = $_.Exception.Message
            }
        }
    }
}

function Get-DeploymentDisabledWebhook {
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$AutomationAccountName
    )

    $state = Get-AzAutomationVariable `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -Name 'BitLockerDeploymentDisabledWebhooks' `
        -ErrorAction SilentlyContinue
    if (-not $state) { return @() }
    if ($state.Encrypted -or $state.Value -isnot [string]) {
        throw "Automation Variable 'BitLockerDeploymentDisabledWebhooks' non valida."
    }
    try {
        return @($state.Value | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        throw "Automation Variable 'BitLockerDeploymentDisabledWebhooks' contiene JSON non valido."
    }
}

function Save-DeploymentDisabledWebhook {
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$AutomationAccountName,
        [Parameter(Mandatory)][object[]]$Webhook
    )

    $uniqueWebhook = @(
        $Webhook |
        Group-Object Name, RunbookName |
        ForEach-Object { $_.Group[0] }
    )
    $value = ConvertTo-Json -InputObject $uniqueWebhook -Compress
    $existing = Get-AzAutomationVariable `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -Name 'BitLockerDeploymentDisabledWebhooks' `
        -ErrorAction SilentlyContinue
    $parameters = @{
        ResourceGroupName     = $ResourceGroupName
        AutomationAccountName = $AutomationAccountName
        Name                  = 'BitLockerDeploymentDisabledWebhooks'
        Encrypted             = $false
        Value                 = $value
    }
    if ($existing) {
        Set-AzAutomationVariable @parameters -ErrorAction Stop | Out-Null
    }
    else {
        New-AzAutomationVariable @parameters `
            -Description 'Stato interno dei webhook temporaneamente disabilitati dal deployment.' `
            -ErrorAction Stop |
            Out-Null
    }
}

function Clear-DeploymentDisabledWebhook {
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$AutomationAccountName
    )

    Remove-AzAutomationVariable `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -Name 'BitLockerDeploymentDisabledWebhooks' `
        -Confirm:$false `
        -ErrorAction Stop
}

function Import-LocalAutomationRunbook {
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$AutomationAccountName,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$Tags
    )

    if ($Name -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,62}$') {
        throw "Nome runbook non valido per l'import locale: '$Name'."
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "File runbook locale non trovato: $Path"
    }

    $importPath = $Path
    $temporaryDirectory = $null
    try {
        if ([IO.Path]::GetFileNameWithoutExtension($Path) -ne $Name) {
            $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) "nimbus-runbook-$([guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $temporaryDirectory -ErrorAction Stop | Out-Null
            $importPath = Join-Path $temporaryDirectory "$Name.ps1"
            Copy-Item -LiteralPath $Path -Destination $importPath -ErrorAction Stop
        }

        Write-Host "==> Import locale runbook '$Name'..." -ForegroundColor Cyan
        Import-AzAutomationRunbook `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Path $importPath `
            -Name $Name `
            -Type PowerShell72 `
            -Tags $Tags `
            -LogProgress $true `
            -LogVerbose $true `
            -Published `
            -Force `
            -ErrorAction Stop |
            Out-Null
    }
    finally {
        if ($temporaryDirectory) {
            Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $publishedRunbook = Get-AzAutomationRunbook `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -Name $Name `
        -ErrorAction Stop
    if ($publishedRunbook.State -ne 'Published') {
        throw "Il runbook '$Name' non risulta Published dopo l'import locale."
    }
}

function Initialize-ExtensionAttributeAutomationVariable {
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$AutomationAccountName,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )

    $automationVariables = @(Get-AzAutomationVariable `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -ErrorAction Stop)
    $existing = @($automationVariables | Where-Object Name -eq $Name)[0]
    if ($existing) {
        if ($existing.Encrypted) {
            throw "Automation Variable '$Name' deve essere una String non cifrata."
        }
        if ($existing.Value -isnot [string]) {
            throw "Automation Variable '$Name' deve contenere un valore di tipo String."
        }
        if ([string]$existing.Value -ne $Value) {
            Write-Warning "Automation Variable '$Name' preservata con valore diverso dal parametro iniziale richiesto."
        }
        Write-Host "    [=] Automation Variable preservata: $Name" -ForegroundColor DarkGray
        return [string]$existing.Value
    }

    Write-Host "    [+] Creazione Automation Variable: $Name = '$Value'" -ForegroundColor Green
    New-AzAutomationVariable `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -Name $Name `
        -Encrypted $false `
        -Value $Value `
        -Description 'Configurazione globale di Sync-BitLockerExtensionAttribute; modificabile dall Automation Account.' |
        Out-Null
    return $Value
}

function Test-ExtensionAttributeMapping {
    param(
        [Parameter(Mandatory)][string]$AttributeName,
        [Parameter(Mandatory)][string]$EncryptedValue,
        [Parameter(Mandatory)][string]$NotEncryptedValue
    )

    if ($AttributeName -notmatch '^extensionAttribute(?:[1-9]|1[0-5])$') {
        throw "Nome extension attribute non valido: '$AttributeName'."
    }
    if ([string]::IsNullOrWhiteSpace($EncryptedValue) -or
        [string]::IsNullOrWhiteSpace($NotEncryptedValue)) {
        throw 'I valori extension attribute cifrato e non cifrato non possono essere vuoti.'
    }
    if ($EncryptedValue -eq $NotEncryptedValue) {
        throw 'I valori extension attribute cifrato e non cifrato devono essere diversi.'
    }
    if ($EncryptedValue.Length -gt 1024 -or $NotEncryptedValue.Length -gt 1024) {
        throw 'I valori extension attribute non possono superare 1024 caratteri.'
    }
}

function Remove-ResourceIfPresent {
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$ResourceType,
        [Parameter(Mandatory)][string]$Name
    )

    $resource = @(Get-AzResource `
        -ResourceGroupName $ResourceGroupName `
        -ResourceType $ResourceType `
        -ErrorAction Stop |
        Where-Object Name -eq $Name |
        Select-Object -First 1)
    if ($resource) {
        Write-Warning "Rimozione risorsa non piu necessaria '$Name'."
        Remove-AzResource -ResourceId $resource.ResourceId -Force | Out-Null
    }
}

function Remove-ExtensionAttributeWorkbookIfPresent {
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$WorkspaceResourceId
    )

    $workbooks = @(
        Get-AzResource `
            -ResourceGroupName $ResourceGroupName `
            -ResourceType 'Microsoft.Insights/workbooks' `
            -ExpandProperties `
            -ErrorAction Stop |
            Where-Object {
                $null -ne $_.Tags -and
                $_.Tags['workbook'] -eq 'extension-attribute' -and
                $_.Tags['workbookVersion'] -eq '2.0' -and
                $_.Properties.displayName -eq 'BitLocker Extension Attribute - Operations Overview v2' -and
                $_.Properties.sourceId -eq $WorkspaceResourceId
            }
    )
    foreach ($workbook in $workbooks) {
        Write-Warning "Rimozione workbook extension attribute non selezionato '$($workbook.Name)'."
        Remove-AzResource -ResourceId $workbook.ResourceId -Force -ErrorAction Stop
    }
}

function Remove-GroupSyncWorkbookIfPresent {
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$WorkspaceResourceId
    )

    $workbooks = @(
        Get-AzResource `
            -ResourceGroupName $ResourceGroupName `
            -ResourceType 'Microsoft.Insights/workbooks' `
            -ExpandProperties `
            -ErrorAction Stop |
            Where-Object {
                $_.Properties.displayName -eq 'Nimbus.BitLockerGroupSync - Monitoring' -and
                $_.Properties.sourceId -eq $WorkspaceResourceId
            }
    )
    foreach ($workbook in $workbooks) {
        Write-Warning "Rimozione workbook GroupSync non selezionato '$($workbook.Name)'."
        Remove-AzResource -ResourceId $workbook.ResourceId -Force -ErrorAction Stop
    }
}

function Resolve-AutomationAccountName {
    param(
        [Parameter(Mandatory)][string]$RequestedName,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$SubscriptionId
    )

    $accounts = @(Get-AzResource -ResourceType 'Microsoft.Automation/automationAccounts' -ErrorAction Stop)
    $conflict = $accounts | Where-Object {
        $_.Name -eq $RequestedName -and $_.ResourceGroupName -ne $ResourceGroupName
    } | Select-Object -First 1
    if (-not $conflict) { return $RequestedName }

    $hashInput = "$SubscriptionId/$($ResourceGroupName.ToLowerInvariant())"
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($hashInput))
        $suffix = ([System.BitConverter]::ToString($hashBytes) -replace '-', '').Substring(0, 8).ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }

    $maxBaseLength = 50 - $suffix.Length - 1
    $baseName = $RequestedName.Substring(0, [Math]::Min($RequestedName.Length, $maxBaseLength)).TrimEnd('-')
    $resolvedName = "$baseName-$suffix"
    $resolvedConflict = $accounts | Where-Object {
        $_.Name -eq $resolvedName -and $_.ResourceGroupName -ne $ResourceGroupName
    } | Select-Object -First 1
    if ($resolvedConflict) {
        throw "Impossibile generare un nome Automation Account univoco: '$resolvedName' esiste in '$($resolvedConflict.ResourceGroupName)'."
    }

    Write-Warning "Automation Account '$RequestedName' gia presente in '$($conflict.ResourceGroupName)'. Verra usato il nome deterministico '$resolvedName'."
    return $resolvedName
}

function ConvertTo-StringHashtable {
    param([Parameter(Mandatory)][object]$InputObject)

    $result = @{}
    if ($InputObject.GetType().FullName -eq 'Newtonsoft.Json.Linq.JObject') {
        foreach ($property in $InputObject.Properties()) {
            $result[[string]$property.Name] = [string]$property.Value
        }
        return $result
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            $result[[string]$key] = [string]$InputObject[$key]
        }
        return $result
    }

    foreach ($property in $InputObject.PSObject.Properties) {
        if (-not [string]::IsNullOrWhiteSpace($property.Name)) {
            $result[$property.Name] = [string]$property.Value
        }
    }
    return $result
}

function ConvertTo-DirectRunbookHashtable {
    param([Parameter(Mandatory)][hashtable]$Parameters)

    $result = $Parameters.Clone()
    try {
        $result['KeyMissingAlertThreshold'] = [int]$result['KeyMissingAlertThreshold']
    }
    catch {
        throw "KeyMissingAlertThreshold non e un intero valido: '$($result['KeyMissingAlertThreshold'])'."
    }
    return $result
}

function ConvertTo-DirectExtensionAttributeRunbookHashtable {
    param([Parameter(Mandatory)][hashtable]$Parameters)

    return $Parameters.Clone()
}

$resolvedParameterFile = (Resolve-Path -LiteralPath $ParameterFile -ErrorAction Stop).Path

if (-not $SkipBootstrap) { Initialize-DeploymentTooling }
Add-BicepToProcessPath

Import-Module Az.Accounts -MinimumVersion 5.0.0 -ErrorAction Stop
Import-Module Az.Resources -MinimumVersion 8.0.0 -ErrorAction Stop
Import-Module Az.Automation -MinimumVersion 1.11.0 -ErrorAction Stop

Assert-Command -Name 'az'
Assert-Command -Name 'Connect-AzAccount'
Assert-Command -Name 'New-AzResourceGroupDeployment'
Assert-Command -Name 'Get-AzResourceGroupDeploymentWhatIfResult'
Assert-Command -Name 'New-AzAutomationWebhook'

if ($GrantGraphPermissions) {
    Assert-Command -Name 'pwsh'
}

$parameterValues = Get-BicepParameterValues -Path $resolvedParameterFile
$AuthenticationMode = if ($parameterValues.authenticationMode) {
    [string]$parameterValues.authenticationMode.value
}
else {
    'ManagedIdentity'
}
$AppTenantId = if ($parameterValues.appTenantId) { [string]$parameterValues.appTenantId.value } else { '' }
$AppClientId = if ($parameterValues.appClientId) { [string]$parameterValues.appClientId.value } else { '' }
$AppCertificateAssetName = if ($parameterValues.certificateAssetName) {
    [string]$parameterValues.certificateAssetName.value
}
else {
    'GraphAuthCertificate'
}
$AppClientSecretVariableName = if ($parameterValues.graphCredentialVariableName) {
    [string]$parameterValues.graphCredentialVariableName.value
}
else {
    'GraphClientSecret'
}
$configuredAutomationAccountName = if ($parameterValues.automationAccountName) {
    [string]$parameterValues.automationAccountName.value
}
else {
    'aa-bitlocker-groupsync'
}
$parameterAutomationAccountPublicNetworkAccess =
    if ($null -ne $parameterValues.automationAccountPublicNetworkAccess) {
        [bool]$parameterValues.automationAccountPublicNetworkAccess.value
    }
    else {
        $true
    }
$configuredLogAnalyticsWorkspaceName = if ($parameterValues.logAnalyticsWorkspaceName) {
    [string]$parameterValues.logAnalyticsWorkspaceName.value
}
else {
    "$configuredAutomationAccountName-law"
}
$configuredRunbookName = if ($parameterValues.runbookName) {
    [string]$parameterValues.runbookName.value
}
else {
    'Sync-BitLockerComplianceGroups'
}
$parameterDeployGroupSync = if ($null -ne $parameterValues.deployGroupSyncRunbook) {
    [bool]$parameterValues.deployGroupSyncRunbook.value
}
else {
    $true
}
$parameterDeployExtensionAttribute = if ($null -ne $parameterValues.deployExtensionAttributeRunbook) {
    [bool]$parameterValues.deployExtensionAttributeRunbook.value
}
else {
    $false
}
$selection = Resolve-RunbookDeploymentSelection `
    -RunbookSelection $RunbookSelection `
    -SelectionWasSpecified $PSBoundParameters.ContainsKey('RunbookSelection') `
    -ParameterDeployGroupSync $parameterDeployGroupSync `
    -ParameterDeployExtensionAttribute $parameterDeployExtensionAttribute
$deployGroupSyncRunbook = $selection.DeployGroupSync
$deployExtensionAttributeRunbook = $selection.DeployExtensionAttribute
$deploymentMode = if ($FullReconcile) { 'FullReconcile' } else { 'Delta' }
Write-Host "==> Modalita deployment: $deploymentMode" -ForegroundColor Cyan
if ($FullReconcile) {
    Write-Warning 'FullReconcile applichera la selezione come stato finale e rimuovera gli artefatti gestiti non selezionati.'
}
$configuredExtensionAttributeRunbookName = 'Sync-BitLockerExtensionAttribute'
$configuredExtensionAttributeName = if ($null -ne $parameterValues.extensionAttributeName) {
    [string]$parameterValues.extensionAttributeName.value
}
else {
    'extensionAttribute10'
}
$configuredExtensionAttributeEncryptedValue =
    if ($null -ne $parameterValues.extensionAttributeEncryptedValue) {
        [string]$parameterValues.extensionAttributeEncryptedValue.value
    }
    else {
        'enc'
    }
$configuredExtensionAttributeNotEncryptedValue =
    if ($null -ne $parameterValues.extensionAttributeNotEncryptedValue) {
        [string]$parameterValues.extensionAttributeNotEncryptedValue.value
    }
    else {
        'notenc'
    }
Test-ExtensionAttributeMapping `
    -AttributeName $configuredExtensionAttributeName `
    -EncryptedValue $configuredExtensionAttributeEncryptedValue `
    -NotEncryptedValue $configuredExtensionAttributeNotEncryptedValue
$deployRunbookContentLinks = if ($null -ne $parameterValues.deployRunbookContentLinks) {
    [bool]$parameterValues.deployRunbookContentLinks.value
}
else {
    $true
}
$deployLogAnalytics = if ($null -ne $parameterValues.deployLogAnalytics) {
    [bool]$parameterValues.deployLogAnalytics.value
}
else {
    $true
}
$deployMonitoring = if ($null -ne $parameterValues.deployMonitoring) {
    [bool]$parameterValues.deployMonitoring.value
}
else {
    $true
}
$deployWorkbook = if ($null -ne $parameterValues.deployWorkbook) {
    [bool]$parameterValues.deployWorkbook.value
}
else {
    $true
}
$configuredTags = if ($null -ne $parameterValues.tags) {
    ConvertTo-StringHashtable -InputObject $parameterValues.tags.value
}
else {
    @{
        solution  = 'BitLockerGroupSync'
        managedBy = 'deploy.ps1'
        version   = '1.5.3'
    }
}
$configuredScheduleIntervalHours = if ($null -ne $parameterValues.scheduleIntervalHours) {
    [int]$parameterValues.scheduleIntervalHours.value
}
else {
    1
}
$configuredExtensionAttributeScheduleIntervalHours =
    if ($null -ne $parameterValues.extensionAttributeScheduleIntervalHours) {
        [int]$parameterValues.extensionAttributeScheduleIntervalHours.value
    }
    else {
        1
    }
$configuredScheduleName = "$configuredRunbookName-every$($configuredScheduleIntervalHours)h"
$configuredExtensionAttributeScheduleName =
    "$configuredExtensionAttributeRunbookName-every$($configuredExtensionAttributeScheduleIntervalHours)h"
$enableKeyEscrowCheck = $null -ne $parameterValues.enableKeyEscrowCheck -and
    [bool]$parameterValues.enableKeyEscrowCheck.value
$requiredGraphAppRoles = @(Get-RequiredGraphAppRole `
        -DeployGroupSync $deployGroupSyncRunbook `
        -EnableKeyEscrowCheck $enableKeyEscrowCheck)

if ($GrantGraphPermissions -and $AuthenticationMode -ne 'ManagedIdentity') {
    throw '-GrantGraphPermissions e supportato solo con AuthenticationMode=ManagedIdentity.'
}
if (($CreateTriggerWebhook -or $StartJobNow) -and -not $deployGroupSyncRunbook) {
    throw 'Webhook e avvio GroupSync richiedono che GroupSync sia incluso in RunbookSelection.'
}
if ($StartExtensionAttributeJobNow -and -not $deployExtensionAttributeRunbook) {
    throw 'Avvio ExtensionAttribute richiede che ExtensionAttribute sia incluso in RunbookSelection.'
}
if ($AuthenticationMode -like 'AppRegistration*') {
    if ([string]::IsNullOrWhiteSpace($AppTenantId) -or [string]::IsNullOrWhiteSpace($AppClientId)) {
        throw 'AppTenantId e AppClientId sono obbligatori per le modalita AppRegistration.'
    }
}
if ($AuthenticationMode -eq 'AppRegistrationCertificate') {
    $hasPfxPath = -not [string]::IsNullOrWhiteSpace($AppCertificatePfxPath)
    $hasPfxPassword = $null -ne $AppCertificatePfxPassword
    if ($hasPfxPath -xor $hasPfxPassword) {
        throw 'Specificare insieme AppCertificatePfxPath e AppCertificatePfxPassword.'
    }
    if ($hasPfxPath) {
        $AppCertificatePfxPath = (Resolve-Path -LiteralPath $AppCertificatePfxPath -ErrorAction Stop).Path
    }
}

Write-Host '==> Verifica login e contesto Azure...' -ForegroundColor Cyan
$context = Get-AzContext
$requiresLogin = -not $context
if ($context -and $TenantId -and $context.Tenant.Id -ne $TenantId) { $requiresLogin = $true }

if ($requiresLogin) {
    $loginParams = @{ UseDeviceAuthentication = $true }
    if ($TenantId) { $loginParams.Tenant = $TenantId }
    Connect-AzAccount @loginParams | Out-Null
}

if ($SubscriptionId) {
    $contextParams = @{ SubscriptionId = $SubscriptionId }
    if ($TenantId) { $contextParams.Tenant = $TenantId }
    Set-AzContext @contextParams | Out-Null
}

$context = Get-AzContext
if (-not $context) { throw 'Nessun contesto Azure attivo.' }
if ($TenantId -and $context.Tenant.Id -ne $TenantId) {
    throw "Tenant attivo '$($context.Tenant.Id)' diverso dal tenant richiesto '$TenantId'."
}
if ($SubscriptionId -and $context.Subscription.Id -ne $SubscriptionId) {
    throw "Subscription attiva '$($context.Subscription.Id)' diversa dalla subscription richiesta '$SubscriptionId'."
}

Write-Host "    Tenant:       $($context.Tenant.Id)" -ForegroundColor Green
Write-Host "    Subscription: $($context.Subscription.Name) ($($context.Subscription.Id))" -ForegroundColor Green

$configuredAutomationAccountName = Resolve-AutomationAccountName `
    -RequestedName $configuredAutomationAccountName `
    -ResourceGroupName $ResourceGroupName `
    -SubscriptionId $context.Subscription.Id

if (-not $SkipProviderRegistration) {
    @(
        'Microsoft.Automation'
        'Microsoft.ManagedIdentity'
        'Microsoft.OperationalInsights'
        'Microsoft.Insights'
        'Microsoft.Logic'
        'Microsoft.Resources'
    ) | ForEach-Object { Register-RequiredResourceProvider -ProviderNamespace $_ }
}

Write-Host "==> Resource group '$ResourceGroupName'..." -ForegroundColor Cyan
if (-not (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue)) {
    New-AzResourceGroup -Name $ResourceGroupName -Location $Location | Out-Null
}

if ($AuthenticationMode -eq 'AppRegistrationCertificate' -and [string]::IsNullOrWhiteSpace($AppCertificatePfxPath)) {
    $existingCertificate = Get-AzAutomationCertificate `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $configuredAutomationAccountName `
        -Name $AppCertificateAssetName `
        -ErrorAction SilentlyContinue
    if (-not $existingCertificate) {
        throw "Automation Certificate '$AppCertificateAssetName' non esistente: specificare PFX e password."
    }
}
if ($AuthenticationMode -eq 'AppRegistrationSecret' -and -not $AppClientSecret) {
    $existingSecretVariable = Get-AzAutomationVariable `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $configuredAutomationAccountName `
        -Name $AppClientSecretVariableName `
        -ErrorAction SilentlyContinue
    if (-not $existingSecretVariable) {
        throw "Automation Variable cifrata '$AppClientSecretVariableName' non esistente: specificare AppClientSecret."
    }
}

$existingAutomationAccount = Get-AzAutomationAccount `
    -ResourceGroupName $ResourceGroupName `
    -Name $configuredAutomationAccountName `
    -ErrorAction SilentlyContinue
$preservedAutomationAccountUserAssignedIdentities = @{}
$preserveAutomationAccountSystemAssignedIdentity = $false
$effectiveAutomationAccountPublicNetworkAccess = $parameterAutomationAccountPublicNetworkAccess
if ($existingAutomationAccount -and -not $FullReconcile) {
    $existingAutomationAccountResource = Get-AzResource `
        -ResourceGroupName $ResourceGroupName `
        -ResourceType 'Microsoft.Automation/automationAccounts' `
        -Name $configuredAutomationAccountName `
        -ExpandProperties `
        -ErrorAction Stop
    $existingIdentity = $existingAutomationAccountResource.Identity
    $preservedAutomationAccountUserAssignedIdentities =
        ConvertTo-UserAssignedIdentityMap `
            -UserAssignedIdentities $existingIdentity.UserAssignedIdentities
    $preserveAutomationAccountSystemAssignedIdentity =
        [string]$existingIdentity.Type -match 'SystemAssigned'
    $existingPublicNetworkAccess =
        [string]$existingAutomationAccountResource.Properties.publicNetworkAccess
    if ([string]::IsNullOrWhiteSpace($existingPublicNetworkAccess)) {
        throw "Impossibile determinare publicNetworkAccess dell'Automation Account esistente '$configuredAutomationAccountName'."
    }
    $effectiveAutomationAccountPublicNetworkAccess =
        $existingPublicNetworkAccess -ne 'Disabled'
}
$existingRunbookNames = if ($existingAutomationAccount) {
    @(
        Get-AzAutomationRunbook `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $configuredAutomationAccountName `
            -ErrorAction Stop |
        ForEach-Object Name
    )
}
else {
    @()
}
$monitoringSelection = Resolve-RunbookMonitoringSelection `
    -DeployGroupSync $deployGroupSyncRunbook `
    -DeployExtensionAttribute $deployExtensionAttributeRunbook `
    -FullReconcile $FullReconcile `
    -ExistingRunbookName $existingRunbookNames `
    -GroupSyncRunbookName $configuredRunbookName `
    -ExtensionAttributeRunbookName $configuredExtensionAttributeRunbookName
$monitorGroupSyncRunbook = $monitoringSelection.MonitorGroupSync
$monitorExtensionAttributeRunbook = $monitoringSelection.MonitorExtensionAttribute
$existingGraphAuthenticationModule = if ($existingAutomationAccount) {
    $graphAuthenticationModuleResourceId =
        "$($existingAutomationAccountResource.ResourceId)/powerShell72Modules/Microsoft.Graph.Authentication"
    Get-AzResource `
        -ResourceId $graphAuthenticationModuleResourceId `
        -ApiVersion '2023-11-01' `
        -ErrorAction SilentlyContinue
}
else {
    $null
}
$deployGraphAuthenticationModule = $FullReconcile -or -not $existingGraphAuthenticationModule
$extensionMappingRequiresInitialization = $false
if ($deployExtensionAttributeRunbook) {
    $existingMappingVariables = if ($existingAutomationAccount) {
        @(
            Get-AzAutomationVariable `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $configuredAutomationAccountName `
            -ErrorAction Stop
        )
    }
    else {
        @()
    }
    $existingMapping = @{}
    foreach ($variable in $existingMappingVariables | Where-Object {
            $_.Name -in @(
                'BitLockerExtensionAttributeName'
                'BitLockerExtensionAttributeEncryptedValue'
                'BitLockerExtensionAttributeNotEncryptedValue'
            )
        }) {
        if ($variable.Encrypted) {
            throw "Automation Variable '$($variable.Name)' deve essere una String non cifrata."
        }
        if ($variable.Value -isnot [string]) {
            throw "Automation Variable '$($variable.Name)' deve contenere un valore di tipo String."
        }
        $existingMapping[$variable.Name] = [string]$variable.Value
    }
    $extensionMappingRequiresInitialization = $existingMapping.Count -lt 3
    if (-not $extensionMappingRequiresInitialization) {
        Test-ExtensionAttributeMapping `
            -AttributeName $existingMapping.BitLockerExtensionAttributeName `
            -EncryptedValue $existingMapping.BitLockerExtensionAttributeEncryptedValue `
            -NotEncryptedValue $existingMapping.BitLockerExtensionAttributeNotEncryptedValue
    }
}

$deploymentName = "nimbus-bitlocker-$(Get-Date -Format 'yyyyMMddHHmmssfff')"
$runtimeEnabled = $GrantGraphPermissions -or $PermissionsConfirmed
$requiresStagedActivation =
    $GrantGraphPermissions -or -not $deployRunbookContentLinks -or $extensionMappingRequiresInitialization
$templateParams = @{
    ResourceGroupName     = $ResourceGroupName
    TemplateParameterFile = $resolvedParameterFile
    location              = $Location
    automationAccountName = $configuredAutomationAccountName
    automationAccountPublicNetworkAccess = $effectiveAutomationAccountPublicNetworkAccess
    preservedAutomationAccountUserAssignedIdentities = $preservedAutomationAccountUserAssignedIdentities
    preserveAutomationAccountSystemAssignedIdentity = $preserveAutomationAccountSystemAssignedIdentity
    deployGraphAuthenticationModule = $deployGraphAuthenticationModule
    deployGroupSyncRunbook = $deployGroupSyncRunbook
    deployExtensionAttributeRunbook = $deployExtensionAttributeRunbook
    monitorGroupSyncRunbook = $monitorGroupSyncRunbook
    monitorExtensionAttributeRunbook = $monitorExtensionAttributeRunbook
    enableSchedule        = $runtimeEnabled
    enableDeadmanAlert    = $runtimeEnabled
}
if ($AppClientSecret) { $templateParams.appClientSecret = $AppClientSecret }
if ($TeamsWebhookUrl) { $templateParams.teamsWebhookUrl = $TeamsWebhookUrl }

Write-Host '==> Preflight ARM/Bicep...' -ForegroundColor Cyan
$validationErrors = @(Test-AzResourceGroupDeployment @templateParams)
if ($validationErrors.Count -gt 0) {
    $validationErrors | Format-List | Out-Host
    throw 'Preflight del deployment non superato.'
}

if (-not $SkipWhatIf) {
    Write-Host '==> What-if del deployment...' -ForegroundColor Cyan
    Get-AzResourceGroupDeploymentWhatIfResult @templateParams -DeploymentName $deploymentName | Out-Host
}

# Azure Automation jobSchedule e immutabile: ricreare il link garantisce che
# ogni redeploy applichi il client ID UAMI e tutti i parametri runtime correnti.
$disabledWebhooks = if ($existingAutomationAccount) {
    @(Get-DeploymentDisabledWebhook `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $configuredAutomationAccountName)
}
else {
    @()
}
if ($requiresStagedActivation -or -not $PermissionsConfirmed) {
    if ($deployGroupSyncRunbook) {
        $disabledWebhooks += @(Disable-RunbookWebhook `
                -ResourceGroupName $ResourceGroupName `
                -AutomationAccountName $configuredAutomationAccountName `
                -RunbookName $configuredRunbookName)
    }
    if ($deployExtensionAttributeRunbook) {
        $disabledWebhooks += @(Disable-RunbookWebhook `
                -ResourceGroupName $ResourceGroupName `
                -AutomationAccountName $configuredAutomationAccountName `
                -RunbookName $configuredExtensionAttributeRunbookName)
    }
    if ($disabledWebhooks.Count -gt 0) {
        Save-DeploymentDisabledWebhook `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $configuredAutomationAccountName `
            -Webhook $disabledWebhooks
    }
}
if ($deployGroupSyncRunbook) {
    Remove-ExistingJobScheduleLink `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $configuredAutomationAccountName `
        -RunbookName $configuredRunbookName `
        -ScheduleName $configuredScheduleName
}
if ($deployExtensionAttributeRunbook) {
    Remove-ExistingJobScheduleLink `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $configuredAutomationAccountName `
        -RunbookName $configuredExtensionAttributeRunbookName `
        -ScheduleName $configuredExtensionAttributeScheduleName
}

Write-Host '==> Deploy Bicep...' -ForegroundColor Cyan
$deploymentParams = $templateParams.Clone()
if ($requiresStagedActivation) {
    $deploymentParams.enableSchedule = $false
    $deploymentParams.enableDeadmanAlert = $false
}
$deployment = New-AzResourceGroupDeployment @deploymentParams -Name $deploymentName -Verbose

$principalId = [string]$deployment.Outputs.managedIdentityPrincipalId.Value
$managedIdentityClientId = [string]$deployment.Outputs.managedIdentityClientId.Value
$managedIdentityResourceId = [string]$deployment.Outputs.managedIdentityResourceId.Value
$aaName = $deployment.Outputs.automationAccountName.Value
$rbName = [string]$deployment.Outputs.runbookName.Value
$runbookParameters = ConvertTo-StringHashtable -InputObject $deployment.Outputs.runbookParameters.Value
$directRunbookParameters = ConvertTo-DirectRunbookHashtable -Parameters $runbookParameters
$extensionAttributeRunbookName = [string]$deployment.Outputs.extensionAttributeRunbookName.Value
$extensionAttributeWorkbookId = [string]$deployment.Outputs.extensionAttributeWorkbookId.Value
$extensionAttributeRunbookParameters = ConvertTo-StringHashtable `
    -InputObject $deployment.Outputs.extensionAttributeRunbookParameters.Value
$extensionAttributeInitialValues = $deployment.Outputs.extensionAttributeInitialValues.Value
$configuredExtensionAttributeName = [string]$extensionAttributeInitialValues.name
$configuredExtensionAttributeEncryptedValue = [string]$extensionAttributeInitialValues.encrypted
$configuredExtensionAttributeNotEncryptedValue = [string]$extensionAttributeInitialValues.notEncrypted
$directExtensionAttributeRunbookParameters = ConvertTo-DirectExtensionAttributeRunbookHashtable `
    -Parameters $extensionAttributeRunbookParameters
if ($AuthenticationMode -eq 'ManagedIdentity') {
    Write-Host "    UAMI resourceId:  $managedIdentityResourceId" -ForegroundColor Green
    Write-Host "    UAMI clientId:    $managedIdentityClientId" -ForegroundColor Green
    Write-Host "    UAMI principalId: $principalId" -ForegroundColor Green
}
$graphPermissionPrincipalId = $principalId

if ($deployExtensionAttributeRunbook) {
    Write-Host '==> Inizializzazione Automation Variables globali extension attribute...' -ForegroundColor Cyan
    $effectiveExtensionAttributeName = Initialize-ExtensionAttributeAutomationVariable `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $aaName `
        -Name 'BitLockerExtensionAttributeName' `
        -Value $configuredExtensionAttributeName
    $effectiveExtensionAttributeEncryptedValue = Initialize-ExtensionAttributeAutomationVariable `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $aaName `
        -Name 'BitLockerExtensionAttributeEncryptedValue' `
        -Value $configuredExtensionAttributeEncryptedValue
    $effectiveExtensionAttributeNotEncryptedValue = Initialize-ExtensionAttributeAutomationVariable `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $aaName `
        -Name 'BitLockerExtensionAttributeNotEncryptedValue' `
        -Value $configuredExtensionAttributeNotEncryptedValue
    Test-ExtensionAttributeMapping `
        -AttributeName $effectiveExtensionAttributeName `
        -EncryptedValue $effectiveExtensionAttributeEncryptedValue `
        -NotEncryptedValue $effectiveExtensionAttributeNotEncryptedValue
}

if (-not $deployRunbookContentLinks) {
    if ($deployGroupSyncRunbook) {
        Import-LocalAutomationRunbook `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $aaName `
            -Path "$PSScriptRoot\runbook\Sync-BitLockerComplianceGroups.ps1" `
            -Name $configuredRunbookName `
            -Tags $configuredTags
    }
    if ($deployExtensionAttributeRunbook) {
        Import-LocalAutomationRunbook `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $aaName `
            -Path "$PSScriptRoot\runbook\Sync-BitLockerExtensionAttribute.ps1" `
            -Name $configuredExtensionAttributeRunbookName `
            -Tags $configuredTags
    }
}

if ($AuthenticationMode -eq 'AppRegistrationCertificate' -and -not [string]::IsNullOrWhiteSpace($AppCertificatePfxPath)) {
    Write-Host "==> Import Automation Certificate '$AppCertificateAssetName'..." -ForegroundColor Cyan
    $certificateParams = @{
        ResourceGroupName     = $ResourceGroupName
        AutomationAccountName = $aaName
        Name                  = $AppCertificateAssetName
        Path                  = $AppCertificatePfxPath
        Password              = $AppCertificatePfxPassword
        ErrorAction           = 'Stop'
    }
    $existingCertificate = Get-AzAutomationCertificate `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $aaName `
        -Name $AppCertificateAssetName `
        -ErrorAction SilentlyContinue
    if ($existingCertificate) {
        Set-AzAutomationCertificate @certificateParams | Out-Null
    }
    else {
        New-AzAutomationCertificate @certificateParams | Out-Null
    }
}

if ($GrantGraphPermissions) {
    Write-Host '==> Assegnazione permessi Graph alla managed identity...' -ForegroundColor Cyan
    $graphAppRolesJson = ConvertTo-Json -InputObject @($requiredGraphAppRoles) -Compress
    $graphAppRolesBase64 = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($graphAppRolesJson)
    )
    $graphPermissionArguments = @(
        '-NoProfile'
        '-File'
        "$PSScriptRoot\scripts\Grant-GraphPermissions.ps1"
        '-ManagedIdentityPrincipalId'
        $graphPermissionPrincipalId
        '-GraphAppRolesBase64'
        $graphAppRolesBase64
        '-TenantId'
        [string]$context.Tenant.Id
        '-UseDeviceCode'
    )
    if ($FullReconcile) {
        $graphPermissionArguments += '-Reconcile'
    }
    & pwsh @graphPermissionArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Aggiornamento dei permessi Graph fallito (exit code $LASTEXITCODE)."
    }

}
elseif (-not $PermissionsConfirmed) {
    Write-Warning 'Permission Graph non confermate: schedule, dead-man alert, webhook e avvio runbook restano disabilitati.'
}
else {
    Write-Host "==> Permission Entra dichiarate come confermate dall'operatore." -ForegroundColor Green
    if ($FullReconcile -and
        $AuthenticationMode -eq 'ManagedIdentity' -and
        -not ($deployGroupSyncRunbook -and $deployExtensionAttributeRunbook)) {
        Write-Warning 'FullReconcile senza -GrantGraphPermissions non revoca gli app role Graph non piu necessari: verificarli manualmente.'
    }
}

if ($requiresStagedActivation -and $runtimeEnabled) {
    Write-Host '==> Attivazione schedule e dead-man alert dopo la preparazione runtime...' -ForegroundColor Cyan
    $activationDeploymentName = "nimbus-bitlocker-activate-$(Get-Date -Format 'yyyyMMddHHmmssfff')"
    $deployment = New-AzResourceGroupDeployment `
        @templateParams `
        -Name $activationDeploymentName `
        -Verbose
}

if ($runtimeEnabled -and $disabledWebhooks.Count -gt 0) {
    $selectedRunbookNames = @()
    if ($deployGroupSyncRunbook) { $selectedRunbookNames += $configuredRunbookName }
    if ($deployExtensionAttributeRunbook) {
        $selectedRunbookNames += $configuredExtensionAttributeRunbookName
    }
    $restoredWebhooks = @(
        Enable-RunbookWebhook `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $aaName `
        -Webhook $disabledWebhooks `
        -SelectedRunbookName $selectedRunbookNames
    )
    $restoredKeys = @(
        $restoredWebhooks |
        Where-Object Restored |
        ForEach-Object { "$($_.RunbookName)|$($_.Name)" }
    )
    $remainingDisabledWebhooks = @(
        $disabledWebhooks |
        Where-Object { "$($_.RunbookName)|$($_.Name)" -notin $restoredKeys }
    )
    if ($remainingDisabledWebhooks.Count -gt 0) {
        Save-DeploymentDisabledWebhook `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $aaName `
            -Webhook $remainingDisabledWebhooks
    }
    else {
        Clear-DeploymentDisabledWebhook `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $aaName
    }
    $restoreFailures = @($restoredWebhooks | Where-Object { -not $_.Restored })
    if ($restoreFailures.Count -gt 0) {
        $failureDetails = $restoreFailures |
            ForEach-Object { "$($_.RunbookName)/$($_.Name): $($_.Error)" }
        throw "Ripristino webhook incompleto; stato preservato per il retry: $($failureDetails -join '; ')"
    }
}

if ($FullReconcile) {
    $configuredWorkspaceResourceId = "/subscriptions/$($context.Subscription.Id)/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$configuredLogAnalyticsWorkspaceName"
    if (-not $deployGroupSyncRunbook) {
        Remove-DeselectedRunbookArtifact `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $aaName `
            -RunbookName $configuredRunbookName `
            -RuntimeVariableName @(
                'BitLockerSyncRuntimeConfig'
                'BitLockerSyncAlertWebhook'
                'BitLockerSyncNotifyWebhook'
            )
    }
    if (-not $deployExtensionAttributeRunbook) {
        Remove-DeselectedRunbookArtifact `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $aaName `
            -RunbookName $configuredExtensionAttributeRunbookName `
            -RuntimeVariableName 'BitLockerExtensionAttributeRuntimeConfig'
    }
    if (-not ($deployExtensionAttributeRunbook -and $deployLogAnalytics -and $deployMonitoring -and $deployWorkbook)) {
        Remove-ExtensionAttributeWorkbookIfPresent `
            -ResourceGroupName $ResourceGroupName `
            -WorkspaceResourceId $configuredWorkspaceResourceId
    }
    if (-not ($deployGroupSyncRunbook -and $deployLogAnalytics -and $deployMonitoring -and $deployWorkbook)) {
        Remove-GroupSyncWorkbookIfPresent `
            -ResourceGroupName $ResourceGroupName `
            -WorkspaceResourceId $configuredWorkspaceResourceId
    }
    if (-not $deployGroupSyncRunbook) {
        Remove-ResourceIfPresent `
            -ResourceGroupName $ResourceGroupName `
            -ResourceType 'Microsoft.Insights/scheduledQueryRules' `
            -Name 'alert-blkgm-no-successful-run'
    }
    if (-not $deployExtensionAttributeRunbook) {
        Remove-ResourceIfPresent `
            -ResourceGroupName $ResourceGroupName `
            -ResourceType 'Microsoft.Insights/scheduledQueryRules' `
            -Name 'alert-blkgm-extension-no-success'
    }
}

if ($CreateTriggerWebhook) {
    if (-not ($GrantGraphPermissions -or $PermissionsConfirmed)) {
        throw 'Creazione webhook bloccata: usare -PermissionsConfirmed dopo la concessione delle permission Entra.'
    }
    Write-Host '==> Creazione webhook di trigger inbound...' -ForegroundColor Cyan
    $expiry = (Get-Date).AddYears(1)
    $wh = New-AzAutomationWebhook `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $aaName `
        -Name "$rbName-trigger" `
        -RunbookName $rbName `
        -Parameters $directRunbookParameters `
        -IsEnabled $true `
        -ExpiryTime $expiry `
        -Force
    Write-Host '    [!] Copia SUBITO questo URI: non sara piu recuperabile.' -ForegroundColor Yellow
    Write-Host "    Webhook URI: $($wh.WebhookURI)" -ForegroundColor Green
}

if ($StartJobNow) {
    if (-not ($GrantGraphPermissions -or $PermissionsConfirmed)) {
        throw 'Avvio runbook bloccato: usare -PermissionsConfirmed dopo la concessione delle permission Entra.'
    }
    Write-Host '==> Avvio job del runbook...' -ForegroundColor Cyan
    Start-AzAutomationRunbook `
        -AutomationAccountName $aaName `
        -ResourceGroupName $ResourceGroupName `
        -Name $rbName `
        -Parameters $directRunbookParameters | Out-Null
}

if ($StartExtensionAttributeJobNow) {
    if (-not ($GrantGraphPermissions -or $PermissionsConfirmed)) {
        throw 'Avvio runbook extension attribute bloccato: usare -PermissionsConfirmed dopo la concessione delle permission Entra.'
    }
    if (-not $deployExtensionAttributeRunbook) {
        throw 'Avvio runbook extension attribute bloccato: deployExtensionAttributeRunbook=false.'
    }
    Write-Host '==> Avvio job del runbook extension attribute...' -ForegroundColor Cyan
    Start-AzAutomationRunbook `
        -AutomationAccountName $aaName `
        -ResourceGroupName $ResourceGroupName `
        -Name $extensionAttributeRunbookName `
        -Parameters $directExtensionAttributeRunbookParameters | Out-Null
}

Write-Host '==> Deploy completato.' -ForegroundColor Green
if (-not [string]::IsNullOrWhiteSpace($extensionAttributeWorkbookId)) {
    Write-Host "    Workbook extension attribute: $extensionAttributeWorkbookId" -ForegroundColor Green
}
