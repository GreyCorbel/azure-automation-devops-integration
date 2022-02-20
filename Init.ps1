Param
(
    [Parameter(Mandatory)]
    [system.io.directoryinfo]$ProjectDir,
    [Parameter(Mandatory)]
    [string]$Environment
)

#setup variables

[string]$ContentRoot = [System.IO.Path]::Combine($ProjectDir.FullName,'Source',$Environment)
[string]$CommonContentRoot = [System.IO.Path]::Combine($ProjectDir.FullName,'Source','Common')
[string]$DefinitionsRoot = [System.IO.Path]::Combine($ProjectDir.FullName,'Definitions')

Function Validate-FileType
{
    param
    (
        [string]$FileType
    )
    begin
    {
        $AllowedFileTypes = 'Runbooks','Variables','Dsc'
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
        if(Test-Path "$ContentRoot\$FileType\$FileName" -PathType Leaf) {
            return "$ContentRoot\$FileType\$FileName"
        }
        if(Test-Path "$CommonContentRoot\$FileType\$FileName" -PathType Leaf) {
            return "$CommonContentRoot\$FileType\$FileName"
        }
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
        if(Test-Path -Path  "$definitionsRoot\$FileType")
        {
            foreach($definition in Get-ChildItem -Path "$definitionsRoot\$FileType" -filter *.json) {
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
