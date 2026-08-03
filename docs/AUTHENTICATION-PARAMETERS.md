# Configurazione dei parametri di autenticazione

Questa guida descrive come configurare `bicep/main.bicepparam` in base al
metodo usato dal runbook per autenticarsi a Microsoft Graph.

## File da utilizzare

Per test o ambienti interni è possibile modificare direttamente:

```text
bicep/main.bicepparam
```

Per un deployment cliente è preferibile creare una copia locale:

```powershell
Copy-Item .\bicep\main.bicepparam .\bicep\customer.local.bicepparam
```

I file `*.local.bicepparam` sono esclusi da Git. Nei comandi di deployment
specificare quindi:

```powershell
-ParameterFile .\bicep\customer.local.bicepparam
```

Non inserire nel file password, client secret, chiavi private o altri valori
sensibili. `appTenantId`, `appClientId`, nomi degli asset e ID delle risorse non
sono credenziali.

## Metodi supportati

| Valore `authenticationMode` | Credenziale | Indicazione |
|---|---|---|
| `ManagedIdentity` | User Assigned Managed Identity | Metodo raccomandato |
| `AppRegistrationCertificate` | App Registration e certificato | Alternativa raccomandata quando è richiesta un'App Registration |
| `AppRegistrationSecret` | App Registration e client secret | Compatibilità; richiede rotazione del secret |

In tutti i casi il principal usato dal runbook deve avere queste Microsoft
Graph **Application permissions**:

- `DeviceManagementManagedDevices.Read.All`
- `BitlockerKey.Read.All`
- `Device.ReadWrite.All`
- `Group.Create`
- `GroupMember.ReadWrite.All`

Le permission devono essere approvate con **Grant admin consent**.

## Managed Identity

Il deployment crea una UAMI dedicata, la collega all'Automation Account e
passa automaticamente il relativo client ID al runbook.

Configurare:

```bicep
param authenticationMode = 'ManagedIdentity'
param managedIdentityName = 'id-bitlocker-groupsync'
param appTenantId = ''
param appClientId = ''
param certificateAssetName = 'NimbusGraphAuth'
param graphCredentialVariableName = 'NimbusGraphClientSecret'
param appClientSecret = ''
```

I parametri relativi all'App Registration restano vuoti o mantengono i nomi
predefiniti perché non vengono utilizzati.

Deployment iniziale:

```powershell
.\deploy.ps1 -ResourceGroupName 'RG-ENCRYPTED_DEVICES' -Location 'italynorth' -ParameterFile .\bicep\customer.local.bicepparam
```

Dopo aver assegnato le permission Graph alla UAMI, attivare il runtime:

```powershell
.\deploy.ps1 -ResourceGroupName 'RG-ENCRYPTED_DEVICES' -Location 'italynorth' -ParameterFile .\bicep\customer.local.bicepparam -SkipBootstrap -PermissionsConfirmed -StartJobNow
```

## App Registration con certificato

Questa modalità usa un certificato caricato nell'App Registration e un
Automation Certificate contenente il PFX con la chiave privata.

Configurare:

```bicep
param authenticationMode = 'AppRegistrationCertificate'
param managedIdentityName = 'id-bitlocker-groupsync'
param appTenantId = '<TENANT-ID>'
param appClientId = '<APPLICATION-CLIENT-ID>'
param certificateAssetName = 'NimbusGraphAuth'
param graphCredentialVariableName = 'NimbusGraphClientSecret'
param appClientSecret = ''
```

Dove:

- `appTenantId` è il Directory (tenant) ID;
- `appClientId` è l'Application (client) ID dell'App Registration;
- `certificateAssetName` è il nome dell'Automation Certificate usato dal
  runbook.

Nell'App Registration caricare la parte pubblica del certificato (`.cer`).
Durante il deployment fornire il PFX contenente la chiave privata e la relativa
password:

```powershell
$pfxPassword = Read-Host 'Password PFX' -AsSecureString

.\deploy.ps1 `
    -ResourceGroupName 'RG-ENCRYPTED_DEVICES' `
    -Location 'italynorth' `
    -ParameterFile .\bicep\customer.local.bicepparam `
    -AppCertificatePfxPath 'C:\Secure\NimbusGraphAuth.pfx' `
    -AppCertificatePfxPassword $pfxPassword `
    -PermissionsConfirmed `
    -StartJobNow
```

Il runbook recupera il certificato tramite `certificateAssetName`: non è
necessario inserire il thumbprint nel file `.bicepparam`.

Nei deployment successivi il certificato esistente viene riutilizzato. I
parametri `-AppCertificatePfxPath` e `-AppCertificatePfxPassword` servono
nuovamente soltanto per sostituire o ruotare il certificato.

## App Registration con client secret

Questa modalità salva il secret in una Automation Variable cifrata. Il valore
non deve essere scritto nel file `.bicepparam`.

Configurare:

```bicep
param authenticationMode = 'AppRegistrationSecret'
param managedIdentityName = 'id-bitlocker-groupsync'
param appTenantId = '<TENANT-ID>'
param appClientId = '<APPLICATION-CLIENT-ID>'
param certificateAssetName = 'NimbusGraphAuth'
param graphCredentialVariableName = 'NimbusGraphClientSecret'
param appClientSecret = ''
```

Dove:

- `appTenantId` è il Directory (tenant) ID;
- `appClientId` è l'Application (client) ID dell'App Registration;
- `graphCredentialVariableName` è il nome della Automation Variable cifrata
  letta dal runbook;
- `appClientSecret` deve rimanere vuoto nel file versionato.

Fornire il secret come `SecureString` durante il primo deployment:

```powershell
$appSecret = Read-Host 'Client secret' -AsSecureString

.\deploy.ps1 `
    -ResourceGroupName 'RG-ENCRYPTED_DEVICES' `
    -Location 'italynorth' `
    -ParameterFile .\bicep\customer.local.bicepparam `
    -AppClientSecret $appSecret `
    -PermissionsConfirmed `
    -StartJobNow
```

Nei deployment successivi la Automation Variable esistente viene riutilizzata.
Ripetere il comando con `-AppClientSecret` quando il secret viene ruotato.

## Cambio del metodo di autenticazione

Per cambiare modalità:

1. Configurare e autorizzare il nuovo principal in Microsoft Entra.
2. Modificare `authenticationMode` e i relativi parametri nel file
   `.bicepparam`.
3. Eseguire `deploy.ps1` con la nuova credenziale, se richiesta.
4. Avviare un job e verificarne il completamento.
5. Solo dopo la verifica, revocare le permission e rimuovere la credenziale
   precedente.

Il deployment incrementale non revoca automaticamente le permission Graph
della vecchia UAMI o dell'App Registration.

## Errori da evitare

- Non usare permission Graph di tipo **Delegated**: il runbook richiede
  **Application permissions**.
- Non inserire il client secret in `appClientSecret` nel file versionato.
- Non caricare soltanto il `.cer` nell'Automation Account: il runbook necessita
  del PFX con chiave privata.
- Non inserire il thumbprint al posto di `certificateAssetName`.
- Non impostare `-PermissionsConfirmed` finché le permission Graph non sono
  state assegnate e approvate.
