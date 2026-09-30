#!/bin/bash

set -euo pipefail

label=work.atrishop.atri-signin
at=
accounts=
executable=
results=
max_signin_count=2
atri_host=
plist_dir=${HOME}/Library/LaunchAgents
log_dir=${HOME}/Library/Logs
force=false
dry_run=false

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: launchd-job.sh [options]

Register a daily Atri Sign-in job for the current macOS user. The job runs from
a LaunchAgent, so it starts only while this user is logged in. See README.md,
section "Scheduling".

Options:
  --accounts PATH        accounts CSV (prompted when omitted)
  --executable PATH      atri-signin binary (default: first one on PATH)
  --results PATH         results directory (default: next to the CSV)
  --max-signin-count N   concurrent account subprocesses (default: 2)
  --atri-host HOST       AtriShop host passed to the CLI
  --at TIME              daily time, HH:MM or H:MM AM/PM (default: 09:17)
  --label NAME           launchd job label (default: work.atrishop.atri-signin)
  --plist-dir PATH       LaunchAgents directory (default: ~/Library/LaunchAgents)
  --log-dir PATH         log directory (default: ~/Library/Logs)
  --force                replace an existing job
  --dry-run              print the plist without installing it
  --help                 show this message
EOF
}

absolute_path() {
  local directory
  directory=$(dirname "$1")
  if [[ -d $directory ]]; then
    (cd "$directory" && printf '%s/%s\n' "$PWD" "$(basename "$1")")
  elif [[ $1 == /* ]]; then
    printf '%s\n' "$1"
  else
    printf '%s/%s\n' "$PWD" "$1"
  fi
}

xml_escape() {
  local text=$1
  text=${text//&/&amp;}
  text=${text//</&lt;}
  text=${text//>/&gt;}
  printf '%s' "$text"
}

normalize_time() {
  local value=$1 hour minute meridiem
  value=$(printf '%s' "$1" | tr -d '[:space:]')
  if [[ $value =~ ^([01]?[0-9]|2[0-3]):([0-5][0-9])$ ]]; then
    printf '%02d:%02d\n' "$((10#${BASH_REMATCH[1]}))" "$((10#${BASH_REMATCH[2]}))"
    return 0
  fi
  if [[ $value =~ ^([0-9]{1,2}):([0-5][0-9])([AaPp][Mm])$ ]]; then
    hour=$((10#${BASH_REMATCH[1]}))
    minute=${BASH_REMATCH[2]}
    meridiem=$(printf '%s' "${BASH_REMATCH[3]}" | tr '[:lower:]' '[:upper:]')
    if ((hour < 1 || hour > 12)); then
      return 1
    fi
    if [[ $meridiem == PM && $hour -ne 12 ]]; then
      hour=$((hour + 12))
    fi
    if [[ $meridiem == AM && $hour -eq 12 ]]; then
      hour=0
    fi
    printf '%02d:%02d\n' "$hour" "$minute"
    return 0
  fi
  return 1
}

plist_string() {
  printf '\t<string>%s</string>\n' "$(xml_escape "$1")"
}

emit_plist() {
  local argument
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
  printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
  printf '%s\n' '<plist version="1.0">' '<dict>'
  printf '\t<key>Label</key>\n'
  plist_string "$label"
  printf '\t<key>ProgramArguments</key>\n\t<array>\n'
  for argument in "$executable" --accounts "$accounts" --results "$results" --max-signin-count "$max_signin_count"; do
    printf '\t\t<string>%s</string>\n' "$(xml_escape "$argument")"
  done
  if [[ -n $atri_host ]]; then
    printf '\t\t<string>--atri-host</string>\n'
    plist_string "$atri_host"
  fi
  printf '\t</array>\n'
  printf '\t<key>WorkingDirectory</key>\n'
  plist_string "$working_directory"
  printf '\t<key>RunAtLoad</key>\n\t<false/>\n'
  printf '\t<key>StartCalendarInterval</key>\n\t<dict>\n'
  printf '\t\t<key>Hour</key>\n\t\t<integer>%d</integer>\n' "$hour"
  printf '\t\t<key>Minute</key>\n\t\t<integer>%d</integer>\n' "$minute"
  printf '\t</dict>\n'
  printf '\t<key>StandardOutPath</key>\n'
  plist_string "$stdout_path"
  printf '\t<key>StandardErrorPath</key>\n'
  plist_string "$stderr_path"
  printf '%s\n' '</dict>' '</plist>'
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --accounts | --executable | --results | --max-signin-count | --atri-host | --at | --label | --plist-dir | --log-dir)
      if [[ $# -lt 2 ]]; then
        die "option $1 needs a value"
      fi
      option=${1#--}
      option=${option//-/_}
      printf -v "$option" '%s' "$2"
      shift 2
      ;;
    --force)
      force=true
      shift
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      printf 'error: unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

command -v launchctl >/dev/null 2>&1 || die 'launchctl was not found. This script requires macOS launchd.'

if [[ -z $executable ]]; then
  executable=$(command -v atri-signin || true)
fi
if [[ -z $executable ]]; then
  die 'atri-signin was not found on PATH. Add its directory to PATH or pass --executable.'
fi
if [[ ! -x $executable ]]; then
  die "the executable is missing or not executable: $executable"
fi
executable=$(absolute_path "$executable")

if [[ -z $accounts ]]; then
  printf 'Path to the accounts CSV: ' >&2
  read -r accounts || accounts=
fi
if [[ -z $accounts ]]; then
  die 'an accounts CSV path is required.'
fi
if [[ ! -f $accounts ]]; then
  die "the accounts CSV does not exist: $accounts"
fi
accounts=$(absolute_path "$accounts")

if [[ -z $at ]]; then
  printf 'Daily time [09:17 AM]: ' >&2
  read -r answer || answer=
  at=${answer:-09:17}
fi
if ! normalized=$(normalize_time "$at"); then
  die "invalid time: $at (use HH:MM or H:MM AM/PM)"
fi
hour=$((10#${normalized%%:*}))
minute=$((10#${normalized##*:}))

if [[ -z $results ]]; then
  results=$(dirname "$accounts")/results
fi
results=$(absolute_path "$results")
if [[ -e $results && ! -d $results ]]; then
  die "the results path is not a directory: $results"
fi

if [[ ! $max_signin_count =~ ^[1-9][0-9]*$ ]] || [[ ${#max_signin_count} -gt 10 ]] || ((10#$max_signin_count > 2147483647)); then
  die "invalid --max-signin-count: $max_signin_count (must be between 1 and 2147483647)"
fi

working_directory=$(dirname "$accounts")
plist_dir=$(absolute_path "$plist_dir")
log_dir=$(absolute_path "$log_dir")
stdout_path=$log_dir/atri-signin.log
stderr_path=$log_dir/atri-signin.error.log
plist_path=$plist_dir/$label.plist

if [[ -e $plist_path && $force != true ]]; then
  die "a job named $label already exists at $plist_path. Use --force to replace it, or choose another --label."
fi

tmp_plist=$(mktemp "${TMPDIR:-/tmp}/launchd-job.XXXXXX")
cleanup() {
  rm -f "$tmp_plist"
}
trap cleanup EXIT

emit_plist >"$tmp_plist"
plutil -lint "$tmp_plist" >/dev/null || die 'the generated plist is invalid.'

if [[ $dry_run == true ]]; then
  cat "$tmp_plist"
  exit 0
fi

mkdir -p "$plist_dir" "$log_dir"
install -m 644 "$tmp_plist" "$plist_path"

domain=gui/$UID
launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
if ! launchctl bootstrap "$domain" "$plist_path" >/dev/null 2>&1; then
  launchctl unload -w "$plist_path" >/dev/null 2>&1 || true
fi
if ! launchctl print "$domain/$label" >/dev/null 2>&1; then
  die "launchd did not load $label from $plist_path. LaunchAgents have to live in a directory launchd recognizes, such as ~/Library/LaunchAgents."
fi

printf 'Label:       %s\n' "$label"
printf 'Executable:  %s\n' "$executable"
printf 'Accounts:    %s\n' "$accounts"
printf 'Results:     %s\n' "$results"
printf 'Plist:       %s\n' "$plist_path"
printf 'Logs:        %s\n' "$stdout_path"
printf 'Schedule:    daily at %02d:%02d (%s local time)\n' "$hour" "$minute" "$(date +%Z)"
printf 'Manage:      launchctl print gui/%s/%s\n' "$UID" "$label"
printf 'Uninstall:   launchctl bootout gui/%s/%s && rm %s\n' "$UID" "$label" "$plist_path"
printf 'The job runs at the next %02d:%02d while you are logged in; launchd runs a missed start after the Mac wakes.\n' "$hour" "$minute"
