# Atri Sign-in

A one-shot Go CLI that logs into each account listed in a CSV and claims the daily check-in on Atri Shop.

## Input

Create `accounts.csv` in the project root:

```csv
one@example.com,password-one
two@example.com,password-two
```

There is no header. Each row must contain exactly two fields. Passwords containing commas, quotes, or newlines must be CSV-quoted. Blank lines are ignored, and duplicate email addresses are skipped.

`accounts.csv` is gitignored. Passwords are never written to stdout or the results file.

## Run

```sh
go build -o atri-signin ./cmd/atri-signin
./atri-signin
```

Useful flags:

```text
-accounts accounts.csv
-max-signin-count 2
-results results
-timeout 25s
-worker-timeout 2m
```

`-max-signin-count` limits how many account subprocesses run at once. The queue continues until every row has been processed.

Each completed run writes `results/signin-YYYYMMDD-HHMMSS.csv` with the timestamp, email, status, message, reward amount, balance, and duration. The most common successful statuses are `success` and `already_signed`.

## Process model

The parent process parses and shuffles the accounts, then runs a bounded worker queue. Each worker launches a separate copy of the binary in hidden worker mode and sends that account's credentials over stdin. A hung worker is terminated when its timeout expires.

The worker follows the browser flow: load the login page, submit the encrypted login request, open the user center, wait briefly, and submit the encrypted daily check-in request. Requests use the installed Chrome 153 user agent and the same cookie, signing, and encryption behavior as the site's JavaScript client.

The program retries transient network errors, HTTP 429 responses, and server errors twice with jittered backoff. Invalid credentials are reported without retrying.

## Scheduling

The command is one-shot. Run it daily with cron, launchd, or another scheduler. For example:

```cron
17 9 * * * cd /path/to/atri-signin && ./atri-signin >> signin.log 2>&1
```
