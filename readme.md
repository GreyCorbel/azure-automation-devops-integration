# Manage-AutomationAccount

The Manage-AutomationAccount DevOps pipeline extension provides a seamless experience for Azure Automation Account resources, automatically updating individual items in the automation account based on the local project with a predefined structure. 
These items include Runbooks, Variables, Configurations, Schedules, Modules, JobSchedules and Webhooks.

Integrate this extension into your pipeline and let it take care of everything for you! 

## How does it all work?

The logic of this extension is based on a predefined directory structure where you store individual items you want to synchronize with Azure Automation. To obtain this directory structure, a PowerShell script called InitializeRepository is used, which, among other things, creates an example in each directory of how the definition of each item to be synchronized should look. The only mandatory input for this script is the directory where the predefined structure should be created. This script creates a directory structure divided into Definitions and Source. Individual environments are defined in the Source directory (for example: UAT, Production,..Note: if you do not use an environment, use the Common directory). The definition is the same for all environments in the Source directory. Simply put, in Definitions you specify the definition and bindings of individual objects, and in Source you store common objects to be synchronized with the storage account.

Let's demonstrate this with the following example:

### Directory tree:
Definitions
---Runbooks
------test.json
------test2.json
---JobSchedules
------test.json
------test2.json
---Schedules
------Minutes-15.json
------Minutes-30.json
Source
---Common
---Prod
------Runbooks
---------test.ps1
---------test2.ps1
------JobSchedules
---------Default-Parameters.json
---UAT


## Definitions

Example of runbook file named <strong>test.json</strong>

```json
{
    "Name": "test",
    "Implementation": "test.ps1",
    "Type": "PowerShell",
    "RuntimeVersion": "5.1",
    "AutoPublish": true,
    "RequiredModules": [
        "CosmosLite"
    ]
}
```

Example of schedule file named <strong>Minutes-15.json</strong>

```json
{
    "Name": "Minutes-15",
    "StartTime": "00:00:00",
    "Interval": 15,
    "Frequency": "Minute",
    "MonthDays": [],
    "WeekDays": [],
    "Description": "Schedule starting every 15 minutes",
    "Disabled": false
}
```

Example of jobSchedule file named <strong>test.json</strong>

```json
{
    "RunbookName": "test",
    "ScheduleName": "Minutes-15",
    "Settings": "Default-Parameters.json"
}
```
Note: Setting refers to the detail (parameters) of schedules of a specific runbook. In this example in Source in file Default-Parameters.json the parameters are defined.

## Source

Example of runbook file named <strong>test.ps1</strong>

```powershell
Write-Host "This is production pwsh script..."
```

Example of jobSchedule file named <strong>Default-Parameters.json</strong>

```json
{
    "RunOn": "azure",
    "Parameters": {"parameterTest":"test2"}
}
```


### The Manage-automationAccount DevOps extension consists of two main parts:
1. manage-automationAccount - With this part, you can synchronize items such as Runbooks, Variables, Configurations, Schedules, Modules, and Job Schedules.
2. manage-automationWebHooks - Use this part even if you use WebHooks to trigger some Runbooks.

The following properties serve as inputs for the manage-automationAccount DevOps extension:
1. environmentName (required) - Defines the environment for which you want to perform synchronization (the default environment is "Common").
2. projectDir (required) - Defines the path where the predefined directory structure is located in the project repository.
3. subscription (required) - Defines the subscription in which Azure Automation resides.
4. azureSubscription (required) - Defines the service connection that has the necessary permissions for Azure Automation. Current version suport service connection as ARM Service principal.
5. resourceGroup (required) - Defines the resource group in which Azure Automation resides.
6. automationAccount (required) - The name of the Azure Automation account to which items will be synchronized.
7. storageAccount - If you need to use powershell modules in your solution that are not part of the powershell gallery and you don't want them to be public, this devOps extension can automatically upload these powershell modules to the storage account whose name you define in this field.
8. storageAccountContainer - Here you can define a specific container in which the powershell module should be saved
9. fullSync - Defines whether items that are not in the predefined directory structure should be deleted from Azure Automation.
10. reportMissingImplementation - Returns a list of items that do not have an implementation.
11. verboseLog - A switch for detailed logging.
   
## Requirements
There are no specific requirements that the extension requires.

## Extension Settings
No special setting is required.

## Release Notes
Initial release of Manage-AutomationAccount Extension.

**Enjoy!**
