# Helper: PowerShell Module Management for Hybrid Worker (Automation Account).
Use this helper you if you would like to manage PowerShell modules on all your hybrid workers in an automated way.

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


2) To register Server to DSC: Run .\Register-HybridWorkerToDsc.ps1 script in elevated prompt on your HybridWorker, that will register your server into Dsc. Update lines below. You can get your URL and key from AutomationAccount\Keys. 
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

Note: Arc Connect machine do not provide an option to use system assigned managed identity, therefore we have to create user assigned managed identity, by following these steps: 
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
1) Prepare Definition file ManageModules.json
  - Under Helpers folder - find HybridWorkerModulesSync folder and open ManageModules.json file.
  - Update lines below with your storage account ($storageAccount) and container ($storageAccountContainer) details.
  - You can also (optionally) update other variables like: 
    -  "$workerLocalPath" --> place where the script will be stored locally on your hybrid worker. 
    -  "$machineType" --> on top of default "arc" option, there is an option to user "vm" - in case Azure VM is used as DSC node.
    -  "$runTimeVersion" --> runtime under which script will be executed - options "5", "7", "Both".
    -  "$blobNameModulesjson" --> name of json file in your storage account that defines which modules should be installed (Note: if you change the name, make sure name is the same as in Manage-AutomationAccount.ps1 - see step #4 for more details).
    -  "$manageModulesScriptName" --> Name of the script that is deployed to worker (Note: if you change the name, make sure name is the same as in Manage-AutomationAccount.ps1 - see step #4 for more details).
  ``` json
   "ParameterValues": {
        "storageAccount": "STORAGE_ACCOUNT_NAME",
        "storageAccountContainer": "STORAGE_ACCOUNT_CONTAINER",
        "workerLocalPath": "C:\\ManageModules",
        "runTimeVersion": "Both", 
        "blobNameModulesJson": "required-modules.json",
        "manageModulesScriptName": "Manage-Modules.ps1",
        "machineType": "arc" 
    }

  ```

2) Move the script Prepare-ManageModulesConfig.ps1 to YOUR_PROJECT_FOLDER\Source\Common\Configurations
3) Move definition file ManageModules.json file to YOUR_PROJECT_FOLDER\Definitions\Configurations
```json
{
    "Name":  "ManageModulesConfig",
    "Description":  "Dsc configuration to ensure sync of modules between automation account and hybrid workers.",
    "Implementation":  "Prepare-ManageModulesConfig.ps1",
    "AutoCompile":  true
}
```
4) Switch task parameter 'helperHybridWorkerModuleSync' of your Automation Account to true. All related variables inside Manage-AutomationAccount.ps1 are these: 

```POwershell
if($helperHybridWorkerModuleSync)
{
    $blobNameModulesJson = "required-modules.json"
    $manageModulesPs1 = "Manage-Modules.ps1"
    $manageModulesPs1Path = "$($grandparentDirectory)\Helpers\HybridWorkerModuleSync\$($manageModulesPS1)"
}
```

5) Define all modules you would like to install under YOUR_PROJECT_FOLDER\Definitions\Configurations (json file pre module) e.g.
```json
{
    "Name": "AadAuthenticationFactory",
    "RuntimeVersion": "5.1",
    "Version": "3.0.5",
    "VersionIndependentLink": "https://www.powershellgallery.com/api/v2/package/AadAuthenticationFactory",
    "Order": 1
}
```

6) Deploy your solutin (by running Manage-AutomationAccount.ps1)
7) You are done !
 
 ### What will happen now ? 

 As soon as you trigger deployement of your code to automation account, these steps are done: 
  - Configuration from YOUR_PROJECT_FOLDER\Source\Common\Configurations - will be compiled and uploaded to your DSC.
  - Configuration will be assigned to each Node (HybridWorker) you have. registered to your automation account.
  - Json file ManageModules.json with all the modules from your definition folder will be created and stored to your Storage Account.
  - Manage-Modules.ps1 will be copied to your Storage Account.

After that: 

  - Hybrid Worker will regularly check if there any changes to modules and will perform them (e.g. version upgrade/downgrade, new module).
  - You can track the status of your module installation on each worker in your storage account container or directly under DSC blade in AutomationAccount.
  - Use definitions folder for modules for your management - e.g. adding new, module, changing versions.
  
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
## Other functionalities
  - You can add your own module repository on top of Powershell Gallery if you wish by adding following hash table into Manage-Module.ps1 script (section is by default commented out)
  ```Powershell
  $script:repositories = @{
    "NAME_OF_REPO"  = "URL_TO_REPO"
  }
  ```