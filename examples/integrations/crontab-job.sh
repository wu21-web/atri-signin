#!/bin/bash

set -euo pipefail

label=atri-signin
at=
accounts=
executable=
results=
max_signin_count=2
atri_host=
log_dir=${XDG_STATE_HOME:-$HOME/.local/state}/atri-signin
force=false
dry_run=false

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: crontab-job.sh [options]

Install a daily Atri Sign-in crontab entry for the current user. The entry is
kept between marker comments so other crontab lines are preserved. See
README.md, section "Scheduling".

Options:
  --accounts PATH        accounts CSV (prompted when omitted)
  --executable PATH      atri-signin binary (default: first one on PATH)
  --results PATH         results directory (default: next to the CSV)
  --max-signin-count N   concurrent account subprocesses (default: 2)
  --atri-host HOST       AtriShop host passed to the CLI
  --at TIME              daily time, HH:MM or H:MM AM/PM (default: 09:17)
  --label NAME           marker name for the crontab block (default: atri-signin)
  --log-dir PATH         log directory (default: ~/.local/state/atri-signin)
  --force                replace an existing entry
  --dry-run              print the resulting crontab without installing it
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

shell_quote() {
  local value=$1
  value=${value//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

cron_escape() {
  printf '%s' "${1//%/\\%}"
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

strip_block() {
  awk -v begin="$begin_marker" -v end="$end_marker" '
    $0 == begin { inside = 1; next }
    $0 == end { inside = 0; next }
    inside { next }
    { print }
    END { if (inside) exit 3 }
  '
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --accounts | --executable | --results | --max-signin-count | --atri-host | --at | --label | --log-dir)
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

if [[ ! $label =~ ^[A-Za-z0-9._-]+$ ]]; then
  die "invalid --label: $label"
fi

command -v crontab >/dev/null 2>&1 || die 'crontab was not found. Install cron before scheduling Atri Sign-in.'

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

log_dir=$(absolute_path "$log_dir")
log_path=$log_dir/atri-signin.log

if [[ ! $max_signin_count =~ ^[1-9][0-9]*$ ]] || [[ ${#max_signin_count} -gt 10 ]] || ((10#$max_signin_count > 2147483647)); then
  die "invalid --max-signin-count: $max_signin_count (must be between 1 and 2147483647)"
fi

begin_marker="# BEGIN atri-signin: $label"
end_marker="# END atri-signin: $label"
working_directory=$(dirname "$accounts")

command_line="cd $(shell_quote "$working_directory") && $(shell_quote "$executable") --accounts $(shell_quote "$accounts") --results $(shell_quote "$results") --max-signin-count $max_signin_count"
if [[ -n $atri_host ]]; then
  command_line+=" --atri-host $(shell_quote "$atri_host")"
fi
command_line+=" >> $(shell_quote "$log_path") 2>&1"
cron_line="$minute $hour * * * $(cron_escape "$command_line")"

existing=$(crontab -l 2>/dev/null || true)
if printf '%s\n' "$existing" | grep -Fqx -- "$begin_marker"; then
  if [[ $force != true ]]; then
    die "a crontab entry named $label already exists. Use --force to replace it, or choose another --label."
  fi
fi

if [[ -n $existing ]]; then
  if ! filtered=$(printf '%s\n' "$existing" | strip_block); then
    die "the crontab has an unterminated $begin_marker block. Remove it manually and run this script again."
  fi
else
  filtered=
fi

new_crontab=$filtered
if [[ -n $new_crontab ]]; then
  new_crontab+=$'\n'
fi
new_crontab+=$begin_marker$'\n'$cron_line$'\n'$end_marker

if [[ $dry_run == true ]]; then
  printf '%s\n' "$new_crontab"
  printf 'Dry run: the crontab was not changed.\n' >&2
  exit 0
fi

mkdir -p "$log_dir"
if ! printf '%s\n' "$new_crontab" | crontab -; then
  die 'the crontab could not be updated'
fi

installed=$(crontab -l 2>/dev/null || true)
if ! printf '%s\n' "$installed" | grep -Fqx -- "$begin_marker"; then
  die "the crontab entry $label is not installed"
fi

printf 'Label:       %s\n' "$label"
printf 'Executable:  %s\n' "$executable"
printf 'Accounts:    %s\n' "$accounts"
printf 'Results:     %s\n' "$results"
printf 'Log:         %s\n' "$log_path"
printf 'Schedule:    daily at %02d:%02d (%s local time)\n' "$hour" "$minute" "$(date +%Z)"
printf 'Manage:      crontab -l\n'
printf 'Remove:      examples/integrations/remove-crontab-job.sh --label %s\n' "$label"
printf 'The first run is the next %02d:%02d while the machine is on; cron does not run missed schedules.\n' "$hour" "$minute"
