Param
(
    [Parameter(Mandatory=$false)]
    [string]$ConfigurationName='Sample-Variable'
)

$connectionName = "AzureRunAsConnection"

$servicePrincipalConnection=Get-AutomationConnection -Name $connectionName
Login-AzAccount -ServicePrincipal `
    -TenantId $servicePrincipalConnection.TenantId `
    -ApplicationId $servicePrincipalConnection.ApplicationId `
    -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint | out-null

#import utility functions from common library runbook
. .\Utils.ps1

#load configuration
$cfg = ConvertFrom-Json -InputObject (Get-AutomationVariable -Name $ConfigurationName)

#get information about automation account we're running in
$self = Get-Self

#initialize telemetry to log to AppInsights
Initialize-AiLogger -InstrumentationKey $cfg.InstrumentationKey -Application $self.AutomationAccountName -Component $self.RunbookName

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
