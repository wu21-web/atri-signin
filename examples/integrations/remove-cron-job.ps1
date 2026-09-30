#Requires -Version 5.1
<#
.SYNOPSIS
Remove the daily Windows task created by cron-job.ps1.
.DESCRIPTION
Removes the named task from the Task Scheduler root folder. The default name
is AtriSignIn. Missing tasks are a successful no-op, so removal can be repeated.
Use -WhatIf to preview or -Confirm:$false for unattended removal. The executable,
accounts CSV, and results are retained. An already-running sign-in can finish.
.EXAMPLE
.\remove-cron-job.ps1
.EXAMPLE
.\remove-cron-job.ps1 -TaskName 'AtriSignIn-Personal' -WhatIf
.EXAMPLE
.\remove-cron-job.ps1 -TaskName 'AtriSignIn-Personal' -Confirm:$false
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^[^\\/:*?"<>|]+$')]
    [string]$TaskName = 'AtriSignIn'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This script requires Windows Task Scheduler.'
}
Import-Module ScheduledTasks -ErrorAction Stop

# Enumerate first to allow an empty root, then match the path and name literally.
$task = Get-ScheduledTask |
    Where-Object { $_.TaskPath -eq '\' -and $_.TaskName -eq $TaskName }
if ($null -eq $task) {
    Write-Host "Task '\$TaskName' is not registered. Nothing to remove."
    return
}

Write-Host "Task:  \$($task.TaskName)"
Write-Host "State: $($task.State)"
if ($PSCmdlet.ShouldProcess("\$($task.TaskName)", 'Remove scheduled Atri Sign-in task')) {
    # Confirm once above; InputObject identifies the exact task without wildcards.
    Unregister-ScheduledTask -InputObject $task -Confirm:$false
    Write-Host 'Removed the schedule. The executable, accounts CSV, and results are retained.'
}
