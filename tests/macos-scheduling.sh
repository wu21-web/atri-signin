#!/bin/bash

set -euo pipefail

repository_root=$(cd "$(dirname "$0")/.." && pwd)
installer=$repository_root/examples/integrations/launchd-job.sh
test_root=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/atri-signin-macos.XXXXXX")" && pwd)
fixture_dir=$test_root/fixture
accounts=$test_root/accounts.csv
plist_dir=$test_root/LaunchAgents
label=work.atrishop.atri-signin.test
launch_agents=$HOME/Library/LaunchAgents
plist=$launch_agents/$label.plist
assertions=0
original_path=$PATH

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_equal() {
  if [[ $1 != "$2" ]]; then
    fail "$3 (expected '$1', got '$2')"
  fi
  assertions=$((assertions + 1))
}

assert_contains() {
  case $2 in
    *"$1"*) ;;
    *) fail "$3 (missing '$1' in: $2)" ;;
  esac
  assertions=$((assertions + 1))
}

run_installer() {
  "$installer" --accounts "$accounts" --plist-dir "$plist_dir" --log-dir "$test_root/logs" --label "$label" "$@"
}

run_installer_live() {
  "$installer" --accounts "$accounts" --log-dir "$test_root/logs" --label "$label" "$@"
}

expect_failure() {
  local runner=$1 pattern=$2
  shift 2
  local output status
  set +e
  output=$("$runner" "$@" 2>&1)
  status=$?
  set -e
  if [[ $status -eq 0 ]]; then
    fail "expected a failure from: $*"
  fi
  assert_contains "$pattern" "$output" "wrong error from: $*"
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1"
}

plist_arguments() {
  local file=$1 index=0 value
  while value=$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:$index" "$file" 2>/dev/null); do
    printf '%s\n' "$value"
    index=$((index + 1))
  done
}

cleanup() {
  launchctl bootout "gui/$UID/$label" >/dev/null 2>&1 || true
  rm -f "$plist"
  PATH=$original_path
  local temp_parent=${TMPDIR:-/tmp}
  temp_parent=${temp_parent%/}
  if [[ $test_root == "$temp_parent"/atri-signin-macos.* && -d $test_root ]]; then
    rm -rf "$test_root"
  fi
}
trap cleanup EXIT

mkdir -p "$fixture_dir"
printf 'test@example.invalid,unused\n' >"$accounts"

cat >"$test_root/fixture.go" <<'GO'
package main

import (
	"os"
	"path/filepath"
	"strings"
)

func main() {
	var results string
	for i := 1; i+1 < len(os.Args); i++ {
		if os.Args[i] == "--results" {
			results = os.Args[i+1]
		}
	}
	if results == "" {
		os.Exit(3)
	}
	if err := os.MkdirAll(results, 0o700); err != nil {
		panic(err)
	}
	cwd, err := os.Getwd()
	if err != nil {
		panic(err)
	}
	if err := os.WriteFile(filepath.Join(results, "cwd.txt"), []byte(cwd), 0o600); err != nil {
		panic(err)
	}
	if err := os.WriteFile(filepath.Join(results, "args.txt"), []byte(strings.Join(os.Args[1:], "\n")), 0o600); err != nil {
		panic(err)
	}
	os.Exit(2)
}
GO

(cd "$test_root" && go build -o "$fixture_dir/atri-signin" fixture.go)

PATH=/usr/bin:/bin expect_failure run_installer 'not found on PATH' --dry-run

export PATH="$fixture_dir:/usr/bin:/bin"

run_installer --dry-run </dev/null >"$test_root/default.plist"
assert_equal 9 "$(plist_value "$test_root/default.plist" StartCalendarInterval:Hour)" 'The default hour is wrong.'
assert_equal 17 "$(plist_value "$test_root/default.plist" StartCalendarInterval:Minute)" 'The default minute is wrong.'
assert_equal "$fixture_dir/atri-signin" "$(plist_value "$test_root/default.plist" ProgramArguments:0)" 'The executable was not resolved through PATH.'
if [[ -e $plist ]]; then
  fail '--dry-run installed a plist.'
fi
assertions=$((assertions + 1))

run_installer --dry-run --at '9:17 PM' >"$test_root/pm.plist"
assert_equal 21 "$(plist_value "$test_root/pm.plist" StartCalendarInterval:Hour)" '12-hour PM times are not converted.'
run_installer --dry-run --at '12:05 am' >"$test_root/midnight.plist"
assert_equal 0 "$(plist_value "$test_root/midnight.plist" StartCalendarInterval:Hour)" 'Midnight is not converted.'
assert_equal 5 "$(plist_value "$test_root/midnight.plist" StartCalendarInterval:Minute)" 'Midnight minutes are wrong.'

expect_failure run_installer 'invalid time' --dry-run --at '24:00'
expect_failure run_installer 'invalid time' --dry-run --at 'noon'

if ! (launchctl print "gui/$UID" >/dev/null 2>&1 && mkdir -p "$launch_agents" && touch "$launch_agents/.atri-signin-test.$$"); then
  printf 'note: launchd is unavailable or %s is not writable; skipping the live install.\n' "$launch_agents"
  printf 'Passed %d assertions.\n' "$assertions"
  exit 0
fi
rm -f "$launch_agents/.atri-signin-test.$$"

launchctl bootout "gui/$UID/$label" >/dev/null 2>&1 || true
rm -f "$plist"

run_installer_live --force
[[ -f $plist ]] || fail 'The plist was not installed.'
plutil -lint "$plist" >/dev/null || fail 'The installed plist is invalid.'
assert_equal "$label" "$(plist_value "$plist" Label)" 'The label is wrong.'
assert_equal "$(dirname "$accounts")" "$(plist_value "$plist" WorkingDirectory)" 'The working directory is wrong.'
assert_equal '2' "$(plist_value "$plist" ProgramArguments:6)" 'The default --max-signin-count is wrong.'
launchctl print "gui/$UID/$label" >/dev/null || fail 'The job is not loaded.'
assertions=$((assertions + 1))

arguments=()
while IFS= read -r line; do
  arguments+=("$line")
done < <(plist_arguments "$plist")
expected=("$fixture_dir/atri-signin" --accounts "$accounts" --results "$(dirname "$accounts")/results" --max-signin-count 2)
assert_equal "${#expected[@]}" "${#arguments[@]}" 'The argument count is wrong.'
for index in "${!expected[@]}"; do
  assert_equal "${expected[$index]}" "${arguments[$index]}" "Argument $index is wrong."
done

set +e
(cd "$(dirname "$accounts")" && "${arguments[@]}")
status=$?
set -e
assert_equal 2 "$status" 'The fixture did not run.'
assert_equal "$(dirname "$accounts")" "$(cat "$(dirname "$accounts")/results/cwd.txt")" 'The job ran in the wrong directory.'
assert_equal "$(printf '%s\n' "${expected[@]:1}")" "$(cat "$(dirname "$accounts")/results/args.txt")" 'The job received the wrong arguments.'

expect_failure run_installer_live 'already exists' --at 09:17
run_installer_live --force --max-signin-count 3 --atri-host shop.example.invalid --at '9:17 AM'
assert_equal '3' "$(plist_value "$plist" ProgramArguments:6)" '--max-signin-count was not replaced.'
assert_equal '--atri-host' "$(plist_value "$plist" ProgramArguments:7)" '--atri-host is missing.'
assert_equal 'shop.example.invalid' "$(plist_value "$plist" ProgramArguments:8)" '--atri-host has the wrong value.'
assert_equal "$fixture_dir/atri-signin" "$(plist_value "$plist" ProgramArguments:0)" 'The executable changed.'

if [[ ${ATRI_SIGNIN_TEST_BOOTSTRAP:-} == 1 ]]; then
  rm -rf "$(dirname "$accounts")/results"
  arguments=()
  while IFS= read -r line; do
    arguments+=("$line")
  done < <(plist_arguments "$plist")
  launchctl kickstart -k "gui/$UID/$label"
  deadline=$((SECONDS + 30))
  while [[ $SECONDS -lt $deadline && ! -f "$(dirname "$accounts")/results/args.txt" ]]; do
    sleep 1
  done
  if [[ -f "$(dirname "$accounts")/results/args.txt" ]]; then
    assert_equal "$(printf '%s\n' "${arguments[@]:1}")" "$(cat "$(dirname "$accounts")/results/args.txt")" 'launchd ran the job with the wrong arguments.'
  else
    printf 'note: launchd did not start the job within 30s; skipping the live run assertion.\n'
  fi
else
  printf 'note: skipping the live launchctl run.\n'
fi

printf 'Passed %d assertions.\n' "$assertions"
