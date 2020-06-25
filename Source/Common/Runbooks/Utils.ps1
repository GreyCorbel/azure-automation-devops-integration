<#
    .DESCRIPTION
        Gets instance of jub function is executed in
        Used to retrieve information about current automation account
        Assumes that Login-AzAccount was already performed

    .NOTES
        AUTHOR: JiriF
#>

#region AutomationSupport
Function Get-Self
{
    if($null -ne $PSPrivateMetadata.JobId.Guid)
    {
        $Error.Clear()
        $accounts = @(Get-AzAutomationAccount -ErrorAction SilentlyContinue)
        if($Error.Count -eq 0)
        {
            foreach($acct in $accounts)
            {
                $job = Get-AzAutomationJob -ResourceGroupName $acct.ResourceGroupName -AutomationAccountName $acct.AutomationAccountName -Id $PSPrivateMetadata.JobId.Guid -ErrorAction SilentlyContinue
                if (!([string]::IsNullOrEmpty($job))) { Break; }
            }
            $job
        }
        else
        {
            Write-Warning "You must call Login-AzAccount for automatic recognition of automation account we're running in"
            $Error.Clear()
        }
    }
}

#endregion

#region AppInsightLoggingSupport
<#
    .DESCRIPTION
        Initializes telemetry client
        and related property bag that gets automatically added to every logged data
    .NOTES
        AUTHOR: JiriF
#>
Function Initialize-AiLogger
{
    Param
    (
        [Parameter(Mandatory)]
        [string]
            #AppInsights instrumentation key
        $InstrumentationKey,
        [Parameter(Mandatory)]
        [string]
            #Name of automation account
        $Application,
        [Parameter(Mandatory)]
        [string]
            #name of runbook
        $Component
    )
    
    $script:telemetryClient=new-object Microsoft.ApplicationInsights.TelemetryClient
    $script:telemetryClient.InstrumentationKey = $InstrumentationKey
    $script:telemetryMetadata = New-Object 'System.Collections.Generic.Dictionary[String,String]'
    $script:telemetryMetadata['Application']=$Application
    $script:telemetryMetadata['Component']=$Component
}

<#
    .DESCRIPTION
        Sends trace with given severity to AppInsight
    .NOTES
        AUTHOR: JiriF
#>
Function Write-AiTrace
{
    param (
        [Parameter(Mandatory)]
        [string]
            #Message to be traced
        $Message,
        [Parameter()]
        [Microsoft.ApplicationInsights.DataContracts.SeverityLevel]
            #Severity of message sent
        $Severity='Information'
    )
    Process
    {
        if($null -ne $script:telemetryClient)
        {
            $script:telemetryClient.TrackTrace($message, $severity, $script:telemetryMetadata)
        }
    }
}

<#
    .DESCRIPTION
        Traces exception to AppInsight
    .NOTES
        AUTHOR: JiriF
#>
Function Write-AiException
{
    param (
        [Parameter(Mandatory)]
        [System.Exception]
            #Message to be traced
        $Exception
    )
    Process
    {
        if($null -ne $script:telemetryClient)
        {
            $script:telemetryClient.TrackException($Exception, $script:telemetryMetadata)
        }
    }
}

<#
    .DESCRIPTION
        Traces exception to AppInsight
    .NOTES
        AUTHOR: JiriF
#>
Function Write-AiEvent
{
    param (
        [Parameter(Mandatory)]
        [string]
            #Message to be traced
        $EventName,
        [Parameter()]
        [System.Collections.Generic.Dictionary[String,Double]]
            #optional metrics to be sent with event
        $Metrics=$null

    )
    Process
    {
        if($null -ne $script:telemetryClient)
        {
            $script:telemetryClient.TrackEvent($EventName, $script:telemetryMetadata, $Metrics)
        }
    }
}

<#
    .DESCRIPTION
        Helper that returns empty dictionary for adding of metrics
        Optionally adds metric names with value = 0
    .NOTES
        AUTHOR: JiriF
#>
Function Get-AiMetricInstance
{
    param
    (
        [Parameter()]
        [string[]]
        $MetricNames=@()
    )
    Process
    {
        $instance = (new-object 'System.Collections.Generic.Dictionary[String,Double]')
        foreach($name in $MetricNames)
        {
            $instance.Add($name,0)
        }
        $instance
    }
}

#endregion
