#load VstsTaskSdk module
Write-Host "Installing dependencies..."
if($null -eq (Get-Module -Name VstsTaskSdk -ListAvailable))
{
    Write-Host "VstsTaskSdk module not found, installing..."
    Install-Module -Name VstsTaskSdk -Force -Scope CurrentUser -AllowClobber
}

#load AadAuthentiacationFactory
if($null -eq (Get-Module -Name AadAuthenticationFactory -ListAvailable))
{
    Write-Host "AadAuthenticationFactory module not found, installing..."
    Install-Module -Name AadAuthenticationFactory -Force -Scope CurrentUser
}
Write-Host "Installation succeeded!"

#load Automation account REST wrapper
Write-Host "Importing internal PS modules..."
#$parentDirectory = Split-Path -Path $PSScriptRoot -Parent
#$grandparentDirectory = Split-Path -Path $parentDirectory -Parent
$modulePath = [System.IO.Path]::Combine($PSScriptRoot,'Module','AutomationAccount')
Write-Host "module path: $modulePath"
Import-Module $modulePath -Force
#load runtime support
$modulePath = [System.IO.Path]::Combine($PSScriptRoot, 'Module', 'AutoRuntime')
Write-Host "module path: $modulePath"
Import-Module $modulePath -Force -WarningAction SilentlyContinue
Write-Host "Import succeeded!"

#read pipeline variables
Write-Host "Reading pipeline variables... (Using vstsTaskSdk)"
$environmentName = Get-VstsInput -Name 'environmentName' -Require
$projectDir = Get-VstsInput -Name 'projectDir' -Require
$subscription = Get-VstsInput -Name 'subscription' -Require
$azureSubscription = Get-VstsInput -Name 'azureSubscription' -Require
$resourceGroup = Get-VstsInput -Name 'resourceGroup' -Require
$automationAccount = Get-VstsInput -Name 'automationAccount' -Require
$fullSync = Get-VstsInput -Name 'fullSync'
Write-Host "Loading finished!"

Write-Host "Starting processing"
# retrieve service connection object
$serviceConnection = Get-VstsEndpoint -Name $azureSubscription -Require

#initialize aadAuthenticationFactory
Write-Verbose "Initialize AadAuthenticationFactory object..."
switch ($serviceConnection.auth.scheme) {
    'ServicePrincipal' { 
        # get service connection object properties
        $servicePrincipalId = $serviceConnection.auth.parameters.serviceprincipalid
        $servicePrincipalkey = $serviceConnection.auth.parameters.serviceprincipalkey
        $tenantId = $serviceConnection.auth.parameters.tenantid

        # SPNcertificate
        if ($serviceConnection.auth.parameters.authenticationType -eq 'SPNCertificate') {
            Write-Host "ServicePrincipal with Certificate auth"

            $certData = $serviceConnection.Auth.parameters.servicePrincipalCertificate
            $cert= [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem($certData,$certData)

            Initialize-AadAuthenticationFactory `
            -servicePrincipalId $servicePrincipalId `
            -servicePrincipalKey $servicePrincipalkey `
            -tenantId $tenantId `
            -cert $cert
        }
        #Service Principal
        else {
            Write-Host "ServicePrincipal with ClientSecret auth"

            Initialize-AadAuthenticationFactory `
            -servicePrincipalId $servicePrincipalId `
            -servicePrincipalKey $servicePrincipalkey `
            -tenantId $tenantId
        }
        break;
     }

     'ManagedServiceIdentity' {
        Write-Host "ManagedIdentitx auth"

        Initialize-AadAuthenticationFactory `
            -serviceConnection $serviceConnection
        break;
     }

     'WorkloadIdentityFederation' {
        Write-Host "Workload identity auth"

        # get service connection properties
        $planId = Get-VstsTaskVariable -Name 'System.PlanId' -Require
        $jobId = Get-VstsTaskVariable -Name 'System.JobId' -Require
        $hub = Get-VstsTaskVariable -Name 'System.HostType' -Require
        $projectId = Get-VstsTaskVariable -Name 'System.TeamProjectId' -Require
        $uri = Get-VstsTaskVariable -Name 'System.CollectionUri' -Require
        $serviceConnectionId = $azureSubscription

        Write-Verbose "Getting access token for service connection"
        $vstsEndpoint = Get-VstsEndpoint -Name SystemVssConnection -Require
        $vstsAccessToken = $vstsEndpoint.auth.parameters.AccessToken
        
        $url = "$uri/$projectId/_apis/distributedtask/hubs/$hub/plans/$planId/jobs/$jobId/oidctoken?serviceConnectionId=$serviceConnectionId`&api-version=7.2-preview.1"

        $username = "username"
        $password = $vstsAccessToken
        $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $username, $password)))

        Write-Verbose "Getting OIDC token from VSTS on uri: $url"
        $response = Invoke-RestMethod -Uri $url -Method Post -Headers @{ "Authorization" = ("Basic {0}" -f $base64AuthInfo) } -ContentType "application/json"
        
        $assertion = $response.oidcToken
        
        $servicePrincipalId = $serviceConnection.auth.parameters.serviceprincipalid
        $tenantId = $serviceConnection.auth.parameters.tenantid
        Write-verbose "Initializing AAD factory with clientId $servicePrincipalId for tenant $tenantId"
        Initialize-AadAuthenticationFactory `
            -servicePrincipalId $servicePrincipalId `
            -assertion $assertion `
            -tenantId $tenantId
        break;
     }
}

#initialize runtime according to environment environment
Init-Environment -ProjectDir $ProjectDir -Environment $EnvironmentName

#this requires to be connected to be logged in to Azure. Azure POwershell task does it automatically for you
#if running outside of this task, you may need to call Connect-AzAccount manually
Connect-AutoAutomationAccount -Subscription $subscription -ResourceGroup $ResourceGroup -AutomationAccount $AutomationAccount

$base = new-object DateTime(1970,1,1)
$base = [DateTime]::SpecifyKind($base, 'Utc')
[int32]$ts = ([DateTime]::UtcNow - $base).TotalSeconds

$existingWebhooks = Get-AutoObject -objectType Webhooks
Write-Host "Existing webhooks: $($existingWebhooks.Count)"
$existingRunbooks = Get-AutoObject -objectType Runbooks
write-host "Existing runbooks: $($existingRunbooks.Count)"

$managedWebhooks = @()
$newWebhooks = @()

$definitions = @(Get-DefinitionFiles -FileType WebHooks)
foreach($def in $definitions)
{
    Write-Host "Processing webhook for runbook: $($def.RunbookName)"
    $existingWebhook = $existingWebhooks | Where-Object{$_.properties.runbook.name -eq $def.RunbookName}
    $needsNewWebhook = $true
    foreach($wh in $existingWebhook)
    {
        $ValidityOverlap = [Timespan]::Parse($def.Overlap)
        if($wh.properties.expiryTime -is [string])
        {
            $expiration = [DateTime]::Parse($wh.properties.expiryTime)
        }
        else
        {
            $expiration = $wh.properties.expiryTime
        }
        if(($expiration - $ValidityOverlap) -gt [DateTime]::Now)
        {
            $needsNewWebhook = $false
            $managedWebhooks+=$wh
            continue
        }
        if($expiration -gt [DateTime]::Now)
        {
            #about to expire, but not expired yet
            $managedWebhooks+=$wh
            continue
        }
        #expired
        Write-Host "Removing expired webhook $($wh.Name)"
        Remove-AutoObject -Name $wh.Name -objectType Webhooks | Out-Null
    }
    if($needsNewWebhook)
    {
        Write-Host "Checking runbook existence: $($def.runbookName)"
        if(-not ($existingRunbooks.Name -contains $def.runbookName))
        {
            Write-Warning "Runbook $($def.runbookName) does not exist --> skipping webhook"
            continue
        }
        $runOn = ''
        $params = @{}

        if(-not [string]::IsNullOrEmpty($def.Settings))
        {
            $settingsFile = Get-FileToProcess -FileType Webhooks -FileName $def.Settings
            if([string]::IsnullOrEmpty($settingsFile))
            {
                write-warning "Missing setting file $($def.Settings) --> skipping"
                continue
            }
            Write-Host "Settings file found: $settingsFile"
            $setting = get-content $settingsFile | ConvertFrom-Json

            if($setting.Parameters -is [Hashtable]) {
                $params = $setting.Parameters
            } else {
                Write-Host "Converting parameters to Hashtable..."
                $params = @{}
                foreach($param in $setting.Parameters.PSObject.Properties) {
                    $params[$param.Name] = $param.Value
                }
            }

            if((-not [string]::IsNullOrEmpty($setting.RunOn) -and ($setting.RunOn -ne 'Azure'))) {$runOn = $setting.RunOn}
        }

        $Expires = [DateTime]::UtcNow + [Timespan]::Parse($def.Expiration)
        $SupportedRequestTypes = $def.SupportedRequestTypes
        $webhookName = "$($def.NamePrefix)-$ts"
        Write-Host "Adding new webhook for runbook $($def.RunbookName) with name $webhookName"
        $webhook = Add-AutoWebhook `
            -Name "$($def.NamePrefix)-$ts" `
            -RunbookName $def.RunbookName `
            -RunOn $runOn `
            -ExpiresOn $Expires `
            -Parameters $params
        
        $webhook | Add-Member -MemberType NoteProperty -Name SupportedRequestTypes -Value $SupportedRequestTypes
        $managedWebhooks+=$webhook
        $newWebhooks += $webhook
        continue; 
    }
}

if($FullSync)
{
    $existingWebhooks = Get-AutoObject -objectType Webhooks

    foreach($wh in $existingWebhooks)
    {
        if($wh.Name -notin $managedWebhooks.Name)
        {
            Write-Host "Removing unmanaged webhook $($wh.Name)"
            Remove-AutoObject -Name $wh.Name -objectType Webhooks | Out-Null
        }
    }
}

#store webhooks to folder for future reference by subsequent task
$newWebhooksfolder = "$($env:SYSTEM_DEFAULTWORKINGDIRECTORY)/WebHooks-new"
$managedWebhooksfolder = "$($env:SYSTEM_DEFAULTWORKINGDIRECTORY)/WebHooks-managed"
if(-not (Test-Path $newWebhooksfolder)) {New-Item -ItemType Directory -Path $newWebhooksfolder | Out-Null}
if(-not (Test-Path $managedWebhooksfolder)) {New-Item -ItemType Directory -Path $managedWebhooksfolder | Out-Null}
foreach($webhook in $newWebhooks)
{
    $webhook | ConvertTo-Json -Depth 9 | Set-Content "$newWebhooksfolder/$($webhook.Name).json" -Encoding UTF8
}
foreach($webhook in $managedWebhooks)
{
    $webhook | ConvertTo-Json -Depth 9 | Set-Content "$managedWebhooksfolder/$($webhook.Name).json" -Encoding UTF8
}
Write-Host "Processing finished!"