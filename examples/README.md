## Examples & Cron Job Integrations

[![Schedule](https://github.com/wu21-web/atri-signin/actions/workflows/schedule.yml/badge.svg)](https://github.com/wu21-web/atri-signin/actions/workflows/schedule.yml)

The two `.csv` files are example inputs and outputs of a single run.

> [!CAUTION]
> The scripts are mostly written by AI. The author is not responsible for any damage to the operating system. **Use with caution.**

### Linux crontab

Use [`integrations/crontab-job.sh`](integrations/crontab-job.sh). Put `atri-signin` on `PATH`, or pass `--executable`. For example, from the repository root:

```sh
./examples/integrations/crontab-job.sh --accounts ~/atri-signin/accounts.csv

# A downloaded release can keep its original filename.
./examples/integrations/crontab-job.sh --accounts ./accounts.csv --executable ./atri-signin-linux-amd64
```

Omit `--accounts` or `--at` to answer the prompts; the time prompt defaults to `09:17 AM` and accepts `HH:MM` or `H:MM AM/PM` in the system timezone. Relative paths are resolved from the directory you run the script in, so keep the executable and CSV where they are or rerun with `--force` after moving them.

The entry is written between `# BEGIN atri-signin: atri-signin` and `# END atri-signin: atri-signin` markers, so unrelated crontab lines are preserved. Use `--label` for another name, `--dry-run` to print the resulting crontab without installing it, or `--force` to replace an existing entry. Optional `--results`, `--max-signin-count`, `--atri-host`, and `--log-dir` configure the corresponding CLI flags and the log file, which defaults to `~/.local/state/atri-signin/atri-signin.log`. Protect the CSV as it contains account passwords; the crontab stores only its path.

Both scripts treat only the usual `no crontab for <user>` result as an empty crontab. Any other `crontab -l` failure aborts without touching the crontab. Updates made by these scripts are serialized with a lock, and before writing they check whether another program changed the crontab; because `crontab` has no portable compare-and-swap operation, an external edit can still race with the final write.

Cron runs the entry as the current user while the machine is on and the cron daemon is running, in the system timezone. Unlike Task Scheduler and launchd it does not run starts that were missed while the machine was off or asleep, and a new run starts even if the previous one is still going. Standard output and errors are appended to the log file, so cron does not mail them. Installing the entry does not run sign-in immediately; the first run is the next occurrence of the chosen time.

To remove the entry, run [`integrations/remove-crontab-job.sh`](integrations/remove-crontab-job.sh):

```sh
./examples/integrations/remove-crontab-job.sh --dry-run # Preview removal of atri-signin.
./examples/integrations/remove-crontab-job.sh # Remove it.

# Use the same custom label supplied to crontab-job.sh.
./examples/integrations/remove-crontab-job.sh --label atri-signin-personal
```

Removal deletes only the marked block, keeps every other crontab line, and treats an already-absent entry as success, so it can be repeated. The executable, accounts CSV, results, and logs are retained.

To test the integration without touching your crontab, run `./tests/integrations/linux-scheduling.sh`. It uses a stub `crontab` command in a temporary directory, builds a harmless argument-capture executable, and verifies the generated schedule, quoting, replacement, and removal. It does not sign in or make requests to Atri Shop.

### Windows Task Scheduler

Use [`integrations/cron-job.ps1`](integrations/cron-job.ps1) with Windows PowerShell 5.1 or PowerShell 7. Put `atri-signin.exe` on `PATH` (the name `atrisign.exe` is also accepted), or supply `-ExecutablePath`. For example, from the repository root:

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
```

To remove the schedule, run [`integrations/remove-cron-job.ps1`](integrations/remove-cron-job.ps1):

```powershell
.\examples\integrations\remove-cron-job.ps1 -WhatIf # Preview removal of AtriSignIn.
.\examples\integrations\remove-cron-job.ps1 # Confirm removal of AtriSignIn.

# Use the same custom name supplied to cron-job.ps1 when registering the task.
.\examples\integrations\remove-cron-job.ps1 -TaskName 'AtriSignIn-Personal'
```

The removal script matches the task name literally in the Task Scheduler root folder and prompts for confirmation. Use `-Confirm:$false` for unattended removal. If the task is already absent, the script reports that and exits successfully. It works even if the executable or CSV has been moved or removed. Removal cancels future scheduled starts; an already-running sign-in can finish. The executable, accounts CSV, and result files are retained.

After the CLI finishes, `LastTaskResult` is `0` for success, `1` for setup/runtime errors, or `2` if any account failed; consult the result CSV for per-account outcomes. Windows can report other codes if the task has not run or could not start. These tasks execute the CLI directly, so stdout/stderr are not saved to a log. If local execution policy blocks the downloaded script, inspect it and use `Unblock-File` on that file, or run it once with `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\examples\integrations\cron-job.ps1` and the desired parameters. This does not change the machine's execution policy; organization policy may still prohibit it.

To test the integration on Windows with Go installed, run `powershell.exe -NoProfile -File .\tests\integrations\windows-scheduling.ps1` or `pwsh.exe -NoProfile -File .\tests\integrations\windows-scheduling.ps1`. The test builds a harmless argument-capture executable, creates and runs uniquely named temporary tasks, verifies removal and preservation of unrelated tasks and files, and removes its remaining tasks and files afterward. It does not sign in or make requests to Atri Shop.

### macOS launchd

Use [`integrations/launchd-job.sh`](integrations/launchd-job.sh), which registers a per-user LaunchAgent. Put `atri-signin` on `PATH`, or pass `--executable`. From the repository root:

```sh
./examples/integrations/launchd-job.sh --accounts ~/atri-signin/accounts.csv

# A downloaded release can keep its original filename.
./examples/integrations/launchd-job.sh --accounts ./accounts.csv --executable ./atri-signin-darwin-arm64
```

Omit `--accounts` or `--at` to answer the prompts; the time prompt defaults to `09:17 AM` and accepts `HH:MM` or `H:MM AM/PM` in the system timezone. Relative paths are resolved when the job is installed, so an executable or CSV that moves afterwards needs another run with `--force`.

The job is named `work.atrishop.atri-signin` and is installed as `~/Library/LaunchAgents/work.atrishop.atri-signin.plist`. Use `--label` for another name, `--dry-run` to print the plist without installing it, or `--force` to replace an existing job. Optional `--results`, `--max-signin-count`, and `--atri-host` map to the CLI flags; results default to a `results` directory next to the CSV. Protect the CSV as it contains account passwords; the plist stores only its path.

The job runs as the current user and only while that user is logged on, including when the screen is locked. The Mac must be on and have network access; the script does not wake it from sleep, and launchd runs a missed start once the Mac wakes. Standard output and errors are appended to `~/Library/Logs/atri-signin.log` and `~/Library/Logs/atri-signin.error.log`. Installing the job does not run sign-in immediately; the first run is the next occurrence of the chosen time.

Manage the job with `launchctl`:

```sh
launchctl print gui/$UID/work.atrishop.atri-signin
launchctl kickstart -k gui/$UID/work.atrishop.atri-signin # Run sign-in now.
```

To remove the schedule, run [`integrations/remove-launchd-job.sh`](integrations/remove-launchd-job.sh):

```sh
./examples/integrations/remove-launchd-job.sh --dry-run # Preview removal of work.atrishop.atri-signin.
./examples/integrations/remove-launchd-job.sh # Unload the job and delete the plist.

# Use the same custom label supplied to launchd-job.sh when installing the job.
./examples/integrations/remove-launchd-job.sh --label work.atrishop.atri-signin-personal
```

The removal script unloads the job with `launchctl bootout` and deletes its plist. A job that is already gone is reported and treated as success, so removal can be repeated, and it works even if the executable or CSV has been moved or deleted. Future scheduled starts are cancelled; a sign-in that is already running can finish. The executable, accounts CSV, results, and logs are retained.
