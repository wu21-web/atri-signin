#Requires -Version 5.1
# Run from Windows PowerShell 5.1 or PowerShell 7 with Go on PATH.
# Uses a harmless executable, a uniquely named task, and temporary files.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module ScheduledTasks
$installer = Join-Path (Split-Path -Parent $PSScriptRoot) 'examples\integrations\cron-job.ps1'
$taskName = 'AtriSignIn-Test-' + [guid]::NewGuid().ToString('N')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) $taskName
$fixtureDirectory = Join-Path $testRoot ('test files ' + [char]0x4E2D + [char]0x6587 + ' [one] & two')
$originalPath = $env:PATH
$assertions = 0

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:assertions++
}

function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    $caught = $false
    try { & $Action } catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        $caught = $true
    }
    Assert-True $caught "Expected failure matching: $Pattern"
}

function Get-TestTask {
    Get-ScheduledTask | Where-Object { $_.TaskPath -eq '\' -and $_.TaskName -eq $taskName }
}

try {
    New-Item -ItemType Directory -Path $fixtureDirectory -Force | Out-Null
    $fixtureSource = Join-Path $testRoot 'fixture.go'
    $fixtureExecutable = Join-Path $fixtureDirectory 'atri-signin.exe'
    $csv = Join-Path $fixtureDirectory 'accounts [test].csv'
    $results = Join-Path $fixtureDirectory 'output [test]'
    Set-Content -LiteralPath $csv -Value 'test@example.invalid,unused' -Encoding ASCII
    @'
package main

import (
    "os"
    "path/filepath"
    "strings"
)

func main() {
    var results string
    for i := 1; i+1 < len(os.Args); i++ {
        if os.Args[i] == "--results" { results = os.Args[i+1] }
    }
    if results == "" { os.Exit(3) }
    if err := os.MkdirAll(results, 0700); err != nil { panic(err) }
    cwd, err := os.Getwd()
    if err != nil { panic(err) }
    if err := os.WriteFile(filepath.Join(results, "cwd.txt"), []byte(cwd), 0600); err != nil { panic(err) }
    if err := os.WriteFile(filepath.Join(results, "args.txt"), []byte(strings.Join(os.Args[1:], "\n")), 0600); err != nil { panic(err) }
    os.Exit(2)
}
'@ | Set-Content -LiteralPath $fixtureSource -Encoding ASCII
    & go build '-ldflags=-H=windowsgui' -o $fixtureExecutable $fixtureSource
    if ($LASTEXITCODE -ne 0) { throw 'Could not build the argument-capture fixture.' }

    # Verify PATH failure and both supported executable names using only fixtures.
    $emptyPath = Join-Path $testRoot 'empty'
    New-Item -ItemType Directory -Path $emptyPath | Out-Null
    $env:PATH = $emptyPath
    Assert-Throws { & $installer -AccountsPath $csv -TaskName $taskName -WhatIf } '*not found on PATH*'
    $env:PATH = $fixtureDirectory

    $common = @{ AccountsPath = $csv; TaskName = $taskName; At = '09:17' }
    # Model a fresh scheduler root without changing any of the user's tasks.
    # The native exact-path query reproduces the no-match error. Enumeration
    # can instead return nothing, or a same-named task in a different folder.
    $emptyQueryPath = '\' + $taskName + '\'
    foreach ($includeNestedTask in @($false, $true)) {
        & {
            function Get-ScheduledTask {
                [CmdletBinding()]
                param([string[]]$TaskPath)
                if ($PSBoundParameters.ContainsKey('TaskPath')) {
                    ScheduledTasks\Get-ScheduledTask -TaskPath $emptyQueryPath -ErrorAction Stop
                } elseif ($includeNestedTask) {
                    [pscustomobject]@{ TaskPath = '\Other\'; TaskName = $taskName }
                }
            }
            & $installer @common -WhatIf
            Assert-True $true 'A scheduler without root tasks should allow installation.'
        }
    }
    & $installer @common -WhatIf
    Assert-True ($null -eq (Get-TestTask)) '-WhatIf registered a task.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixtureDirectory 'results'))) '-WhatIf created the results directory.'
    Rename-Item -LiteralPath $fixtureExecutable -NewName 'atrisign.exe'
    & $installer @common -WhatIf
    Rename-Item -LiteralPath (Join-Path $fixtureDirectory 'atrisign.exe') -NewName 'atri-signin.exe'

    Assert-Throws { & $installer @common -ExecutablePath (Join-Path $testRoot 'missing.exe') } '*does not exist*'
    Assert-Throws { & $installer @common -ExecutablePath $csv } '*Windows .exe*'
    Assert-Throws { & $installer -AccountsPath $fixtureDirectory -TaskName $taskName } '*Expected a file*'
    Assert-Throws { & $installer -AccountsPath (Join-Path $testRoot 'missing.csv') -TaskName $taskName } '*does not exist*'
    Assert-Throws { & $installer -AccountsPath $csv -TaskName $taskName -At '24:00' } '*At*'
    Assert-Throws { & $installer @common -ResultsPath $csv } '*not a directory*'
    Assert-Throws { & $installer @common -MaxSigninCount 0 } '*MaxSigninCount*'
    Assert-True ($null -eq (Get-TestTask)) 'Invalid input registered a task.'

    # Exercise relative paths, defaults, native registration, and duplicate handling.
    Push-Location -LiteralPath $fixtureDirectory
    try {
        & $installer -AccountsPath '.\accounts [test].csv' -ExecutablePath '.\atri-signin.exe' -TaskName $taskName
    } finally { Pop-Location }
    $task = Get-TestTask
    Assert-True ($task.Actions[0].Execute -eq $fixtureExecutable) 'The executable path was not resolved.'
    Assert-True ($task.Actions[0].WorkingDirectory -eq $fixtureDirectory) 'The working directory was not resolved.'
    Assert-True ($task.Principal.LogonType -eq 'Interactive') 'The task does not use an interactive user token.'
    Assert-True ($task.Principal.RunLevel -eq 'Limited') 'The task requests elevated privileges.'
    Assert-True ($task.Settings.MultipleInstances -eq 'IgnoreNew') 'Overlapping task instances are allowed.'
    Assert-True $task.Settings.StartWhenAvailable 'Missed starts are not enabled.'
    Assert-True (-not $task.Settings.DisallowStartIfOnBatteries) 'Battery starts are disabled.'
    Assert-True (-not $task.Settings.StopIfGoingOnBatteries) 'Battery transitions stop the task.'
    Assert-True ($task.Triggers[0].DaysInterval -eq 1) 'The task is not daily.'
    Assert-True ([datetime]$task.Triggers[0].StartBoundary -gt (Get-Date)) 'The first trigger is not in the future.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixtureDirectory 'results'))) 'Registration started the executable.'
    Assert-Throws { & $installer @common } '*already exists*'

    # Updating must preserve exact native argv, even with quotes and trailing slashes.
    $hostArgument = 'https://example.invalid/a"b\'
    & $installer @common -Force -ResultsPath ($results + '\') -MaxSigninCount 3 -AtriHost $hostArgument
    $task = Get-TestTask
    Start-ScheduledTask -InputObject $task
    $deadline = (Get-Date).AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 250
        $info = Get-ScheduledTaskInfo -InputObject $task
        $currentTask = Get-TestTask
        $complete = (Test-Path -LiteralPath (Join-Path $results 'args.txt')) -and
            $currentTask.State -ne 'Running' -and $info.LastTaskResult -eq 2
    } while (-not $complete -and (Get-Date) -lt $deadline)
    Assert-True $complete "The fixture did not complete with exit code 2 (result: $($info.LastTaskResult))."
    $actual = [IO.File]::ReadAllLines((Join-Path $results 'args.txt'))
    $expected = @('--accounts', $csv, '--results', ($results + '\'), '--max-signin-count', '3', '--atri-host', $hostArgument)
    Assert-True ($actual.Count -eq $expected.Count) 'The native argument count is wrong.'
    for ($i = 0; $i -lt $expected.Count; $i++) {
        Assert-True ($actual[$i] -ceq $expected[$i]) "Native argument $i was changed."
    }
    Assert-True ([IO.File]::ReadAllText((Join-Path $results 'cwd.txt')) -eq $fixtureDirectory) 'The process ran in the wrong directory.'
    Write-Host "Passed $assertions assertions on PowerShell $($PSVersionTable.PSVersion)."
} finally {
    $env:PATH = $originalPath
    $task = Get-TestTask
    if ($null -ne $task) {
        Stop-ScheduledTask -InputObject $task -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -InputObject $task -Confirm:$false
    }
    # Guard the only recursive deletion; never delete outside this unique temp folder.
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedRoot.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolvedRoot) -eq $taskName -and
        (Test-Path -LiteralPath $resolvedRoot)) {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
