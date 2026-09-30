#!/bin/bash

set -euo pipefail

repository_root=$(cd "$(dirname "$0")/.." && pwd)
installer=$repository_root/examples/integrations/crontab-job.sh
remover=$repository_root/examples/integrations/remove-crontab-job.sh
test_root=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/atri-signin-linux.XXXXXX")" && pwd)
stub_dir=$test_root/bin
crontab_file=$test_root/crontab
fixture_dir="$test_root/test files [one] & two"
accounts="$fixture_dir/accounts [test].csv"
results="$fixture_dir/output [test]"
label=atri-signin-test
assertions=0
original_path=$PATH

export CRONTAB_FILE=$crontab_file

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
  "$installer" --accounts "$accounts" --results "$results" --label "$label" --log-dir "$test_root/logs" "$@"
}

run_remover() {
  "$remover" --label "$label" "$@"
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

cron_line() {
  awk -v begin="# BEGIN atri-signin: $label" '
    $0 == begin { getline; print; exit }
  ' "$crontab_file"
}

cron_command() {
  printf '%s' "$(cron_line)" | cut -d' ' -f6-
}

cleanup() {
  PATH=$original_path
  local temp_parent=${TMPDIR:-/tmp}
  temp_parent=${temp_parent%/}
  if [[ $test_root == "$temp_parent"/atri-signin-linux.* && -d $test_root ]]; then
    rm -rf "$test_root"
  fi
}
trap cleanup EXIT

mkdir -p "$fixture_dir" "$stub_dir"
printf 'test@example.invalid,unused\n' >"$accounts"
printf '%s\n' '# keep me' '0 4 * * * /usr/bin/true' >"$crontab_file"

cat >"$stub_dir/crontab" <<'SH'
#!/bin/bash
set -euo pipefail
case ${1:-} in
  -l | --list)
    if [[ -f $CRONTAB_FILE.error ]]; then
      printf 'crontab: permission denied\n' >&2
      exit 1
    fi
    if [[ ! -f $CRONTAB_FILE ]]; then
      printf 'no crontab for %s\n' "${USER:-user}" >&2
      exit 1
    fi
    cat "$CRONTAB_FILE"
    if [[ -f $CRONTAB_FILE.mutate ]]; then
      printf '# concurrent edit\n' >>"$CRONTAB_FILE"
    fi
    ;;
  -)
    temporary=$(mktemp)
    cat >"$temporary"
    mv "$temporary" "$CRONTAB_FILE"
    ;;
  *)
    printf 'unsupported crontab invocation: %s\n' "$*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$stub_dir/crontab"

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

PATH="$stub_dir:/usr/bin:/bin" expect_failure run_installer 'not found on PATH' --dry-run

export PATH="$fixture_dir:$stub_dir:/usr/bin:/bin"

printf '%s\n' '# keep me' "# BEGIN atri-signin: $label" '17 9 * * * /usr/bin/true' >"$crontab_file"
expect_failure run_installer 'unterminated' --dry-run --force
expect_failure run_remover 'unterminated'
printf '%s\n' '# keep me' '0 4 * * * /usr/bin/true' >"$crontab_file"

run_installer --dry-run </dev/null >"$test_root/default.cron" 2>/dev/null
assert_contains '17 9 * * *' "$(cat "$test_root/default.cron")" 'The default schedule is wrong.'
assert_contains "# BEGIN atri-signin: $label" "$(cat "$test_root/default.cron")" 'The begin marker is missing.'
assert_contains "# END atri-signin: $label" "$(cat "$test_root/default.cron")" 'The end marker is missing.'

run_installer --dry-run --at '9:17 PM' >"$test_root/pm.cron" 2>/dev/null
assert_contains '17 21 * * *' "$(cat "$test_root/pm.cron")" '12-hour PM times are not converted.'
run_installer --dry-run --at '12:05 am' >"$test_root/midnight.cron" 2>/dev/null
assert_contains '5 0 * * *' "$(cat "$test_root/midnight.cron")" 'Midnight is not converted.'

expect_failure run_installer 'invalid time' --dry-run --at '24:00'
expect_failure run_installer 'invalid time' --dry-run --at 'noon'
expect_failure run_installer 'invalid --max-signin-count' --dry-run --max-signin-count 2147483648
expect_failure run_installer 'invalid --max-signin-count' --dry-run --max-signin-count 99999999999999999999

run_installer --dry-run --atri-host 'ex%ample.invalid' 2>/dev/null | grep -F 'ex\%ample.invalid' >/dev/null || fail 'A percent sign was not escaped for cron.'
assertions=$((assertions + 1))

(cd "$test_root" && run_installer --dry-run --results relative-results --log-dir relative-logs 2>/dev/null) >"$test_root/relative.cron"
assert_contains "'$test_root/relative-results'" "$(cat "$test_root/relative.cron")" 'A relative --results path was not resolved.'
assert_contains "'$test_root/relative-logs/atri-signin.log'" "$(cat "$test_root/relative.cron")" 'A relative --log-dir was not resolved.'

run_installer --force
assert_contains '# keep me' "$(cat "$crontab_file")" 'An unrelated crontab comment was removed.'
assert_contains '0 4 * * * /usr/bin/true' "$(cat "$crontab_file")" 'An unrelated crontab entry was removed.'
assert_equal 1 "$(grep -Fc "# BEGIN atri-signin: $label" "$crontab_file")" 'The block was not installed exactly once.'
if [[ ! -d $test_root/logs ]]; then
  fail 'The log directory was not created.'
fi
assertions=$((assertions + 1))

expected=("$fixture_dir/atri-signin" --accounts "$accounts" --results "$results" --max-signin-count 2)
set +e
(cd "$(dirname "$accounts")" && sh -c "$(printf '%s' "$(cron_command)" | sed 's/\\%/%/g')")
status=$?
set -e
assert_equal 2 "$status" 'The installed cron command did not run.'
assert_equal "$(dirname "$accounts")" "$(cat "$results/cwd.txt")" 'The cron command ran in the wrong directory.'
assert_equal "$(printf '%s\n' "${expected[@]:1}")" "$(cat "$results/args.txt")" 'The cron command received the wrong arguments.'

expect_failure run_installer 'already exists' --at 09:17
run_installer --force --max-signin-count 3
assert_equal 1 "$(grep -Fc "# BEGIN atri-signin: $label" "$crontab_file")" '--force left more than one block.'
assert_contains '--max-signin-count 3' "$(cat "$crontab_file")" '--force did not replace the entry.'
assert_contains '# keep me' "$(cat "$crontab_file")" '--force removed an unrelated crontab comment.'

before=$(cat "$crontab_file")
expect_failure run_installer 'already exists' --dry-run --at 08:00
run_installer --dry-run --force --at 08:00 >/dev/null 2>&1
assert_equal "$before" "$(cat "$crontab_file")" '--dry-run changed the crontab.'

before=$(cat "$crontab_file")
run_remover --dry-run >/dev/null 2>&1
assert_equal "$before" "$(cat "$crontab_file")" 'Removal --dry-run changed the crontab.'

run_remover
if grep -Fq "# BEGIN atri-signin: $label" "$crontab_file"; then
  fail 'The block was not removed.'
fi
assert_contains '# keep me' "$(cat "$crontab_file")" 'Removal deleted an unrelated crontab comment.'
assert_contains '0 4 * * * /usr/bin/true' "$(cat "$crontab_file")" 'Removal deleted an unrelated crontab entry.'
[[ -f $accounts ]] || fail 'Removal deleted the accounts CSV.'
[[ -x $fixture_dir/atri-signin ]] || fail 'Removal deleted the executable.'
[[ -f $results/args.txt ]] || fail 'Removal deleted a result file.'
assertions=$((assertions + 4))

output=$(run_remover 2>&1)
assert_contains 'is not installed' "$output" 'Repeated removal is not a no-op.'

rm -f "$crontab_file"
run_installer --force >/dev/null
assert_contains "# BEGIN atri-signin: $label" "$(cat "$crontab_file")" 'A missing crontab was not created.'
run_remover >/dev/null
assert_equal '' "$(cat "$crontab_file")" 'Removal left content in an otherwise empty crontab.'

printf '%s\n' '# keep me' >"$crontab_file"
touch "$crontab_file.error"
expect_failure run_installer 'refusing to change it' --force
expect_failure run_remover 'refusing to change it'
assert_equal '# keep me' "$(cat "$crontab_file")" 'A failed crontab read changed the crontab.'
rm -f "$crontab_file.error"

touch "$crontab_file.mutate"
expect_failure run_installer 'changed while this script was running' --force
if grep -Fq "# BEGIN atri-signin: $label" "$crontab_file"; then
  fail 'The installer wrote after detecting a concurrent edit.'
fi
assert_contains '# concurrent edit' "$(cat "$crontab_file")" 'A concurrent crontab edit was lost.'
rm -f "$crontab_file.mutate"

if [[ -d ${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/atri-signin-crontab.lock ]]; then
  fail 'The crontab lock directory was left behind.'
fi
assertions=$((assertions + 1))

printf 'Passed %d assertions.\n' "$assertions"
