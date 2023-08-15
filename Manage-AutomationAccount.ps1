Param
(
    [Parameter(Mandatory)]
    [ValidateSet('Runbooks', 'Variables', 'Dsc', 'Schedules', 'Modules')]
    [string[]]
    #What we are deploying
    $Scope,
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
    [string]
    #name of hybrid worker group to use when scheduling runbook or creating webhook and job execution needs to be on hybrid worker
    $HybridWorkerGroup,
    [Switch]
    #whether or not to remove any existing runbooks and variables from automation account that are not source-controlled 
    $FullSync,
    [Switch]
    #whether to automatically publish runbooks and Dsc configurations. This can be overriden in runbook/Dsc definition file
    $AutoPublish,
    [Switch]
    #whether to report missing implementation file
    #Note: it may be perfectly OK not to have implementation file, if artefact is meant to be used just in subset of environments
    $ReportMissingImplementation
)

Import-Module Az.Accounts
Import-Module Az.Automation
Import-Module Az.Resources

#import common routines - library file is expected in the same folder as we are
. "$PSScriptRoot\Runtime.ps1" -ProjectDir $ProjectDir -Environment $EnvironmentName

#region Connect subscription

"Setting active subscription to $Subscription"
$subscritionObject = Select-AzSubscription -Subscription $Subscription

#endregion

#region Variables
if (Check-Scope -Scope $scope -RequiredScope 'Variables') {
    "Processing Automation variables"
    $definitions = @(Get-DefinitionFiles -FileType Variables)

    $CurrentVariables = Get-AzAutomationVariable -AutomationAccountName $AutomationAccount -ResourceGroupName $ResourceGroup
    "Updating existing variables"
    foreach ($variable in $currentVariables) {
        try {
            if ($variable.name -notin $definitions.Name) {
                if ($FullSync) {
                    "$($variable.name) not managed and we're doing full sync -> removing variable"
                    Remove-AzAutomationVariable -Name $variable.Name -AutomationAccountName $AutomationAccount -ResourceGroupName $ResourceGroup
                }
                else {
                    "$($variable.name) not managed and we're NOT doing full sync -> keeping variable"
                }
            }
            else {
                $managedVariable = $definitions.Where{ $_.Name -eq $variable.name }
                $contentFile = Get-FileToProcess -FileType Variables -FileName $managedVariable.Content
                if ($null -ne $contentFile) {
                    "$($variable.name) managed -> updating variable from $contentFile"
                    #TODO: Add support for more data types than string
                    [string]$variableValue = Get-Content $contentFile -Raw
                    #set value
                    Set-AzAutomationVariable -Name $variable.Name `
                        -AutomationAccountName $AutomationAccount `
                        -ResourceGroupName $ResourceGroup `
                        -Encrypted $managedVariable.Encrypted `
                        -Value $variableValue | Out-Null                
                }
                else {
                    if ($ReportMissingImplementation) {
                        Write-Warning "$($variable.name)`: Missing content file, skipping variable content update"
                    }
                }
            
                #set description - it's different parameter set
                if (-not [string]::IsnullOrEmpty($managedVariable.Description)) {
                    Set-AzAutomationVariable -Name $variable.Name `
                        -AutomationAccountName $AutomationAccount `
                        -ResourceGroupName $ResourceGroup `
                        -Description $managedVariable.Description | Out-Null
                }
            }
        }
        catch {
            Write-Warning $_.Exception
        }
    }

    #add new variables
    "Adding new variables"
    foreach ($managedVariable in $definitions) {
        try {
            if ($managedVariable.Name -notin $currentVariables.Name) {
                $contentFile = Get-FileToProcess -FileType Variables -FileName $managedVariable.Content
                if ($null -ne $contentFile) {
                    "$($managedVariable.name) not present -> adding variable from $contentFile"
                    #TODO: Add support for more data types than string
                    [string]$variableValue = Get-Content $contentFile -Raw
                    New-AzAutomationVariable -Name $managedVariable.Name `
                        -AutomationAccountName $AutomationAccount `
                        -ResourceGroupName $ResourceGroup `
                        -Encrypted $managedVariable.Encrypted `
                        -Value $variableValue `
                        -Description $managedVariable.Description | Out-Null
                }
                else {
                    if ($ReportMissingImplementation) {
                        Write-Warning "$($variable.name)`: Missing content file, skipping variable creation"
                    }
                }
            }
        }
        catch {
            Write-Warning $_.Exception
        }
    }
}
#endregion Variables

#region Modules
if (Check-Scope -Scope $scope -RequiredScope 'Modules') {
    "Processing Modules"
    
    $uriBase = "https://management.azure.com"
    $resourceProviderName = "Microsoft.Automation"
    $resourceType = "automationAccounts"
    $apiVersion = "2019-06-01"

    #Get requested (non-default) modules from runbook definitions
    $definitions = @(Get-DefinitionFiles -FileType Modules)

    foreach ($def in $definitions) {
        $contentFile = Get-FileToProcess -FileType Modules -FileName $def.ModulesList
        if ($null -eq $contentFile) {
            if ($ReportMissingImplementation) {
                Write-Warning "$($def.ModulesList)`: Missing modules list file, skipping"
            }
            continue
        }
        $modulesList = Get-Content $contentFile -Raw | ConvertFrom-Json
        $ModulesToBeInstalled = @()
        $azToken = $null
        $versionEnum = @{
            '5.1' = @{ resource = 'Modules';            runtimeParameter = $null }
            '7.1' = @{ resource = 'powershell7Modules'; runtimeParameter = $null }
            '7.2' = @{ resource = 'powershell7Modules'; runtimeParameter = '&runtimeVersion=7.2' }
        }
        
        function Search-CurrentModule {
            param (
                [Parameter(Mandatory)]
                [string[]]
                    $ModuleName,
                [Parameter(Mandatory)]
                [ValidateSet('5.1', '7.1', '7.2')]
                [string]
                    $Runtime
            )
            
            $resource =         $versionEnum[$Runtime].resource
            $runtimeParameter = $versionEnum[$Runtime].runtimeParameter
            $returnValue = @{ 
                moduleName = $ModuleName
                runtime = $Runtime
                messageImportPhase = $null
                messageCheckPhase = $null
                importAction = $false
                checkAction = $false
                provisioningStatus = $null
            }
            
            $method = "GET"
            if (($null -eq $azToken) -or ($azToken.ExpiresOn -lt (Get-Date).AddMinutes(-10)))
            {
                $azToken = Get-AzAccessToken
            }
            $header = @{
                "Authorization" = "$($azToken.Type) $($azToken.Token)"
            }
        
            # Check if module is already present in the automation account for the runtime version
            $uriCall = "/subscriptions/$Subscription/resourceGroups/$RGName/providers/$resourceProviderName/$resourceType/$AAName/$resource/$($moduleName)?api-version=$apiVersion$runtimeParameter"
            
            try { 
                $currentModule = Invoke-RestMethod -Method $method -Uri ($uriBase+$uriCall) -Headers $header
                #we do not use System.Version as it does not support some versioning schemes
                if ($currentModule.properties.provisioningState -ne 'Succeeded') {
                    $returnValue.messageImportPhase = "$moduleName with runtime $runtime present with wrong status -> reimporting"
                    $returnValue.importAction = $true
                    $returnValue.provisioningStatus = $currentModule.properties.provisioningState
                    $returnValue.checkAction = $true        
                }
                else {
                    $currentVersion = $currentModule.properties.version.ToLowerInvariant()
                    $requiredVersion = $module.Version.ToLowerInvariant()
                    if ($currentVersion -lt $requiredVersion) {
                        $returnValue.messageImportPhase = "$moduleName with runtime $runtime version lower than required ($currentVersion : $requiredVersion) -> importing"
                        $returnValue.importAction = $true
                        $returnValue.provisioningStatus = $currentModule.properties.provisioningState
                    }
                    else {
                        $returnValue.messageImportPhase = "$moduleName with runtime $runtime version up to date or newer -> nothing to do"
                        $returnValue.importAction = $false
                        $returnValue.provisioningStatus = $currentModule.properties.provisioningState
                    }
                }
                return $returnValue
            } 
            catch { 
                if ($_.Exception.Response.StatusCode -eq 'NotFound') {
                    $returnValue.messageImportPhase = "$moduleName not present for runtime $runtime -> importing"
                    $returnValue.messageCheckPhase = "The module $moduleName for runtime $runtime was not found (possibly deleted during import) -> will not check further."
                    $returnValue.importAction = $true
                    $returnValue.provisioningStatus = $null
                    $returnValue.checkAction = $false
                }
                else {
                    $returnValue.messageImportPhase = "Error while fetching information about the module $moduleName for runtime $runtime -> skipping"
                    $returnValue.messageCheckPhase = "Error while checking the provisioning status of the module $moduleName for runtime $runtime -> will try again."
                    $returnValue.importAction = $false
                    $returnValue.provisioningStatus = $null
                    $returnValue.checkAction = $true
                }
                return $returnValue
            }
        }
        
        foreach($module in $modulesList.RequiredModules) {
            if ($null -ne $module.Runtimes) {
                foreach ($runtime in $module.Runtimes) {
                    $currentModuleInfo = Search-CurrentModule -ModuleName $module.Name -Runtime $runtime
                    Write-Host $currentModuleInfo.messageImportPhase
                    if ($currentModuleInfo.importAction) {
                        $moduleTemp = @{}
                        $moduleTemp = $module.psobject.Copy()
                        $moduleTemp | Add-Member -NotePropertyName 'Runtime' -NotePropertyValue $runtime
                        $modulesToBeInstalled += $moduleTemp
                    }
                }
            }
            else {
                $currentModuleInfo = Search-CurrentModule -ModuleName $module.Name -Runtime '5.1'
                Write-Host $currentModuleInfo.messageImportPhase
                if ($currentModuleInfo.importAction) {
                    $moduleTemp = @{}
                    $moduleTemp = $module.psobject.Copy()
                    $moduleTemp | Add-Member -NotePropertyName 'Runtime' -NotePropertyValue '5.1'
                    $modulesToBeInstalled += $moduleTemp
                }
            }
        }
        
        #start async import
        $method = "PUT"
        $contentType = "application/json"
        if (($null -eq $azToken) -or ($azToken.ExpiresOn -lt (Get-Date).AddMinutes(-10))) {
            $azToken = Get-AzAccessToken
        }
        $header = @{
            "Authorization" = "$($azToken.Type) $($azToken.Token)"
            "Content-type" = $contentType
        }
        foreach($module in $modulesToBeInstalled) {
            $resource =         $versionEnum[$module.Runtime].resource
            $runtimeParameter = $versionEnum[$module.Runtime].runtimeParameter
            $uriCall = "/subscriptions/$Subscription/resourceGroups/$RGName/providers/$resourceProviderName/$resourceType/$AAName/$resource/$($module.Name)?api-version=$apiVersion$runtimeParameter"
            $requestBody = @{
                properties = @{
                    contentLink = @{
                        uri = "$($module.VersionIndependentLink)/$($module.Version)"
                        version = "$($module.Version)"
                    }
                }
            }
            try {
                $modulesBatch += Invoke-RestMethod -Method $method -Uri ($uriBase+$uriCall) -Headers $header -Body ($requestBody | ConvertTo-Json)
            }
            catch {
                Write-Host "Error while initiating module $($module.Name) import for runtime $($module.Runtime) -> try again later"
                continue
            }
        }
        #wait till import completes
        do {
            $dirty = $false
            $modulesBatch = @()
            foreach($module in $modulesToBeInstalled) {
                $moduleInfo = Search-CurrentModule -ModuleName $module.Name -Runtime $module.Runtime
                if ($moduleInfo.provisioningStatus) {
                    if ($moduleInfo.provisioningStatus -eq 'Creating') {
                        $dirty = $true
                        $modulesBatch += $moduleInfo
                    }
                    if ($moduleInfo.provisioningStatus -eq 'Failed') {
                        Write-Host "Could not import module $($moduleInfo.moduleName) for runtime $($moduleInfo.runtime). The import finished with status 'Failed'."
                        continue
                    }
                }
                else {
                    Write-Host $moduleInfo.messageCheckPhase
                    if ($moduleInfo.checkAction) {
                        $modulesBatch += $moduleInfo
                    }
                }
            }
            if ($modulesBatch.Count -gt 0) {
                $modulesBatch | Select-Object moduleName, runtime, provisioningStatus | Format-Table
                Start-Sleep -Seconds 30
            }
        } while ($dirty)
    }
}
        
#endregion Modules

#region Schedules
function Build-StartTime {
    <# 
        Calculates the nearest acceptable start time for automation account schedule.
        The schedule will trigger the task at StartHour and StartMinute plus corresponding interval.
        The start time must be set to 15 minutes after the schedule deployment time.
    #>

    param (
        [Parameter()] [datetime] $Time,
        [Parameter()] [int] $StartHour,
        [Parameter()] [int] $StartMinute,
        [Parameter()] [string] $Interval
    )
    
    # Azure accepts as start time time at least 15 minutes from the moment of execution - info in portal
    # The start time of the schedule must be at least 5 minutes after the time you create the schedule. - error message
    $NecessaryDelayInMinutes = 15
    $DayInTicks = (New-TimeSpan -Days 1).Ticks
    $RoundToDay = [System.DateTime]([Int64][math]::Floor($Time.Ticks / $DayInTicks) * $DayInTicks)
    $StartTime = $RoundToDay.AddHours($StartHour).AddMinutes($StartMinute)
    
    while ($StartTime -lt $Time.AddMinutes($NecessaryDelayInMinutes)) {
        $StartTime = $StartTime.AddHours($Interval)
    }
    return $StartTime
}

if (Check-Scope -Scope $scope -RequiredScope 'Schedules') {
    "Processing Schedules"
    $definitions = @(Get-DefinitionFiles -FileType Schedules)

    $currentSchedules = Get-AzAutomationSchedule -AutomationAccountName $AutomationAccount -ResourceGroupName $ResourceGroup
    "Updating existing schedules"
    foreach ($schedule in $currentSchedules) {
        try {
            if ($schedule.name -notin $definitions.Name) {
                if ($FullSync) {
                    "$($schedule.name) not managed and we're doing full sync -> removing schedule"
                    # Schedule will be removed even if it is enabled and linked to runbooks
                    Remove-AzAutomationSchedule -Name $schedule.Name -AutomationAccountName $AutomationAccount -ResourceGroupName $ResourceGroup -Force
                }
                else {
                    "$($schedule.name) not managed and we're NOT doing full sync -> keeping schedule"
                }
            }
            else {
                $managedSchedule = $definitions | Where-Object { $_.Name -eq $schedule.name }
                "$($schedule.name) managed -> updating schedule"
                #set value
                #updates only Description, IsEnabled parameters
                Set-AzAutomationSchedule -Name $schedule.Name `
                    -AutomationAccountName $AutomationAccount `
                    -ResourceGroupName $ResourceGroup `
                    -IsEnabled $managedSchedule.IsEnabled `
                    -Description $managedSchedule.Description | Out-Null
            }
        }
        catch {
            Write-Warning $_.Exception
        }
    }
    #add new schedules
    "Adding new schedules"
    foreach ($managedSchedule in $definitions) {
        try {
            if ($managedSchedule.Name -notin $currentSchedules.Name) {
                "$($managedSchedule.name) not present -> adding schedule"
                switch ($managedSchedule.Frequency) {
                    "OneTime" { $Interval = $null }
                    "Hourly" { $Interval = $managedSchedule.Interval }
                    { $_ -in "Daily", "Weekly", "Monthly" } { $Interval = 24 }
                    Default { Write-Host "Invalid frequency defined!" }
                }
            
                $StartTimeValidationSucceeded = $false
                [TimeOnly] $tempStartTimeOnly = New-Object System.TimeOnly
                [DateTimeOffset] $StartTime = New-Object System.DateTimeOffset
                # Starttime validation and calculation
                switch ($managedSchedule.StartTime) {
                    { [string]::IsnullOrEmpty($_) } {
                        # Prepare the nearest possible time
                        # Write-Host "Parameter StartTime is empty. The nearest possible start time will be set."
                        $StartTime = [System.DateTimeOffset](Get-Date).AddMinutes(15)
                        $StartTimeValidationSucceeded = $true
                        break
                    }
                    { [TimeOnly]::TryParseExact($_, "HH:mm", [ref] $tempStartTimeOnly) } {
                        # Write-Host "The user requests the schedule to start at specific hour and minute. The nearest possible start time will be calculated."
                        $StartTime = Build-StartTime -Time (Get-Date) -StartMinute $tempStartTimeOnly.Minute -StartHour $tempStartTimeOnly.Hour -Interval $Interval
                        $StartTimeValidationSucceeded = $true
                        break
                    }
                    { [DateTimeOffset]::TryParse($_, [ref] $StartTime) } {
                        if ($StartTime -ge (Get-Date).AddMinutes(15)) {
                            Write-Host "The user requests fixed time to start the schedule and the provided date and time are valid."
                            $StartTimeValidationSucceeded = $true
                        }
                        else {
                            Write-Warning "The user requests fixed time to start the schedule but the parameter StartTime is invalid. Hint: The start time of the schedule must be at least 15 minutes after the time you create the schedule. Skipping."
                            $StartTimeValidationSucceeded = $false
                            break
                        }
                    }
                    Default {
                        Write-Warning "Invalid StartTime defined. Skipping."
                        $StartTimeValidationSucceeded = $false
                    }
                }
            
                if ([string]::IsnullOrEmpty($managedSchedule.TimeZone)) {
                    $TimeZone = $null
                } 
                else {
                    $TimeZone = $managedSchedule.TimeZone
                }
            
                if ($StartTimeValidationSucceeded) {
                    $strStartTime = $StartTime.ToString("yyyy-MM-dd THH:mm:ss zzzz")
            
                    switch ($managedSchedule.Frequency) {
                        'OneTime' {
                            New-AzAutomationSchedule -Name $managedSchedule.Name `
                                -AutomationAccountName $AutomationAccount `
                                -ResourceGroupName $ResourceGroup `
                                -Description $managedSchedule.Description `
                                -StartTime $strStartTime `
                                -TimeZone $TimeZone ` | Out-Null
                        }
                        'Hourly' {
                            New-AzAutomationSchedule -Name $managedSchedule.Name `
                                -AutomationAccountName $AutomationAccount `
                                -ResourceGroupName $ResourceGroup `
                                -Description $managedSchedule.Description `
                                -StartTime $strStartTime `
                                -TimeZone $TimeZone `
                                -HourInterval $managedSchedule.Interval | Out-Null
                        }
                        'Daily' {
                            New-AzAutomationSchedule -Name $managedSchedule.Name `
                                -AutomationAccountName $AutomationAccount `
                                -ResourceGroupName $ResourceGroup `
                                -Description $managedSchedule.Description `
                                -StartTime $strStartTime `
                                -TimeZone $TimeZone `
                                -DayInterval $managedSchedule.Interval | Out-Null
                        }
                        'Weekly' {
                            New-AzAutomationSchedule -Name $managedSchedule.Name `
                                -AutomationAccountName $AutomationAccount `
                                -ResourceGroupName $ResourceGroup `
                                -Description $managedSchedule.Description `
                                -StartTime $strStartTime `
                                -TimeZone $TimeZone `
                                -WeekInterval $managedSchedule.Interval `
                                -DaysOfWeek $managedSchedule.WeeklyScheduleOptions.DaysOfWeek | Out-Null
                        }
                        'Monthly' {
                            if (($null -eq $managedSchedule.MonthlyScheduleOptions.DaysOfMonth) -xor ($null -eq $managedSchedule.MonthlyScheduleOptions.DayOfWeek)) {
                                if (-not ($null -eq $managedSchedule.MonthlyScheduleOptions.DaysOfMonth)) {
                                    New-AzAutomationSchedule -Name $managedSchedule.Name `
                                        -AutomationAccountName $AutomationAccount `
                                        -ResourceGroupName $ResourceGroup `
                                        -Description $managedSchedule.Description `
                                        -StartTime $tsrStartTime `
                                        -TimeZone $TimeZone `
                                        -MonthInterval $managedSchedule.Interval `
                                        -DaysOfMonth $managedSchedule.MonthlyScheduleOptions.DaysOfMonth | Out-Null
                                }
                                else {
                                    New-AzAutomationSchedule -Name $managedSchedule.Name `
                                        -AutomationAccountName $AutomationAccount `
                                        -ResourceGroupName $ResourceGroup `
                                        -Description $managedSchedule.Description `
                                        -StartTime $strStartTime `
                                        -TimeZone $TimeZone `
                                        -MonthInterval $managedSchedule.Interval `
                                        -DayOfWeek $managedSchedule.MonthlyScheduleOptions.DayOfWeek.Day `
                                        -DayOfWeekOccurrence $managedSchedule.MonthlyScheduleOptions.DayOfWeek.Occurrence | Out-Null
                                }
                            }
                            else {
                                Write-Warning "Schedule $($managedSchedule.Name)`: Parameters for Monthly schedule invalid. Hint: Both monthly schedule options are defined or none. Skipping."
                            }
                        }
                        Default {
                            Write-Warning "Schedule $($managedSchedule.Name)`: Parameter Frequency is invalid. Skipping."
                        }
                    }
                }
            }
        }
        catch {
            Write-Warning $_.Exception
        }
    }
}

#endregion Schedules

#region Runbooks
if (Check-Scope -Scope $scope -RequiredScope 'Runbooks') {
    "Processing Runbooks"
    #create a scriptblock for importing runbook as a job
    #this is to increase the performance as the inport takes terribly long
    $runbookImportJob = {
        param
        (
            [PSCustomObject]$RunbookDefinition,
            [string]$RGName,
            [string]$AAName,
            [string]$Path,
            [bool]$Published,
            [string[]] $CurrentSchedulesNames,
            [string]$HWGroup,
            [string]$SubscriptionId,
            $azToken
        )
        
        $location = (Get-AzResourceGroup -Name $RGName).Location
        $defaultApiVersion = '2019-06-01'
        # Using preview API to support PowerShell runtime 7.2
        $versionEnum = @{
            '7.2' =  @{runbookType = 'PowerShell' ; ApiVersion = '2022-06-30-preview'; runtime = 'PowerShell-7.2' }
            '7.1' =  @{runbookType = 'PowerShell7'; ApiVersion = $defaultApiVersion }
            '5.1' =  @{runbookType = 'PowerShell' ; ApiVersion = $defaultApiVersion }
        }
        $runtime = $null

        switch ($RunbookDefinition.Type) {
            "PowerShell" { 
                if([string]::IsnullOrEmpty($RunbookDefinition.RuntimeVersion)) {$requestedRuntime = '5.1'} else {$requestedRuntime = $RunbookDefinition.RuntimeVersion}
                $runbookType = $versionEnum[$requestedRuntime].runbookType; 
                # For the runtime 7.2 the .properties.runtime parametr in payload is needed
                if ($versionEnum[$requestedRuntime].runtime) { $runtime = $versionEnum[$requestedRuntime].runtime };
                $apiVersion = $versionEnum[$requestedRuntime].ApiVersion 
            }
            { $_ -in ("GraphicalPowerShell", "PowerShellWorkflow", "GraphicalPowerShellWorkflow", "Graph", "Python2") } { 
                $runbookType = $RunbookDefinition.Type; 
                $apiVersion = $defaultApiVersion 
            }
            Default { $runbookType = $null; Write-Warning "Unsupported runbook type of $_ specified for runbook $($RunbookDefinition.Name)."}
        }
        
        $uriBase = "https://management.azure.com"
        $resourceProviderName = "Microsoft.Automation"
        $resourceType = "automationAccounts" 

        # Create or Update runbook
        $method = "PUT"
        $uriCall = "/subscriptions/$SubscriptionId/resourceGroups/$RGName/providers/$resourceProviderName/$resourceType/$AAName/runbooks/$($RunbookDefinition.Name)?api-version=$apiVersion"
        $contentType = "application/json"
        $Header = @{
            "Authorization" = "$($azToken.Type) $($azToken.Token)"
            "Content-type" = $contentType
        }
        $newRunbookPayload = @{
            location   = $location
            properties = @{
              runbookType = $runbookType
              runtime     = $runtime
              logProgress = $false
              logVerbose  = $false
              draft       = @{}
            }
        }
        
        try {
            Invoke-RestMethod -Method $method -Uri ($uriBase+$uriCall) -Headers $Header -Body ($newRunbookPayload | ConvertTo-Json)
            Write-Information "Created/Updated runbook $($RunbookDefinition.Name)"
        }
        catch {
            Write-Error "Error while creating/updating the runbook $($RunbookDefinition.Name) : $($_.Exception.Response)"
            
        }
        
        # Update runbook content (script)
        $method = "PUT"
        $uriCall = "/subscriptions/$SubscriptionId/resourceGroups/$RGName/providers/$resourceProviderName/$resourceType/$AAName/runbooks/$($RunbookDefinition.Name)/draft/content?api-version=$apiVersion"
        $contentType = "text/powershell"
        $Header = @{
            "Authorization" = "$($azToken.Type) $($azToken.Token)"
            "Content-type" = $contentType
        }
        $scriptContent = Get-Content -Raw -Path $Path
                
        try {
            Invoke-RestMethod -Method $method -Uri ($uriBase+$uriCall) -Headers $Header -Body $scriptContent
            Write-Information "Uploaded runbook content: $($RunbookDefinition.Name)"

        }
        catch {
            Write-Error "Error while uploading the script content to runbook $($RunbookDefinition.Name) : $($_.Exception.Response)"
        }
        # Publish runbook
        if ($Published)
        {
            $method = "POST"
            $uriCall = "/subscriptions/$SubscriptionId/resourceGroups/$RGName/providers/$resourceProviderName/$resourceType/$AAName/runbooks/$($RunbookDefinition.Name)/publish?api-version=$apiVersion"
            $Header = @{
                "Authorization" = "$($azToken.Type) $($azToken.Token)"
            }
            
            try {
                Invoke-RestMethod -Method $method -Uri ($uriBase+$uriCall) -Headers $Header
                Write-Information "Published runbook $($RunbookDefinition.Name)"
            }
            catch {
                Write-Error "Error while publishing the runbook $($RunbookDefinition.Name) : $($_.Exception.Response)"
            }    
        }
        
        if (-not $null -eq $RunbookDefinition.Schedules) {
            if ($Published) {
                foreach ($scheduleName in $RunbookDefinition.Schedules) {
                    if ($scheduleName -in $CurrentSchedulesNames) {
                        Register-AzAutomationScheduledRunbook `
                            -RunbookName $RunbookDefinition.Name `
                            -ScheduleName $scheduleName `
                            -ResourceGroupName $RGName `
                            -AutomationAccountName $AAName `
                            -RunOn $HWGroup
                    }
                    else {
                        Write-Warning "Schedule $scheduleName requested for runbook $($RunbookDefinition.Name) is not defined in automation account $AAName."
                    }
                }
                #unregister schedules no longer there
                $schedules = Get-AzAutomationScheduledRunbook `
                    -RunbookName $RunbookDefinition.Name `
                    -ResourceGroupName $RGName `
                    -AutomationAccountName $AAName
                foreach($schedule in $schedules)
                {
                    if($schedule.ScheduleName -notin $RunbookDefinition.Schedules)
                    {
                        Unregister-AzAutomationScheduledRunbook `
                            -RunbookName $RunbookDefinition.Name `
                            -ScheduleName $schedule.ScheduleName `
                            -ResourceGroupName $RGName `
                            -AutomationAccountName $AAName `
                            -Force
                        Write-Host "Unregistered schedule $($schedule.ScheduleName) from runbook $($RunbookDefinition.Name)"
                    }
                }
            }
            else {
                Write-Warning "Schedules were not linked to runbook $($RunbookDefinition.Name) as requested, because the parameter AutoPublish is false."
            }
        }
    }

    $token = Get-AzAccessToken

    $importJobs = @()
    $definitions = @(Get-DefinitionFiles -FileType Runbooks)
    $CurrentSchedules = Get-AzAutomationSchedule -AutomationAccountName $AutomationAccount -ResourceGroupName $ResourceGroup
    foreach ($def in $definitions) {
        $Publish = $def.AutoPublish
        if ($null -eq $Publish) {
            $Publish = $AutoPublish.ToBool()
        }

        $ScheduleCheckResult = $true
        if ($null -ne $def.Schedules) {
            foreach ($schedule in $def.Schedules) {
                <# $schedule is the current item #>
                if ($schedule -notin $CurrentSchedules.Name) {
                    Write-Warning "Schedule $schedule requested by runbook definition for $($def.Name) was not defined and does not exist, skipping."
                    $ScheduleCheckResult = $false
                }
            }
        }

        $implementationFileCheckResult = $true
        $implementationFile = Get-FileToProcess -FileType Runbooks -FileName $def.Implementation
        if ($null -eq $implementationFile) {
            if ($ReportMissingImplementation) {
                Write-Warning "Runbook $($def.name)`: Implementation file not defined for this environment, skipping."
            }
            $implementationFileCheckResult = $false
        }

        #import logic of runbook
        if ($implementationFileCheckResult -and $ScheduleCheckResult) {
            "Starting runbook import: $($def.name); Source: $implementationFile; Publish: $Publish"
            $HWG = if ($def.RunsOn -eq 'HybridWorker') { $HybridWorkerGroup }else { $null }
            #$RunOn = if($def.RunsOn){$HWGroupCheckResult.HWGroupDefined}else{$null}

            $importJobs += Start-Job `
                -ScriptBlock $runbookImportJob `
                -ArgumentList `
                    $def, `
                    $ResourceGroup, `
                    $AutomationAccount, `
                    $implementationFile, `
                    $Publish, `
                    $CurrentSchedules.Name, `
                    $HWG, `
                    $subscritionObject.Subscription.id, `
                    $token `
                -Name $def.Name
        }
    }

    do {
        $incompleteJobs = $importJobs.Where{ $_.State -notin 'Completed', 'Suspended', 'Failed' }
        if ($VerbosePreference -ne 'SilentlyContinue') {
            $importJobs | select-object Name, JobStateInfo, Error
            Write-Host "-----------------"
        }
        else {
            Write-Host "Waiting for import jobs to complete ($($incompleteJobs.Count))"
        }
        if ($incompleteJobs.Count -gt 0) { Start-Sleep -Seconds 15 }
    } while ($incompleteJobs.Count -gt 0)

    foreach ($job in $importJobs) {
        $job | Select-Object Name, JobStateInfo, Error | format-table
        $job.ChildJobs | Select-Object -ExpandProperty Error
        $job.ChildJobs | Select-Object -ExpandProperty Warning
    }

    if ($FullSync) {
        $existingRunbooks = @(Get-AzAutomationRunbook -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccount)
        foreach ($runbook in $existingRunbooks) {
            if ($runbook.Name -notin $definitions.name) {
                "$($Runbook.name) not managed and we're doing full sync -> removing runbook"
                Remove-AzAutomationRunbook -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccount -Name $runbook.Name -Force
            }
        }
    }
}
#endregion Runbooks

#region Dsc
if (Check-Scope -Scope $scope -RequiredScope 'Dsc') {
    $ManagedConfigurations = @()
    $CompilationJobs = @()

    $definitions = @(Get-DefinitionFiles -FileType Dsc)

    foreach ($def in $definitions) {
        $Publish = $def.AutoPublish
        if ($null -eq $Publish) {
            $Publish = $AutoPublish.ToBool()
        }
        $implementationFile = Get-FileToProcess -FileType Dsc -FileName $def.Implementation
        #import logic of DSC config
        if ($null -ne $implementationFile) {
            "Importing Dsc: Source: $implementationFile; Publish: $Publish; Compile: $($def.AutoCompile)"
            $DscConfig = Import-AzAutomationDscConfiguration `
                -SourcePath $implementationFile `
                -ResourceGroupName $ResourceGroup `
                -AutomationAccountName $AutomationAccount `
                -Force `
                -Published:$def.AutoPublish
            
            if ($def.AutoCompile) {
                #prepare params dictionary if definition specifies
                $Params = @{}
                if ($null -ne $def.Parameters) {
                    $def.Parameters.psobject.properties | Foreach-Object { $Params[$_.Name] = $_.Value }
                }
                $compilationJob = Start-AzAutomationDscCompilationJob `
                    -ResourceGroupName $ResourceGroup `
                    -AutomationAccountName $AutomationAccount `
                    -ConfigurationName $DscConfig.Name `
                    -Parameters $Params
                $CompilationJobs += $CompilationJob
            }
            $ManagedConfigurations += $DscConfig
        }
        else {
            if ($ReportMissingImplementation) {
                Write-Warning "Dsc $($def.Name)`: Implementation file not defined for this environment, skipping"
            }
        }
    }

    #wait for compilations to complete
    do {
        $incompleteJobs = @($compilationJobs `
            | Foreach-object { Get-AzAutomationDscCompilationJob `
                    -Id $_.Id `
                    -ResourceGroupName $ResourceGroup `
                    -AutomationAccountName $AutomationAccount `
            } `
            | Where-Object { $_.Status -notin 'Completed', 'Suspended', 'Failed' })
        
        if ($VerbosePreference -ne 'SilentlyContinue') {
            $incompleteJobs
            Write-Host "-----------------"
        }
        else {
            Write-Host "Waiting for compilation jobs to complete ($($incompleteJobs.Count))"
        }

        if ($incompleteJobs.Count -gt 0) { Start-Sleep -Seconds 15 }
    } while ($incompleteJobs.Count -gt 0)

    if ($FullSync) {
        $existingDscConfigurations = @(Get-AzAutomationDscConfiguration -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccount)
        foreach ($DscConfig in $existingDscConfigurations) {
            if ($DscConfig.Name -notin $ManagedConfigurations.name) {
                "$($DscConfig.name) not managed and we're doing full sync -> removing Dsc configuration"
                Remove-AzAutomationDscConfiguration -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccount -Name $DscConfig.Name -Force
            }
        }
    }
}
#endregion Dsc