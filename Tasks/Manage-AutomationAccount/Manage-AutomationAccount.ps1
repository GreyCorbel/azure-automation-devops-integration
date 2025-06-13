#read pipeline variables
Write-Host "Reading task parameters"
[char[]]$delimiters = @(',', ' ')
$scope = (Get-VstsInput -Name 'scope' -Require).Split($delimiters, [StringSplitOptions]::RemoveEmptyEntries)
$environmentName = Get-VstsInput -Name 'environmentName' -Require
$projectDir = Get-VstsInput -Name 'projectDir' -Require
$subscription = Get-VstsInput -Name 'subscription' -Require
$azureSubscription = Get-VstsInput -Name 'azureSubscription' -Require
$resourceGroup = Get-VstsInput -Name 'resourceGroup' -Require
$automationAccount = Get-VstsInput -Name 'automationAccount' -Require
$storageAccount = Get-VstsInput -Name 'storageAccount'
$storageAccountContainer = Get-VstsInput -Name 'storageAccountContainer'
$fullSync = Get-VstsInput -Name 'fullSync' -AsBool
$reportMissingImplementation = Get-VstsInput -Name 'reportMissingImplementation' -AsBool
$verboseLog = Get-VstsInput -Name 'verbose' -AsBool
$helperHybridWorkerModuleManagement = Get-VstsInput -Name 'helperHybridWorkerModuleManagement' -AsBool

if ($verboseLog) {
    Write-host "Verbose log will be enabled"
    $VerbosePreference = 'Continue'
}
Write-Host "Full sync set to $fullSync"

if ($helperHybridWorkerModuleManagement -eq $true) {
    Write-host "Helper Hybrid Worker module management is set to: $($helperHybridWorkerModuleManagement)"

    $blobNameModulesJson = "required-modules.json"
    $manageModulesPs1 = "HybridWorkerModuleManagement.ps1"
    $manageModulesPs1Path = "$($projectDir)\Helpers\HybridWorkerModuleManagement\$($manageModulesPS1)"
}
 #>#load VstsTaskSdk module
Write-Host "Installing dependencies..."
if ($null -eq (Get-Module -Name VstsTaskSdk -ListAvailable)) {
    Write-Host "VstsTaskSdk module not found, installing..."
    Install-Module -Name VstsTaskSdk -Force -Scope CurrentUser -AllowClobber
}
Write-Host "Installation succeeded!"

#load AadAuthentiacationFactory
if ($null -eq (Get-Module -Name AadAuthenticationFactory -ListAvailable)) {
    Write-Host "AadAuthenticationFactory module not found, installing..."
    Install-Module -Name AadAuthenticationFactory -Force -Scope CurrentUser
}
Write-Host "Installation succeeded!"
Import-Module AadAuthenticationFactory

Write-Host "Importing internal PS modules..."
$modulePath = [System.IO.Path]::Combine($PSScriptRoot, 'Module', 'AutomationAccount')
Write-Host "module path: $modulePath"
Import-Module $modulePath -Force -WarningAction SilentlyContinue
#load runtime support
$modulePath = [System.IO.Path]::Combine($PSScriptRoot, 'Module', 'AutoRuntime')
Write-Host "module path: $modulePath"
Import-Module $modulePath -Force -WarningAction SilentlyContinue
Write-Host "Import succeeded!"

Write-Host "Starting process..."
# retrieve service connection object
$serviceConnection = Get-VstsEndpoint -Name $azureSubscription -Require

# we support service principal with client secret or certificate, MSI, and workload identity federation
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

    if ($FullSync) {
        "Removing unmanaged variables"
        foreach ($variable in $currentVariables) {
            if ($variable.Name -in $definitions.Name) {
                continue; #variable is managged
            }
            "$($variable.name) not managed -> removing"
            Remove-AutoObject -Name $variable.Name -objectType Variables | Out-Null
        }
    }
}
#endregion Variables

#region Modules
function Upload-FileToBlob {
    param(
        [Parameter(Mandatory = $true)]
        [string]$storageAccount,
        [Parameter(Mandatory = $true)]
        [string]$storageContainerName,
        [Parameter(Mandatory = $true)]
        [string]$filePath,
        [Parameter(Mandatory = $true)]
        [string]$storageBlobName
    )
    
    begin {
        $h = Get-AutoAccessToken -ResourceUri 'https://storage.azure.com/.default' -AsHashTable
        $h['x-ms-version'] = '2023-11-03'
        $h['x-ms-date'] = [DateTime]::UtcNow.ToString('R')
        $h['x-ms-blob-type'] = 'BlockBlob'
    }
    process {
        $rsp = Invoke-RestMethod `
            -Uri "https://$($storageAccount).blob.core.windows.net/$($storageContainerName)/$($storageBlobName)" `
            -Headers $h `
            -InFile $filePath `
            -Method Put
    }
}
function Upload-ModulesForHybridWorker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$storageAccount,
        [Parameter(Mandatory = $true)]
        [string]$storageContainerName,
        [Parameter(Mandatory = $false)]
        [string]$storageBlobName,
        [Parameter(Mandatory = $true)]
        [Array]$body
    )
    begin {
        $h = Get-AutoAccessToken -ResourceUri 'https://storage.azure.com/.default' -AsHashTable
        $h['x-ms-version'] = '2023-11-03'
        $h['x-ms-date'] = [DateTime]::UtcNow.ToString('R')
        $h['x-ms-blob-type'] = 'BlockBlob'
    }
    process {

        $rsp = Invoke-RestMethod `
            -Uri "https://$($storageAccount).blob.core.windows.net/$($storageContainerName)/$($storageBlobName)" `
            -Headers $h `
            -body ($body | ConvertTo-Json)`
            -Method PUT
    }
}

function Check-CustomModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$storageAccount,
        [Parameter(Mandatory = $true)]
        [string]$storageContainerName,
        [Parameter(Mandatory = $true)]
        [string]$moduleName
    )
    begin {
        $h = Get-AutoAccessToken -ResourceUri 'https://storage.azure.com/.default' -AsHashTable
        $h['x-ms-version'] = '2023-11-03'
        $h['x-ms-date'] = [DateTime]::UtcNow.ToString('R')
        $h['x-ms-blob-type'] = 'BlockBlob'
    }
    process {
        try {
            $rsp = Invoke-RestMethod `
                -Uri "https://$($storageAccount).blob.core.windows.net/$($storageContainerName)/$($moduleName).zip" `
                -Headers $h `
                -ErrorAction Stop
        }
        catch
        {}
         
        if ($rsp) {
            return [bool]$true 
        }
        else {
            return [bool]$false
        }
    }
}

function Get-ModulesForHybridWorker {
    param(
        $definitions,
        $storageAccount,
        $storageAccountContainer
    )

    begin {
        $requiredModules = @()        
        
        # these modules will be excluded from sync by default always
        $builtInModules = @("Microsoft.PowerShell.Diagnostics", "Microsoft.WSMan.Management", "Microsoft.PowerShell.Utility", "Microsoft.PowerShell.Security", "Microsoft.PowerShell.Core")
        $builtInModules += @("Microsoft.PowerShell.Management", "GPRegistryPolicyParser", "Orchestrator.AssetManagement.Cmdlets")
        $dscModules = @("AuditPolicyDsc", "ComputerManagementDsc", "PSDscResources", "SecurityPolicyDsc", "StateConfigCompositeResources", "xDSCDomainjoin", "xPowerShellExecutionPolicy", "xRemoteDesktopAdmin", "AutomationPSModuleResource")

        $ModuleToIgnore += $builtInModules
        $ModuleToIgnore += $dscModules
    }

    process {
        # process definition files only
        foreach ($module in $definitions) {
            # we check if its custom module --> meaning there is no source URL from PS gallery defined
            if ($module.VersionIndependentLink -eq "") {
                # make sure we dont import one module twice
                [bool]$check = Check-CustomModule -storageAccount $storageAccount -storageContainerName $storageAccountContainer -moduleName $module.name 
                    
                # if exists in storage account --> get sas url only
                if ($check) {
                    $source = Get-BlobSasUrl -Permissions "r" -storageAccount $storageaccount -blobPath "$($storageAccountContainer)/$($module.name).zip"
                }
                else { # if does not exist --> upload module and get SaS URL
                    $source = GetModuleContentLink -moduleDefinition $module -storageAccount $storageAccount -storageAccountContainer $storageAccountContainer
                }
            }
            # get powershell gallery URL 
            else {
                $source = GetModuleContentLink -moduleDefinition $module -storageAccount $storageAccount -storageAccountContainer $storageAccountContainer
            }
            $requiredModules += [PSCustomObject]@{
                Name           = $module.name
                Version        = $module.version
                Source         = $source
                RuntimeVersion = $module.RuntimeVersion
            }
        }
        return $requiredModules    
    }
}

function GetModuleContentLink {
    param
    (
        $moduleDefinition,
        $storageAccount,
        $storageAccountContainer
    )

    process {
        if (-not [string]::IsNullOrEmpty($moduleDefinition.VersionIndependentLink)) {
            #we want to support custom nuget providers that have different format of URL
            if($moduleDefinition.VersionIndependentLink.Contains('{0}'))
            {
                return $moduleDefinition.VersionIndependentLink -f $moduleDefinition.Version
            }
            else
            {
                return "$($moduleDefinition.VersionIndependentLink)/$($moduleDefinition.Version)"
            }
        }
        else {
            $moduleFolder = Get-ModuleToProcess -ModuleName $moduleDefinition.Name
            if ([string]::IsnullOrEmpty($moduleFolder)) {
                write-Warning "Module $($moduleDefinition.Name) does not have content link and implementation not found"
                return
            }
            if ([string]::IsnullOrEmpty($storageAccount) -or [string]::IsnullOrEmpty($storageAccountContainer) ) {
                write-Warning "Storage account and/or storage container not specified, but needed --> cannot process module $($moduleDefinition.Name)"
                return
            }
            return Get-AutoModuleUrl -modulePath $moduleFolder -storageAccount $storageAccount -storageAccountFolder $storageAccountContainer
        }
    }
}
if (Check-Scope -Scope $scope -RequiredScope 'Modules') {
    "Processing Modules"
    
    $definitions = @(Get-DefinitionFiles -FileType Modules)

    $definitions = $definitions | Sort-Object -Property Order
    $priorities = $definitions.Order | Select-object -Unique

    foreach ($priority in $priorities) {
        "Batching modules processing for priority $priority"
        $modulesBatch = $definitions | Where-Object { $_.Order -eq $priority }
        $importingPackages = new-object System.Collections.ArrayList
        foreach ($module in $modulesBatch) {
            "Processing module $($module.Name) $($module.Version) for runtime $($module.RuntimeEnvironment)"
            try {
                $existingPackage = Get-AutoPackage -RuntimeEnvironment $module.RuntimeEnvironment -Name $module.Name -ErrorAction Stop
            }
            catch {
                Write-Warning $_
                ###[warning]{"code":"NotFound","message":"The package does not exist in runtime environment PowerShell-74. "}
                
                if ($_ -like '*NotFound*') {
                    Write-Warning "Error NotFound"
                }
                elseif ($_.Exception.Message -like '*NotFound*') {
                    Write-Warning "Error NotFound"
                }
                else {
                    Write-Warning "Uknown error"
                    throw
                }
            }

            if ($null -ne $existingPackage -and $existingPackage.properties.Version -eq $module.version) {
                "Module up to date"
                continue
            }
            "Module version does not match --> importing"
            $contentLink = GetModuleContentLink -moduleDefinition $module -storageAccount $storageAccount -storageAccountContainer $storageAccountContainer
            "ContentLink: $contentLink"
            if([string]::IsNullOrEmpty($contentLink))
            {
                Write-Warning "No content link for module $($module.Name) --> skipping"
                continue
            }
            switch ($module.RuntimeEnvironment) {
                'PowerShell-5.1' {
                    $newPackage = Add-AutoModule `
                        -Name $module.Name `
                        -ContentLink $contentLink `
                        -Version $module.Version
                    $ImportingPackages.Add($newPackage) | Out-Null
                    break;
                }
                'PowerShell-7.2' {
                    $newPackage = Add-AutoPowershell7Module `
                        -Name $module.Name `
                        -ContentLink  $contentLink `
                        -Version $module.Version
                    $ImportingPackages.Add($newPackage) | Out-Null
                    break;
                }
                default {                    
                    $newPackage =  Add-AutoPackage `
                        -Name $module.Name `
                        -RuntimeEnvironment $module.RuntimeEnvironment `
                        -ContentLink  $contentLink `
                        -Version $module.Version
                    $ImportingPackages.Add($newPackage) | Out-Null
                    break;
                }
            }
        }
        #wait for modules import completion
        
        if ($importingPackages.count -gt 0) {
            'Waiting for import of modules'
            $results = $importingPackages.ToArray()
            do
            {
                Start-Sleep -Seconds 5
                $results = @( $results | Get-AutoPackage | Where-Object {$_.properties.provisioningState -in @('Creating')} )
                "Waiting for $($results.Count) module(s) to be imported"
            }while($results.Count -gt 0)
        }
        $results = $importingPackages | Get-AutoPackage
        $results | select-object name, @{N = 'version'; E = { $_.properties.version } }, @{N = 'provisioningState'; E = { $_.properties.provisioningState } } | Out-String
        #report provisioning results
        $failed = $results | Where-Object { $_.properties.provisioningState -ne 'Succeeded' }
        if ($failed.Count -gt 0) {
            Write-Error "Some modules failed to import"
            $failed | select-object name, @{N = 'version'; E = { $_.properties.version } }, @{N = 'provisioningState'; E = { $_.properties.provisioningState } } | Out-String
        }
        #shall we wait for some time before importing next batch?

        if ([string]::IsNullOrEmpty($StorageAccount) -or [string]::IsNullOrEmpty($storageAccountContainer)) {
            continue
        }

        # using solution for sync of powershell modules between automation account and hybrid workers - if you wish to not use the solution set $helperHybridWorkerModuleManagement = $false
        if ($helperHybridWorkerModuleManagement -eq $true) {

            # process modules for hybrid workers
            $requiredModules = Get-ModulesForHybridWorker -definitions $definitions `
                -storageAccount $storageAccount `
                -storageAccountContainer $storageAccountContainer

            # upload definition file for hybrid workers to storage Account
            Upload-ModulesForHybridWorker `
                -storageAccount $storageAccount `
                -storageContainerName $storageAccountContainer `
                -body $requiredModules `
                -storageBlobName $blobNameModulesJson
            
            # upload HybridWorkerModuleManagement.ps1 to storage account
            if((Test-path -Path $manageModulesPS1Path) -eq $true)
            {
                Upload-FileToBlob `
                    -storageAccount $storageAccount `
                    -storageContainerName $storageAccountContainer `
                    -filePath $manageModulesPS1Path `
                    -storageBlobName $manageModulesPS1
            }
            else{
                "$($manageModulesPS1Path) do not exist --> skipping copy to storage account - ensure that script is available in storage account."
            }
        }
    }
    if ($FullSync) {
        $runtimeEnvironments = @($definitions | Select-Object -ExpandProperty RuntimeEnvironment -Unique | Sort-Object)
        foreach($runtimeEnvironment in $runtimeEnvironments)
        {
            "Removing unmanaged modules for runtime $($runtimeEnvironment)"
            $managedModules = $definitions | Where-Object { $_.RuntimeEnvironment -eq $runtimeEnvironment }
            $installedModules = Get-AutoPackage -RuntimeEnvironment $runtimeEnvironment | Where-Object { $_.properties.isDefault -eq $False } 
            $packagesToRemove = $installedModules | Where-Object { $_.Name -notin $managedModules.Name }
            foreach($package in $packagesToRemove)
            {
                "Removing $($package.Name) for runtime $runtimeEnvironment"
                switch($runtimeEnvironment)
                {
                    'PowerShell-5.1' {
                        Remove-AutoPackage -Name $package.Name -RuntimeEnvironment $runtimeEnvironment | Out-Null
                        break;
                    }
                    'PowerShell-7.2' {
                        Remove-AutoPowershell7Module -Name $package.Name | Out-Null
                        break;
                    }
                    default {
                        Remove-AutoPackage -Name $package.Name -RuntimeEnvironment $runtimeEnvironment | Out-Null
                        break;
                    }
                }
            }
        }
    }
}
#endregion Modules

#region Schedules
if (Check-Scope -Scope $scope -RequiredScope 'Schedules') {
    "Processing schedules"

    $definitions = @(Get-DefinitionFiles -FileType Schedules)

    $existingSchedules = Get-AutoObject -objectType Schedules

    foreach ($schedule in  $definitions) {
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
    if ($fullSync) {
        "Removing unmanaged schedules"
        $schedulesToRemove = $existingSchedules | Where-Object { $_.Name -notin $definitions.Name }
        foreach ($schedule in $schedulesToRemove) {
            "Removing $($schedule.Name)"
            Remove-AutoObject -Name $schedule.Name -objectType Schedules | Out-Null
        }
    }
}
#endregion Schedules

#region Runbooks
if (Check-Scope -Scope $scope -RequiredScope 'Runbooks') {
    "Processing Runbooks"

    "Getting installed runbooks"
    $installedRunbooks = Get-AutoObject -objectType Runbooks
    "$($installedRunbooks.Count) runbooks installed"

    $definitions = @(Get-DefinitionFiles -FileType Runbooks)

    $importingRunbooks = new-object System.Collections.Generic.List[PSCustomObject]
    foreach ($runbook in $definitions) {
        switch($runbook.RuntimeEnvironment)
        {
            {$_ -in '5.1','PowerShell-5.1'} { $runbook.RuntimeEnvironment = 'PowerShell-5.1'; break}
            {$_ -in '7.2','PowerShell-7.2'} { $runbook.RuntimeEnvironment = 'PowerShell-7.2'; break }
        }

        "Processing runbook $($runbook.Name) for runtime $($runbook.RuntimeEnvironment)"
        $implementationFile = Get-FileToProcess -FileType Runbooks -FileName $runbook.Implementation
        if ([string]::IsnullOrEmpty($ImplementationFile)) {
            write-warning "Missing implementation file --> skipping"
            continue
        }
        $installedRunbook = $installedRunbooks | Where-Object { $_.Name -eq $runbook.Name}
        if($null -ne $installedRunbook -and $installedRunbook.properties.RuntimeEnvironment -ne $runbook.RuntimeEnvironment) {
            "Runbook $($runbook.Name) has different runtime environment ($($installedRunbook.properties.RuntimeEnvironment) : $(($runbook.RuntimeEnvironment)))--> removing runbook before updating"
            Remove-AutoObject -Name $runbook.Name -objectType Runbooks | Out-Null
        }
        $runbook = Add-AutoRunbook -Name $runbook.Name `
            -Type $runbook.Type `
            -RuntimeEnvironment $runbook.RuntimeEnvironment `
            -Content (Get-Content -Path $ImplementationFile -Raw) `
            -Description $runbook.Description `
            -AutoPublish:$runbook.AutoPublish `
            -Location $runbook.Location
        $importingRunbooks.Add($runbook) | Out-Null
    }

    #wait for runbook import completion
    if ($importingRunbooks.Count -gt 0) {
        'Waiting for import of runbooks'
        $results = Wait-AutoObjectProcessing -Name $importingRunbooks.Name -objectType Runbooks
        #report provisioning results
        $results | select-object name, @{N = 'provisioningState'; E = { $_.properties.provisioningState } } | Out-String
        $failed = $results | Where-Object { $_.properties.provisioningState -ne 'Succeeded' }
        if ($failed.Count -gt 0) {
            Write-Error "Some runbooks failed to import"
        }
    }

    if ($fullSync) {
        $allRunbooks = Get-AutoObject -objectType Runbooks
        #if runbook from definition is not on server then delete:
        $runbooksToRemove = $allRunbooks | Where-Object { $_.Name -notin $definitions.Name }
        foreach($runbook in $runbooksToRemove)
        {
            "Removing $($runbook.Name) for runtime $($runtimeEnvironment.Name)"
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

    $alljobSchedules = Get-AutoObject -objectType JobSchedules
    $allSchedules = Get-AutoObject -objectType Schedules
    $existingRunbooks = Get-AutoObject -objectType Runbooks

    Write-Host "Removing obsolite JobSchedules to update all JobSchedules parameters..."

    # delete all JobSchedule, REST API missing update method...
    foreach ($jobSchedule in $alljobSchedules) {
        Write-Host "Removing jobSchedule: $($jobSchedule.properties.jobScheduleId)"
        Remove-AutoObject -Name $jobSchedule.properties.jobScheduleId -objectType JobSchedules
    }

    Write-Host "Removing done. Creating..."

    $managedSchedules = @()
    foreach ($def in $definitions) {
        "Checking runbook existence: $($def.runbookName)"
        if (-not ($existingRunbooks.Name -contains $def.runbookName)) {
            Write-Warning "Runbook $($def.runbookName) does not exist --> skipping job schedule"
            continue
        }
        "Checking schedule existence: $($def.scheduleName)"
        if (-not ($allSchedules.Name -contains $def.scheduleName)) {
            Write-Warning "Schedule $($def.scheduleName) does not exist --> skipping job schedule"
            continue
        }

        $params = @{}
        if (-not [string]::IsNullOrEmpty($def.Settings)) {
            $settingsFile = Get-FileToProcess -FileType JobSchedules -FileName $def.Settings
            if ([string]::IsnullOrEmpty($settingsFile)) {
                write-warning "Missing setting file $($def.Settings) --> skipping"
                continue
            }
            $setting = get-content $settingsFile -Encoding utf8 | ConvertFrom-Json
            if (-not [string]::IsNullOrEmpty($setting.Parameters)) { 
                #converting pamaters object to hashtable
                foreach($param in $setting.Parameters.PSObject.Properties) {
                    $params[$param.Name] = $param.Value
                }
            }
            Write-Host "Checking JobSchedules params :"
            $params
        }
        "Updating schedule $($def.scheduleName) on $($def.runbookName)"
        $jobSchedule = Add-AutoJobSchedule -RunbookName $def.runbookName `
            -ScheduleName $def.scheduleName `
            -RunOn $(if ($setting.runOn -eq 'Azure' -or [string]::IsnullOrEmpty($setting.runOn)) { '' } else { $setting.runOn }) `
            -Parameters $params
        
        $managedSchedules += $jobSchedule
    }

    if ($fullSync) {
        "Removing unmanaged job schedules"
        foreach ($jobSchedule in $alljobSchedules) {
            $result = $managedSchedules `
            | Where-Object { $_.properties.runbook.name -eq $jobSchedule.properties.runbook.name } `
            | Where-Object { $_.properties.schedule.name -eq $jobSchedule.properties.schedule.name }

            if ($null -ne $result) {
                #schedule is managed
                continue;
            }
            else {
                "Unlinking schedule $($jobSchedule.properties.schedule.name) from runbook $($jobSchedule.properties.runbook.name)"
                Remove-AutoObject -Name $jobSchedule.properties.jobScheduleId -objectType JobSchedules
            }
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
        
        # take definition file for parameter values for current environment
        $configParamValuesDef = Get-DefinitionFiles -FileType "ConfigurationParameterValues"|Where-Object{$_.ConfigurationName -eq $def.Name}
        $filePath = Get-FileToProcess -FileType ConfigurationParameterValues -FileName $configParamValuesDef.Content
        $paramValues = (Get-Content -Path $filePath)|ConvertFrom-Json
        
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
            -ParameterValues $paramValues
        if ($def.autoCompile) {
            #we received compilation job here
            $CompilationJobs += $rslt
        }
    }
    if ($CompilationJobs.Count -gt 0) {
        Wait-AutoObjectProcessing -Name $compilationJobs.Name -objectType Compilationjobs | select-object name, @{N = 'provisioningState'; E = { $_.properties.provisioningState } } | Out-String
        # get config to assign
        "Retrieving config to assign"
        $configToAssign = Get-DscNodeConfiguration -Subscription $Subscription -ResourceGroup $resourceGroup -AutomationAccount $automationAccount |`
            Where-object { $_.properties.configuration.name -eq $CompilationJobs.properties.configuration.name }
    
        # get nodes 
        "Retrieving nodes"
        $nodes = Get-DscNodes -Subscription $Subscription -ResourceGroup $resourceGroup -AutomationAccount $automationAccount
        if($nodes.id.count -gt 0)
        {
            # assign compiled config to nodes
            foreach ($node in $nodes) {
                "Assigning $($configToassign.name) to $($node.name)"
                $rslt = Assign-DscNodeConfig -Subscription $Subscription -ResourceGroup $resourceGroup -AutomationAccount $automationAccount -NodeConfigId $configToAssign.name -NodeName $node.properties.nodeId
                "Configuration assigned"
               
            }
        }else{
            "No DSC nodes are registered, therefore skipping assignment."
        }
    }
    if ($fullSync) {
        "Removing unmanaged configurations"
        foreach ($configuration in $existingConfigurations) {
            if ($configuration.Name -in $definitions.Name) {
                continue
            }
            "Removing $($configuration.Name)"
            Remove-AutoObject -Name $configuration.Name -objectType Configurations | Out-Null
        }
    }
}
#endregion Dsc


if ($verboseLog) {
    $VerbosePreference = 'SilentlyContinue'
}
