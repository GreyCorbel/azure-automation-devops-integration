# Get the directory of the script
$scriptDirectory = Split-Path $script:MyInvocation.MyCommand.Path
$scriptDirectory

# Create absolute path to the task directory
$taskDirectory = Join-Path $scriptDirectory "Tasks\$taskDirectoryName"
$taskDirectory