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

