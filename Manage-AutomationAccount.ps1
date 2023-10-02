Param
(
    [Parameter(Mandatory)]
    [ValidateSet('Runbooks', 'Variables', 'Configurations', 'Schedules', 'Modules', 'JobSchedules',"Webhooks")]
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
    #name of storage account used for uploading of private modules to automation account
    #caller must have permission to:
    #  - upload blobs
    #  - create SAS tokens for uplaoded blobs
    #Not needed if private modules not used
    $storageAccount,
    [Parameter()]
    [string]
    #name of blob container where to upload private modules to
    #SAS token valid for 2 hours is then created a used to generate content link for module
    #so as automation account can use it to upload module to itself
    $storageAccountContainer,
    [Parameter()]
    [Switch]
    #whether or not to remove any existing runbooks and variables from automation account that are not source-controlled 
    $FullSync,
    [Switch]
    #whether to report missing implementation file
    #Note: it may be perfectly OK not to have implementation file, if artefact is meant to be used just in subset of environments
    $ReportMissingImplementation
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

#region Variables
if (Check-Scope -Scope $scope -RequiredScope 'Variables') {
    "Processing Automation variables"
    $definitions = @(Get-DefinitionFiles -FileType Variables)

    $CurrentVariables = Get-AutoObject -objectType Variables
    "Updating variables"
    foreach ($variable in $definitions) {
        try {
            $contentFile = Get-FileToProcess -FileType Variables -FileName $variable.Content
            if ($null -ne $contentFile) {
                "$($variable.name) managed -> updating variable from $contentFile"
                #TODO: Add support for more data types than string
                [string]$variableValue = Get-Content $contentFile -Raw
                #set value
                Add-AutoVariable -Name $variable.Name `
                    -Description $variable.description `
                    -Content $variableValue `
                    -Encrypted:$variable.Encrypted | Out-Null                
            }
            else {
                if ($ReportMissingImplementation) {
                    Write-Warning "$($variable.name)`: Missing content file, skipping variable content update"
                }
            }
        }
        catch {
            Write-Warning $_.Exception
        }
    }

    if($FullSync)
    {
        "Removing unmanaged variables"
        foreach ($variable in $currentVariables) {
            if($variable.Name -in $definitions.Name)
            {
                continue;   #variable is managged
            }
            "$($variable.name) not managed -> removing"
            Remove-AutoObject -Name $variable.Name -objectType Variables | Out-Null
        }
    }
}
#endregion Variables

#region Modules

Function GetModuleContentLink
{
    param
    (
        $moduleDefinition,
        $storageAccount,
        $storageAccountContainer
    )

    process
    {
        if(-not [string]::IsNullOrEmpty($moduleDefinition.VersionIndependentLink))
        {
            return "$($moduleDefinition.VersionIndependentLink)/$($moduleDefinition.Version)"
        }
        else
        {
            $moduleFolder = Get-ModuleToProcess -ModuleName $moduleDefinition.Name
            if([string]::IsnullOrEmpty($moduleFolder))
            {
                write-Warning "Module $($moduleDefinition.Name) does not have content link and implementation not found"
                return
            }
            if([string]::IsnullOrEmpty($storageAccount) -or [string]::IsnullOrEmpty($storageAccountContainer) )
            {
                write-Warning "Storage account and/or storage container not specified, but needed --> cannot process module $($moduleDefinition.Name)"
                return
            }
            return Get-AutoModuleUrl -modulePath $moduleFolder -storageAccount $storageAccount -storageAccountFolder $storageAccountContainer
        }
    }
}
if (Check-Scope -Scope $scope -RequiredScope 'Modules') {
    "Processing Modules"
    
    #Get requested (non-default) modules from runbook definitions
    $definitions = @(Get-DefinitionFiles -FileType Modules)

    $definitions = $definitions | Sort-Object -Property Order
    $priorities = $definitions.Order | Select-object -Unique

    $desktopModules = Get-AutoObject -objectType Modules
    $coreModules = Get-AutoPowershell7Module
    foreach($priority in $priorities)
    {
        "Batching modules processing for priority $priority"
        $modulesBatch = $definitions | Where-Object{$_.Order -eq $priority}
        $importingDesktopModules = @()
        $importingCoreModules = @()
        foreach($module in $modulesBatch)
        {
            "Processing module $($module.Name) for runtime $($module.RuntimeVersion)"
            switch($module.RuntimeVersion)
            {
                '5.1' {
                    $existingModule = $desktopModules | Where-Object{$_.Name -eq $module.Name}
                    if($existingModule.Count -eq 0 -or $existingModule[0].properties.Version -ne $module.version)
                    {
                        "Module version does not match --> importing"
                        $contentLink = GetModuleContentLink -moduleDefinition $module -storageAccount $storageAccount -storageAccountContainer $storageAccountContainer
                        "ContentLink: $contentLink"
                        if(-not [string]::IsnullOrEmpty($contentLink))
                        {
                            $importingDesktopModules+=Add-AutoModule `
                                -Name $module.Name `
                                -ContentLink $contentLink `
                                -Version $module.Version
                        }
                    }
                    else
                    {
                        "Module up to date"
                    }
                    break;
                }
                '7.2' {
                    $existingModule = $coreModules | Where-Object{$_.Name -eq $module.Name}
                    #currently, API returns "Unknown" for module version --> we always re-import
                    if($existingModule.Count -eq 0 -or $existingModule[0].properties.Version -ne $module.version)
                    {
                        "Module version does not match --> importing"
                        $contentLink = GetModuleContentLink -moduleDefinition $module -storageAccount $storageAccount -storageAccountContainer $storageAccountContainer
                        "ContentLink: $contentLink"
                        if(-not [string]::IsnullOrEmpty($contentLink))
                        {
                            $importingCoreModules+=Add-AutoPowershell7Module `
                                -Name $module.Name `
                                -ContentLink  $contentLink `
                                -Version $module.Version
                        }
                    }
                    else
                    {
                        "Module up to date"
                    }
                    break;
                }
            }
        }
        #wait for modules import completion
        $results = @()
        if($importingDesktopModules.count -gt 0)
        {
            'Waiting for import of modules for 5.1 runtime'
            $results+= Wait-AutoObjectProcessing -Name $importingDesktopModules.Name -objectType Modules
        }
        if($importingCoreModules.count -gt 0)
        {
            'Waiting for import of modules for 7.x runtime'
            $results+= Wait-AutoObjectProcessing -Name $importingCoreModules.Name -objectType Powershell7Modules
        }
        #report provisioning results
        $results  | select-object name, type, @{N='provisioningState'; E={$_.properties.provisioningState}} | Out-String
        $failed = $results | Where-Object{$_.properties.provisioningState -ne 'Succeeded'}
        if($failed.Count -gt 0)
        {
            Write-Error "Some modules failed to import"
        }
        #shall we wit for some time before importing next batch?
    }
    if($FullSync)
    {
        $runtime = '5.1'
        "Removing unmanaged modules for runtime $runtime"
        $managedModules = $definitions | Where-Object{$_.RuntimeVersion -eq $runtime}
        foreach ($module in $desktopModules) {
            if($module.Name -in $managedModules.Name)
            {
                continue;   #module is managged
            }
            if($module.properties.IsGlobal)
            {
                continue;   # we do not remove global modules
            }

            "$($module.name) for runtime $runtime not managed and not global -> removing"
            Remove-AutoObject -Name $module.Name -objectType Modules | Out-Null
        }
        $runtime = '7.2'
        "Removing unmanaged modules for runtime $runtime"
        $managedModules = $definitions | Where-Object{$_.RuntimeVersion -eq $runtime}
        foreach ($module in $coreModules) {
            if($module.Name -in $managedModules.Name)
            {
                continue;   #module is managged
            }
            if($module.properties.IsGlobal)
            {
                continue;   # we do not remove global modules
            }
            "$($module.name) for runtime $runtime not managed and not global -> removing"
            Remove-AutoPowershell7Module -Name $module.Name | Out-Null
        }
    }
}
#endregion Modules

#region Schedules
if (Check-Scope -Scope $scope -RequiredScope 'Schedules') {
    "Processing schedules"

    $definitions = @(Get-DefinitionFiles -FileType Schedules)

    $existingSchedules = Get-AutoObject -objectType Schedules

    foreach($schedule in  $definitions)
    {
        "Processing $($schedule.Name)"
        Add-AutoSchedule `
            -Name $schedule.Name `
            -StartTime $schedule.StartTime `
            -Interval $schedule.Interval `
            -Frequency $schedule.Frequency `
            -MonthDays $schedule.MonthDays `
            -WeekDays $schedule.WeekDays `
            -Description $schedule.Description `
            -Disabled:$schedule.Disabled | Out-Null
    }
    if($fullSync)
    {
        "Removing unmanaged schedules"
        $schedulesToRemove = $existingSchedules | Where-Object{$_.Name -notin $definitions.Name}
        foreach($schedule in $schedulesToRemove)
        {
            "Removing $($schedule.Name)"
            Remove-AutoObject -Name $schedule.Name -objectType Schedules | Out-Null
        }
    }
}
#endregion Schedules

#region Runbooks
if (Check-Scope -Scope $scope -RequiredScope 'Runbooks') {
    "Processing Runbooks"

    $definitions = @(Get-DefinitionFiles -FileType Runbooks)

    $existingRunbooks = Get-AutoObject -objectType Runbooks

    $importingRunbooks=@()
    foreach($runbook in $definitions)
    {
        "Processing runbook $($runbook.Name) for runtime $($runbook.RuntimeVersion)"
        $implementationFile = Get-FileToProcess -FileType Runbooks -FileName $runbook.Implementation
        if([string]::IsnullOrEmpty($ImplementationFile))
        {
            write-warning "Missing implementation file --> skipping"
            continue
        }
        switch($runbook.RuntimeVersion)
        {
            '5.1' {
                $importingRunbooks+=Add-AutoRunbook `
                    -Name $runbook.Name `
                    -Type  $runbook.Type `
                    -Content (Get-Content -Path $ImplementationFile -Raw) `
                    -Description $runbook.Description `
                    -AutoPublish:$runbook.AutoPublish
                break;
            }
            '7.2' {
                $importingRunbooks+=Add-AutoPowershell7Runbook `
                    -Name $runbook.Name `
                    -Content (Get-Content -Path $ImplementationFile -Raw) `
                    -Description $runbook.Description `
                    -AutoPublish:$runbook.AutoPublish
                break;
            }
        }
    }
    #wait for runbook import completion
    if($importingRunbooks.Count -gt 0)
    {
        'Waiting for import of runbooks'
        $results = Wait-AutoObjectProcessing -Name $importingRunbooks.Name -objectType Runbooks
        #report provisioning results
        $results | select-object name, @{N='provisioningState'; E={$_.properties.provisioningState}} | Out-String
        $failed = $results | Where-Object{$_.properties.provisioningState -ne 'Succeeded'}
        if($failed.Count -gt 0)
        {
            Write-Error "Some runbooks failed to import"
        }
    }
    if($fullSync)
    {
        "Removing unmanaged runbooks"
        foreach($runbook in $existingRunbooks)
        {
            if($runbook.Name -in $definitions.Name)
            {
                continue
            }
            "Removing $($runbook.Name)"
            Remove-AutoObject -Name $runbook.Name -objectType Runbooks | Out-Null
        }
    }
}
#endregion Runbooks

#region JobSchedules
if (Check-Scope -Scope $scope -RequiredScope 'JobSchedules') {
    "Configuring runbook job schedules"
    #process linked schedules
    $definitions = @(Get-DefinitionFiles -FileType JobSchedules)

    $alljobSchedules =  Get-AutoObject -objectType JobSchedules
    $managedSchedules = @()
    foreach($def in $definitions)
    {
        "Updating schedule $($def.scheduleName) on $($def.runbookName)"
        $jobSchedule = Add-AutoJobSchedule -RunbookName $def.runbookName `
            -ScheduleName $def.scheduleName `
            -RunOn $(if($def.runOn -eq 'Azure' -or [string]::IsnullOrEmpty($def.runOn)) {''} else {$def.runOn}) `
            -Parameters $def.Parameters
        
        $managedSchedules += $jobSchedule
    }
    if($fullSync)
    {
        foreach($jobSchedule in $alljobSchedules)
        {
            if($jobSchedule.properties.runbook.name -in $managedSchedules.properties.runbook.name -and  $jobSchedule.properties.schedule.name -in $managedSchedules.properties.schedule.name)
            {
                #schedule is managed
                continue;
            }
            "Unlinking schedule $($jobSchedule.properties.schedule.name) from runbook $($jobSchedule.properties.runbook.name)"
            Remove-AutoObject -Name $jobSchedule.Name -objectType JobSchedules
        }
    }
}
#endregion JobSchedules

#region Configurations
if (Check-Scope -Scope $scope -RequiredScope 'Configurations') {
    "Processing configurations"

    $existingConfigurations = Get-AutoObject -objectType Configurations
    $CompilationJobs = @()

    $definitions = @(Get-DefinitionFiles -FileType Configurations)

    foreach ($def in $definitions) {
        "Processing configuration $($def.Name)"
        $implementationFile = Get-FileToProcess -FileType Configurations -FileName $def.Implementation

        if ($null -eq $implementationFile) {
            write-warning "Missing implementation file --> skipping"
            continue

        }
        #import logic of DSC config
        
        "Importing Dsc: Source: $implementationFile; Compile: $($def.AutoCompile)"
        $rslt = Add-AutoConfiguration `
            -Name $def.Name `
            -Content (Get-Content -Path $implementationFile -Encoding utf8 -Raw) `
            -Description $def.Description `
            -AutoCompile:$def.AutoCompile `
            -Parameters $def.Parameters `
            -ParameterValues $def.$ParameterValues
        if($def.autoCompile)
        {
            #we received compilation job here
            $CompilationJobs+=$rslt
        }
    }
    if($CompilationJobs.Count -gt 0)
    {
        Wait-AutoObjectProcessing -Name $compilationJobs.Name -objectType Compilationjobs | select-object name, @{N='provisioningState'; E={$_.properties.provisioningState}} | Out-String
    }
    if($fullSync)
    {
        "Removing unmanaged configurations"
        foreach($configuration in $existingConfigurations)
        {
            if($configuration.Name -in $definitions.Name)
            {
                continue
            }
            "Removing $($configuration.Name)"
            Remove-AutoObject -Name $configuration.Name -objectType Configurations | Out-Null
        }
    }
}
#endregion Dsc

