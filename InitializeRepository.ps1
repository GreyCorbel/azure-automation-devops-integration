Param
(
    [Parameter(Mandatory)]
    [string]
        #root folder of repository
        $ProjectDir,
    [Parameter()]
    [string]
        #Name of the stage/environment we're deploying
        $EnvironmentName = 'Common',
    [switch]$NoSamples
)

#region SampleContent

#Samples
$runbookDefinition = @'
{
    "Name": "Sample-Runbook",
    "Implementation": "_Template-Runbook.ps1",
    "Type": "PowerShell",
    "RuntimeVersion": "5.1",
    "SupportedRequestTypes": [
        //requestType in EventGrid schema if runbook is triggered by EVentGrid event posted to webhook 
        "Company.App.RequestType"
    ],
    "TriggeredByWebhook": true,
    //where runbook runs - HybridWorker or Azure
    "RunsOn": "HybridWorker",
    //modules required by runbook - for documentation only
    "RequiredModules": [
        "CosmosLite"
    ],
    //names of schedules that should trigger runbook, if any
    "Schedules": []
}

'@
$runbookContent = @'
<#
.SYNOPSIS
Brief description of runbook
.DESCRIPTION
Detailed description of runbook
.NOTES
Additional info
#>
param
(
    [Parameter()]
    [object]$WebhookData
)

#implementation
'@
$variableDefinition = @'
{
    "Name": "Sample-Variable",
    "Description": "Description of variable",
    "Encrypted": false,
    "Content": "_Template-Variable.txt"
}
'@
$variableContent = @'
87008d2a-2de2-424c-88f0-adeef796fd63
'@
$scheduleDefinition = @'
{
    "Name": "Hourly-45",
    "StartTime": "",
    "SetMinute": 45,
    "Description": "Hourly schedule starting at 45 minutes",
    "TimeZone": "",
    "Frequency": "Hourly",
    "Interval": 1,
    "IsEnabled": true
}
'@
$modulesDefinition = @'
{
    //list of modules to be imported to automation account
    "ModulesList": "_Template_modules.json"
}
'@
$modulesSource = @'
{
    "RequiredModules": [
        {
            "Name": "AadAuthenticationFactory",
            "Version": "2.1.2",
            "VersionIndependentLink": "https://www.powershellgallery.com/api/v2/package/AadAuthenticationFactory"
        },
        {
            "Name": "Microsoft.Graph.Authentication",
            "Version": "2.1.0",
            "VersionIndependentLink": "https://www.powershellgallery.com/api/v2/package/Microsoft.Graph.Authentication"
        }
    ]
}
'@
$dscDefinition = @'
{
    //sample DSC configuration
    "Implementation": "_Template-Dsc.ps1",
    "AutoPublish": true,
    "AutoCompile": true,
    "Parameters": null
}
'@
$dscSource = @'
#sample Dsc configuration that sets registry value
Configuration Test {
    Import-DscResource -ModuleName PSDesiredStateConfiguration
    Node 'localhost' {
        Registry SampleDsc {
            Key = "HKEY_LOCAL_MACHINE\Software\Test"
            ValueName = "TestValue"
            ValueData = 0
            ValueType = 'Dword'
            Ensure = 'Present'
        }
    }
}
'@

#endregion

Write-host "Processing repository root"
if(-not (Test-Path -Path $ProjectDir))
{
    New-Item -ItemType Directory -Path $ProjectDir -Force | Out-Null
}
Write-host "Processing definitions root"
if(-not (Test-Path -Path "$ProjectDir/Definitions"))
{
    New-Item -ItemType Directory -Path "$ProjectDir/Definitions" -Force | Out-Null
}

Write-host "Processing source root"
if(-not (Test-Path -Path "$ProjectDir/Source"))
{
    New-Item -ItemType Directory -Path "$ProjectDir/Source" -Force | Out-Null
}

Write-host "Processing environment roots for $EnvironmentName"
if(-not (Test-Path -Path "$ProjectDir/Source/$EnvironmentName"))
{
    New-Item -ItemType Directory -Path "$ProjectDir/Source/$EnvironmentName" -Force | Out-Null
}

$supportedEntities = 'Dsc','Runbooks','Variables','Modules','Schedules'
foreach($entity in $supportedEntities)
{
    switch($entity)
    {
        'Schedules' {
            $createDefinitionFolder = $true
            $createSourceFolder = $false
            break;
        }
        default {
            $createDefinitionFolder = $true
            $createSourceFolder = $true
            break;
        }
    }
    Write-host "Processing $entity"
    if($createSourceFolder -and -not (Test-Path -Path "$ProjectDir/Source/$EnvironmentName/$entity"))
    {
        New-Item -ItemType Directory -Path "$ProjectDir/Source/$EnvironmentName/$entity" -Force | Out-Null
    }

    if($NoSamples)
    {
        continue;
    }
    #create samples
    switch($entity)
    {
        'Runbooks' {
            New-Item -Path "$ProjectDir/Definitions/$entity" -Name '_Template-Runbook.json' -ItemType File -Value $runbookDefinition -Force | Out-Null
            New-Item -Path "$ProjectDir/Source/$EnvironmentName/$entity" -Name '_Template-Runbook.ps1' -ItemType File -Value $runbookContent -Force | Out-Null
            break;
        }
        'Variables' {
            New-Item -Path "$ProjectDir/Definitions/$entity" -Name '_Template-Variable.json' -ItemType File -Value $variableDefinition -Force | Out-Null
            New-Item -Path "$ProjectDir/Source/$EnvironmentName/$entity" -Name '_Template-Variable.txt' -ItemType File -Value $variableContent -Force | Out-Null
            break;
        }
        'Schedules' {
            New-Item -Path "$ProjectDir/Definitions/$entity" -Name '_Template-Schedule.json' -ItemType File -Value $scheduleDefinition -Force | Out-Null
            break;
        }            
        'Modules' {
            New-Item -Path "$ProjectDir/Definitions/$entity" -Name '_Template-Modules.json' -ItemType File -Value $modulesDefinition -Force | Out-Null
            New-Item -Path "$ProjectDir/Source/$EnvironmentName/$entity" -Name '_Template-Modules.json' -ItemType File -Value $modulesSource -Force | Out-Null
            break;
        }
        'Dsc' {
            New-Item -Path "$ProjectDir/Definitions/$entity" -Name '_Template-Dsc.json' -ItemType File -Value $dscDefinition -Force | Out-Null
            New-Item -Path "$ProjectDir/Source/$EnvironmentName/$entity" -Name '_Template-Dsc.ps1' -ItemType File -Value $dscSource -Force | Out-Null
            break;
        }
    }
}
