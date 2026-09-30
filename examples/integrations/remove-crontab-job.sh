#!/bin/bash

set -euo pipefail

label=atri-signin
dry_run=false

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: remove-crontab-job.sh [options]

Remove the daily Atri Sign-in crontab entry installed by crontab-job.sh. Other
crontab lines are preserved. Missing entries are a successful no-op, so removal
can be repeated. The executable, accounts CSV, results, and logs are retained.
See README.md, section "Scheduling".

Options:
  --label NAME   marker name of the crontab block (default: atri-signin)
  --dry-run      print the resulting crontab without installing it
  --help         show this message
EOF
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
    --label)
      if [[ $# -lt 2 ]]; then
        die "option $1 needs a value"
      fi
      label=$2
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

if [[ ! $label =~ ^[A-Za-z0-9._-]+$ ]]; then
  die "invalid --label: $label"
fi

command -v crontab >/dev/null 2>&1 || die 'crontab was not found. Install cron before removing the schedule.'

begin_marker="# BEGIN atri-signin: $label"
end_marker="# END atri-signin: $label"

existing=$(crontab -l 2>/dev/null || true)
if ! printf '%s\n' "$existing" | grep -Fqx -- "$begin_marker"; then
  printf 'The job %s is not installed. Nothing to remove.\n' "$label"
  exit 0
fi

if ! filtered=$(printf '%s\n' "$existing" | strip_block); then
  die "the crontab has an unterminated $begin_marker block. Remove it manually and run this script again."
fi

if [[ $dry_run == true ]]; then
  if [[ -n $filtered ]]; then
    printf '%s\n' "$filtered"
  fi
  printf 'Dry run: the crontab was not changed.\n' >&2
  exit 0
fi

new_crontab=$filtered
if [[ -n $new_crontab ]]; then
  new_crontab+=$'\n'
fi

if ! printf '%s' "$new_crontab" | crontab -; then
  die 'the crontab could not be updated'
fi

installed=$(crontab -l 2>/dev/null || true)
if printf '%s\n' "$installed" | grep -Fqx -- "$begin_marker"; then
  die "the crontab entry $label is still installed"
fi

printf 'Removed %s. The executable, accounts CSV, results, and logs are retained.\n' "$label"
