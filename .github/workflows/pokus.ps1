$tasksFolder = "Tasks"
$extensionInfo = get-content 'vss-extension.json' | ConvertFrom-Json -Depth 99
$extensionVersion = [System.Version]::Parse($extensionInfo.version)
$versionInfo =[ordered]@{ 
    Major = $extensionVersion.Major
    Minor = $extensionVersion.Minor
    Patch = $extensionVersion.Build
}
$tasks = Get-ChildItem $tasksFolder -Directory
foreach($task in $tasks.Name)
{
    Write-Host "Setting version of task $task to $extensionVersion"
    $taskInfo = get-content ([System.IO.Path]::Combine($tasksFolder,$task,'task.json')) | ConvertFrom-Json -Depth 99
    $taskInfo.version = $versionInfo
    $taskInfo | ConvertTo-Json -Depth 99 | Out-File -Path ([System.IO.Path]::Combine($tasksFolder,$task,'task.json')) -Force
}


$extensionInfo = "1.9.15"
$extensionVersion = [System.Version]::Parse($extensionInfo.version)
$versionInfo =[ordered]@{ 
    Major = $v.Major
    Minor = $v.Minor
    Patch = $v.Build
}