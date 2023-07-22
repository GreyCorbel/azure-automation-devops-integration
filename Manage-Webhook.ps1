Param
(
    [Parameter(Mandatory)]
    [ValidateSet('Webhooks')]
    [string[]]
        #What we are deploying
        $Scope,
    [Parameter(Mandatory)]
    [string]
        #Name of the stage/environment we're deploying
        $EnvironmentName,
    [Parameter(Mandatory)]
    [string]
        #root folder of repository
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
    [string]
        #name of hybrid worker group to use when scheduling runbook or creating webhook and job execution needs to be on hybrid worker
        $HybridWorkerGroup,
    [Parameter(Mandatory)]
    [string]
        #name of automation account that we deploy to
        $KeyVaultName,
    [Parameter(Mandatory)]
    [string]
        #name of automation account that we deploy to
        $EventGridTopicName
)

Import-Module Az.Automation
Import-Module Az.Resources
Import-Module Az.KeyVault
Import-Module Az.EventGrid

. "$projectDir\..\Runtime.ps1" -ProjectDir $ProjectDir -Environment $EnvironmentName

#region Connect subscription

"Setting active subscription to $Subscription"
Select-AzSubscription -Subscription $Subscription

#endregion

#region webhooks

if(Check-Scope -Scope $scope -RequiredScope 'Webhooks')
{
    "Checking and updating Webhooks"
    $definitions = @(Get-DefinitionFiles -FileType Runbooks)
    $currentRunbooks = Get-AzAutomationRunbook -AutomationAccountName $AutomationAccount -ResourceGroupName $ResourceGroup
    foreach($def in $definitions) {
        if ($def.Name -notin $currentRunbooks.Name) {
            write-warning "Runbook $($def.Name) not deployed yet -> skipping"
            continue;
        }
        if(-not $def.TriggeredByWebHook)
        {
            write-host "Runbook $($def.Name) not triggered by webhook -> skipping"
            continue;
        }
        $deployedRunbook = $currentRunbooks | Where-Object{$_.Name -eq $def.Name}
        if($deployedRunbook.State -eq 'New')
        {
            write-warning "Runbook $($def.Name) not published yet -> skipping"
            continue;
        }
        #get list of webhooks for a runbook
        $webhooks = Get-AzAutomationWebhook `
            -ResourceGroupName $ResourceGroup `
            -AutomationAccountName $AutomationAccount `
            -RunbookName $def.Name `
            -ErrorAction Stop

        $newWebHookNeeded=$false
        foreach ($wh in $webhooks)
        {
            if ($wh.ExpiryTime.DateTime -lt [DateTime]::Now)
            {
                Remove-AzAutomationWebhook `
                    -ResourceGroupName $ResourceGroup `
                    -AutomationAccountName $AutomationAccount `
                    -Name $wh.Name `
                    -ErrorAction Stop

                write-host "Removed expired webhook $($wh.Name) with expiration date $($wh.ExpiryTime.DateTime)"
            }
            if ($wh.ExpiryTime.DateTime.AddDays(-7) -lt [DateTime]::Now -and (-not $newWebHookNeeded))
            {
                $newWebHookNeeded=$true
            }
        }

        if ($webhooks.Count -eq 0) { $newWebHookNeeded=$true }
        if (-not $newWebHookNeeded)
        {
            Write-Host "Webhook for runbook $($def.Name) is up-to-date"
            continue;
        }

        switch($def.RunsOn)
        {
            'Azure' {
                #runs on Azure
                $wh = New-AzAutomationWebhook `
                    -ResourceGroupName $ResourceGroup `
                    -AutomationAccountName $AutomationAccount `
                    -Name "$($def.Name)-$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss'))" `
                    -RunbookName $def.Name `
                    -IsEnabled $true `
                    -ExpiryTime ([DateTime]::UtcNow.AddDays(365)) `
                    -Force `
                    -ErrorAction Stop
                break;
            }
            'HybridWorker' {
                #runs on hybrid worker group
                $wh = New-AzAutomationWebhook `
                    -ResourceGroupName $ResourceGroup `
                    -AutomationAccountName $AutomationAccount `
                    -Name "$($def.Name)-$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss'))" `
                    -RunbookName $def.Name `
                    -IsEnabled $true `
                    -ExpiryTime ([DateTime]::UtcNow.AddDays(365)) `
                    -RunOn $HybridWorkerGroup `
                    -Force `
                    -ErrorAction Stop
                break;
            }
            default {
                #just to be sure - no webhook - we have RunsOn = null for utility runbooks
                $wh = $null
                break;
            }
        }
        if($null -eq $wh) {continue}
        write-host "Webhook created for runbook $($def.Name) to run on $($def.RunsOn)"
        # store webhook to keyvault
        # ensure the identity the script is using has keyvault rbac role assigned
        $updatedSecret = Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $def.Name -SecretValue ($wh.WebhookURI | ConvertTo-SecureString -AsPlainText -Force) -ErrorAction Stop
        write-host "Secret updated: $($updatedSecret.id)"
        
        
        # create/update event subscription
        if ($def.SupportedRequestTypes.length -gt 0) {
            $eventSubscription = Get-AzEventGridSubscription `
                -ResourceGroupName $ResourceGroup `
                -TopicName $EventGridTopicName `
                -EventSubscriptionName $def.Name `
                -ErrorAction SilentlyContinue
            
            if($null -eq $eventSubscription)
            {
                $eventSubscription = New-AzEventGridSubscription `
                    -ResourceGroupName $ResourceGroup `
                    -TopicName $EventGridTopicName `
                    -EventSubscriptionName $def.Name `
                    -Endpoint $wh.WebhookURI `
                    -EndpointType 'webhook' `
                    -IncludedEventType $def.SupportedRequestTypes `
                    -ErrorAction Stop
                write-host "Routing created: $($eventSubscription.EventSubscriptionName)"
            }
            else
            {
                $eventSubscription = $eventSubscription | Update-AzEventGridSubscription `
                    -Endpoint $wh.WebhookURI `
                    -IncludedEventType $def.SupportedRequestTypes `
                    -ErrorAction Stop
                write-host "Routing updated: $($eventSubscription.EventSubscriptionName)"
            }
        }
        else 
        {
            Write-Warning "Event routing for runbook $($def.Name) requested, but no request types to route defined."
        }
    }
}
#endregion webhooks
