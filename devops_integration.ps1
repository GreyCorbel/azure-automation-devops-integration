Param
(
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
        #whether to automatically publish runbooks. This can be overriden in runbook definition file
        $AutoPublish
)

Function Get-FileToProcess
{
    Param
    (
        [Parameter(Mandatory)]
        [ValidateSet('Runbooks','Variables')]
        [string]$FileType,
        [Parameter(Mandatory)]
        [string]$FileName
    )

    Process
    {
        if(Test-Path "$ContentRoot\$FileType\$FileName" -PathType Leaf) {
            return "$ContentRoot\$FileType\$FileName"
        }
        if(Test-Path "$CommonContentRoot\$FileType\$FileName" -PathType Leaf) {
            return "$CommonContentRoot\$FileType\$FileName"
        }
        return $null
    }
}

$ContentRoot = "$ProjectDir\Source\$EnvironmentName"
$CommonContentRoot = "$ProjectDir\Source\Common"
$definitionsRoot = "$ProjectDir\Definitions"

#region Runbooks
"Processing Runbooks"
$definitions = @()

foreach($definition in Get-ChildItem -Path "$definitionsRoot\Runbooks" -filter *.json) {
    $definitions+= get-content $definition.FullName | ConvertFrom-Json
}
foreach($def in $definitions) {
    [bool]$Publish=$false
    if($null -eq $def.AutoPublish) {
        $Publish = $AutoPublish
    }
    else {
        $Publish = $def.AutoPublish
    }
    $implementationFile = Get-FileToProcess -FileType Runbooks -FileName $def.Implementation
    #import logic of runbook
    if($null -ne $implementationFile) {
        "Importing runbook $($def.name); Source: $implementationFile; Publish: $Publish"
        Import-AzAutomationRunbook `
            -Name $def.Name `
            -ResourceGroupName $ResourceGroup `
            -AutomationAccountName $AutomationAccount `
            -Path $implementationFile `
            -Type $def.Type `
            -Force `
            -Published:($def.AutoPublish) | Out-Null
    }
    else {
        Write-Warning "Runbook $($def.name)`: Missing implementation file, skipping"
    }
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

#endregion Runbooks

#region Variables
$definitions = @()
foreach($definition in Get-ChildItem -Path "$definitionsRoot\Variables" -filter *.json) {
    $definitions+= get-content $definition.FullName | ConvertFrom-Json
}

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
                Write-Warning "$($variable.name)`: Missing content file, skipping variable content update"
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
                Write-Warning "$($managedVariable.name)`: Missing content file, skipping variable creation"
            }
        }
    }
    catch {
        Write-Warning $_.Exception
    }
}

#endregion Variables