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
    [Switch]
        #whether or not to remove any existing runbooks and variables from automation account that are not source-controlled 
        $FullSync,
    [Parameter()]
        [Switch]
        #whether to report missing implementation file
        #Note: it may be perfectly OK not to have implementation file, if artefact is meant to be used just in subset of environments
        $ReportMissingImplementation
)

Import-Module Az.Resources

. "$projectDir\Init.ps1" -ProjectDir $ProjectDir -Environment $EnvironmentName

Get-AzContext
#region ArmTemplateSpecs
"Processing Arm Template Specs"
$definitions = @(Get-DefinitionFiles -FileType ArmTemplates)

#create and update policies
foreach($def in $definitions)
{
    Set-AzContext -SubscriptionName $def.SubscriptionName | Out-Null
    $implementationFile = Get-FileToProcess -FileType ArmTemplates -FileName $def.TemplateImplementation
    if($null -eq $implementationFile) {
        if($ReportMissingImplementation)
        {
            Write-Warning "Template spec $($def.name)`: Missing implementation file, skipping"
        }
        continue
    }
    $location = $def.Location
    if($null -eq $Location) {$location='westeurope'}

    $existingTemplate = Get-AzTemplateSpec -Name $def.Name -ResourceGroupName $def.ResourceGroupName -errorAction SilentlyContinue
    if($null -ne $existingTemplate -and ($Location -ne $existingTemplate.Location -or $def.ResourceGroupName -ne $existingTemplate.ResourceGroupName))
    {
        Write-Verbose "Removing template $($def.Name) because location changes"
        #cannot change template location -> must delete and create a new template in new location
        $existingtemplate | Remove-AzTemplateSpec -Force | Out-Null
    }
    #upsert template
    "Upserting template $($def.Name) : $($def.Version)"
    try {
        Set-AzTemplateSpec -Name $def.Name `
        -Description $def.Description `
        -Version $def.Version `
        -ResourceGroupName $def.ResourceGroupName `
        -Location westeurope `
        -TemplateFile $implementationFile `
        | Out-Null
    }
    catch {
        Write-Warning "Could not process; error: $($_.Exception.Body.Error.Message)"
        $_.Exception
        continue
    }

    #setup permissions
    if($null -ne $def.ShareTargetGroupName)
    {
        "Assigning permission on template $($def.Name) for $($def.ShareTargetGroupName)"
        $Role = "Reader"
        try {
            $existingTemplate = Get-AzTemplateSpec -Name $def.Name -ResourceGroupName $def.ResourceGroupName -ErrorAction Stop
            $targetgroup = Get-AzADGroup -DisplayName $def.ShareTargetGroupName
            $Error.Clear()
            New-AzRoleAssignment -Scope $existingTemplate.id -RoleDefinitionName $Role -ObjectId $targetgroup.id -ErrorAction SilentlyContinue | Out-Null
            if($Error.Count -gt 0 )
            {
                if($Error[0].Exception.HResult -eq 0x80131500) #AlreadyExists
                {
                    "AlreadyExists: $Role role for $($def.ShareTargetGroupName) on template $($def.Name)"
                }
                else {
                    throw $Error[0].Exception
                }
            }
            else {
                "Assigned: $Role role for $($def.ShareTargetGroupName) on template $($def.Name)"
            }
        }
        catch {
            Write-Warning "Could not process"
            $_.Exception
            continue
        }
    }
}

if($FullSync)
{
    $existingTemplates = Get-AzTemplateSpec
    foreach($tpl in $existingTemplates)
    {
        if($tpl.Name -notin $definitions.Name)
        {
            "Deleting unmanaged template $($tpl.Name)"
            $tpl | Remove-AzTemplateSpec -Force | Out-Null
        }
    }
}
#endregion
