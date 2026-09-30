# Atri Sign-in

[![CI](https://github.com/wu21-web/atri-signin/actions/workflows/build.yml/badge.svg)](https://github.com/wu21-web/atri-signin/actions/workflows/build.yml)

<details>
<summary>中文特供版</summary>

[AtriShop](https://shop.atrishop.work) 允许你每天签到，领取0~0.3毛钱。平均0.15
<p>它的网易云季度会员价格是 ¥28.46，`28.46 / 0.15 > 90`，但是你可以开多个账号同时刷。刷够天数以后，就有用不完的会员了（只要你注册的号足够多）</p>
<p>也可以用来刷别的会员，mc挂等</p>
<p>用临时邮箱注册都可以，bing上搜一大堆</p>
<p>想设置的看examples下的README教程，有github和atrishop账户就能刷</p>

</details>

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

**Please reference the [examples/README.md](examples/README.md) scheduling integrations guide and setup shell scripts under `examples/integrations/` if you are considering setting up `atri-signin` on your computer.**
