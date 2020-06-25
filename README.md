# azure-automation-devops-integration
This repo contains Powershell script that demonstrates integration of Azure automation account into DevOps source control and release pipeline.  
Main motivation for creation of this work were only basic capabilities of native integration of Azure Automation account with source control, namely:
* lack of integration into DevOps pipeline; every repo update results in update of automation account
* only runbooks are source-controlled, but not other assets - I particularly missed ability to control variables
* only flat structure of repo (runbooks in subfolders are not managed)
* dependency on PAT tokens
* inability to manage variables and provide state-specific content for variables
* inability to deliver different versions of runbooks to different stages/environments

Sample runbook and variable included in this repo demonstrates how to effectively log runbook activity and telemetry data into AppInsights instance - just by providing instrumentation key in variable - makes it really easy to standardize runbook activity logging and get more out of AppInsights.

## Capabilities
Current implementation has the following features:
* Source control for runbooks and variables
* Variable content can be different per stage/environment (this sample demonstrates this on AppInsights instrumentation key that is different for DEV/TEST/PROD environment)
* Runbook version can be different for each stage/environment
* Common runbooks and variables (the same version/value for all stages/environments)
* Runbooks can be automatically published (global and per-runbook setting; runbook setting overrides global setting)
* Automation account can be fully managed (runbooks and variables not in source control are removed during deployment)

## Folder structure
```
Definitions
    Runbooks
        <RunbookDefinitionName>.json
        <OtherRunbookDefinitionName>.json
        ...
    Variables
        <VariableDefinitionName>.json
        <OtherVariableDefinitionName>.json
        ...
Source
    Common
        Runbooks
            <commonRunbookImplementationFile>
            <commonRunbookImplementationFile2>
            ...
        Variables
            <commonVariableContentFile>
            <commonVariableContentFile2>
            ...
    <Stage>
        Runbooks
            <stage-SpecificRunbookImplementationFile>
            <stage-SpecificRunbookImplementationFile2>
            ...
        Variables
            <stage-SpecificVariableContentFile>
            <stage-SpecificVariableContentFile2>
            ...
    <Stage>
        ...
```
Sample in this repo contains:
- Common runbook Utils.ps1
- Stages DEV and TEST with stage-specific variable Sample-Variable and stage-specific runbook Sample-Runbook.ps1

## Concept
Concept relies on JSON files that describe which and how runbooks and variables are managed in automation account. Source control can contain more files - only runbokks and variables devined in JSON files are imported to automation account and managed there.  
JSON definition files are stored in Definitions folder as shown in this sample.
Integration script executed by DevOps agent reads JSON definitions and performs deployment - see below for details.

### Schema of definition files
Runbook definition:
```json
{
    "Name": "<Name of the runbook as appears in automation account>",
    "Implementation": "<FileName in Sources that contains implementation of runbook>",
    "Type": "<type of runbook, e.g. PowerShell>",
    "AutoPublish": "true or false - if the runbook shall be automatically published"
}
```
Variable definition:
```json
{
    "Name": "<Name of the variable as appears in automation account>",
    "Description": "<description of variable>",
    "Encrypted": "true or false - if the variable shall be encrypted>",
    "Content": "<FileName in Sources that contains content of variable>"
}
```
### Processing logic
Script devops_integration.ps1 looks for definition of runbook in Definitions\Runbooks folder and:
- looks for implementation file in Stage-specific folder
- if found, it's used for import of runbook content
- if not found in Stage-specific, script looks for the same file in Common folder
- if found, it's used for import of runbook
- if not found, warning is logged

The same logic applies for variables - variable definition is loaded from definition JSON file, and content of variable is first searched for in Stage-specific folder and - if not found there - in Common folder.

## Integration script
Integration with DevOps is implemented by devops_integration.ps1 script. It's supposed to be run by standard Azure PowerShell task in DevOps - note that script uses **Az Powershell** module, so Azure Powershell task version should be at least 4.* (previous versions rely on AzureRm Powershell instead of Az Powershell).

Typical usage and command line:
```
$(System.DefaultWorkingDirectory)/devops_integration.ps1 -ProjectDir "$(System.DefaultWorkingDirectory)" -EnvironmentName $(EnvironmentName) -ResourceGroup $(ResourceGroup) -AutomationAccount $(AutomationAccount) -AutoPublish
```
Above sample loads environment name, resource group of automation account and automation account name from variables defined for DevOps release, imports runbooks and variables as dfined in JSON definition files in repo, and automatically publishes all runbooks (unless runbook definition file specifies that runbook shall not be published).
Running task produces output simlar to the below upon successful finish:
```
2020-06-25T10:39:33.0686398Z ##[section]Starting: Run devops_integration.ps1
2020-06-25T10:39:33.1350708Z ==============================================================================
2020-06-25T10:39:33.1351037Z Task         : Azure PowerShell
2020-06-25T10:39:33.1351193Z Description  : Run a PowerShell script within an Azure environment
2020-06-25T10:39:33.1351316Z Version      : 4.0.13
2020-06-25T10:39:33.1351421Z Author       : Microsoft Corporation
2020-06-25T10:39:33.1351552Z Help         : [More Information](https://go.microsoft.com/fwlink/?LinkID=613749)
2020-06-25T10:39:33.1351679Z ==============================================================================
2020-06-25T10:39:39.5587719Z Added TLS 1.2 in session.
2020-06-25T10:39:47.2609508Z ##[command]Import-Module -Name C:\Program Files\WindowsPowerShell\Modules\Az.Accounts\1.7.3\Az.Accounts.psd1 -Global
2020-06-25T10:39:52.9165193Z ##[command]Clear-AzContext -Scope Process
2020-06-25T10:39:55.7821284Z ##[command]Clear-AzContext -Scope CurrentUser -Force -ErrorAction SilentlyContinue
2020-06-25T10:39:56.4330692Z ##[command]Connect-AzAccount -ServicePrincipal -Tenant *** -Credential System.Management.Automation.PSCredential -Environment AzureCloud
2020-06-25T10:40:00.0905493Z ##[command] Set-AzContext -SubscriptionId *** -TenantId ***
2020-06-25T10:40:01.1408755Z ##[command]& 'C:\***\Automation\devops_integration.ps1' -ProjectDir "C:\***/Automation" -EnvironmentName DEV -ResourceGroup myRG -AutomationAccount myAccount -AutoPublish
2020-06-25T10:40:01.2307977Z Processing Runbooks
2020-06-25T10:40:01.2826969Z Importing runbook Sample-Runbook; Source: C:\***/Automation\Source\DEV\Runbooks\Sample-Runbook.ps1; Publish: True
2020-06-25T10:43:12.5687203Z Importing runbook Utils; Source: C:\***/Automation\Source\Common\Runbooks\Utils.ps1; Publish: True
2020-06-25T10:44:18.0574966Z Updating existing variables
2020-06-25T10:44:18.0944373Z Sample-Variable managed -> updating variable
2020-06-25T10:44:27.6900367Z ##[command]Disconnect-AzAccount -Scope Process -ErrorAction Stop
2020-06-25T10:44:28.0766231Z ##[command]Clear-AzContext -Scope Process -ErrorAction Stop
2020-06-25T10:44:29.1959197Z ##[section]Finishing: Run devops_integration.ps1
```

Script parameters:  
| Parameter         |  Meaning |
|-------------------|----------|
|  **ProjectDir**       |  Root folder of repository |
|  **EnvironmentName**  |  Name of the stage/environment we're deploying |
|  **ResourceGroup**    | Name of the resource group where automation account is located  |
| **AutomationAccount** |  name of automation account that we deploy to |
|  **FullSync**         |  whether or not to remove any existing runbooks and variables from automation account that are not source-controlled  |
|  **AutoPublish**      | whether to automatically publish runbooks. This can be overriden in runbook definition file  |


## Limitations
Current implementation manages just runbooks and variables, but not other assets in automation account - for many assets it's not good idea to store them in source control.
> If you have good use case for manageement of other assets, let me know

Currently, only variables of type [string] are supported; support for other variable types may comee in next release.

Variable encryption status cannot be changed when variable already exists. To change encryption status, you need to delete the variable manually in automation account and then run deployment again with updated Encryption in variable definition file.

Integration is supposed to work with any runbook type, however it was heavily tested with powershell runbooks.
> Looking for testers with other runbook types.

Enjoy!