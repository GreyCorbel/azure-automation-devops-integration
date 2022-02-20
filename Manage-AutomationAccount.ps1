Param
(
    [Parameter(Mandatory)]
    [ValidateSet('Runbooks','Variables','Dsc')]
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

Import-Module Az.Automation
Import-Module Az.Resources

. "$projectDir\Init.ps1" -ProjectDir $ProjectDir -Environment $EnvironmentName

#region Connect subscription

"Setting active subscription to $Subscription"
Select-AzSubscription -Subscription $Subscription

#endregion

#region Runbooks
if(Check-Scope -Scope $scope -RequiredScope 'Runbooks')
{
    "Processing Runbooks"
    #create a scriptblock for importing runbook as a job
    #this is to increase the performance as the inport takes terribly long
    $runbookImportJob = {
        param
        (
            [string]$Name,
            [string]$Description,
            [string]$RGName,
            [string]$AAName,
            [string]$Path,
            [string]$Type,
            [bool]$Published
        )
        Import-AzAutomationRunbook `
            -Name $Name `
            -Description $Description `
            -ResourceGroupName $RGName `
            -AutomationAccountName $AAName `
            -Path $Path `
            -Type $Type `
            -Force `
            -Published:$Published
    }

    $importJobs=@()
    $definitions = @(Get-DefinitionFiles -FileType Runbooks)
    foreach($def in $definitions) {
        $Publish=$def.AutoPublish
        if($null -eq $Publish) {
            $Publish = $AutoPublish.ToBool()
        }
        $implementationFile = Get-FileToProcess -FileType Runbooks -FileName $def.Implementation
        #import logic of runbook
        if($null -ne $implementationFile) {
            "Starting runbook import: $($def.name); Source: $implementationFile; Publish: $Publish"

            $importJobs+= Start-Job `
                -ScriptBlock $runbookImportJob `
                -ArgumentList `
                    $def.Name,`
                    $def.Description, `
                    $ResourceGroup,`
                    $AutomationAccount,`
                    $implementationFile,`
                    $def.Type,`
                    $Publish `
                -Name $def.Name
        }
        else {
            if($ReportMissingImplementation)
            {
                Write-Warning "Runbook $($def.name)`: Implementation file not defined for this environment, skipping"
            }
        }
    }

    do
    {
        $incompleteJobs=$importJobs.Where{$_.State -notin 'Completed','Suspended','Failed'}
        if($VerbosePreference -ne 'SilentlyContinue')
        {
            $importJobs | select-object Name, JobStateInfo, Error
            Write-Host "-----------------"
        } else {
            Write-Host "Waiting for import jobs to complete ($($incompleteJobs.Count))"
        }
        if($incompleteJobs.Count -gt 0) {Start-Sleep -Seconds 15}
    } while($incompleteJobs.Count -gt 0)

    $importJobs | foreach-object{
        $_ | Select-Object Name,JobStateInfo,Error
        $_.ChildJobs | Select-Object Name,JobStateInfo -ExpandProperty Error
    }

    if($FullSync) {
        $existingRunbooks = @(Get-AzAutomationRunbook -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccount)
        foreach($runbook in $existingRunbooks) {
            if($runbook.Name -notin $definitions.name) {
                "$($Runbook.name) not managed and we're doing full sync -> removing runbook"
                Remove-AzAutomationRunbook -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccount -Name $runbook.Name -Force
            }
        }
    }
}
#endregion Runbooks

#region Variables
if(Check-Scope -Scope $scope -RequiredScope 'Variables')
{
    "Processing Automation variables"
    $definitions = @(Get-DefinitionFiles -FileType Variables)

    $CurrentVariables = Get-AzAutomationVariable -AutomationAccountName $AutomationAccount -ResourceGroupName $ResourceGroup
    "Updating existing variables"
    foreach($variable in $currentVariables) {
        try {
            if($variable.name -notin $definitions.Name) {
                if($FullSync) {
                    "$($variable.name) not managed and we're doing full sync -> removing variable"
                    Remove-AzAutomationVariable -Name $variable.Name -AutomationAccountName $AutomationAccount -ResourceGroupName $ResourceGroup
                }
                else {
                    "$($variable.name) not managed and we're NOT doing full sync -> keeping variable"
                }
            }
            else {
                $ManagedVariable = $definitions.Where{$_.Name -eq $variable.name}
                $contentFile = Get-FileToProcess -FileType Variables -FileName $managedVariable.Content
                if ($null -ne $contentFile) {
                    "$($variable.name) managed -> updating variable"
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
                    if($ReportMissingImplementation)
                    {
                        Write-Warning "$($variable.name)`: Missing content file, skipping variable content update"
                    }
                }
            
                #set description - it's different parameter set
                if(-not [string]::IsnullOrEmpty($managedVariable.Description)) {
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
    foreach($managedVariable in $definitions) {
        try {
            if($managedVariable.Name -notin $currentVariables.Name) {
                $contentFile = Get-FileToProcess -FileType Variables -FileName $managedVariable.Content
                if (Test-Path $contentFile -PathType Leaf) {
                    "$($managedVariable.name) not present -> adding variable"
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
                    if($ReportMissingImplementation)
                    {
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

#region Dsc
if(Check-Scope -Scope $scope -RequiredScope 'Dsc')
{
    $ManagedConfigurations = @()
    $CompilationJobs = @()

    $definitions = @(Get-DefinitionFiles -FileType Dsc)

    foreach($def in $definitions) {
        $Publish= $def.AutoPublish
        if($null -eq $Publish) {
            $Publish = $AutoPublish.ToBool()
        }
        $implementationFile = Get-FileToProcess -FileType Dsc -FileName $def.Implementation
        #import logic of DSC config
        if($null -ne $implementationFile) {
            "Importing Dsc: Source: $implementationFile; Publish: $Publish; Compile: $($def.AutoCompile)"
            $DscConfig = Import-AzAutomationDscConfiguration `
                -SourcePath $implementationFile `
                -ResourceGroupName $ResourceGroup `
                -AutomationAccountName $AutomationAccount `
                -Force `
                -Published:$def.AutoPublish
            
            if($def.AutoCompile)
            {
                #prepare params dictionary if definition specifies
                $Params=@{}
                if($null -ne $def.Parameters) {
                    $def.Parameters.psobject.properties | Foreach-Object{ $Params[$_.Name] = $_.Value }
                }
                $compilationJob = Start-AzAutomationDscCompilationJob `
                    -ResourceGroupName $ResourceGroup `
                    -AutomationAccountName $AutomationAccount `
                    -ConfigurationName $DscConfig.Name `
                    -Parameters $Params
                $CompilationJobs+=$CompilationJob
            }
            $ManagedConfigurations+=$DscConfig
        }
        else {
            if($ReportMissingImplementation)
            {
                Write-Warning "Dsc $($def.Name)`: Implementation file not defined for this environment, skipping"
            }
        }
    }

    #wait for compilations to complete
    do
    {
        $incompleteJobs=@($compilationJobs `
            | Foreach-object{Get-AzAutomationDscCompilationJob `
                -Id $_.Id `
                -ResourceGroupName $ResourceGroup `
                -AutomationAccountName $AutomationAccount `
            } `
            | Where-Object{$_.Status -notin 'Completed','Suspended','Failed'})
        
        if($VerbosePreference -ne 'SilentlyContinue')
        {
            $incompleteJobs
            Write-Host "-----------------"
        } else {
            Write-Host "Waiting for compilation jobs to complete ($($incompleteJobs.Count))"
        }

        if($incompleteJobs.Count -gt 0) {Start-Sleep -Seconds 15}
    } while($incompleteJobs.Count -gt 0)

    if($FullSync) {
        $existingDscConfigurations = @(Get-AzAutomationDscConfiguration -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccount)
        foreach($DscConfig in $existingDscConfigurations) {
            if($DscConfig.Name -notin $ManagedConfigurations.name) {
                "$($DscConfig.name) not managed and we're doing full sync -> removing Dsc configuration"
                Remove-AzAutomationDscConfiguration -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccount -Name $DscConfig.Name -Force
            }
        }
    }
}
#endregion