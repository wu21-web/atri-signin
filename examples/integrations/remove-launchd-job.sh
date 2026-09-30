#!/bin/bash

set -euo pipefail

label=work.atrishop.atri-signin
plist_dir=${HOME}/Library/LaunchAgents
dry_run=false

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: remove-launchd-job.sh [options]

Remove the daily Atri Sign-in LaunchAgent installed by launchd-job.sh. Missing
jobs are a successful no-op, so removal can be repeated. The executable,
accounts CSV, results, and logs are retained. See README.md, section
"Scheduling".

Options:
  --label NAME      launchd job label (default: work.atrishop.atri-signin)
  --plist-dir PATH  LaunchAgents directory (default: ~/Library/LaunchAgents)
  --dry-run         report what would be removed without removing it
  --help            show this message
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --label | --plist-dir)
      if [[ $# -lt 2 ]]; then
        die "option $1 needs a value"
      fi
      option=${1#--}
      option=${option//-/_}
      printf -v "$option" '%s' "$2"
      shift 2
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

if [[ -z $label || $label == */* ]]; then
  die "invalid --label: $label"
fi

command -v launchctl >/dev/null 2>&1 || die 'launchctl was not found. This script requires macOS launchd.'

plist_path=$plist_dir/$label.plist
domain=gui/$UID
loaded=false
if launchctl print "$domain/$label" >/dev/null 2>&1; then
  loaded=true
fi

if [[ $loaded == false && ! -e $plist_path ]]; then
  printf 'The job %s is not installed. Nothing to remove.\n' "$label"
  exit 0
fi

state='not loaded'
if [[ $loaded == true ]]; then
  state=loaded
fi

printf 'Label: %s\n' "$label"
printf 'Plist: %s\n' "$plist_path"
printf 'State: %s\n' "$state"

if [[ $dry_run == true ]]; then
  printf 'Dry run: nothing was removed.\n'
  exit 0
fi

if [[ $loaded == true ]]; then
  launchctl bootout "$domain/$label" || die "launchctl could not unload $label. Remove it with: launchctl bootout $domain/$label"
  if launchctl print "$domain/$label" >/dev/null 2>&1; then
    die "the job is still loaded. Remove it with: launchctl bootout $domain/$label"
  fi
fi

if ! rm -f "$plist_path"; then
  die "could not remove $plist_path"
fi

printf 'Removed the schedule. The executable, accounts CSV, results, and logs are retained.\n'
