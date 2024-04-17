function Init-Environment
{
    Param
    (
        [Parameter(Mandatory)]
        [system.io.directoryinfo]$ProjectDir,
        [Parameter(Mandatory)]
        [string]$Environment
    )

    #setup variables

    [string]$script:ContentRoot = [System.IO.Path]::Combine($ProjectDir.FullName,'Source',$Environment)
    [string]$script:CommonContentRoot = [System.IO.Path]::Combine($ProjectDir.FullName,'Source','Common')
    [string]$script:DefinitionsRoot = [System.IO.Path]::Combine($ProjectDir.FullName,'Definitions')
}

Function Validate-FileType
{
    param
    (
        [string]$FileType
    )
    begin
    {
        $AllowedFileTypes = 'Runbooks','Variables','Configurations','Schedules','Modules','JobSchedules','Webhooks','ConfigurationParameterValues'
    }
    process
    {
        return ($FileType -in $AllowedFileTypes)
    }
}
Function Get-FileToProcess
{
    Param
    (
        [Parameter(Mandatory)]
        [ValidateScript({Validate-FileType -FileType $_})]
        [string]$FileType,
        [Parameter()]
        [string]$FileName
    )

    Process
    {
        if([string]::IsNullOrWhiteSpace($FileName)) {
            return $null
        }

        #try environment-specific path adn use it if found
        [string]$path = [System.IO.Path]::Combine($script:ContentRoot,$FileType,$FileName)
        if(Test-Path $path -PathType Leaf) {
            return $path
        }
        #if environment specific not found, use common
        $path = [System.IO.Path]::Combine($script:CommonContentRoot,$FileType,$FileName)
        if(Test-Path $path -PathType Leaf) {
            return $path
        }
        #not found
        return $null
    }
}

Function Get-ModuleToProcess
{
    Param
    (
        [Parameter()]
        [string]$ModuleName
    )

    Process
    {
        if([string]::IsNullOrWhiteSpace($ModuleName)) {
            return $null
        }

        #try environment-specific path adn use it if found
        [string]$path = [System.IO.Path]::Combine($script:ContentRoot,'Modules',$ModuleName)
        if(Test-Path $path -PathType Container) {
            return $path
        }
        #if environment specific not found, use common
        $path = [System.IO.Path]::Combine($script:CommonContentRoot,'Modules',$ModuleName)
        if(Test-Path $path -PathType Container) {
            return $path
        }
        #not found
        return $null
    }
}

Function Get-DefinitionFiles
{
    param
    (
        [Parameter(Mandatory)]
        [ValidateScript({Validate-FileType -FileType $_})]
        [string]$FileType
    )

    Process
    {
        $path = [System.IO.Path]::Combine($script:DefinitionsRoot,$FileType)
        if(Test-Path -Path $path)
        {
            foreach($definition in Get-ChildItem -Path $path -filter *.json) {
                get-content $definition.FullName -Encoding utf8 | ConvertFrom-Json
            }
        }
    }
}
Function Check-Scope
{
    Param
    (
        [Parameter(Mandatory)]
        [string[]]$Scope,
        [Parameter(Mandatory)]
        [string[]]$RequiredScope
    )

    Process
    {
        $result=$false
        foreach($s in $scope){
            if($RequiredScope -contains $s) {
                $result=$true
                break;
            }
        }
        $result
    }
}
