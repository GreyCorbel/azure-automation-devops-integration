function Initialize-AadAuthenticationFactory 
{
    [CmdletBinding()]
    param
    (
        [Parameter(ParameterSetName = 'ServicePrincipal')]
        [string]$servicePrincipalKey,
        [Parameter(ParameterSetName = 'ServicePrincipal')]
        [string]$cert,
        [Parameter(ParameterSetName = 'ServicePrincipal')]
        [Parameter(ParameterSetName = 'WorkloadIdentityFederation')]
        [string]$servicePrincipalId,
        [Parameter(ParameterSetName = 'WorkloadIdentityFederation')]
        [string]$Assertion,
        [Parameter(ParameterSetName = 'ManagedServiceIdentity')]
        [string]$ServiceConnection,
        [Parameter()]
        [string]$tenantId
    )
    process
    {
        #create authnetication factory and store it into the script variable
        switch($PSCmdlet.ParameterSetName)
        {
            'ServicePrincipal' {
                if ($cert) {
                    $script:aadAuthenticationFactory = New-AadAuthenticationFactory `
                    -TenantId $tenantId `
                    -ClientId $servicePrincipalId `
                    -X509Certificate $cert
                }
                else {
                    $script:aadAuthenticationFactory = New-AadAuthenticationFactory `
                    -TenantId $tenantId `
                    -ClientId $servicePrincipalId `
                    -ClientSecret $servicePrincipalKey
                }
            }
            'ManagedServiceIdentity' {
                $msiClientId = $serviceConnection.Data.msiClientId
                if ($msiClientId) {
                    $script:aadAuthenticationFactory = New-AadAuthenticationFactory `
                    -ClientId $msiClientId `
                    -UseManagedIdentity
                }
                else {
                    $script:aadAuthenticationFactory = New-AadAuthenticationFactory `
                    -UseManagedIdentity
                }
            }
            'WorkloadIdentityFederation' {
                $script:aadAuthenticationFactory = New-AadAuthenticationFactory `
                    -TenantId $tenantId `
                    -ClientId $servicePrincipalId `
                    -Assertion $assertion
            }
        }
    }
}

function Get-AutoAccessToken
{
    param
    (
        [string]$ResourceUri = "https://management.azure.com/.default",
        [switch]$AsHashTable
    )

    process
    {
        if ($null -eq $script:aadAuthenticationFactory)
		{
			throw ('Call Initialize-AadAuthenticationFactory first')
		}
		Get-AadToken -Factory $script:aadAuthenticationFactory -Scopes $ResourceUri -AsHashTable:$AsHashTable
    }
}

function Get-AutoSubscription
{
    param
    (
        [Parameter(Mandatory)]
        [string]$Subscription
    )

    begin
    {
        $headers = Get-AutoAccessToken -AsHashTable
        $pageUri = "https://management.azure.com/subscriptions`?api-version=2019-06-01"
    }
    process
    {
        $canContinue = $true
        do
        {
            write-verbose "Fetching results from $pageUri"
            $rslt = Invoke-RestMethod `
                -Uri $pageUri `
                -Headers $headers `
                -ErrorAction Stop
            foreach($v in $rslt.value) {
                if($v.subscriptionId -eq $Subscription -or $v.displayName -eq $Subscription)
                {
                    $v
                    $canContinue = $false
                    break
                }
            }
            if(-not $canContinue) {break}
            $pageUri = $rslt.nextLink
        }until($null-eq $pageUri)
    }
}

function Connect-AutoAutomationAccount
{
    param
    (
        [Parameter(Mandatory)]
        [string]$Subscription,
        [Parameter(Mandatory)]
        [string]$ResourceGroup,
        [Parameter(Mandatory)]
        [string]$AutomationAccount
    )

    process
    {
        $subscriptionObject = Get-AutoSubscription -Subscription $Subscription
        if($null -eq $subscriptionObject)
        {
            throw "Subscription $Subscription no found"
        }
        write-verbose "Connected to subscription $Subscription"
        $script:AutomationAccountResourceId = "$($subscriptionObject.id)/resourceGroups/$ResourceGroup/providers/Microsoft.Automation/automationAccounts/$AutomationAccount"

        $headers = Get-AutoAccessToken -AsHashTable
        $uri = "https://management.azure.com$($script:AutomationAccountResourceId)`?api-version=2023-11-01"
        $rslt = Invoke-RestMethod `
            -Uri $uri `
            -Headers $headers `
            -ErrorAction Stop
        $script:accountLocation = $rslt.location
        write-verbose "Automation account validated; location: $($script:accountLocation)"
    }
}

#region Get/Remove
function Get-AutoPowershell7Module
<#
    This is one-off for PS7.2
    We do not support PS7.1
#>
{
    param
    (
        [Parameter()]
        [string]$Name,
        [Parameter()]
        [string]$AutomationAccountResourceId = $script:AutomationAccountResourceId
    )

    begin
    {
        $headers = Get-AutoAccessToken -AsHashTable
        $uri = "https://management.azure.com$AutomationAccountResourceId/powershell72Modules"
        if(-not [string]::IsnullOrEmpty($Name))
        {
            $uri = "$uri/$Name"
        }
        $uri = "$uri`?api-version=2023-11-01"

    }
    process
    {
        $pageUri = $uri
        do
        {
            write-verbose "Fetching result(s) from $pageUri"
            $rslt = Invoke-RestMethod `
                -Uri $pageUri `
                -Headers $headers `
                -ErrorAction Stop
            if($null -ne $rslt.value)
            {
                foreach($v in $rslt.value) {$v}
                $pageUri = $rslt.nextLink
            }
            else
            {
                $rslt
                $pageUri = $null
            }
        }until($null-eq $pageUri)
    }
}

function Get-AutoObject
{
    param
    (
        [Parameter(Mandatory)]
        [ValidateSet('Variables','Runbooks','Schedules','Configurations','Compilationjobs','Modules','Webhooks','JobSchedules')]
        [string]$objectType,
        [Parameter()]
        [string]$Name,
        [Parameter()]
        [string]$AutomationAccountResourceId = $script:AutomationAccountResourceId
    )

    begin
    {
        $headers = Get-AutoAccessToken -AsHashTable
        $uri = "https://management.azure.com$AutomationAccountResourceId/$objectType"
        if(-not [string]::IsnullOrEmpty($Name))
        {
            $uri = "$uri/$Name"
        }
    }
    process
    {
        if($objectType -ne 'Webhooks')
        {
            $uri = "$uri`?api-version=2023-11-01"
        }
        else {
            #webhooks not available in 2023-11-01 (yet?)
            $uri = "$uri`?api-version=2018-06-30"
        }

        $pageUri = $uri
        do
        {
            write-verbose "Fetching object(s) from $pageUri"
            $rslt = Invoke-RestMethod `
                -Uri $pageUri `
                -Headers $headers `
                -ErrorAction Stop
            if($null -ne $rslt.value)
            {
                foreach($v in $rslt.value) {$v}
                $pageUri = $rslt.nextLink
            }
            else
            {
                $rslt
                $pageUri=$null
            }
        }until($null -eq $pageUri)
    }
}

Function Remove-AutoObject
{
    param
    (
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [ValidateSet('Variables','Runbooks','Schedules','Configurations','Modules','Webhooks','JobSchedules','Powershell72Modules')]
        [string]$objectType,
        [Parameter()]
        [string]$AutomationAccountResourceId = $script:AutomationAccountResourceId
    )

    begin
    {
        $headers = Get-AutoAccessToken -AsHashTable
        $uri = "https://management.azure.com$AutomationAccountResourceId/$objectType/$Name"
    }
    process
    {
        if($objectType -ne 'Webhooks')
        {
            $uri = "$uri`?api-version=2023-11-01"
        }
        else {
            #webhooks not available in 2023-11-01 (yet?)
            $uri = "$uri`?api-version=2018-06-30"
        }

        write-verbose "Sending DELETE to $Uri"
        Invoke-RestMethod -Method Delete `
        -Uri $Uri `
        -Headers $headers `
        -ErrorAction Stop
    }
}

Function Remove-AutoPowershell7Module
{
    param
    (
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter()]
        [string]$AutomationAccountResourceId = $script:AutomationAccountResourceId
    )

    begin
    {
        $headers = Get-AutoAccessToken -AsHashTable
        $uri = "https://management.azure.com$AutomationAccountResourceId/Powershell72Modules/$Name`?api-version=2023-11-01"
    }
    process
    {
        write-verbose "Sending DELETE to $Uri"
        Invoke-RestMethod -Method Delete `
        -Uri $Uri `
        -Headers $headers `
        -ErrorAction Stop
    }
}

#endregion

Function Add-AutoVariable
{
    param
    (
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$Content,
        [Parameter()]
        [string]$Description,
        [switch]$Encrypted,
        [Parameter()]
        [string]$AutomationAccountResourceId = $script:AutomationAccountResourceId
    )

    begin
    {
        $headers = Get-AutoAccessToken -AsHashTable
        $uri = "https://management.azure.com$AutomationAccountResourceId/variables/$Name`?api-version=2023-11-01"
    }
    process
    {
        try {
            write-verbose "Sending content to $Uri"
            $payload = @{
                name = $Name
                properties = @{
                    description = $Description
                    isEncrypted = [bool]$Encrypted
                    value = ($Content | ConvertTo-Json)
                }
            } |  ConvertTo-Json
            write-verbose $payload
    
            Invoke-RestMethod -Method Put `
                -Uri $Uri `
                -Body $payload `
                -ContentType 'application/json' `
                -Headers $headers `
                -ErrorAction Stop
    
        }
        catch {
            write-error $_
            throw;
        } 
   }
}


Function Add-AutoSchedule
{
    param
    (
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [timespan]$StartTime,
        [Parameter(Mandatory)]
        [Uint32]$Interval,
        [Parameter(Mandatory)]
        [ValidateSet('Day','Hour','Minute','Month','Week')]
        [string]$Frequency,
        [Parameter()]
        [Uint32[]]$MonthDays,
        [Parameter()]
        [ValidateSet('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')]
        [string[]]$WeekDays,
        [Parameter()]
        [string]$Description,
        [switch]$Disabled,
        [Parameter()]
        [string]$AutomationAccountResourceId = $script:AutomationAccountResourceId
    )

    begin
    {
        $headers = Get-AutoAccessToken -AsHashTable
        $uri = "https://management.azure.com$AutomationAccountResourceId/schedules/$Name`?api-version=2023-11-01"
    }
    process
    {
        try {
            write-verbose "Sending content to $Uri"
            switch($Frequency)
            {
                'Minute' {
                    $ts = [DateTime]::UtcNow
                    $start = $ts.Date + $startTime
                    while($start -lt [DateTime]::UtcNow.AddMinutes(6)) {$start = $start.AddMinutes($Interval)}

                    break;
                }
                'Hour' {
                    $ts = [DateTime]::UtcNow
                    $start = $ts.Date + $startTime
                    while($start -lt [DateTime]::UtcNow.AddMinutes(6)) {$start = $start.AddHours($Interval)}
                    
                    break;
                }
                default {
                    $start = [DateTime]::UtcNow.Date + $startTime
                    if($start -lt [DateTime]::UtcNow.AddMinutes(6)) {$start = $start.AddDays(1)}
                    break;
                }
            }
            
            
            $payload = @{
                name = $Name
                properties = @{
                    frequency = $Frequency
                    interval = $Interval
                    startTime = $start
                    description = $Description
                    advancedSchedule = @{
                        monthDays = $MonthDays
                        weekdays = $WeekDays
                    }
                    timezone = 'UTC'
                }
            }
            $payload = $payload |  ConvertTo-Json -Depth 9
            write-verbose $payload
    
            $rslt = Invoke-RestMethod -Method Put `
            -Uri $Uri `
            -Body $payload `
            -ContentType 'application/json' `
            -Headers $headers `
            -ErrorAction Stop
    
    
            write-verbose "Setting schedule Enabled status to $(-not $Disabled)"
            $payload = @{
                name = $Name
                properties = @{
                    isEnabled = (-not $Disabled)
                }
            }
            $payload = $payload |  ConvertTo-Json -Depth 9
    
            write-verbose "Sending content to $Uri"
            $rslt = Invoke-RestMethod -Method Patch `
            -Uri $Uri `
            -Body $payload `
            -ContentType 'application/json' `
            -Headers $headers `
            -ErrorAction Stop
            
            $rslt
        }
        catch {
            write-error $_
            throw;
        }
    }
}

Function Add-AutoModule
{
    param
    (
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$ContentLink,
        [Parameter()]
        [string]$Version,
        [switch]
        $WaitForCompletion,
        [Parameter()]
        [string]$AutomationAccountResourceId = $script:AutomationAccountResourceId
    )

    begin
    {
        $headers = Get-AutoAccessToken -AsHashTable
        $uri = "https://management.azure.com$AutomationAccountResourceId/modules/$Name`?api-version=2023-11-01"
    }
    process
    {
       try {
            write-verbose "Sending content to $Uri"
            $payload = @{
                properties = @{
                    contentLink = @{
                        uri = $ContentLink
                    }
                    version = $Version
                }
            } |  ConvertTo-Json
            write-verbose $payload

            $rslt = Invoke-RestMethod -Method Put `
            -Uri $Uri `
            -Body $payload `
            -ContentType 'application/json' `
            -Headers $headers `
            -ErrorAction Stop
            if($WaitForCompletion)
            {
                write-Verbose 'Waiting for importing of the module'
                Wait-AutoObjectProcessing -Name $name -objectType Modules
            }
            $rslt
       }
       catch {
            write-error $_
            throw;
       }
    }
}

Function Add-AutoPowershell7Module
{
    param
    (
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$ContentLink,
        [Parameter()]
        [string]$Version,
        [switch]
        $WaitForCompletion,
        [Parameter()]
        [string]$AutomationAccountResourceId = $script:AutomationAccountResourceId
    )

    begin
    {
        $headers = Get-AutoAccessToken -AsHashTable
        $uri = "https://management.azure.com$AutomationAccountResourceId/powershell72Modules/$Name`?api-version=2023-11-01"
    }
    process
    {
        try {
            write-verbose "Sending content to $Uri"
            $payload = @{
                properties = @{
                    contentLink = @{
                        uri = $ContentLink
                    }
                    version = $Version
                }
            } |  ConvertTo-Json
            write-verbose $payload

            $rslt = Invoke-RestMethod -Method Put `
            -Uri $Uri `
            -Body $payload `
            -ContentType 'application/json' `
            -Headers $headers `
            -ErrorAction Stop
            if($WaitForCompletion)
            {
                do
                {
                    write-Verbose 'Waiting for importing of the module'
                    Start-Sleep -Seconds 5
                    $rslt = Get-AutoPowershell7Module -Name $Name
                }while($rslt.properties.provisioningState -in @('Creating','RunningImportModuleRunbook'))
            }
            $rslt
        }
        catch {
            write-error $_
            throw;
        }
    }
}

Function Add-AutoRunbook
{
    param
    (
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [ValidateSet('Graph','GraphPowerShell','GraphPowerShellWorkflow','PowerShell','PowerShellWorkflow','Python2','Python3','Script','Powershell72')]
        [string]$Type,
        [Parameter(Mandatory)]
        [string]$Content,
        [Parameter()]
        [string]$Description,
        [switch]
        $AutoPublish,
        [switch]
        $WaitForCompletion,
        [Parameter()]
        [string]$Location,
        [Parameter()]
        [string]$AutomationAccountResourceId = $script:AutomationAccountResourceId
    )

    begin
    {
        $headers = Get-AutoAccessToken -AsHashTable
        $runbookUri = "https://management.azure.com$AutomationAccountResourceId/runbooks/$Name`?api-version=2023-11-01"
        $runbookContentUri = "https://management.azure.com$AutomationAccountResourceId/runbooks/$Name/draft/content`?api-version=2022-08-08"
        $runbookPublishUri = "https://management.azure.com$AutomationAccountResourceId/runbooks/$Name/publish`?api-version=2023-11-01"
    }
    process
    {
        try {
            if([string]::IsNullOrEmpty($location)) {$location = $script:accountLocation}
            write-verbose "Modifying runbook on $runbookUri"
            $payload = @{
                name = $Name
                location = $location
                properties = @{
                    runbookType = $Type
                    description = $Description
                }
            } |  ConvertTo-Json
            write-verbose $payload
    
            $rslt = Invoke-RestMethod -Method Put `
                -Uri $runbookUri `
                -Body $payload `
                -ContentType 'application/json' `
                -Headers $headers `
                -ErrorAction Stop
            if($rslt.properties.provisioningState -ne 'Succeeded')
            {
                return $rslt
            }
    
            write-verbose "Uploading runbook content to $runbookContentUri"
            Invoke-RestMethod -Method Put `
                -Uri $runbookContentUri `
                -Body $Content `
                -ContentType 'text/powershell' `
                -Headers $headers `
                -ErrorAction Stop | Out-Null
            if(-not $AutoPublish)
            {
                return $rslt
            }
                
            write-verbose "Publishing runbook on $runbookPublishUri"
            Invoke-RestMethod -Method Post `
                -Uri $runbookPublishUri `
                -Body '{}' `
                -ContentType 'application/json' `
                -Headers $headers `
                -ErrorAction Stop | Out-Null
    
            if($WaitForCompletion)
            {
                write-Verbose 'Waiting for publishing of the runbook'
                Wait-AutoObjectProcessing -Name $name -objectType Runbooks
            }
            $rslt
        }
        catch {
            write-error $_
            throw;
        }
    }
}
Function Add-AutoPowershell7Runbook
{
    param
    (
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$Content,
        [Parameter()]
        [string]$Description,
        [switch]
        $AutoPublish,
        [switch]
        $WaitForCompletion,
        [Parameter()]
        [string]$Location,
        [Parameter()]
        [string]$AutomationAccountResourceId = $script:AutomationAccountResourceId
    )

    begin
    {
        $headers = Get-AutoAccessToken -AsHashTable
        $runbookUri = "https://management.azure.com$AutomationAccountResourceId/runbooks/$Name`?api-version=2022-06-30-preview"
        $runbookContentUri = "https://management.azure.com$AutomationAccountResourceId/runbooks/$Name/draft/content`?api-version=2022-08-08"
        $runbookPublishUri = "https://management.azure.com$AutomationAccountResourceId/runbooks/$Name/publish`?api-version=2022-08-08"
    }
    process
    {
        try {
            if([string]::IsNullOrEmpty($location)) {$location = $script:accountLocation}
            write-verbose "Modifying runbook on $runbookUri"
            $payload = @{
                name = $Name
                location = $location
                properties = @{
                    runbookType = 'PowerShell'
                    runtime = 'PowerShell-7.2'
                    description = $Description
                }
            } |  ConvertTo-Json
            write-verbose $payload
    
            $rslt = Invoke-RestMethod -Method Put `
                -Uri $runbookUri `
                -Body $payload `
                -ContentType 'application/json' `
                -Headers $headers `
                -ErrorAction Stop
            if($rslt.properties.provisioningState -ne 'Succeeded')
            {
                return $rslt
            }
    
            write-verbose "Uploading runbook content to $runbookContentUri"
            Invoke-RestMethod -Method Put `
                -Uri $runbookContentUri `
                -Body $Content `
                -ContentType 'text/powershell' `
                -Headers $headers `
                -ErrorAction Stop | Out-Null
            if(-not $AutoPublish)
            {
                return $rslt
            }
    
            write-verbose "Publishing runbook on $runbookPublishUri"
            #returns $null response
            Invoke-RestMethod -Method Post `
                -Uri $runbookPublishUri `
                -Body '{}' `
                -ContentType 'application/json' `
                -Headers $headers `
                -ErrorAction Stop | Out-Null
    
            if($WaitForCompletion)
            {
                do
                {
                    write-Verbose 'Waiting for publishing of the runbook'
                    Start-Sleep -Seconds 5
                    $rslt = Get-AutoObject -objectType Runbooks -Name $Name
    
                }while($rslt.properties.provisioningState -in @('Creating'))
            }
            $rslt
        }
        catch {
            write-error $_
            throw;
        }
    }
}

function Get-AutoModuleUrl
{
    param
    (
        [string]$modulePath,
        [string]$storageAccount,
        [string]$storageAccountFolder
    )

    begin
    {
        $moduleName = [System.IO.Path]::GetFileName($modulePath)
        $tempFile = [system.io.path]::Combine([system.io.path]::GetTempPath(),"$moduleName`.zip")
    }
    process
    {
        #compress to zip
        Write-Verbose "Compressing $modulePath to archive $tempFile"
        Compress-Archive -Path $modulePath -DestinationPath $tempFile -Update
        #get compressinon results
        #upload to storage account
        $h = Get-AutoAccessToken -ResourceUri 'https://storage.azure.com/.default' -AsHashTable
        #block id statically set to '1' and we assume only uploading single block
        $blobUri = "https://$storageAccount.blob.core.windows.net/$storageAccountFolder/$moduleName`.zip"
        Write-Verbose "Uploading compressed module to $blobUri"
        $h['x-ms-version'] = '2019-12-12'
        $h['x-ms-date'] = [DateTime]::UtcNow.ToString("R")
        $h['x-ms-blob-content-disposition'] = "attachment; fileName = $moduleName`.zip"
        $h['x-ms-blob-type'] = 'BlockBlob'

        Invoke-RestMethod -Method Put -Uri $blobUri -InFile $tempFile -headers $h -ErrorAction Stop | Out-Null

        #file uploaded, create SAS-ed URL
        Write-Verbose "Getting SAS token for uploaded module"
        Get-BlobSasUrl -ExpiresIn '02:00' -Permissions 'r' -storageAccount $storageAccount -blobPath "$storageAccountFolder/$moduleName`.zip"
    }
    end
    {
        if(Test-Path $tempFile)
        {
            Remove-Item $tempFile -Force
        }
    }
}
Function Add-AutoConfiguration
{
    param
    (
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$Content,
        [Parameter()]
        [string]$Description,
        [Parameter()]
        [System.Object]$Parameters,
        [Parameter()]
        [System.Object]$ParameterValues,
        [switch]
        $AutoCompile,
        [switch]
        $WaitForCompletion,
        [Parameter()]
        [string]$Location = "westeurope",
        [Parameter()]
        [string]$AutomationAccountResourceId = $script:AutomationAccountResourceId
    )

    begin
    {
        $headers = Get-AutoAccessToken -AsHashTable
        $configUri = "https://management.azure.com$AutomationAccountResourceId/configurations/$Name`?api-version=2023-11-01"
        $compilationJobName = "$Name-$((New-Guid))"
        $compilationUri = "https://management.azure.com$AutomationAccountResourceId/compilationjobs/$compilationJobName`?api-version=2019-06-01"
    }
    process
    {
        try {
            write-verbose "Modifying config on $configUri"
            $payload = @{
                name = $Name
                location = $location
                properties = @{
                    description = $Description
                    source = @{
                        type = 'embeddedContent'
                        value = $Content
                    }
                    parameters = $Parameters
                }
            } |  ConvertTo-Json
            write-verbose $payload
    
            $rslt = Invoke-RestMethod -Method Put `
                -Uri $configUri `
                -Body $payload `
                -ContentType 'application/json; charset=utf-8' `
                -Headers $headers `
                -ErrorAction Stop
            if(-not $AutoCompile)
            {
                return $rslt
            }
    
            #place compilation job
            write-verbose "Creating compilation job on $compilationUri"
            $payload = @{
                name = $compilationJobName
                properties = @{
                    configuration = @{
                        name = $Name
                    }
                    parameters = $ParameterValues
                }
            } |  ConvertTo-Json
            write-verbose $payload
    
            $rslt = Invoke-RestMethod -Method Put `
                -Uri $compilationUri `
                -Body $payload `
                -ContentType 'application/json' `
                -Headers $headers `
                -ErrorAction Stop
            if(-not $AutoCompile)
            {
                return $rslt
            }
    
            if($WaitForCompletion)
            {
                do
                {
                    write-Verbose 'Waiting for compilation job to complete'
                    Start-Sleep -Seconds 5
                    $rslt = Get-AutoObject -objectType Compilationjobs -Name $compilationJobName
                }while($rslt.properties.provisioningState -in @('Processing'))
            }
            $rslt
        }
        catch {
            write-error $_
            throw;
        }
    }
}

Function Add-AutoJobSchedule
{
    param
    (
        [Parameter(Mandatory)]
        [string]$RunbookName,
        [Parameter(Mandatory)]
        [string]$ScheduleName,
        [Parameter()]
        [string]$RunOn,
        [Parameter()]
        [hashTable]$Parameters,
        [Parameter()]
        [string]$AutomationAccountResourceId = $script:AutomationAccountResourceId
    )

    begin
    {
        $headers = Get-AutoAccessToken -AsHashTable
        $jobScheduleName = "$((New-Guid))"
        $Uri = "https://management.azure.com$AutomationAccountResourceId/jobSchedules/$jobScheduleName`?api-version=2023-11-01"
    }
    process
    {
        try
        {
            write-verbose "Modifying job schedule on $Uri"
            $payload = @{
                name = $jobScheduleName
                properties = @{
                    runbook = @{
                        name = $RunbookName
                    }
                    schedule = @{
                        name = $ScheduleName
                    }
                    parameters = $Parameters
                    runOn = $RunOn
                }
            } |  ConvertTo-Json
            write-verbose $payload

            Invoke-RestMethod -Method Put `
                -Uri $Uri `
                -Body $payload `
                -ContentType 'application/json' `
                -Headers $headers `
                -ErrorAction Stop
        }
        catch {
            write-error $_
            throw;
        }
    }
}

Function Add-AutoWebhook
{
    param
    (
        [Parameter(Mandatory)]
        [string]$Name,
         [Parameter(Mandatory)]
        [string]$RunbookName,
        [Parameter(Mandatory)]
        [datetime]$ExpiresOn,
        [Parameter()]
        [string]$RunOn,
        [Parameter()]
        [hashTable]$Parameters,
        [switch]$Force,
        [Parameter()]
        [string]$AutomationAccountResourceId = $script:AutomationAccountResourceId
    )

    begin
    {
        $headers = Get-AutoAccessToken -AsHashTable
        $Uri = "https://management.azure.com$AutomationAccountResourceId/webhooks/$Name`?api-version=2018-06-30"
    }
    process
    {
        try {
            write-verbose "Checking webhook on $Uri"
            try {
                Get-AutoObject -Name $Name -objectType Webhooks | Out-Null
                if($Force)
                {
                    #webhook likely exists -> remove first
                    Remove-AutoObject -Name $Name -objectType Webhooks
                }
            }
            catch {
                if($_.Exception.Response.StatusCode -ne 'NotFound') {throw}
            }
            
            #creating new webhook if does not exist of -Force
            #otherwise updating existing -> new url not reurned in this case
            write-verbose "Modifying webhook on $Uri"
            $payload = @{
                name = $Name
                properties = @{
                    runbook = @{
                        name = $RunbookName
                    }
                    expiryTime = $ExpiresOn
                    isEnabled = $true
                    parameters = $Parameters
                    runOn = $RunOn
                }
            } |  ConvertTo-Json
            write-verbose $payload
    
            Invoke-RestMethod -Method Put `
                -Uri $Uri `
                -Body $payload `
                -ContentType 'application/json' `
                -Headers $headers `
                -ErrorAction Stop
        }
        catch {
            write-error $_
            throw;
        }
    }
}

function Wait-AutoObjectProcessing
{
    param
    (
        [Parameter(Mandatory)]
        [string[]]$Name,
        [Parameter(Mandatory)]
        [ValidateSet('Runbooks','Compilationjobs','Modules','Powershell7Modules')]
        [string]$objectType
    )

    begin
    {
        $processingStates = @('Processing','Creating','RunningImportModuleRunbook','ModuleDataStored','ContentDownloaded', 'ContentValidated','ConnectionTypeImported')
    }
    process
    {
        do
        {
            $unprocessed = 0
            foreach($objName in $name)
            {
                switch($objectType)
                {
                    'Powershell7Modules' {
                        $obj = Get-AutoPowershell7Module -Name $objName
                        break;
                    }
                    default {
                        $obj = Get-AutoObject -objectType $objectType -Name $objName
                        break;
                    }
                }
                if($obj.properties.provisioningState -in $processingStates)
                {
                    $unprocessed++
                }
            }
            Write-Verbose "Pending: $unprocessed"
            if($unprocessed -gt 0)
            {
                Start-Sleep -Seconds 5
            }
        }while($unprocessed -gt 0)
        #report results
        foreach($objName in $name)
        {
            switch($objectType)
            {
                'Powershell7Modules' {
                    Get-AutoPowershell7Module -Name $objName
                    break;
                }
                default {
                    Get-AutoObject -objectType $objectType -Name $objName
                    break;
                }
            }
        }
    }
}

Function Get-BlobSasUrl
{
    param
    (
        [Timespan]$ExpiresIn = '02:00',
        [string]$Permissions,
        [string]$storageAccount,
        [string]$blobPath
    )

    process
    {
        $startDate = [DateTime]::UtcNow

        $keyInfo = Get-DelegationToken -StartDate $startDate -ExpiresIn $ExpiresIn -storageAccountName $storageAccount

        $signedPermissions = $Permissions
        $signedStart = $keyInfo.signedStart
        $signedExpiry = $keyInfo.signedExpiry
        $canonicalizedResource = "/blob/$storageAccount/$blobPath"
        $signedKeyObjectId = $keyInfo.SignedOid
        $signedKeyTenantId =$keyInfo.SignedTid
        $signedKeyStart = $keyInfo.signedStart
        $signedKeyExpiry = $keyInfo.signedExpiry
        $signedKeyService = $keyInfo.SignedService
        $signedKeyVersion = $keyInfo.SignedVersion
        $signedAuthorizedUserObjectId = ''
        $signedUnauthorizedUserObjectId =''
        $signedCorrelationId =''
        $signedIP =''
        $signedProtocol = 'https'
        $signedVersion = '2022-11-02'
        $signedResource = 'b'
        $signedSnapshotTime =''
        $signedEncryptionScope = ''
        $rscc = ''
        $rscd=''
        $rsce=''
        $rscl=''
        $rsct=''

        $stringToSign= "$signedPermissions" + [char]10 + "$signedStart" + [char]10 + "$signedExpiry" + [char]10 + "$canonicalizedResource" + [char]10 + `
            "$signedKeyObjectid" + [char]10 + $signedKeyTenantId + [char]10 +  $signedKeyStart + [char]10 + $signedKeyExpiry + [char]10 + `
            $signedKeyService + [char]10 + $signedKeyVersion + [char]10  + $signedAuthorizedUserObjectId + [char]10 + $signedUnauthorizedUserObjectId + [char]10 + `
            $signedCorrelationId + [char]10 + $signedIP + [char]10 + $signedProtocol + [char]10 + $signedVersion + [char]10 +$signedResource + [char]10 + `
            $signedSnapshotTime + [char]10 + $signedEncryptionScope + [char]10 + $rscc + [char]10 + $rscd + [char]10 + $rsce + [char]10 + $rscl + [char]10 + $rsct
        $signature = GetSasSignature -text $stringToSign -key $keyInfo.Value
        $signature = [Uri]::EscapeDataString($signature)
        $uriParams = "`?sp=$signedPermissions`&st=$signedStart`&se=$signedExpiry`&skoid=$signedKeyObjectId`&sktid=$signedKeyTenantId`&skt=$signedKeyStart`&ske=$signedKeyExpiry`&sks=$signedKeyService`&skv=$signedKeyVersion`&spr=$signedProtocol`&sv=$signedVersion`&sr=$signedResource`&sig=$signature"
        
        "https://$storageAccount.blob.core.windows.net/$blobPath$uriParams"
    }
}
Function Get-DelegationToken
{
    param
    (
        [DateTime]$StartDate,
        [Timespan]$ExpiresIn,
        [string]$storageAccountName
    )

    begin
    {
        $payloadTemplate = "<?xml version=`"1.0`" encoding=`"utf-8`"?><KeyInfo><Start>{0}</Start><Expiry>{1}</Expiry></KeyInfo>"
    }

    process
    {
        $payload = [string]::Format($payloadTemplate, $startDate.ToString('yyyy-MM-ddTHH:mm:ssZ'), ($startDate+$ExpiresIn).ToString('yyyy-MM-ddTHH:mm:ssZ'))
        $h = Get-AutoAccessToken -ResourceUri 'https://storage.azure.com/.default' -AsHashTable
        $h['x-ms-version'] = '2022-11-02'

        $rsp = Invoke-RestMethod -Method Post -Uri "https://$storageAccountName.blob.core.windows.net/`?restype=service`&comp=userdelegationkey" -Headers $h -body $payload -ContentType 'text/xml'
        $data =$rsp.Substring(3)
        
        # catch PS7 xml format issue
        if($PSVersionTable.PSVersion.Major -eq "7")
        {
            [xml]$xml=  $data.Replace('xml version="1.0" encoding="utf-8"?>','')
            $keyInfo = $xml.SelectSingleNode("//UserDelegationKey")
        }
        else 
        {
            $keyInfo=([xml]$data).UserDelegationKey
        }
        return $keyInfo
    }
}


function GetSasSignature
{
    param
    (
        [Parameter(Mandatory,ValueFromPipeline)]
        [string]$text,
        [Parameter(Mandatory)]
        [string]$key
    )

    begin
    {
        [System.Security.Cryptography.HashAlgorithm]$hmacsha256 = (new-object System.Security.Cryptography.HMACSHA256(,[Convert]::FromBase64String($key))) -as [System.Security.Cryptography.HashAlgorithm]
    }
    process
    {
        [Convert]::ToBase64String($hmacsha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text)))
    }
    end
    {
        if($null -ne $hmacsha256)
        {
            $hmacsha256.Dispose()
        }
    }
}
Function Get-DscNodes
{
    param(
        $Subscription,
        $ResourceGroup,
        $AutomationAccount
    )
   
    $subscriptionObject = Get-AutoSubscription -Subscription $Subscription
    $baseUri ="https://management.azure.com$($subscriptionObject.id)/resourceGroups/$($ResourceGroup)/providers/Microsoft.Automation/automationAccounts/$($AutomationAccount)/nodes?api-version=2023-11-01"
    $h = Get-AutoAccessToken -AsHashTable
    return (Invoke-RestMethod -Method Get -Uri $baseUri -Headers $h).value
}

Function Get-DscNodeConfiguration
{
    param(
        $Subscription,
        $ResourceGroup,
        $AutomationAccount
    )
    $subscriptionObject = Get-AutoSubscription -Subscription $Subscription
    $baseUri ="https://management.azure.com$($subscriptionObject.id)/resourceGroups/$($ResourceGroup)/providers/Microsoft.Automation/automationAccounts/$($AutomationAccount)/nodeConfigurations?api-version=2023-11-01"
    $h = Get-AutoAccessToken -AsHashTable
    return (Invoke-RestMethod -Method Get -Uri $baseUri -Headers $h).value
}


Function Assign-DscNodeConfig
{
    param(
        $Subscription,
        $ResourceGroup,
        $AutomationAccount,
        $NodeConfigId,
        $NodeName
    )
    $subscriptionObject = Get-AutoSubscription -Subscription $Subscription
    $baseUri ="https://management.azure.com$($subscriptionObject.id)/resourceGroups/$($ResourceGroup)/providers/Microsoft.Automation/automationAccounts/$($AutomationAccount)/nodes/$($nodeName)?api-version=2019-06-01"
    $h = Get-AutoAccessToken -AsHashTable
    $body = @{
        nodeId= $NodeName
        properties = @{
            nodeConfiguration = @{
                name = $NodeConfigId
            }
        }
    }|ConvertTo-Json 
    return Invoke-RestMethod -Method Patch -Uri $baseUri -Headers $h -ContentType "application/json" -Body $body
}

Function Get-ScheduleDetail {
    param (
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter()]
        [string]$AutomationAccountResourceId = $script:AutomationAccountResourceId
    )

    begin {
        $headers = Get-AutoAccessToken -AsHashTable
        $uri = "https://management.azure.com$($AutomationAccountResourceId)/schedules/$($Name)?api-version=2023-11-01"
        Write-Host "Tohle je uri: $($uri)"
    }

    process {
        write-verbose "Fetching schedule details from $uri"
        try {
            $response = Invoke-RestMethod -Method Get `
                -Uri $uri `
                -Headers $headers `
                -ErrorAction Stop
            Write-Host "Response Parameters: $($response.properties)"
            return $response
        } catch {
            write-error $_
            throw
        }
    }
}

