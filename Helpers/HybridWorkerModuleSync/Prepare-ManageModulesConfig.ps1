<#
.SYNOPSIS
This script to create DSC configuration and upload Manage-Modules.ps1 script
1) Script Manage-Modules.ps1 
It downloads ps1 file from defined AzureStorage Location as well as create scheduled task for hybrid worker module management. 
On top of these two main actions, you can add as many other actions as you need for management of your hybrid worker.
#>

Configuration ManageModulesConfig {
    param(
        $script:blobNameModulesJson = 'required-modules.json',
        $script:storageAccount = 'STORAGE_ACCOUNT',
        $script:storageAccountContainer = 'STORAGE_CONTAINER',
        $script:runTimeVersion = 'Both', # "5", "7", "both"
        $script:workerLocalPath = "C:\ManageModules",
        $script:manageModulesScriptName = "Manage-Modules.ps1",
        $script:machineType = "arc" # "arc" or "vm"
    )

    $script:scriptPath = "$($workerLocalPath)\$($manageModulesScriptName)"
    $script:storageAccount = $storageAccount
    $script:blobpath = "$($storageAccountContainer)/$($manageModulesScriptName)"

    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'
    Node $env:COMPUTERNAME {
        
        # script to get ps1 from storage account
        Script GetManageModuleScript {
            SetScript = { 
                $targetFolder = ($using:scriptPath)
                $targetFolder = ($targetFolder.Split("\")|Select-Object -SkipLast 1) -join "\"
                if((Test-Path -Path $targetFolder) -eq $false)
                {
                    New-Item $targetFolder -ItemType Directory -Force
                }

                # get managed identity token either as Arc or Azure VM machine
                $resource = 'https://storage.azure.com'

                # arc
                if($using:machineType -eq "arc")
                {
                    $apiVersion = '2019-11-01'
                    $baseUri = 'http://localhost:40342/metadata/identity/oauth2'
                    $encodedResource = $resource
                    $uri = "$baseUri/token?api-version=$apiVersion`&resource=$encodedResource"

                    try
                    {
                        Invoke-WebRequest -UseBasicParsing -Uri $uri -Headers @{ Metadata = "true"} -ErrorAction Stop
                    }
                    catch
                    {
                        $response= $_.Exception.Response
                    }
                    $header = $response.Headers.Where{$_.Key -eq 'WWW-Authenticate'}
                    $secretPath = $header.value.TrimStart("Basic realm=")
                    $secret= Get-Content $secretPath -Raw
                    $token= (Invoke-RestMethod -Uri "$baseUri/token?api-version=$apiVersion&resource=$encodedResource" -Headers @{ Metadata = "true"; Authorization = "Basic $secret"} -ErrorAction Stop).access_token
                    $h = @{}
                    $h.Add("Authorization","Bearer $($token)")
                    $h.Add('x-ms-version','2023-11-03')
                    $h.Add('x-ms-date',[DateTime]::UtcNow.ToString('R'))
                }

                # vm
                if($using:machineType -eq "vm")
                {
                    
                    $resource = [Uri]::EscapeUriString($resource)
                    $baseUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$resource"
                    $token= (Invoke-RestMethod -Uri $baseUri -Headers @{ Metadata = "true" }).access_token
                    $h = @{}
                    $h.Add("Authorization","Bearer $($token)")
                    $h.Add("x-ms-version","2017-11-09")
                    $h.Add("Accept","application/json")
                }
                $rsp = Invoke-RestMethod `
                -Uri "https://$($using:storageAccount).blob.core.windows.net/$($using:blobPath)" `
                -Headers $h `
                -OutFile $using:scriptPath

                # we need wait a bit to make sure fike is saved locally before being executed 
                Start-Sleep -Seconds 10
            }
            TestScript = { $false } 
            GetScript = {"" }
            
        }
        switch($runTimeVersion)
        {
            "Both"
            {
                Script ManageModulesScript5 {
                    SetScript = {
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
                            $ps5Path = Test-PSInstallation -executable powershell
                            Write-Verbose "Executing $($ps5path) -File $using:scriptPath -blobNameModulesJson $using:blobNameModulesJson -storageAccountContainer $using:storageAccountContainer -storageAccount $using:storageAccount -machineType $using:machineType"
                            &"$($ps5path)" -File $using:scriptPath -blobNameModulesJson $using:blobNameModulesJson -storageAccountContainer $using:storageAccountContainer -storageAccount $using:storageAccount -machineType $using:machineType 
                        }
                    TestScript = { $false } 
                    GetScript = {"" }
                    DependsOn = "[script]GetManageModuleScript"
                }

                Script ManageModulesScripT7 {
                    SetScript = {
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
                            $ps7Path = Test-PSInstallation -executable pwsh
                            Write-Verbose "Executing $($ps7path) -File $using:scriptPath -blobNameModulesJson $using:blobNameModulesJson -storageAccountContainer $using:storageAccountContainer -storageAccount $using:storageAccount -machineType $using:machineType"
                            &"$($ps7path)" -File $using:scriptPath -blobNameModulesJson $using:blobNameModulesJson -storageAccountContainer $using:storageAccountContainer -storageAccount $using:storageAccount -machineType $using:machineType 
                        }
                    TestScript = { $false }  
                    GetScript = {"" }
                    DependsOn = "[script]ManageModulesScript5","[script]GetManageModuleScript"

                }
            }
            "5"
            {
                Script ManageModulesScript5 {
                    SetScript = {
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
                            $ps5Path = Test-PSInstallation -executable powershell
                            Write-Verbose "Executing $($ps5path) -File $using:scriptPath -blobNameModulesJson $using:blobNameModulesJson -storageAccountContainer $using:storageAccountContainer -storageAccount $using:storageAccount -machineType $using:machineType"
                            &"$($ps5path)" -File $using:scriptPath -blobNameModulesJson $using:blobNameModulesJson -storageAccountContainer $using:storageAccountContainer -storageAccount $using:storageAccount -machineType $using:machineType 

            
                        }
                    TestScript = { $false } 
                    GetScript = {"" }
                    DependsOn = "[script]GetManageModuleScript"
                }
            }
            "7"
            {
                Script ManageModulesScripT7 {
                    SetScript = {
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
                            Write-Verbose "Executing $($ps7path) -File $using:scriptPath -blobNameModulesJson $using:blobNameModulesJson -storageAccountContainer $using:storageAccountContainer -storageAccount $using:storageAccount -machineType $using:machineType"
                            &"$($ps7path)" -File $using:scriptPath -blobNameModulesJson $using:blobNameModulesJson -storageAccountContainer $using:storageAccountContainer -storageAccount $using:storageAccount -machineType $using:machineType 

                        }
                    TestScript = { $false } 
                    GetScript = {"" }
                    DependsOn = "[script]GetManageModuleScript"

                }
            }
        }
    }
}
