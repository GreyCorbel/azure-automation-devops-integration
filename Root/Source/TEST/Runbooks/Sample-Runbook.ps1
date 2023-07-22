Param
(
    [Parameter(Mandatory=$false)]
    [string]$ConfigurationName='Sample-Variable'
)

Login-AzAccount -Identity
# Import Application Insight logging module
# see https://github.com/GreyCorbel/AiLogging
Import-Module AiLogging
#import utility functions from common library runbook
. .\Utils.ps1

#load configuration
$cfg = ConvertFrom-Json -InputObject (Get-AutomationVariable -Name $ConfigurationName)

#initialize telemetry to log to AppInsights
Initialize-AiLogger -InstrumentationKey $cfg.InstrumentationKey -Application 'MyAutomationAccount' -Component 'Sample-Runbook'

#report start
Write-AiTrace -Message "Started processing"

#do some other work work
$metrics = Get-AiMetricInstance -MetricNames 'ProcessedItems','FailedItems'
$metrics["ProcessedItems"]=15
$metrics["FailedItems"]=1
#report some performance metrics
Write-AiEvent -EventName "Runbook execution metrics" -Metrics $metrics

#report finish
Write-AiTrace -Message "FinishedProcessing"
