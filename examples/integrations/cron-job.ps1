#Requires -Version 5.1
<#
.SYNOPSIS
Register a daily Atri Sign-in task for the current Windows user.
.DESCRIPTION
Finds atri-signin.exe (or atrisign.exe) on PATH and prompts for the accounts
CSV if omitted. Use -ExecutablePath for a downloaded release with another name.
The task runs only while this user is logged on, without storing a Windows
password. Use -WhatIf to preview and -Force to replace an existing task.
.EXAMPLE
.\cron-job.ps1 -AccountsPath 'C:\Atri Sign-in\accounts.csv' -At '09:17'
.EXAMPLE
.\cron-job.ps1 -AccountsPath .\accounts.csv -ExecutablePath .\atri-signin.exe -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$AccountsPath,

    [ValidatePattern('^([01][0-9]|2[0-3]):[0-5][0-9]$')]
    [string]$At = '09:17',

    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^[^\\/:*?"<>|]+$')]
    [string]$TaskName = 'AtriSignIn',

    [string]$ExecutablePath,
    [string]$ResultsPath,

    [ValidateRange(1, 2147483647)]
    [int]$MaxSigninCount = 2,

    [string]$AtriHost,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This script requires Windows Task Scheduler.'
}
Import-Module ScheduledTasks -ErrorAction Stop

function Resolve-InputFile([string]$Path) {
    # Resolve first: Windows PowerShell 5.1 can mishandle relative literal paths
    # when the current directory contains square brackets.
    $fileProvider = $null
    $fileDrive = $null
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $Path, [ref]$fileProvider, [ref]$fileDrive)
    if ($fileProvider.Name -ne 'FileSystem') {
        throw "Expected a filesystem file: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSProvider.Name -ne 'FileSystem' -or $item.PSIsContainer) {
        throw "Expected a file: $Path"
    }
    return $item.FullName
}

function ConvertTo-NativeArgument([string]$Value) {
    # Windows argv quoting: escape quotes and double backslashes before a quote
    # (including the closing quote). No command shell interprets these arguments.
    return '"' + (($Value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
    foreach ($name in @('atri-signin.exe', 'atrisign.exe')) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -ne $command) {
            $ExecutablePath = $command.Path
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
        throw 'atri-signin.exe was not found on PATH. Add its directory to PATH or pass -ExecutablePath.'
    }
}
$ExecutablePath = Resolve-InputFile $ExecutablePath
if ([IO.Path]::GetExtension($ExecutablePath) -ine '.exe') {
    throw '-ExecutablePath must point to a Windows .exe file.'
}

if ([string]::IsNullOrWhiteSpace($AccountsPath)) {
    $AccountsPath = Read-Host 'Path to the accounts CSV (without surrounding quotes)'
}
if ([string]::IsNullOrWhiteSpace($AccountsPath)) {
    throw 'An accounts CSV path is required.'
}
$AccountsPath = Resolve-InputFile $AccountsPath
$workingDirectory = Split-Path -Parent $AccountsPath

if ([string]::IsNullOrWhiteSpace($ResultsPath)) {
    $ResultsPath = Join-Path $workingDirectory 'results'
}
$provider = $null
$drive = $null
$ResultsPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
    $ResultsPath, [ref]$provider, [ref]$drive)
if ($provider.Name -ne 'FileSystem') {
    throw '-ResultsPath must be a filesystem directory.'
}
if ((Test-Path -LiteralPath $ResultsPath) -and
    -not (Test-Path -LiteralPath $ResultsPath -PathType Container)) {
    throw "The results path is not a directory: $ResultsPath"
}

$arguments = @(
    '--accounts', $AccountsPath,
    '--results', $ResultsPath,
    '--max-signin-count', [string]$MaxSigninCount
)
if (-not [string]::IsNullOrWhiteSpace($AtriHost)) {
    $arguments += @('--atri-host', $AtriHost)
}
$argumentLine = ($arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '

# Enumerate first: an exact -TaskPath query throws when the root has no tasks.
# Compare paths and names literally so nested tasks and wildcards cannot collide.
$existing = Get-ScheduledTask |
    Where-Object { $_.TaskPath -eq '\' -and $_.TaskName -eq $TaskName }
if ($null -ne $existing -and -not $Force) {
    throw "Task '$TaskName' already exists. Use -Force to replace it, or choose another -TaskName."
}

$now = Get-Date
$firstRun = $now.Date.Add([TimeSpan]::ParseExact($At, 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture))
if ($firstRun -le $now) {
    $firstRun = $firstRun.AddDays(1)
}

Write-Host "Task:       $TaskName (daily at $At, local time)"
Write-Host "Executable: $ExecutablePath"
Write-Host "Arguments:  $argumentLine"
Write-Host "Results:    $ResultsPath"

if ($PSCmdlet.ShouldProcess($TaskName, 'Register daily Atri Sign-in task')) {
    $action = New-ScheduledTaskAction -Execute $ExecutablePath -Argument $argumentLine -WorkingDirectory $workingDirectory
    $trigger = New-ScheduledTaskTrigger -Daily -At $firstRun
    $userId = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Description 'Run Atri Sign-in daily for the current user. Managed by examples/integrations/cron-job.ps1.'
    Register-ScheduledTask -TaskName $TaskName -TaskPath '\' -InputObject $task -Force:$Force | Out-Null
    Write-Host "Registered. First scheduled run: $($firstRun.ToString('yyyy-MM-dd HH:mm'))."
    Write-Host 'Keep the executable and CSV at these paths. The task runs while you are logged on (including when locked).'
}
