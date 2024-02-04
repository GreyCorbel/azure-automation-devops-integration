Param
(
    [Parameter(Mandatory)]
    [string]
    #Name of the stage/environment we're deploying
    $EnvironmentName,
    [Parameter(Mandatory)]
    [string]
    #root folder of automation account content
    $ProjectDir,
    [Parameter(Mandatory)]
    [string]
    #name of the subscription where automation account is located
    $Subscription,
    [Parameter(Mandatory)]
    [string]
    #name of the resource group where automation account is located
    $ResourceGroup,
    [Parameter(Mandatory)]
    [string]
    #name of automation account that we deploy to
    $AutomationAccount,
    [Parameter()]
    [Switch]
    #whether or not to remove any existing webhooks not covered by definitions
    $FullSync
)

#load Automation account REST wrapper
$modulePath = [System.IO.Path]::Combine($PSScriptRoot,'Module','AutomationAccount')
Import-Module $modulePath -Force
#load runtime support
$modulePath = [System.IO.Path]::Combine($PSScriptRoot, 'Module', 'AutoRuntime')
Import-Module $modulePath -Force

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
        "Checking runbook existence: $($def.runbookName)"
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
