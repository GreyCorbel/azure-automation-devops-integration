Param
(
    [Parameter(Mandatory)]
    [string]
        #root folder of repository
        $ProjectDir,
    [Parameter()]
    [string]
        #Name of the stage/environment we're deploying
        $EnvironmentName = 'Common'
)

$modulePath = [System.IO.Path]::Combine($PSScriptRoot,'Module','AutomationDefinitions')
Import-Module $modulePath -Force

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

$supportedEntities = 'Configurations','Runbooks','Variables','Modules','Schedules','JobSchedules','Webhooks'
foreach($entity in $supportedEntities)
{
    switch($entity)
    {
        {$_ -in @('Schedules','JobSchedules','Webhooks')}  {
            $createSourceFolder = $false
            break;
        }
        default {
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

    $DefContent = "# $entity`nThis is a folder to store definition of automation account artifacts of type $entity. Sample definition for $entity is specified below.`n``````json`n{}`n``````"
    $SrcContent = "# $Entity`nThis is a folder to store implementation of automation account artifacts of type $entity "
    if($EnvironmentName -eq 'Common')
    {
        $SrcContent += "common for all environment, unless environment-specific version is found.  `n"
    }
    else
    {
        $SrcContent += "specific for environment $EnvironmentName. Environment-specific versions have preference over common versions when deploying to given environment.  `n"
    }
    #create samples
    switch($entity)
    {
        'Runbooks' {

            $def = New-RunbookDefinition -Name "Sample runbook" -Implementation "sample_runbook.ps1" -Type PowerShell -RuntimeVersion '7.2' -AsJson
            $DefContent = $defContent.Replace('{}', $def)
            New-Item -Path "$ProjectDir/Definitions/$entity" -Name 'readme.md' -ItemType File -Value $DefContent -Force | Out-Null
            New-Item -Path "$ProjectDir/Source/$EnvironmentName/$entity" -Name 'readme.md' -ItemType File -Value $SrcContent -Force | Out-Null
            break;
        }
        'Variables' {
            $def = New-VariableDefinition -Name "Sample variable" -Content "sample_variable.txt" -Description "Description of variable" -AsJson
            $DefContent = $defContent.Replace('{}', $def)
            New-Item -Path "$ProjectDir/Definitions/$entity" -Name 'readme.md' -ItemType File -Value $DefContent -Force | Out-Null
            $SrcContent += "__Note__: Currently, only string variables are supported. However variable may contain JSOn string to provide runbook with structured data.  `n"
            New-Item -Path "$ProjectDir/Source/$EnvironmentName/$entity" -Name 'readme.md' -ItemType File -Value $SrcContent -Force | Out-Null
            break;
        }
        'Schedules' {
            $def = New-ScheduleDefinition -Name 'Sample schedule' -StartTime '07:00' -Interval 15 -Frequency Minute -Description "Schedule for 15-minute interval" -AsJson
            $DefContent = $defContent.Replace('{}', $def)
            New-Item -Path "$ProjectDir/Definitions/$entity" -Name 'readme.md' -ItemType File -Value $DefContent -Force | Out-Null
            break;
        }            
        'Modules' {
            $def = New-ModuleDefinition -Name SampleModule -RuntimeVersion 5.1 -Version 1.0.0 -VersionIndependentLink "www.powershellgallery.com/api/v2/package/SampleModule" -Order 1 -AsJson
            $DefContent = $defContent.Replace('{}', $def)
            New-Item -Path "$ProjectDir/Definitions/$entity" -Name 'readme.md' -ItemType File -Value $DefContent -Force | Out-Null
            break;
        }
        'Configurations' {
            $def = New-ConfigurationDefinition -Name "SampleConfiguration" -Implementation "sample_configuration.ps1" -Description "Sample Powershell Dsc configuration" -AutoCompile -AsJson
            $DefContent = $defContent.Replace('{}', $def)
            New-Item -Path "$ProjectDir/Definitions/$entity" -Name 'readme.md' -ItemType File -Value $DefContent -Force | Out-Null
            New-Item -Path "$ProjectDir/Source/$EnvironmentName/$entity" -Name 'readme.md' -ItemType File -Value $SrcContent -Force | Out-Null
            break;
        }
        'JobSchedules' {
            $def = New-JobScheduleDefinition -RunbookName "Sample runbook" -ScheduleName "Sample schedule" -RunOn Azure -Parameters @{SampleParameter = 'Sample Parameter value'} -AsJson
            $DefContent = $defContent.Replace('{}', $def)
            New-Item -Path "$ProjectDir/Definitions/$entity" -Name 'readme.md' -ItemType File -Value $DefContent -Force | Out-Null
            break;
        }
        'Webhooks' {
            $def = New-WebhookDefinition -NamePrefix "Sample" -RunbookName "Sample Runbook" -RunOn MyHybridWorkerGroup -Overlap '14.00:00:00' -AsJson
            $DefContent = $defContent.Replace('{}', $def)
            New-Item -Path "$ProjectDir/Definitions/$entity" -Name 'readme.md' -ItemType File -Value $DefContent -Force | Out-Null
            break;
        }
    }
}
