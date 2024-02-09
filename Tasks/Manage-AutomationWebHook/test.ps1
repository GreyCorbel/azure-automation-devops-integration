# Get the directory of the script
$parentDirectory = Split-Path -Path $PSScriptRoot -Parent
$grandparentDirectory = Split-Path -Path $parentDirectory -Parent
$grandparentDirectory
$modulePath = [System.IO.Path]::Combine($grandparentDirectory,'Module','AutomationAccount')
$modulePath