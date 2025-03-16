function New-RunbookDefinition
{
    param
    (
        [string]
            #Name of the runbook as it appears in automation account
        $Name,
        [string]
            #Name of the file that has runbook content
        $Implementation,
        [ValidateSet('Graph','GraphPowerShell','GraphPowerShellWorkflow','PowerShell','PowerShellWorkflow','PowerShell','Python2','Python3','Script')]
        [string]
            #Type of the runbook
        $Type,
        [string]
            #Version of runtime to run on
            #Used by v1 of ManageAutomationAccount task
        $RuntimeVersion = '5.1',
        [string]
            #id of runtime environment to run on
            #Used by v2 of ManageAutomationAccount task
        $RuntimeEnvironment = 'PowerShell-5.1',
        [switch]
            #where runbook runs
            #for running on Azure, enter 'Azure' or empty string.
            #for running on hybrid worker, specify name of hybrid worker group
        $DoNotPublish,
        [string[]]
            #names of module that are needed by runbook
            #just for documentation of runbook requirements
        $RequiredModules,
        [switch]
            #returns formatted JSON rather than object
        $AsJson
    )

    process
    {
        $retVal = [PSCustomObject][ordered]@{
            Name = $Name
            Implementation = $Implementation
            Type = $Type
            RuntimeVersion = $RuntimeVersion
            RuntimeEnvironment = $RuntimeEnvironment
            AutoPublish = (-not $DoNotPublish.IsPresent)
            RequiredModules = $RequiredModules
        }
        if($AsJson)
        {
            $retVal | ConvertTo-Json
        }
        else
        {
            $retVal
        }
    }
}

function New-ConfigurationDefinition
{
    param
    (
        [string]
            #Name of the runbook as it appears in automation account
        $Name,
        [string]
            #Name of the file that has runbook content
        $Implementation,
        [string]
            #Description of configuration
        $Description,
        [switch]
            #whether automatically compile the configuration
        $AutoCompile,
        [hashtable]
            #specification of configuration parameters, if any
        $Parameters,
        [switch]
            #returns formatted JSON rather than object
        $AsJson
    )

    process
    {
        $retVal = [PSCustomObject][ordered]@{
            Name = $Name
            Description = $Description
            Implementation = $Implementation
            Parameters = $Parameters
            AutoCompile = $AutoCompile.IsPresent
        }
        if($AsJson)
        {
            $retVal | ConvertTo-Json
        }
        else
        {
            $retVal
        }
    }
}


function New-ConfigurationParameterValues
{
    param
    (
        [string]
            #Name of the parameter values as it appears in automation account
        $Name,
        [string]
            #Description 
        $Description,
        [string]
            #content 
        $Content,
        [string]
            #Configuration name
        $ConfigurationName,
        [switch]
            #returns formatted JSON rather than object
        $AsJson
    )

    process
    {
        $retVal = [PSCustomObject][ordered]@{
            Name = $Name
            Description = $Description
            ConfigurationName = $ConfigurationName
            Content = $Content
        }
        if($AsJson)
        {
            $retVal | ConvertTo-Json
        }
        else
        {
            $retVal
        }
    }
}


function New-VariableDefinition
{
    param
    (
        [string]
            #Name of the variable as it appears in automation account
        $Name,
        [string]
            #Description of variable
        $Description,
        [bool]
            #whether stored in plaintext or excrypted in automation account
        $Encrypted,
        [string]
            #content of the variable
            #Note: Only string variables are currently supported
        $Content,
        [switch]
            #returns formatted JSON rather than object
        $AsJson
    )

    process
    {
        $retVal = [PSCustomObject][ordered]@{
            Name = $Name
            Description = $Description
            Encrypted = $Encrypted
            Content = $Content
        }
        if($AsJson)
        {
            $retVal | ConvertTo-Json
        }
        else
        {
            $retVal
        }
    }
}

function New-JobScheduleDefinition
{
    param
    (
        [string]
            #Name of the runbook triggered by schedule
        $RunbookName,
        [string]
            #Name of the schedule that triggers the runbook
        $ScheduleName,
        [string]
            #Name of settings file
        $Settings,
        [switch]
            #returns formatted JSON rather than object
        $AsJson
    )

    process
    {
        if($null -eq $Parameters) {$Parameters = @{}}
        $retVal = [PSCustomObject][ordered]@{
            RunbookName = $RunbookName
            ScheduleName = $ScheduleName
            Settings = $Settings
        }
        if($AsJson)
        {
            $retVal | ConvertTo-Json
        }
        else
        {
            $retVal
        }
    }
}

function New-WebhookDefinition
{
    param
    (
        [string]
            #Name of the webhook
        $NamePrefix,
        [string]
            #Name of the runbook triggered by webhook
        $RunbookName,
        [string]
            #Name of webhook settings file
        $Settings,
        [Timespan]
            #how long till expire
            #default: 365.0:0:0 (1 year)
        $Expiration = ([Timespan]::FromDays(365)),
        [Timespan]
            #how long before expiration create a new one
            #must be parsable as timespan
            #default: 7.0:0:0 (1 week)
        $Overlap = ([Timespan]::FromDays(7)),
        [switch]
            #whether created as disabled
        $Disabled,
        [switch]
            #returns formatted JSON rather than object
        $AsJson,
        [string[]]
            #reserved for future use
        $SupportedRequestTypes
    )

    process
    {
        if($null -eq $Parameters) {$Parameters = @{}}
        $retVal = [PSCustomObject][ordered]@{
            NamePrefix = $NamePrefix
            RunbookName = $RunbookName
            Settings = $Settings
            Expiration = $Expiration.ToString()
            Overlap = $Overlap.ToString()
            Disabled = $Disabled.IsPresent
            SupportedRequestTypes = $SupportedRequestTypes
        }
        if($AsJson)
        {
            $retVal | ConvertTo-Json
        }
        else
        {
            $retVal
        }
    }
}

function New-ScheduleDefinition
{
    param
    (
        [string]
            #Name of the schedule as it appears in automation account
        $Name,
        [string]
            #hour and minute when schedule should trigger
            #Example: 07:00
            #Time is understood as Utc
        $StartTime,
        [int]
            #Interval for schedule trigger
            #works together with Frequeny parameter
            #Example: 2 --> every 2 hour, weeh, month
        $Interval,
        [ValidateSet('Minute','Hour', 'Day','Week','Month')]
        [string]
            #Frequency of recurrence
            #Note: We do not support one-time schedules here
            $Frequency,
        [uint32[]]
            #on which days in month it triggers
            #works together with Month frequency, otherwise ignored
            #Example: 2,15 --> every 2nd and 15th in month
        $MonthDays = @(),
        [ValidateSet('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')]
        [string[]]
            #on which days in week it triggers
            #works together with Week frequency, otherwise ignored
            #Example: 'Monday','Friday' --> every Monday and Friday
        $WeekDays = @(),
        [string]
            #Description of schedule
        $Description,
        [switch]
            #whether schedule should be disabled
        $Disabled,
        [switch]
            #returns formatted JSON rather than object
        $AsJson
    )

    process
    {
        $retVal = [PSCustomObject][ordered]@{
            Name = $Name
            StartTime = $startTime
            Interval = $Interval
            Frequency = $Frequency
            MonthDays = $MonthDays
            WeekDays = $WeekDays
            Description = $Description
            Disabled = $Disabled.IsPresent
        }
        if($AsJson)
        {
            $retVal | ConvertTo-Json
        }
        else
        {
            $retVal
        }
    }
}

function New-ModuleDefinition
{
    param
    (
        [string]
            #Name of the module as it appears in automation account
        $Name,
        [ValidateSet('5.1',"7.2")]
        [string]
            #Runtime for the module
            #Supported runtimes are 5.1 and 7.2
            #Used by v1 of ManageAutomationAccount task
        $RuntimeVersion,
        [string]
            #identifier of automation account runtime environment to import module to
            #used by v2 of ManageAutomationAccount task
            $RuntimeEnvironment,
        [string]
            #Version of module to be imported
        $Version,
        [string]
            #Link to module (typically in PS Gallery), without the version
            # module import mechanism the constructs url for module by putting together VersionIndependentLink and version to download the module
            #If this parameter is not specified, it means that m,odule is not published in public repository
            # in this case, module import mechanism looks for module implementation in the Modules folder under /Source folder
            # and packs it to zip file, uploads to blob container in given atroeage account, generates SAS token for it and constructs URL with SAS token
            # Url is then passed to automation account as download link for module
        $VersionIndependentLink,
        [int]
            #Order for module import
            #automation account cannot resolve module dependencies, so modules need to be imported in order
            #so as dependencies are satisfied
            #import logic imports modules according to their order
            #modules with the same order are imported in parallel to speed up procesing
            $Order,
        [switch]
            #returns formatted JSON rather than object
        $AsJson
    )

    process
    {
        $retVal = [PSCustomObject][ordered]@{
            Name = $Name
            RuntimeVersion = $RuntimeVersion
            RuntimeEnvironment = $RuntimeEnvironment
            Version = $Version
            VersionIndependentLink = $VersionIndependentLink
            Order = $Order
        }
        if($AsJson)
        {
            $retVal | ConvertTo-Json
        }
        else
        {
            $retVal
        }
    }
}
