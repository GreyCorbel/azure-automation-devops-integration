Write-Host "Initialize script"

# Import VSTSTaskSdk
# $modulePath = Join-Path $PSScriptRoot "ps_modules\VstsTaskSdk\VstsTaskSdk.psd1"
# Import-Module $modulePath

# Install VstsTaskSdk module
Write-Host "VstsTaskSD installing..."
Install-Module -Name VstsTaskSdk -Force -Scope CurrentUser -AllowClobber

# Load variables
Write-Host "Reading variables..."
$subscriptionValue = Get-VstsInput -Name 'subscription' -Require
$azureSubscriptionValue = Get-VstsInput -Name 'azureSubscription' -Require

Write-Host "Subscription value: $subscriptionValue"
Write-Host "Azure Subscription value: $azureSubscriptionValue"

# Získání názvu služebního připojení
$azureSubscription = Get-VstsInput -Name 'azureSubscription' -Require

# Výpis názvu služebního připojení pro diagnostiku
Write-Host "Azure Subscription: $azureSubscription"

# Získání objektu služebního připojení
$serviceConnection = Get-VstsEndpoint -Name $azureSubscription -Require
Write-Host "Service connection: $serviceConnection"
Write-Host "Service connection auth: " + $serviceConnection.auth
Write-Host "Service connection auth param: " + $serviceConnection.auth.parameters

# Převod objektu na JSON s hloubkou 9
$jsonRepresentation = $serviceConnection | ConvertTo-Json -Depth 9

# Vypsání JSON reprezentace do konzole
Write-Host "JSON Representation:"
Write-Host $jsonRepresentation

# Získání access tokenu
$servicePrincipalId = $serviceConnection.auth.parameters.serviceprincipalid
$servicePrincipalkey = $serviceConnection.auth.parameters.serviceprincipalkey
$tenantId = $serviceConnection.auth.parameters.tenantid

# Získání aktuálního pracovního adresáře
$currentDirectory = Get-Location
Write-Host "lokace douboru: " + $currentDirectory

# Vytvoření souboru s přístupovým tokenem v aktuálním adresáři
$servicePrincipalId | Out-File (Join-Path $currentDirectory "servicePrincipalId.txt")
Write-Host "SPid written to file."

# Vypsání obsahu souboru do konzole
$servicePrincipalIdContent = Get-Content (Join-Path $currentDirectory "servicePrincipalId.txt")
Write-Host "A Content: $servicePrincipalIdContent"

# Vytvoření souboru s přístupovým tokenem v aktuálním adresáři
$servicePrincipalkey | Out-File (Join-Path $currentDirectory "servicePrincipalkey.txt")
Write-Host "SPkey written to file."

# Vypsání obsahu souboru do konzole
$servicePrincipalkeyContent = Get-Content (Join-Path $currentDirectory "servicePrincipalkey.txt")
Write-Host "B Content: $servicePrincipalkeyContent"


Write-Host "Instaluji module aadAuthFactory..."
Install-Module AadAuthenticationFactory -Force -Scope CurrentUser

$appId = $servicePrincipalId
$secret = $servicePrincipalkey
#create authnetication factory and cache it inside module
New-AadAuthenticationFactory -TenantId $tenantId -ClientId $appId -ClientSecret $secret | Out-Null

#ask for token
$Token = Get-AadToken -Scopes 'https://management.azure.com/.default'

#examine access token data
$tokenData = $Token.AccessToken | Test-AadToken | Select -Expand Payload
Write-Host "token data:" + $tokenData
$tokenDataToJson = $tokenData | ConvertTo-Json -Depth 9
Write-Host "token data as json:" + $tokenDataToJson






Save-Module –Name VstsTaskSdk –Path .\ps_modules -Force
$sourcePath = Get-Location
$directoryWithFiles = Get-ChildItem -Path $sourcePath -Directory | Where-Object { (Get-ChildItem $_.FullName -File).Count -gt 0 } | Select-Object -First 1

# Pokud byl nalezen podadresář s obsahem
if ($directoryWithFiles) {
    # Kopíruj soubory z podadresáře zpět do původního adresáře
    Copy-Item -Path "$($directoryWithFiles.FullName)\*" -Destination $sourcePath -Recurse -Force

    Write-Host "Obsah podadresáře byl zkopírován do původního adresáře ($sourcePath)."

    # Smaž původní podadresář včetně obsahu
    Remove-Item -Path $directoryWithFiles.FullName -Recurse -Force

    Write-Host "Původní podadresář byl smazán."
} else {
    Write-Host "Nebyly nalezeny žádné podadresáře s obsahem."
}