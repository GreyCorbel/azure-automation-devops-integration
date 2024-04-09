<#
.SYNOPSIS
This script is created for purpose of PowerShell Module Sync between Automation Account and hybrid workers.
.DESCRIPTION
Script works in the following way: 
    1) File with required modules is created as part of deployment and stored to Azure Storage Account
    2) Hybrid Worker retrieves required modules json from Storage Account and compares module definitions with locally installed modules
    3) Installation / Upgrade / Downgrade is performed based on comparison results
    4) Compliance status per hybrid worker is stored to the same container
#>

param(
    [Parameter(Mandatory=$true)]    
    [string]$blobNameModulesJson,

    [Parameter(Mandatory=$true)]
    [string]$storageAccountContainer,

    [Parameter(Mandatory=$true)]
    [string]$storageAccount,

    [Parameter(Mandatory=$true)]
    [ValidateSet("arc", "vm")]
    [string]$machineType
)

#################
## Variables  
#################

$script:scriptRoot = $(Split-Path -Parent $MyInvocation.MyCommand.Path)
$script:scriptName = $MyInvocation.MyCommand.Name
$script:scriptPath = Join-path $scriptRoot $scriptName
$script:runTimeVersion = $PSVersionTable.PSVersion.Major
$script:LogFile = Join-Path $scriptRoot "Manage-PS-$($runTimeVersion)Modules-$(Get-date -Format yyyy-MM-dd).log"
$script:newContent = @()
$script:installedmodules = @()
$script:reinstalledModules = @()
$script:blobPathModules = "$($storageAccountContainer)/$($blobNameModulesJson)"
$script:blobPathCompliance = "$($storageAccountContainer)/$($env:COMPUTERNAME)-PS-$($runTimeVersion)-modules-compliance.json" 
$script:storageAccount = $storageAccount
$script:machineType = $machineType

# (optional) - define extra repositories on top of powershell gallery if required or keep empty
# $script:repositories = @{
#     "NAME_OF_REPO"  = "URL_TO_REPO"
# }

$script:builtinModulesToIgnore = @(

    "Microsoft.PowerShell.Core",
    "Pester",
    "PSReadline",
    "PowerShellGet",
    "AppLocker",
    "AppvClient",
    "AppBackgroundTask",
    "Microsoft.PowerShell.Operation.Validation"
    "PackageManagement",
    "PSDesiredStateConfiguration",
    "ServiceSet",
    "WindowsFeatureSet",
    "WindowsOptionalFeatureSet",
    "ProcessSet",
    "GroupSet"
)


#################
## Functions   
#################

#logging functions
function Remove-OldLogs
{
    Write-Log "Checking if any logs are older than 14days and needs to be deleted"
    $AllLogs = Get-ChildItem -Path $scriptRoot|Where-Object {$_.Extension -eq ".log"}
    foreach($logfile in $AllLogs)
    {
        $result = (Get-Date) - $logfile.lastWriteTime
        if($result.Days -ge 14)
        {
            Write-Log "$($logfile) is older than 14days therefore will be removed"
            try
            {
                Write-log "Trying to remove $($logfile.FullName)"
                Remove-Item -Path ($logfile.Fullname) -Force
                Write-log "$($logfile.FullName) was removed"
                $tobeDeleted +=1
            }
            catch
            {
                Write-log "$($logfile.FullName) was not removed, because: $($_.exception.message)" -LogLevel Error
            }
        }
    }
    if ($null -eq $tobeDeleted)
    {
        Write-Log "No log files are older than 14 days, therefore no clean up will be performed"
    }
}

function Start-Log
{
    [CmdLetBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({ Split-Path $_ -Parent | Test-Path })]
        [String]$Path
    )
    try 
    {
        if ( -not (Test-Path $Path)) 
        {
            New-Item $Path -Type File | Out-Null
        }   
        $Script:ScriptLogFilePath = $Path
    }
    catch 
    {
        Write-Error $_.Exception.Message    
    }
}
function Write-Log
{
    [CmdLetBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [String]$Message,
        [Parameter(Mandatory = $false)]
        [ValidateSet("Informational", "Warning", "Error")]
        [String]$LogLevel = "Informational"
    )

    $Level = 1

    switch ($LogLevel)
    {

        "Informational" { Write-Host ("{0} - {1}" -f (Get-Date), $Message) }
        "Warning" { $Level = 2; Write-Host ("{0} - {1}" -f (Get-Date), $Message) -ForeGroundColor Yellow}
        "Error" { $Level = 3; Write-Host ("{0} - {1}" -f (Get-Date), $Message) -ForeGroundColor Red}

    }
    $TimeGenerated = "{0:HH:mm:ss.fff}+000" -f (Get-Date)
    $LogLine = "$TimeGenerated - $LogLevel - $Message"

    while ($true)
    {
        try 
        {
            Add-Content -Value $LogLine -Path $Script:ScriptLogFilePath -Force -ErrorAction Stop
            break
        }
        catch 
        {
            $RetryTimeoutInMilliseconds = 450
            Write-Host ("Error writing to log file, retrying in {0} milliseconds" -f $RetryTimeoutInMilliseconds) -ForegroundColor Yellow
            Start-Sleep -Milliseconds $RetryTimeoutInMilliseconds
        }
    }    
}

function Manage-ModuleComplianceJson
{
    param(
        [Parameter(Mandatory = $true)]
        [string]$storageAccount,
        [Parameter(Mandatory = $false)]
        [string]$blobPathCompliance,
        [Parameter(Mandatory = $false)]
        [Array]$body,
        [Parameter(Mandatory = $true)]
        [ValidateSet("GET","PUT")]
        [string]$action
    )
    begin
    {
        $h = Get-Token -resourceUrl "https://storage.azure.com" -machineType $machineType
    }
    process
    {
        switch($action)
        {
            "GET"
            {
                $rsp = Invoke-RestMethod -Uri "https://$($storageAccount).blob.core.windows.net/$($blobPathCompliance)"  -Headers $h -Method GET
            }

            "PUT"
            {
                $h['x-ms-blob-type'] = 'BlockBlob'
                $rsp = Invoke-RestMethod -Uri "https://$($storageAccount).blob.core.windows.net/$($blobPathCompliance)"  -Headers $h  -body $body  -Method PUT
            }
        }
        $rsp
    }
}
function Test-PSInstallation 
{
    param(
    $executable
    )
    begin
    {
        $executable = $executable+".exe"  
        $envPaths = $env:PATH.Split(';')  
    }

    process
    {
        $envPaths = $env:PATH.Split(';')  
        
        foreach($path in $envPaths)
        {
            $executablePath = Join-Path $path $executable 
            if (Test-Path $executablePath) {
                return $executablePath
               
            }
        }
    }
}

function Get-Token
{
    param(
        $resourceUrl,
        [ValidateSet("vm","arc")]
        $machineType
    )
    switch($machineType)
    {
        "vm"
        {
            $resourceUrl = [Uri]::EscapeUriString($resourceUrl)
            $baseUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$resourceUrl"
            $token = (Invoke-RestMethod -Uri $baseUri -Headers @{ Metadata = "true" }).access_token
            $h = @{}
            $h.Add("Authorization","Bearer $($token)")
            $h.Add("x-ms-version","2017-11-09")
            $h.Add("Accept","application/json")
            return $h
        }
        "arc"
        {
            $apiVersion = '2019-11-01'
            $baseUri = 'http://localhost:40342/metadata/identity/oauth2'
            $encodedResource = $resourceUrl
            $uri = "$baseUri/token?api-version=$apiVersion`&resource=$encodedResource"

            try{
                Invoke-WebRequest `
                    -UseBasicParsing `
                    -Uri $uri `
                    -Headers @{ Metadata = "true"} `
                    -ErrorAction Stop
            }
            catch{
                $response= $_.Exception.Response
            }
            # Extract the path to the secret file
            $header = $response.Headers.Where{$_.Key -eq 'WWW-Authenticate'}

            $secretPath = $header.value.TrimStart("Basic realm=")

            # Read the token
            $secret= Get-Content $secretPath -Raw
            # Acquire Access Token
            $token= Invoke-RestMethod `
                -Uri "$baseUri/token?api-version=$apiVersion&resource=$encodedResource" `
                -Headers @{ Metadata = "true"; Authorization = "Basic $secret"} `
                -ErrorAction Stop
            $h = @{}
            $h.Add("Authorization","Bearer $($token)")
            $h.Add('x-ms-version','2023-11-03')
            $h.Add('x-ms-date',[DateTime]::UtcNow.ToString('R'))
            return $h
        }
    }
        
}
function Get-ModulesToProcess
{
    param(
        [Parameter(Mandatory = $true)]
        [string]$storageAccount,
        [Parameter(Mandatory = $true)]
        [string]$blobPath
        
    )
    begin
    {
        $h = Get-Token -resourceUrl "https://storage.azure.com" -machineType $machineType
    }
    process
    {

    $rsp = Invoke-RestMethod `
        -Uri "https://$storageAccount`.blob.core.windows.net/$blobPath" `
        -Headers $h 
    $rsp
    }
}

function Compare-Modules
{
    param(
    
        $localModules,
        $requiredModules
    )

    begin
    {
        $overview = [PSCustomObject]@{
            uninstall = @()
            install = @()
            diffVersion = @()
        }
    }

    process
    {

        # check which module should be uninstalled 
        foreach ($module in $localModules)
        {
            if($module.Name -notin $requiredModules.Name)
            {
                $overview.uninstall += $module.Name
            }
        }

        # check which module should be installed
        foreach($module in $requiredModules|Where-Object {$_.Name -notin @('Az')})
        {
            if($module.Name -notin $localModules.Name)
            {
                $overview.install += @{"name"="$($module.Name)";"version"=$($module.Version);"Source" = $($module.source)}
            }
            else
            {
                #if module is installed, compare version 
                if($module.Version -ne ($localModules|Where-Object{$_.Name -eq $module.Name}).version)
                {
                    Write-Log "$($module.name) is installed but has different version $($module.version) from required and $(($localModules|Where-Object{$_.Name -eq $module.Name}).version) from local" 
                    $overview.diffVersion += @{"name"=$module.Name;"currentVersion"=$(($localModules|Where-Object{$_.Name -eq $module.Name}).version);"requiredVersion"= $module.Version;"Source" = $($module.source)}
                }

            }
           
        }        
        return $overview
    }
}

function Ensure-Repositories
{
    param(
        $repositories
    )
    foreach ($repositoryName in $repositories.Keys)
    {
        $sourceLocation = $repositories[$repositoryName]

        if (-not (Get-PSRepository -Name $repositoryName -ErrorAction SilentlyContinue))
        {
            Register-PSRepository -Name $repositoryName -SourceLocation $sourceLocation -InstallationPolicy Trusted
        }
        else
        {
            "$repositoryName registered - no action"
        }

        #make sure default repo is available
        if (-not (Get-PSRepository -Name "PSGallery"))
        {
            Register-PSRepository -Default
        }
    }
    
}

function Manage-CustomModule
{
    [CmdLetBinding()]
    param(
        $module,
        [ValidateSet("Install","Reinstall")]
        $action,
        $runTimeVersion
    )

    switch($action)
    {
        "Install"
        {
            try
            {
                Write-Log "Installing $($module.Name)" 
            
                $zipFilePath = "$($env:temp)\$($module.name).zip"
                Write-Log "Retrieveing source file :$($module.source)"
                Invoke-RestMethod -Uri $module.source -OutFile $zipFilePath
            
                $extractPath = "$($env:temp)\"
                Write-Log "Extracting module to $($extractPath)"
                Expand-Archive -Path $zipFilePath -DestinationPath $extractPath -Force 
                switch($runTimeVersion)
                {
                    "5"
                    {
                        $installPath = Join-Path -Path "$env:ProgramFiles\WindowsPowerShell\Modules" -ChildPath "$($module.name)"
                        Write-Log "Creating new folder under $($installPath)"
                        New-Item -Path $installPath -ItemType Directory -Force | Out-Null
                    
                    }
                    "7"
                    {
                        $installPath = Join-Path -Path "$env:ProgramFiles\PowerShell\Modules" -ChildPath "$($module.name)"
                        Write-Log "Creating new folder under $($installPath)"
                        New-Item -Path $installPath -ItemType Directory -Force | Out-Null
                    }
                }
            
                Write-Log "Renaming file $($env:temp)\$($module.name) to $($module.version)"
                Rename-Item -Path "$($env:temp)\$($module.name)" -NewName $module.version -Force
            
                Write-Log "Moving file to $($installPath)"
                Move-Item -Path "$($env:temp)\$($module.version)" -Destination $installPath -Force
            
                Remove-Item -Path $zipFilePath -Force
            }
            catch
            {
                Write-log "$($_.exception.message)" -LogLevel Error
                Remove-Item -Path $zipFilePath -Force
                Remove-item -Path $installPath -Force
                Remove-item -Path "$($env:temp)\$($module.version)" -Force -Recurse
            }

            $module = Get-module -ListAvailable $module.name
            if($null -ne $module)
            {
               Write-log "Module: $($module.name) installed."
              
            }
            else
            {
                Write-Log "Module:  $($module.name) installation failed." -LogLevel Error
                throw  "Module:  $($module.name) installation failed."
                
            }
        }
        "Reinstall"
        {
            # remove old version of custom module
            Write-Log "Installing $($module.Name) - overwriting version $($module.currentVersion), with: $($module.requiredVersion)"
            $moduleLocals = Get-module -ListAvailable $($module.name)|Where-Object{$_.version -ne $module.requiredVersion}
            foreach($moduleLocal in $moduleLocals)
            {
                if($moduleLocal.path)
                { 
                    Remove-Item -Path $(Join-Path (($moduleLocal.path) -Split($($moduleLocal.name)))[0] -ChildPath $($moduleLocal.name)) -Force -Recurse -Confirm:$false
                }
                else
                {
                    Write-log "$($module.name) do not exist, exiting uninstallation"
                    return
                }
            }
           
            # install new version
            try
            {
                Write-Log "Installing $($module.Name) from $($repo.Name) - overwriting version $($module.currentVersion), with: $($module.requiredVersion)"
                $zipFilePath = "$($env:temp)\$($module.name).zip"
                Write-Log "Retrieving source file :$($module.source)"
                Invoke-RestMethod -Uri $module.source -OutFile $zipFilePath
            
                $extractPath = "$($env:temp)\"
                Write-Log "Extracting module to $($extractPath)"
                Expand-Archive -Path $zipFilePath -DestinationPath $extractPath -Force 
            
                switch($runTimeVersion)
                {
                    "5"
                    {
                        $installPath = Join-Path -Path "$env:ProgramFiles\WindowsPowerShell\Modules" -ChildPath "$($module.name)"
                        Write-Log "Creating new folder under $($installPath)"
                        New-Item -Path $installPath -ItemType Directory -Force | Out-Null
                    
                    }
                    "7"
                    {
                        $installPath = Join-Path -Path "$env:ProgramFiles\PowerShell\Modules" -ChildPath "$($module.name)"
                        Write-Log "Creating new folder under $($installPath)"
                        New-Item -Path $installPath -ItemType Directory -Force | Out-Null
                    }
                }
            
                Write-Log "Renaming file $($env:temp)\$($module.name) to $($module.requiredVersion)"
                Rename-Item -Path "$($env:temp)\$($module.name)" -NewName $module.requiredVersion -Force
            
                Write-Log "Moving file to $($installPath)"
                Move-Item -Path "$($env:temp)\$($module.requiredVersion)" -Destination $installPath -Force
            
                Remove-Item -Path $zipFilePath -Force
            }
            catch
            {
                Write-log "$($_.exception.message)" -LogLevel Error
                Remove-Item -Path $zipFilePath -Force
                Remove-item -Path $installPath -Force
                Remove-item -Path "$($env:temp)\$($module.version)" -Force
            }

            $module = Get-module -ListAvailable $module.name
            if($null -ne $module)
            {
               Write-log "Module: $($module.name) installed."
              
            }
            else
            {
                Write-Log "Module:  $($module.name) installation failed." -LogLevel Error
                throw  "Module:  $($module.name) installation failed."
            }
        }
    }
}

function Manage-GalleryModule
{
    [CmdLetBinding()]
    param(
        $module,
        [ValidateSet("Install","Reinstall")]
        $action,
        $repos,
        $runTimeVersion
    )

    process
    {
        switch($action)
        {
            "Install"
            {
                foreach($repo in $repos)
                {
                  
                    Write-Log "Installing $($module.Name) from $($repo.Name) with version $($module.version)"
                    Install-Module -Name $module.Name -RequiredVersion $module.Version -AllowClobber -SkipPublisherCheck -Force -ErrorAction Stop -Repository $repo.Name -Verbose -Scope AllUsers
                    
                    $testModule = (Get-Module -ListAvailable $module.name|Where-Object{$_.Version -eq $module.Version})
                    if ($null -ne $testModule)
                    {
                        Write-Log "Module: $($module.name) installed."
                        break
                    }
                    else
                    {
                        Write-Log "Module:  $($module.name) installation failed." -LogLevel Error
                      
                    }
                }
            } 
            "Reinstall"
            {
                switch($runTimeVersion)
                {
                    "7"{ $modulePath = "*\Powershell\*"}
                    "5"{ $modulePath = "*\WindowsPowershell\*"}
                }
                foreach($repo in $repos)
                {
                    # if required version > current version we use update-module
                    if($module.requiredVersion -gt $module.currentVersion)
                    {
                        Write-Log "Re-installing (upgrading) $($module.Name) from $($repo.Name) - overwriting version $($module.currentVersion), with: $($module.requiredVersion)"
                        switch($runTimeVersion)
                        {
                            "7"
                            {
                                Update-Module -name $module.name -RequiredVersion $module.requiredVersion -Force -confirm:$false -Verbose -scope AllUsers
                            }
                            "5"
                            {
                                Update-Module -name $module.name -RequiredVersion $module.requiredVersion -Force -confirm:$false -Verbose 
                            }
                        }
                        #remove old versions
                        $modulesToRemove = Get-module -ListAvailable $module.Name|Where-Object{$_.Version -ne $module.requiredVersion}
                        $modulesToRemove = ($modulesToRemove|Where-Object{$_.path -like $modulePath})
                        if($modulesToRemove.count -gt 0)
                        {
                            foreach($moduleToRemove in $modulesToRemove)
                            {
                                $path = ($moduleToRemove.path.split("\")|Select-Object -SkipLast 1)-join "\"
                                try {
                            
                                    Write-log "Removing old version of: $($moduleToRemove.name), path: $($path)"
                                    Remove-item $path -Force -Confirm:$false -Recurse
                                }
                                catch {
                                    Write-log "Error during removal of old version $($path) : $($_.exception.message)" -LogLevel Error
                                }
                            }
                        }
                        else
                        {
                            Write-log "No old versions to uninstall."
                        }
                    }
                    # if required version < current version we -force remove folder locally
                    else
                    {
                        Write-Log "Re-installing (downgrading) $($module.Name) from $($repo.Name) - overwriting version $($module.currentVersion), with: $($module.requiredVersion)"
                        $modulesToRemove = Get-module -ListAvailable $module.Name|Where-Object{$_.Version -ne $module.requiredVersion}
                        $modulesToRemove = ($modulesToRemove|Where-Object{$_.path -like $modulePath})
                        if($modulesToRemove.count -gt 0)
                        {
                            foreach($moduleToRemove in $modulesToRemove)
                            {
                                $path = ($moduleToRemove.path.split("\")|Select-Object -SkipLast 1) -join "\"
                                try {
                                    Write-log "Removing old version of: $($moduleToRemove.name), path: $($path)"
                                    Remove-item $path -Force -Confirm:$false -Recurse
                                }
                                catch {
                                    Write-log "Error during removal of old version $($path) : $($_.exception.message)" -LogLevel Error
                                }
                            }
                        }
                        else 
                        {
                            Write-log "No old versions to uninstall."
                        }

                        Install-Module -Name $module.Name -RequiredVersion $module.requiredVersion -AllowClobber -SkipPublisherCheck -Force -ErrorAction Stop -Repository $repo.Name -Verbose -Scope AllUsers
                        $testModule = (Get-Module -ListAvailable $module.name|Where-Object{$_.Version -eq $module.Version})
                    }
                    Write-log "Checking if new version was installed"
                    $testModule = (Get-Module -ListAvailable $module.name|Where-Object{$_.Version -eq $module.requiredVersion})
                    if ($null -ne $testModule)
                    {
                        Write-Log "Module: $($module.name) installed in path $($testmodule.path)"
                        break
                    }
                    else
                    {
                        Write-Log "Module:  $($module.name) installation failed" -LogLevel Error
                        continue
                
                    }
                }
            }
        }
    }
}
function Prepare-ComplianceStatus
{
    param(
        $currentContent,
        $overview
    )
    begin
    {
        $newContent = @()
    }
    process
    {
        if([string]::IsNullOrEmpty($currentcontent) -eq $false)
        {
            $thresholdDate = (Get-Date).AddDays(-3)
            $currentContent = $currentContent | Where-Object { [DateTime]::Parse($_.($env:COMPUTERNAME).LastChecked) -ge $thresholdDate }
            $newContent += $currentContent
            $newContent += $overview
        }
        else
        {
            $newContent = $overview
        }
        return $newContent
    }
}

function Prepare-Overview
{
    if($installedModules.count -gt 0 -or $reinstalledModules.count -gt 0 -or $failedInstallation.count -gt 0)
    {
        Write-Log "Overview after  -- $($installedModules.count) installed, $($reinstalledModules.count) reinstalled, $($failedInstallation.count) failed"
        $overview = [PSCustomObject]@{

            $env:COMPUTERNAME = @{
                LastChecked =   (Get-date -Format 'yyyy-MM-dd HH:mm:ss ').ToString() 
                WasCompliant = $false
                Details = @{
                    InstalledModules = @($installedModules)
                    ReInstalledModules = @($reinstalledModules)
                    FailedInstallation  = @($failedInstallation)
                }
            }
        }
    }
    else
    {
        Write-Log "No updates to modules, exiting."
        $overview = [PSCustomObject]@{

            $env:COMPUTERNAME = @{
                LastChecked =   (Get-date -Format 'yyyy-MM-dd HH:mm:ss ').ToString() 
                WasCompliant = $true
                Details = $null
            }
        }
    }
    $overview
}

#################
## Main Execution   
#################
Start-Log -Path $LogFile
$user = &whoami
Write-Log "RuntimeVersion: $($runTimeVersion)| server: $($env:COMPUTERNAME)| user: $($user)"

# Ensure repose are mapped
Ensure-Repositories -repositories $repositories

try
{  
    # Get all modules
    Write-log "Retrieving module info from $storageAccount/$($blobPathModules)"
    $requiredModules = Get-ModulesToProcess -storageAccount $storageAccount -blobpath $blobPathModules
}
catch
{
    Write-log  "Error retrieving modules from blob $($_.exception.message)" -Loglevel Error
    exit
}

# Compare modules
$modules = Compare-Modules -localModules $(Get-Module -ListAvailable|Where-Object{$_.Name -notin $builtInModulesToIgnore} |Select-Object -Unique) -requiredModules ($requiredModules|Where-Object{$_.RunTimeVersion -like "$($runTimeVersion)*"})
Write-Log "Overview after comparison  -- $($modules.install.count) to be installed, $($modules.diffversion.count) to be reinstalled"

# Install modules that are required
if($modules.install.count -eq 0)
{
    Write-Log "No modules to install - worker is compliant."
}
else
{
    # get repositories from which we try to install
    $repos = $(Get-PSRepository)
    # We intentially remove all the modules from session to make sure there is no dependency issue
    Get-module|Where-object{$_.name -notin($builtinModulesToIgnore)}|Remove-Module -Confirm:$false -force 
    foreach($module in $modules.install)
    {
        if($module.source -like "*$($storageAccount)*")
        {
            try
            {
                Manage-CustomModule -module $module -action Install -runTimeVersion $runTimeVersion -ErrorAction Stop
                $installedModules += $module.name
            }
            catch
            {
                Write-Log "Error during installation: $($_.exception.message)" -LogLevel Error
                $failedInstallation += $module.Name
                continue
            }
        }
        else
        {
            try
            {
                Manage-GalleryModule -module $module -action Install -repos $repos -runTimeVersion $runTimeVersion -ErrorAction Stop
                $installedModules += $module.name
            }
            catch
            {
                Write-Log "Module:  $($module.name) installation failed $($_.exception.message)" -LogLevel Error
                $failedInstallation += $module.Name
                continue
            }
        }
    }
}
# Re-install modules that have different version
if($modules.diffversion.count -eq 0)
{
    Write-Log "No modules to re-install - worker is compliant."
}
else
{
    # get repositories from which we try to install
    $repos = $(Get-PSRepository)
    # We intentially remove all the modules from session to make sure there is no dependency issue
    Get-module|Where-object{$_.name -notin($builtinModulesToIgnore)}|Remove-Module -Confirm:$false -force
    foreach($module in $modules.diffVersion)
    {
        if($module.source -like "*$($storageAccount)*")
        {
            try
            {
                Manage-CustomModule -module $module -action Reinstall -runTimeVersion $runTimeVersion -ErrorAction Stop
                $reinstalledModules += $module.name
            }
            catch
            {
                Write-Log "Error during reinstallation: $($_.exception.message)" -LogLevel Error
                $failedInstallation += $module.Name
                continue
            }
        }
        else
        {
            try
            {
                Manage-GalleryModule -module $module -action Reinstall -repos $repos -runTimeVersion $runTimeVersion -ErrorAction Stop
                $reinstalledModules += $module.name
            }
            catch
            {
                Write-Log "Module:  $($module.name) reinstallation failed, $($_.exception.message)" -LogLevel Error
                $failedInstallation += $module.Name
                continue
            }
        }
    }
}

# get overview after installation
$overview = Prepare-Overview 

try
{
    # Get current compliance status
    $currentContent = Manage-ModuleComplianceJson -storageAccount $storageAccount -blobPathCompliance $blobPathCompliance -action GET
}
catch
{
    if($_ -like '*blob does not exist*')
    {
        Write-Log "Blob does not exist, creating one"
        Manage-ModuleComplianceJson -storageAccount $storageAccount -blobPathCompliance $blobPathCompliance -action PUT -body ""
        Write-Log "Uploading file to container"
        $currentContent = Manage-ModuleComplianceJson -storageAccount $storageAccount -blobPathCompliance $blobPathCompliance -action GET
    }
    else
    {
        Write-Log "Error during blob retrieval: $($_.exception.message)"
    }   
}

# prepare compliance status before upload
$newContent = Prepare-ComplianceStatus -currentContent $currentContent -overview $overview

try
{
    # upload file to container
    Write-Log "Uploading compliance status"
    Manage-ModuleComplianceJson -storageAccount $storageAccount -blobPathCompliance $blobPathCompliance -action PUT -body ($newContent|ConvertTo-Json -Depth 99)
    Write-log "Upload completed"
}
catch
{
    "Error uploading json to blob $($_.exception.message)"
}

# check if there are any logs older than 14 days. 
Remove-OldLogs