# Helper: PowerShell Module Management for Hybrid Worker (Automation Account).
Use this helper you if you would like to manage PowerShell modules on all your hybrid workers in an automated way directly from your project folder without need to go to your servers ! 

Note: Motivation behind creation of this helper is that native DSC PackageManagement module do not work with additional parameters like -AllowClobber or -Force. This leads to multiple issues if there is a need to upgrade module. 

- Prerequisites:
  - Automation Account
  - Hybrid Worker Registered to Arc
  - Hybrid Worker Registered to Dsc (of your Automation Account)
  - Managed Identity
  - Azure Storage Account

# Pre-requites preparation
## 1) Register Server to Azure Arc: 

Note: If you use Azure VM this step is not required. 

  - Navigate to Azure Arc Machines in Azure
  - Click Machines
  - Click Add/Create
  - Click Add a single server
  - Click Generate Script
  - Select your Azure Resources (Resource Group, Region)
  - Download the script
  - Run the script in elevated prompt on your server - make sure you allow all outbound URLs or you use proxy 


## 2) Register Server to DSC


 Run .\Register-HybridWorkerToDsc.ps1 script in an elevated prompt on your HybridWorker, that will register your server into Dsc. Before you do that update lines below. You can get your URL and key from AutomationAccount\Keys. 

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
! Make sure you keep ConfigurationMode set to 'ApplyAndAutoCorrect' !
Once this step is done, you can see your worker registered in Automation Account under DSC blade. 

## 3) Create Managed Identity

Note: Arc Connect machine do not provide an option to use system assigned managed identity, therefore we have to create user assigned managed identity, by following these steps: 
- Search for Managed Identities
- Click Create
- Select Resource group to which you want to assign managed identity
- Select Region and Name
- Click Create


## 4) Assign Storage Blob Data Contributor Role
You have to assign role to your worker (that belongs to your user assigned managed identity) as well as to your Service Connection (in case you are deploying with pipeline). 

  Open the Storage Account Container where you will store necessary files. 
  - From the left side navigation menu, select Access Control (IAM).
  - Select Add > Add role assignment
  - Select the role: Storage Blob Data Contributor
  - Click Next
  - On members page select managed identity
  - Find worker you want to assign role to
  - Finalize the role assignment by clicking on Next or directly click on Review + assign on the bottom of the

# Config preparation

## 1) Prepare source and definition files

  -  Under Helpers folder - find HybridWorkerModulesManagement folder and open Prepare-HybridWorkerModuleManagementParamValuesSource.json.
  ```
 Helpers
   ├── HybridWorkerModulesManagement
   │   └── Prepare-HybridWorkerModuleManagementParamValuesSource.json

```
  - Mandatory: Update your storage account and container details.

  - Optional: update other variables: 
    -  "workerLocalPath" --> folder where the script will be stored locally on your hybrid worker. 
    -  "runTimeVersion" --> runtime under which script will be executed - availables options: ["5", "7", "Both"].
    -  "blobNameModulesjson" --> name of the json file in your storage account that defines which modules should be installed (Note: if you change the name, make sure name is the same as in Manage-AutomationAccount.ps1 - see step #6 for more details).
    -  "manageModulesScriptName" --> Script that is used for actual module management on hybrid workers. Script is deployed from your project folder to Storage Account from where its later downloaded by each worker and called by DSC configuration that was defined as part of this step. (Note: if you change the name, make sure name is the same as in Manage-AutomationAccount.ps1 - see step #6 for more details).
    -  "machineType" --> on top of default "arc" option, there is an option to use "vm"  (in case Azure VM is used as DSC node - e.g. testing)

  ``` json

  {
    "storageAccount": "YOUR_STORAGE_ACCOUNT",
    "storageAccountContainer": "YOUR_STORAGE_CONTAINER",
    "workerLocalPath": "C:\\ManageModules",
    "runTimeVersion": "Both", 
    "blobNameModulesJson": "required-modules.json",
    "manageModulesScriptName": "HybridWorkerModuleManagement.ps1",
    "machineType": "arc" 
  }

  ```
-  Move json  (Source file) (Prepare-HybridWorkerModuleManagementParamValuesSource.json) to YOUR_PROJECT_FOLDER\Source\ENVIRONMENT_NAME\ConfigurationParameterValues --> make sure you do this per environment

-  Move script (Source file)  (Prepare-HybridWorkerModuleManagement.ps1) to YOUR_PROJECT_FOLDER\Source\ENVIRONMENT_NAME\Configurations --> make sure you do this per environment

-  Move json (Definition file) (Prepare-HybridWorkerModuleManagement.json) file to YOUR_PROJECT_FOLDER\Definitions\Configurations

-  Move json (Definition file) (Prepare-HybridWorkerModuleManagementParamValuesDef.json) to YOUR_PROJECT_FOLDER\Definitions\ConfigurationParameterValues
-  Move script HybridWorkerModuleManagement.ps1 to YOUR_PROJECT_FOLDER\Helpers\HybridWorkerModuleManagement\HybridWorkerModuleManagement.ps1 (you have to create missing folder structure based on hrierarchy below. Note: if you decide to place this script no different folder - please make sure you update path to it - please see section "Important" in this chapter).
```
YOUR_PROJECT_FOLDER
│
├── Source
│   ├── ENVIRONMENT_NAME (e.g., DEV, TEST, PROD)
│   │   ├── ConfigurationParameterValues
│   │   │   └── Prepare-HybridWorkerModuleManagementParamValuesSource.json
│   │   └── Configurations
│   │       └── Prepare-HybridWorkerModuleManagement.ps1
│   │
├── Definitions
│   ├── Configurations
│   │   └── Prepare-HybridWorkerModuleManagement.json
│   │
│   └── ConfigurationParameterValues
│       └── Prepare-HybridWorkerModuleManagementParamValuesDef.json
│
├── Helpers
│   ├── HybridWorkerModuleManagement
│   │   └── HybridWorkerModuleManagement.ps1
│   │
└── (Other Project Files and Folders)


```
## 2) Activate helper

-  If you are using deployment pipeline update your pipeline input variable "helperHybridWorkerModuleManagement to true"
```yml
- task: Manage-AutomationAccount@1
  inputs:
    scope: 'SCOPE'
    environmentName: 'ENV'
    projectDir: '$(System.DefaultWorkingDirectory)'
    subscription: 'SUBSCRIPTION'
    azureSubscription: 'SERVICE_CONNECTION'
    resourceGroup: 'RG'
    automationAccount: 'AA'
    storageAccount: 'SA'
    storageAccountContainer: 'SC'
    helperHybridWorkerModuleManagement: true #--> switch to true
 ```  
 -  If you are not using pipeline, add this variable into your script 


### Important

Make sure that $manageModulesPs1Path matches an actual path of ManageModule script, otherwise script will not be copied to StorageAccount - by default path to Helpers folder is set to PROJECT_DIR\Helpers\HybridWorkerModuleManagement\HybridWorkerModuleManagement.ps1. 

All related variables inside Manage-AutomationAccount.ps1 are these:

```PowerShell

if($helperHybridWorkerModuleManagement -eq $true)
{
    $blobNameModulesJson = "required-modules.json"
    $manageModulesPs1 = "HybridWorkerModuleManagement.ps1"
    $manageModulesPs1Path = "$($projectDir)\Helpers\HybridWorkerModuleManagement\$($manageModulesPS1)"
}
```
## 3) Define modules 

- Define all modules you would like to install under YOUR_PROJECT_FOLDER\Definitions\Modules (json file per module) e.g.

```json
{
    "Name": "AadAuthenticationFactory",
    "RuntimeVersion": "5.1",
    "Version": "3.0.5",
    "VersionIndependentLink": "https://www.powershellgallery.com/api/v2/package/AadAuthenticationFactory",
    "Order": 1
}
```
- Typical structure: 
```
YOUR_PROJECT_FOLDER
│
├── Definitions
│   ├── Modules
│   │   ├── AadAuthenticationFactory_5.1.json
│   │   ├── AadAuthenticationFactory_7.2.json
│   │   ├── CosmosLIte_5.1.json
│   │   ├── CosmosLIte_7.2.json
│   │   ├── ExchangeOnlineManagement_5.1.json
│   │   ├── ExoHelper_5.1.json
│   │   ├── Microsoft.Graph.Applications_5.1.json
│   │   ├── Microsoft.Graph.Authentication_5.1.json
│   │   ├── Microsoft.Graph.Authentication_7.2.json
│   │   ├── MicrosoftTeams_5.1.json
│   │   ├── PnP.PowerShell_5.1.json
│   │   ├── S.DS.P_5.1.json
│   │   └── S.DS.P_7.2.json
│
└── (Other Project Files and Folders)

``` 

## 4) Deploy your solution 
## 5) You are done !

 
 ## What will happen now ? 

 As soon as you trigger deployement of your code to automation account, these steps are done: 
  - Configuration from YOUR_PROJECT_FOLDER\Source\ENVIRONMENT_NAME\Configurations - will be compiled and uploaded to your DSC.
  - Configuration will be assigned to each Node (HybridWorker) you have. registered to your automation account.
  - Json file HybridWorkerModuleManagement.json with all the modules from your definition folder will be created and stored to your Storage Account.
  - HybridWorkerModuleManagement.ps1 will be copied to your Storage Account.

After that: 

  - Hybrid Worker will regularly check if there any changes to modules and will perform them (e.g. version upgrade/downgrade, new module).
  - You can track the status of your module installation on each worker in your storage account container or directly under DSC blade in AutomationAccount.
  - Use definitions folder for modules for your management - e.g. adding new, module, changing versions.

Testing: 
  - If you do not want to wait for Node to react on your changes you can make it faster by running: 
  ```PowerShell
    Get-Process wmiprvse|Stop-Process -Force
    Start-Process wmiprvse 
  ```
  - Commands above will restart service responsible for DSC. 

  - After that you can run command below to simulate what exactly is being done, when configuration is taken over from AutomationAccount and executed locally. 
  ```PowerShell
  Invoke-CimMethod -Namespace root/Microsoft/Windows/DesiredStateConfiguration -Cl MSFT_DSCLocalConfigurationManager -Method PerformRequiredConfigurationChecks -Arguments @{Flags = [System.UInt32]1} -Verbose
  ```
  
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
  - You can add your own module repository on top of Powershell Gallery if you wish by adding following hash table into HybridWorkerModuleManagement.ps1 script (section is by default commented out)
  ```Powershell
  $script:repositories = @{
    "NAME_OF_REPO"  = "URL_TO_REPO"
  }
  ```