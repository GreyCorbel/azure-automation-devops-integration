# Helper: Sync PowershellModules between AutomationAccount and HybridWorkers
Use this helper you if you would like to sync PowerShell modules from your AutomationAccount with modules to your hybrid worker(s). Any changes you make to your Automation Account modules will be replicated to workers.

- Prerequisites:
  - Automation Account
  - Hybrid Worker Registered to Arc
  - Hybrid Worker Registered to Dsc (of your Automation Account)
  - Managed Identity
  - Azure Storage Account

## Pre-requites preparation
1) To register Server to Azure Arc: 

Note: If you use Azure VM this step is not required. 

  - Navigate to Azure Arc Machines in Azure
  - Click Machines
  - Click Add/Create
  - Click Add a single server
  - Click Generate Script
  - Select your Azure Resources (Resource Group, Region)
  - Download the script
  - Run the script in elevated prompt on your server - make sure you allow all outbound URLs or you use proxy 


2) To register Server to DSC: Run .\Register-HybridWorkerToDsc.ps1 script in elevated prompt on your HybridWorker, that allows you to register your server into Dsc. Update lines below. You can get your URL and key from AutomationAccount\Keys. 
```Powershell
     RegistrationUrl = 'REGISTRATION_URL';
     RegistrationKey = 'REGISTRATION_KEY';
     ComputerName = @("$($env:COMPUTERNAME)");
     NodeConfigurationName = '';
     RefreshFrequencyMins = 30;
     ConfigurationModeFrequencyMins = 15;
     RebootNodeIfNeeded = $False;
     AllowModuleOverwrite = $False;
     ConfigurationMode = 'ApplyAndAutoCorrect';
     ActionAfterReboot = 'ContinueConfiguration';
     ReportOnly = $False;
```
Make sure you keep ConfigurationMode set to 'ApplyAndAutoCorrect'.
Once this step is done, you can see your worker registered in Automation Account under DSC blade. 

3) To create Managed Identity

Note: Arc Connect machine do not provide an option to use system assigned identity, therefore we have to create user assigned identity, by following these steps: 
- Search for Managed Identities
- Click Create
- Select Resource group to which you want to assign managed identity
- Select Region and Name
- Click Create


4) Assign Storage Blob Data Contributor Role to your worker (that belongs to your user assigned managed identity). 

  Open the Storage Account Container where you will store necessary files. 
  - From the left side navigation menu, select Access Control (IAM).
  - Select Add > Add role assignment
  - Select the role: Storage Blob Data Contributor
  - Click Next
  - On members page select managed identity
  - Find worker you want to assign role to
  - Finalize the role assignment by clicking on Next or directly click on Review + assign on the bottom of the
## Config preparation
1) Prepare Config Script
  - Under Helpers Folder - find Manage-HybridWorkerModules folder and open the script Prepare-ManageModulesConfig.ps1
  - Update lines below with your storage account and container details.
  - You can also update other variables like where the script will be store locally on your hybrid worker. 
  - Script also support usage of Azure VM instead of Arc Connected machine.
  - Make sure that $manageModulesScriptName is same as name of the script inside this folder. 

  ``` PowerShell
  param(
        $script:blobNameModulesJson = 'required-modules.json',
        $script:storageAccount = 'pjstorageaccountpj',
        $script:storageAccountContainer = 'temp',
        $script:runTimeVersion = 'Both',
        $script:workerLocalPath = "C:\ManageModules",
        $script:manageModulesScriptName = "Manage-Modules.ps1",
        $script:machineType = "arc" # "arc" or "VM"
    )

  ```
2)  Move the script Prepare-ManageModulesConfig.ps1 to YOUR_PROJECT_FOLDER\Source\Common\Configurations
2) Under Helpers Folder - find ManageModules.json file and move file to YOUR_PROJECT_FOLDER\Definitions\Configurations
```json
{
    "Name":  "ManageModulesConfig",
    "Description":  "Dsc configuration to ensure sync of modules between automation account and hybrid workers.",
    "Implementation":  "Prepare-ManageModulesConfig.ps1",
    "AutoCompile":  true
}
```
3) Switch task parameter 'helperHybridWorkerModuleSyncof' Automation Account to true. 
4) Deploy your code
3) You are done and good to go
 
 ### What will happen now ? 

 As soon as you finished steps above and deployed your code to automation account, these steps are done: 
  - Configuration from YOUR_PROJECT_FOLDER\Source\Common\Configurations - was compiled
  - Configuration is assigned to each Node (HybridWorker) you have registered to your automation account
  - Json file with all the modules from your automation account is created and stored to your Storage Account
  - Manage-Module.ps1 was copied to your Storage Account
  - Hybrid Worker will regularly check if there any changes to modules and perform them
  - You can track the status of your module instalaltion on each worker in your storage account container or directly under DSC blade in AutomationAccount.
  Example when worker is compliant 
  ``` json
  {
      "PJ-VM":  
      {
        "WasCompliant":  true,
        "LastChecked":  "2024-03-14 13:30:06 ",
        "Details":  null
      }
      }
  ```
 Example when worker performed changes:
 ```json
 {
    "PJ-VM": {
      "WasCompliant": false,
      "Details": {
        "FailedInstallation": [
        ],
        "InstalledModules": [
          "CosmosLite"
        ],
        "ReInstalledModules": []
      },
      "LastChecked": "2024-03-17 10:08:17 "
    }
  },
 ```

  - You can add your own module repository on top of Powershell Gallery if you wish by adding following hash table into Manage-Module.ps1 script
  ```Powershell
  $script:repositories = @{
    "NAME_OF_REPO"  = "URL_TO_REPO"
  }
  ```