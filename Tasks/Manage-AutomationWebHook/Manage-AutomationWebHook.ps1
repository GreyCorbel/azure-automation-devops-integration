#load VstsTaskSdk module
Write-Host "Installing dependencies..."
Install-Module -Name VstsTaskSdk -Force -Scope CurrentUser -AllowClobber

#load AadAuthentiacationFactory
Install-Module AadAuthenticationFactory -Force -Scope CurrentUser
Write-Host "Installation succeeded!"

#load Automation account REST wrapper
Write-Host "Importing internal PS modules..."
$parentDirectory = Split-Path -Path $PSScriptRoot -Parent
$grandparentDirectory = Split-Path -Path $parentDirectory -Parent
$modulePath = [System.IO.Path]::Combine($grandparentDirectory,'Module','AutomationAccount')
Import-Module $modulePath -Force
#load runtime support
$modulePath = [System.IO.Path]::Combine($grandparentDirectory, 'Module', 'AutoRuntime')
Import-Module $modulePath -Force
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

Write-Host "Starting process..."
# retrieve service connection object
$serviceConnection = Get-VstsEndpoint -Name $azureSubscription -Require

# get service connection object properties
$servicePrincipalId = $serviceConnection.auth.parameters.serviceprincipalid
$servicePrincipalkey = $serviceConnection.auth.parameters.serviceprincipalkey
$tenantId = $serviceConnection.auth.parameters.tenantid

#initialize aadAuthenticationFactory
Write-Verbose "Initialize AadAuthenticationFactory object..."
Initialize-AadAuthenticationFactory -servicePrincipalId $servicePrincipalId -servicePrincipalKey $servicePrincipalkey -tenantId $tenantId

#initialize runtime according to environment environment
Init-Environment -ProjectDir $ProjectDir -Environment $EnvironmentName

#this requires to be connected to be logged in to Azure. Azure POwershell task does it automatically for you
#if running outside of this task, you may need to call Connect-AzAccount manually
Connect-AutoAutomationAccount -Subscription $subscription -ResourceGroup $ResourceGroup -AutomationAccount $AutomationAccount

$base = new-object DateTime(1970,1,1)
$base = [DateTime]::SpecifyKind($base, 'Utc')
[int32]$ts = ([DateTime]::UtcNow - $base).TotalSeconds

$existingWebhooks = Get-AutoObject -objectType Webhooks
$existingRunbooks = Get-AutoObject -objectType Runbooks

$managedWebhooks = @()
$definitions = @(Get-DefinitionFiles -FileType WebHooks)
foreach($def in $definitions)
{
    $existingWebhook = $existingWebhooks | Where-Object{$_.properties.runbook.name -eq $def.RunbookName}
    $needsNewWebhook = $true
    foreach($wh in $existingWebhook)
    {
        $ValidityOverlap = [Timespan]::Parse($def.Overlap)
        if($wh.properties.expiryTime - $ValidityOverlap -gt [DateTime]::Now)
        {
            $needsNewWebhook = $false
            $managedWebhooks+=$wh
            continue
        }
        if($wh.properties.expiryTime -gt [DateTime]::Now)
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

        $Expires = [DateTime]::UtcNow + [Timespan]::Parse($def.Expiration)
        $webhook = Add-AutoWebhook `
            -Name "$($def.NamePrefix)-$ts" `
            -RunbookName $def.RunbookName `
            -RunOn $(if($def.runOn -eq 'Azure' -or [string]::IsnullOrEmpty($def.runOn)) {''} else {$def.runOn}) `
            -ExpiresOn $Expires `
            -Parameters $def.Parameters
        $managedWebhooks+=$webhook
        $webhook
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