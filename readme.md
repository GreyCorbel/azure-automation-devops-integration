# Manage-AutomationAccount

The Manage-AutomationAccount DevOps pipeline extension provides a seamless experience for Azure Automation Account resources, automatically updating individual items in the automation account based on the local project with a predefined structure. 
These items include Runbooks, Variables, Configurations, Schedules, Modules, JobSchedules and Webhooks.

Integrate this extension into your pipeline and let it take care of everything for you! 

## How does it all work?

The image below demonstrates a high-level overview of how the DevOps extension manage-automationAccount operates.

<image>

The logic of this extension is based on a predefined directory structure where you store individual items you want to synchronize with Azure Automation. To obtain this directory structure, a PowerShell script called InitializeRepository is used, which, among other things, creates an example in each directory of how the definition of each item to be synchronized should look. The only mandatory input for this script is the directory where the predefined structure should be created.

The Manage-automationAccount DevOps extension consists of two main parts:
1. manage-automationAccount - With this part, you can synchronize items such as Runbooks, Variables, Configurations, Schedules, Modules, and Job Schedules.
2. manage-automationWebHooks - Use this part even if you use WebHooks to trigger some Runbooks.

The following properties serve as inputs for the manage-automationAccount DevOps extension:
1. environmentName (required) - Defines the environment for which you want to perform synchronization (the default environment is "Common").
2. projectDir (required) - Defines the path where the predefined directory structure is located in the project repository.
3. subscription (required) - Defines the subscription in which Azure Automation resides.
4. azureSubscription (required) - Defines the service connection that has the necessary permissions for Azure Automation. Current version suport service connection as ARM Service principal.
5. resourceGroup (required) - Defines the resource group in which Azure Automation resides.
6. automationAccount (required) - The name of the Azure Automation account to which items will be synchronized.
7. storageAccount - 
8. storageAccountContainer - 
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
