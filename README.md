# Azure automation - Integration with source control

This repo contains Powershell scripts that demonstrates integration of Azure automation account and Azure Template Specs into DevOps source control and release pipeline.  
Main motivation for creation of this work were only basic capabilities of native integration of Azure Automation account with source control, namely:
* Lack of integration into DevOps pipeline; every repo update results in update of automation account
* Only runbooks are source-controlled, but not other assets - I particularly missed ability to control variables, modules installed in automation account, schedules, webhooks and schedules associated with runbooks, and Dsc configurations
* Only flat structure of repo (runbooks in subfolders are not managed)
* Dependency on PAT tokens
* Inability to manage variables and provide state-specific content for variables
* Inability to deliver different versions of runbooks to different stages/environments

Work then evolved with interest of various development teams to manage more Azure areas from TFS

## Capabilities
Current implementation has the following features:
* Source control for runbooks, variables, schedules, modules installed in automation account, Dsc configurations, webhooks for runbooks and schedule links with runbooks.
* All managed artifacts can be the same for all environments/stages, or can be specific for each environment/stage
  * Place implementation to Common folder, or stage-specific folder, depending on your needs
  * Stage-specific folders have priority when deployment looks for implementation file
* Runbooks can be automatically published
* Dsc Configurations can be automatically published
* All managed artifacts can be fully managed (auto-deleted from automation account when not found in source control)
* Runbooks and Powershell modules support 5.1 (Powershell Desktop) and 7.2 (Powershell Core) runtimes
  * Powershell runtime v7.1 is not supported and not planned to be supported in the future - focus is to support most recent Powershell Core runtimes


Everything can be easily published to Azure via Azure PowerShell task from DevOps pipeline as demonstrated by [deployment pipeline](./Automation%20deployment.yml) and [associated pipeline template](./automation-tasks-template.yml).

Management scripts to use for deployment are:
* Manage-AutomationAccount.ps1: Can manage everything except webhooks for runbooks.
  * What is actually managed is defined by `-Scope` parameter
* Manage-AutomationAccountWebHook.ps1: Manages webhooks for runbooks
  * passes newly created webhooks to pipeline, so they can be used by dependent processes (store them to KeyVault, use them to create routing of events in Event Grid, etc.)

Management scripts are designed to be executed by `AzurePowerShell@5` pipeline task that automatically logs in to Azure. For use outside of pipeline, you need to:
* have `Az.Accounts` PowerShell module installed
> call `Connect-AzAccount` command prior running management scripts

Apart from `Az.Accounts`, no other Az modules are requiired  - all work is performed via Azure Automation REST API.
## Folder structure for the root
Folder structure can be easily created by InitializeRepository script - it creates all the folders and places small readme file to each folder, describing what's supposed to be placed inside the folder.

Repo itself can deploy to multiple automation accounts - just create multiple root folders according to needs and deploy their content from DevOps pipeline, pointing management script to proper root folder and proper automation account.

## Concept
Concept relies on JSON files that describe which and how runbooks, variables, schedules, modules, etc. are managed in automation account. Source control can contain more files - only runbooks and variables specified in JSON definition files are imported to automation account and managed there.  
JSON definition files are stored in Definitions folder as shown in this sample.
Management script executed by DevOps agent as a part of deployment pipeline via [Azure Powershell](https://docs.microsoft.com/en-us/azure/devops/pipelines/tasks/deploy/azure-powershell?view=azure-devops) task reads JSON definitions and performs deployment - see below for details.

Logic for management of automation account artifacts is implemented in companion module [AutomationAccount](./Modules/AutomationAccount)

### Schema of definition files
Schema of definition files of runbooks, variables, schedules, modules and Dsc configs is shown in readme file in respective folder. There is helper module described in [AutomationDefinitions](./Modules/AutomationDefinitions) that can be used to create definition files for vaious artifacts.

### Processing logic
Generally, processing logic is as follows:
- load all definitions of given artifact type (defined by `-Scope` parameter)
- looks for implementation file in Environment-specific folder (if artifact has implementation file)
- if found, it's used for import of runbook/variable/Dsc configuration content
- if not found in Environment-specific, script looks for the same file in Common folder
- if found, it's used for import
- if not found, warning is logged

So logic of looking for artecats is the same for all artefacts types - environment/stage specific implementations always have priority. Logic is implemented by helper module [AutoRuntime](./Modules/AutoRuntime)

## Limitations
Current implementation as shown in `Manage-AutomationAccount.ps1` script manages just runbooks, variables, schedules, mudules, schedule links and webhooks for runbooks, and Dsc Configurations, but not other assets in automation account - for many assets it's not good idea to store them in source control.
> If you have good use case for management of other assets, let me know

PowerShell modules for PowerShell 7.2 runtime does not show version information in automation account - until fixed by MS, they're redeployed every time management script is executed and `Modules` scope specified.

Powershell modules are installed to automation account, but not on any hybrid workers - you have to install them on hybrid worker yourself.

PowerShell runtimes other than 5.1 and 7.2 are not currently supported.

Webhooks are integrated with Event Grid only - if you desire to integrate with other services that trigger webhook, let us know.

Currently, only variables of type [string] are supported; support for other variable types may come in next release. However, variables can contain JSON strings to provide runbooks with structured data.

Variable encryption status cannot be changed when variable already exists. To change encryption status, you have to delete the variable manually in automation account and then run deployment again with updated Encryption in variable definition file.

Integration is supposed to work with any runbook type, however it was heavily tested with PowerShell runbooks only.
> Looking for testers with other runbook types.

Enjoy!
