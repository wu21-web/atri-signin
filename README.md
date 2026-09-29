# Atri Sign-in

[![CI](https://github.com/wu21-web/atri-signin/actions/workflows/build.yml/badge.svg)](https://github.com/wu21-web/atri-signin/actions/workflows/build.yml)

A one-shot Go CLI that logs into each account listed in a CSV and claims the daily check-in on Atri Shop.

## Input

Create `accounts.csv` in the project root:

```csv
one@example.com,password-one
two@example.com,password-two
```

There is no header. Each row must contain exactly two fields. Passwords containing commas, quotes, or newlines must be CSV-quoted. Blank lines are ignored, and duplicate email addresses are skipped.

`accounts.csv` is gitignored. Passwords are never written to stdout or the results file.

You can reference example inputs and outputs in the `examples/` directory.

## Run

```sh
go build -o atri-signin ./cmd/atri-signin
./atri-signin --accounts accounts.csv --max-signin-count 2
```

Useful flags:

```text
--accounts accounts.csv
--max-signin-count 2
--results results
--timeout 25s
--worker-timeout 2m
-H, --atri-host shop.atrishop.work
--version
```

`--max-signin-count` limits how many account subprocesses run at once. The queue continues until every row has been processed.

`-H` and `--atri-host` override the target host. They accept a hostname, such as `shop.atrishop.work`, or a full base URL, such as `https://shop.atrishop.work`. A plain hostname defaults to HTTPS.

Each completed run writes `results/signin-YYYYMMDD-HHMMSS.csv` with the timestamp, email, status, message, reward amount, balance, and duration. The most common successful statuses are `success` and `already_signed`.

`-v` and `--version` print the version embedded at build time. Tagged release binaries print the exact tag, while normal development builds print a `dev-<revision>` value.

## Process model

The parent process parses and shuffles the accounts, then runs a bounded worker queue. Each worker launches a separate copy of the binary in hidden worker mode and sends that account's credentials over stdin. A hung worker is terminated when its timeout expires.

The worker follows the browser flow: load the login page, submit the encrypted login request, open the user center, wait briefly, and submit the encrypted daily check-in request. Requests use the installed Chrome 153 user agent and the same cookie, signing, and encryption behavior as the site's JavaScript client.

The program retries transient network errors, HTTP 429 responses, and server errors twice with jittered backoff. Invalid credentials are reported without retrying.

## Scheduling

The command is one-shot. Run it daily with cron, launchd, or another scheduler. For example:

```cron
17 9 * * * cd /path/to/atri-signin && ./atri-signin >> signin.log 2>&1
```

### Windows Task Scheduler

Use [`examples/integrations/cron-job.ps1`](examples/integrations/cron-job.ps1) with Windows PowerShell 5.1 or PowerShell 7. Put `atri-signin.exe` on `PATH` (the name `atrisign.exe` is also accepted), or supply `-ExecutablePath`. For example, from the repository root:

```powershell
.\examples\integrations\cron-job.ps1 -AccountsPath 'C:\Atri Sign-in\accounts.csv' -At '09:17'

# A downloaded release can keep its original filename.
.\examples\integrations\cron-job.ps1 -AccountsPath '.\accounts.csv' `
    -ExecutablePath 'C:\Tools\atri-signin-v0.4-windows-amd64.exe' -At '09:17'
```

Omit `-AccountsPath` to enter the CSV path interactively, without surrounding quotes. `-At` uses 24-hour `HH:mm` local time and defaults to `09:17`. Relative paths are resolved from the current PowerShell directory when registering the task. The executable and CSV must exist; their absolute paths are saved in the task, so keep them in place or rerun the script with `-Force` after moving them.

The task is named `AtriSignIn` by default. Use `-TaskName` for another name, `-WhatIf` to preview without registering, or `-Force` to replace a task with the same name. Optional `-ResultsPath`, `-MaxSigninCount`, and `-AtriHost` configure the corresponding CLI flags. Results default to a `results` directory next to the CSV, created by the CLI when it writes its first report. Protect the CSV as it contains account passwords; the task stores only its path.

The task runs as the current user with normal privileges and only while that user is logged on, including when the screen is locked. The computer must be on and have network access; the script does not wake it from sleep. Task Scheduler is configured to run missed starts when available, allow battery operation, and skip a new instance while the previous run is still active. The first scheduled start is the next occurrence of `-At`; registering a task does not immediately run sign-in. A console window may appear during execution.

Manage the task in Task Scheduler (`taskschd.msc`) or PowerShell:

```powershell
Get-ScheduledTaskInfo -TaskName 'AtriSignIn' -TaskPath '\'
Start-ScheduledTask -TaskName 'AtriSignIn' -TaskPath '\' # Run sign-in now.
Unregister-ScheduledTask -TaskName 'AtriSignIn' -TaskPath '\' # Remove the schedule.
```

After the CLI finishes, `LastTaskResult` is `0` for success, `1` for setup/runtime errors, or `2` if any account failed; consult the result CSV for per-account outcomes. Windows can report other codes if the task has not run or could not start. These tasks execute the CLI directly, so stdout/stderr are not saved to a log. If local execution policy blocks the downloaded script, inspect it and use `Unblock-File` on that file, or run it once with `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\examples\integrations\cron-job.ps1` and the desired parameters. This does not change the machine's execution policy; organization policy may still prohibit it.

To test the integration on Windows with Go installed, run `powershell.exe -NoProfile -File .\tests\windows-scheduling.ps1` or `pwsh.exe -NoProfile -File .\tests\windows-scheduling.ps1`. The test builds a harmless argument-capture executable, creates and runs a uniquely named temporary task, and removes its task and files afterward. It does not sign in or make requests to Atri Shop.
