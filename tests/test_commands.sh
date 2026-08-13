#!/bin/bash
set -u

TESTS_DIR="$(CDPATH= cd -P -- "$(dirname -- "$0")" && pwd)"
CLI_PATH="$TESTS_DIR/../bin/dsh-mac"

. "$TESTS_DIR/helpers.sh"

assert_contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *)
      printf 'expected output to contain <%s>, got <%s>\n' "$2" "$1" >&2
      return 1
      ;;
  esac
}

home_inventory() {
  (CDPATH= cd -P -- "$HOME" && /usr/bin/find . -print | LC_ALL=C /usr/bin/sort)
}

run_cli() {
  CLI_OUTPUT=$(DSH_MAC_SOURCE_ONLY=0 /bin/bash "$CLI_PATH" "$@" 2>&1)
  CLI_STATUS=$?
}

assert_line() {
  printf '%s\n' "$1" | /usr/bin/grep -F -x -- "$2" >/dev/null
}

write_service_fakes() {
  write_fake launchctl '
log_line=
for arg in "$@"; do
  if [ -n "$log_line" ]; then log_line="$log_line|$arg"; else log_line=$arg; fi
done
if [ "${DSH_TEST_MUTATION_ONLY_LOG:-0}" != 1 ] || [ "${1:-}" != print ]; then
  printf "%s\n" "$log_line" >>"$DSH_TEST_COMMAND_LOG"
fi
case "${1:-}" in
  print)
    [ "$#" -eq 2 ] || exit 90
    case "$2" in
      gui/[0-9]*)
        case "$2" in */dev.dsh-mac.web) ;; *) exit 0 ;; esac
        ;;
    esac
    [ "$(<"$DSH_TEST_LOADED")" = loaded ] || exit 113
    printf "{\n    pid = %s\n}\n" "$(<"$DSH_TEST_PID")"
    ;;
  bootstrap|kickstart)
    printf "loaded\n" >"$DSH_TEST_LOADED"
    printf "4242\n" >"$DSH_TEST_PID"
    printf "4242|127.0.0.1:3080\n" >"$DSH_TEST_LISTENERS"
    ;;
  kill)
    [ "${2:-}" = SIGTERM ] || exit 91
    printf "4343\n" >"$DSH_TEST_PID"
    printf "4343|127.0.0.1:3080\n" >"$DSH_TEST_LISTENERS"
    ;;
  bootout)
    if [ -n "${DSH_TEST_EXPECT_CLI_DURING_BOOTOUT:-}" ]; then
      [ -e "$DSH_TEST_EXPECT_CLI_DURING_BOOTOUT" ] || exit 93
    fi
    printf "unloaded\n" >"$DSH_TEST_LOADED"
    : >"$DSH_TEST_PID"
    : >"$DSH_TEST_LISTENERS"
    ;;
  *) exit 92 ;;
esac'

  write_fake lsof '
while IFS="|" read -r listener_pid listener_name || [ -n "$listener_pid$listener_name" ]; do
  [ -n "$listener_pid" ] || continue
  case "$*" in
    *-iTCP@127.0.0.1:3080*) [ "$listener_name" = 127.0.0.1:3080 ] || continue ;;
  esac
  printf "p%s\nn%s\n" "$listener_pid" "$listener_name"
  found=1
done <"$DSH_TEST_LISTENERS"
[ "${found:-0}" = 1 ]'

  write_fake curl '[ "$(<"$DSH_TEST_HTTP_OK")" = 1 ]'
  write_fake open 'printf "%s\n" "$*" >>"$DSH_TEST_OPEN_LOG"'
  write_fake tail '
log_line=
for arg in "$@"; do
  if [ -n "$log_line" ]; then log_line="$log_line|$arg"; else log_line=$arg; fi
done
printf "%s\n" "$log_line" >>"$DSH_TEST_TAIL_LOG"'
}

prepare_service_case() {
  case_name=$1
  export HOME="$TEST_ROOT/home-$case_name"
  /bin/mkdir -p "$HOME" || return 1
  export DSH_TEST_COMMAND_LOG="$TEST_ROOT/$case_name-command.log"
  export DSH_TEST_OPEN_LOG="$TEST_ROOT/$case_name-open.log"
  export DSH_TEST_TAIL_LOG="$TEST_ROOT/$case_name-tail.log"
  export DSH_TEST_LOADED="$TEST_ROOT/$case_name-loaded"
  export DSH_TEST_PID="$TEST_ROOT/$case_name-pid"
  export DSH_TEST_LISTENERS="$TEST_ROOT/$case_name-listeners"
  export DSH_TEST_HTTP_OK="$TEST_ROOT/$case_name-http-ok"
  : >"$DSH_TEST_COMMAND_LOG"
  : >"$DSH_TEST_OPEN_LOG"
  : >"$DSH_TEST_TAIL_LOG"
  printf 'loaded\n' >"$DSH_TEST_LOADED"
  printf '4242\n' >"$DSH_TEST_PID"
  printf '4242|127.0.0.1:3080\n' >"$DSH_TEST_LISTENERS"
  printf '1\n' >"$DSH_TEST_HTTP_OK"
  write_service_fakes
  export DSH_MAC_LAUNCHCTL_BIN="$TEST_ROOT/bin/launchctl"
  export DSH_MAC_PLUTIL_BIN=/usr/bin/true
  export DSH_MAC_LSOF_BIN="$TEST_ROOT/bin/lsof"
  export DSH_MAC_CURL_BIN="$TEST_ROOT/bin/curl"
  export DSH_MAC_OPEN_BIN="$TEST_ROOT/bin/open"
  export DSH_MAC_TAIL_BIN="$TEST_ROOT/bin/tail"
  export DSH_MAC_WAIT_ATTEMPTS=3
  export DSH_MAC_WAIT_INTERVAL=0
  export DSH_MAC_WAIT_TIMEOUT_SECONDS=3
}

write_runtime_fakes() {
  write_fake node '
if [ "${1:-}" = --version ]; then
  printf "%s\n" "${DSH_TEST_NODE_VERSION:-v22.19.0}"
  exit 0
fi
if [ "${1:-}" = -e ]; then
  metadata_path=
  for metadata_arg in "$@"; do metadata_path=$metadata_arg; done
  version=$(/usr/bin/sed -n '\''s/.*"version":"\([^" ]*\)".*/\1/p'\'' "$metadata_path")
  package_bin=$(/usr/bin/sed -n '\''s/.*"dsh":"\([^" ]*\)".*/\1/p'\'' "$metadata_path")
  [ -n "$version" ] && [ -n "$package_bin" ] || exit 65
  printf "%s\n%s\n" "$version" "$package_bin"
  exit 0
fi
cli_path=${1:-}
[ "${2:-}" = --version ] && [ "$#" -eq 2 ] || exit 64
release_path=${cli_path%/node_modules/@deepseek-ai/dsh/lib/bin.js}
version=$(/usr/bin/sed -n "s/^DSH_VERSION=//p" "$release_path/manifest.env")
[ -n "$version" ] || exit 66
printf "@deepseek-ai/dsh %s\n" "$version"'

  write_fake npm '
printf "%s\n" "$*" >>"$DSH_TEST_NPM_LOG"
if [ "${1:-}" = view ]; then
  [ "$#" -eq 3 ] && [ "$2" = @deepseek-ai/dsh@latest ] && [ "$3" = version ] || exit 70
  manager_root="$HOME/Library/Application Support/dsh-mac"
  [ -f "$manager_root/.lock/pid" ] || exit 71
  [ "${DSH_TEST_NPM_VIEW_FAIL:-0}" != 1 ] || exit 69
  printf "%s\n" "${DSH_TEST_LATEST_VERSION:-1.2.3}"
  exit 0
fi
[ "${1:-}" = install ] || exit 72
[ "${DSH_TEST_NPM_INSTALL_FAIL:-0}" != 1 ] || exit 69
if [ -n "${DSH_TEST_NPM_SIGNAL:-}" ]; then
  kill -"$DSH_TEST_NPM_SIGNAL" "$PPID" || exit 75
  exit 69
fi
shift
install_prefix=
package_spec=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix) install_prefix=$2; shift 2 ;;
    @deepseek-ai/dsh@*) package_spec=$1; shift ;;
    *) shift ;;
  esac
done
[ -n "$install_prefix" ] && [ -n "$package_spec" ] || exit 73
version=${package_spec#@deepseek-ai/dsh@}
/bin/mkdir -p "$install_prefix/node_modules/@deepseek-ai/dsh/lib" || exit 74
printf "{\"version\":\"%s\",\"bin\":{\"dsh\":\"lib/bin.js\"}}\n" "$version" >"$install_prefix/node_modules/@deepseek-ai/dsh/package.json"
printf "entry\n" >"$install_prefix/node_modules/@deepseek-ai/dsh/lib/bin.js"'
}

prepare_install_case() {
  case_name=$1
  prepare_service_case "$case_name" || return 1
  write_runtime_fakes
  printf 'unloaded\n' >"$DSH_TEST_LOADED"
  : >"$DSH_TEST_PID"
  : >"$DSH_TEST_LISTENERS"
  export DSH_TEST_NPM_LOG="$TEST_ROOT/$case_name-npm.log"
  : >"$DSH_TEST_NPM_LOG"
  export DSH_TEST_LATEST_VERSION=1.2.3
  export DSH_TEST_NODE_VERSION=v22.19.0
  unset DSH_TEST_NPM_VIEW_FAIL DSH_TEST_NPM_INSTALL_FAIL DSH_TEST_NPM_SIGNAL
  export PATH="$TEST_ROOT/bin:/usr/bin:/bin"
}

release_count() {
  releases="$HOME/Library/Application Support/dsh-mac/releases"
  [ -d "$releases" ] || {
    printf '0\n'
    return 0
  }
  count=0
  for release_child in "$releases"/*; do
    [ -e "$release_child" ] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

assert_no_install_transaction_artifacts() {
  for transaction_parent in \
    "$HOME/.local/bin" \
    "$HOME/Library/Application Support/dsh-mac/libexec"; do
    [ -d "$transaction_parent" ] || continue
    for transaction_path in "$transaction_parent"/.dsh-mac-*; do
      [ ! -e "$transaction_path" ] && [ ! -L "$transaction_path" ] || {
        printf 'unexpected manager transaction artifact: %s\n' "$transaction_path" >&2
        return 1
      }
    done
  done
  releases="$HOME/Library/Application Support/dsh-mac/releases"
  if [ -d "$releases" ]; then
    for staging_path in "$releases"/.staging-*; do
      [ ! -e "$staging_path" ] && [ ! -L "$staging_path" ] || {
        printf 'unexpected staging artifact: %s\n' "$staging_path" >&2
        return 1
      }
    done
  fi
}

make_status_release() {
  manager_root="$HOME/Library/Application Support/dsh-mac"
  release_id=1.2.3-1786640000-1234
  release_path="$manager_root/releases/$release_id"
  /bin/mkdir -p "$release_path" || return 1
  {
    printf 'SCHEMA_VERSION=1\n'
    printf 'DSH_VERSION=1.2.3\n'
    printf 'NODE_BIN=/usr/bin/true\n'
    printf 'CLI_RELATIVE=lib/bin.js\n'
    printf 'INSTALLED_AT=1786640000\n'
  } >"$release_path/manifest.env" || return 1
  /bin/ln -s "releases/$release_id" "$manager_root/current"
}

test_unknown_command_exits_64_with_usage() {
  run_cli definitely-unknown
  assert_eq 64 "$CLI_STATUS" || return 1
  assert_contains "$CLI_OUTPUT" 'Usage: dsh-mac' || return 1
  assert_contains "$CLI_OUTPUT" 'install'
}

test_every_public_command_rejects_extra_arguments() {
  for public_command in install start stop restart status open logs update uninstall version help; do
    run_cli "$public_command" extra
    assert_eq 64 "$CLI_STATUS" || {
      printf 'command with extra argument: %s\n' "$public_command" >&2
      return 1
    }
    assert_contains "$CLI_OUTPUT" 'Usage: dsh-mac' || return 1
  done
}

test_help_and_version_are_read_only() {
  before=$(home_inventory) || return 1

  run_cli help
  assert_eq 0 "$CLI_STATUS" || return 1
  assert_contains "$CLI_OUTPUT" 'Usage: dsh-mac' || return 1

  run_cli version
  assert_eq 0 "$CLI_STATUS" || return 1
  assert_eq '0.1.0' "$CLI_OUTPUT" || return 1

  after=$(home_inventory) || return 1
  assert_eq "$before" "$after"
}

test_status_prints_all_public_fields() {
  prepare_service_case status-fields || return 1
  make_status_release || return 1

  run_cli status

  assert_eq 0 "$CLI_STATUS" || return 1
  assert_line "$CLI_OUTPUT" 'Manager version: 0.1.0' || return 1
  assert_line "$CLI_OUTPUT" 'DSH version: 1.2.3' || return 1
  assert_line "$CLI_OUTPUT" 'Launchd: loaded' || return 1
  assert_line "$CLI_OUTPUT" 'PID: 4242' || return 1
  assert_line "$CLI_OUTPUT" 'URL: http://127.0.0.1:3080' || return 1
  assert_line "$CLI_OUTPUT" 'Health: healthy'
}

test_status_reports_an_activation_journal_as_interrupted() {
  prepare_service_case status-interrupted || return 1
  make_status_release || return 1
  activation="$HOME/Library/Application Support/dsh-mac/activation.env"
  printf 'interrupted transaction\n' >"$activation"
  before=$(<"$activation")

  run_cli status

  assert_eq 1 "$CLI_STATUS" || return 1
  assert_line "$CLI_OUTPUT" 'Health: interrupted' || return 1
  assert_eq "$before" "$(<"$activation")"
}

test_open_requires_verified_health_and_no_activation_journal() {
  prepare_service_case open-health || return 1
  make_status_release || return 1

  run_cli open
  assert_eq 0 "$CLI_STATUS" || return 1
  assert_eq 'http://127.0.0.1:3080' "$(<"$DSH_TEST_OPEN_LOG")" || return 1

  : >"$DSH_TEST_OPEN_LOG"
  printf 'journal\n' >"$HOME/Library/Application Support/dsh-mac/activation.env"
  run_cli open
  assert_eq 1 "$CLI_STATUS" || return 1
  assert_eq '' "$(<"$DSH_TEST_OPEN_LOG")" || return 1

  /bin/rm -f "$HOME/Library/Application Support/dsh-mac/activation.env"
  printf '0\n' >"$DSH_TEST_HTTP_OK"
  run_cli open
  assert_eq 1 "$CLI_STATUS" || return 1
  assert_eq '' "$(<"$DSH_TEST_OPEN_LOG")"
}

test_logs_execs_tail_F_for_only_the_two_owned_logs() {
  prepare_service_case logs-arguments || return 1

  run_cli logs

  assert_eq 0 "$CLI_STATUS" || return 1
  expected="-F|$HOME/Library/Logs/dsh-mac/stdout.log|$HOME/Library/Logs/dsh-mac/stderr.log"
  assert_eq "$expected" "$(<"$DSH_TEST_TAIL_LOG")"
}

test_logs_replaces_the_cli_process_with_tail() {
  prepare_service_case logs-signal || return 1
  export DSH_TEST_TAIL_PID="$TEST_ROOT/logs-tail.pid"
  write_fake blocking-tail '
printf "%s\n" "$$" >"$DSH_TEST_TAIL_PID"
trap "exit 130" INT
trap "exit 143" TERM
while :; do /bin/sleep 1; done'
  export DSH_MAC_TAIL_BIN="$TEST_ROOT/bin/blocking-tail"

  DSH_MAC_SOURCE_ONLY=0 /bin/bash "$CLI_PATH" logs >/dev/null 2>&1 &
  cli_pid=$!
  attempts=0
  while [ "$attempts" -lt 50 ] && [ ! -s "$DSH_TEST_TAIL_PID" ]; do
    /bin/sleep 0.1
    attempts=$((attempts + 1))
  done
  [ -s "$DSH_TEST_TAIL_PID" ] || {
    kill -KILL "$cli_pid" 2>/dev/null || :
    wait "$cli_pid" 2>/dev/null || :
    return 1
  }
  assert_eq "$cli_pid" "$(<"$DSH_TEST_TAIL_PID")" || return 1
  kill -TERM "$cli_pid" || return 1
  wait "$cli_pid"
  assert_eq 143 "$?"
}

test_install_finishes_preflight_before_creating_owned_paths() {
  prepare_install_case install-preflight || return 1
  export DSH_TEST_NODE_VERSION=v23.9.0
  before=$(home_inventory) || return 1

  run_cli install

  assert_eq 1 "$CLI_STATUS" || return 1
  assert_contains "$CLI_OUTPUT" 'unsupported Node.js version' || return 1
  after=$(home_inventory) || return 1
  assert_eq "$before" "$after"
}

test_install_atomically_publishes_executable_cli_and_runner() {
  prepare_install_case install-success || return 1

  run_cli install

  assert_eq 0 "$CLI_STATUS" || {
    printf '%s\n' "$CLI_OUTPUT" >&2
    return 1
  }
  installed_cli="$HOME/.local/bin/dsh-mac"
  installed_runner="$HOME/Library/Application Support/dsh-mac/libexec/dsh-mac-run"
  [ -f "$installed_cli" ] && [ -x "$installed_cli" ] && [ ! -L "$installed_cli" ] || return 1
  [ -f "$installed_runner" ] && [ -x "$installed_runner" ] && [ ! -L "$installed_runner" ] || return 1
  /usr/bin/cmp -s "$CLI_PATH" "$installed_cli" || return 1
  /usr/bin/cmp -s "$TESTS_DIR/../libexec/dsh-mac-run" "$installed_runner" || return 1
  assert_eq 1 "$(release_count)" || return 1
  assert_eq loaded "$(<"$DSH_TEST_LOADED")" || return 1
  assert_eq 'http://127.0.0.1:3080' "$(<"$DSH_TEST_OPEN_LOG")" || return 1
  [ ! -e "$HOME/Library/Application Support/dsh-mac/.lock" ]
}

test_failed_first_install_removes_new_manager_files_and_empty_root() {
  prepare_install_case install-first-failure || return 1
  export DSH_TEST_NPM_VIEW_FAIL=1

  run_cli install

  assert_eq 1 "$CLI_STATUS" || return 1
  [ ! -e "$HOME/.local/bin/dsh-mac" ] || return 1
  [ ! -e "$HOME/Library/Application Support/dsh-mac/libexec/dsh-mac-run" ] || return 1
  [ ! -e "$HOME/Library/Application Support/dsh-mac" ]
}

test_failed_install_restores_both_older_manager_files() {
  prepare_install_case install-restore || return 1
  installed_cli="$HOME/.local/bin/dsh-mac"
  installed_runner="$HOME/Library/Application Support/dsh-mac/libexec/dsh-mac-run"
  /bin/mkdir -p "${installed_cli%/*}" "${installed_runner%/*}" || return 1
  printf 'older cli\n' >"$installed_cli" || return 1
  printf 'older runner\n' >"$installed_runner" || return 1
  /bin/chmod 0755 "$installed_cli" "$installed_runner" || return 1
  export DSH_TEST_NPM_INSTALL_FAIL=1

  run_cli install

  assert_eq 1 "$CLI_STATUS" || return 1
  assert_eq 'older cli' "$(<"$installed_cli")" || return 1
  assert_eq 'older runner' "$(<"$installed_runner")" || return 1
  [ -x "$installed_cli" ] && [ -x "$installed_runner" ] || return 1
  [ ! -e "$HOME/Library/Application Support/dsh-mac/releases" ] || return 1
  assert_no_install_transaction_artifacts || return 1
  [ ! -e "$HOME/Library/Application Support/dsh-mac/.lock" ]
}

test_true_npm_install_failure_removes_every_new_empty_install_directory() {
  prepare_install_case install-npm-failure-cleanup || return 1
  export DSH_TEST_NPM_INSTALL_FAIL=1

  run_cli install

  assert_eq 1 "$CLI_STATUS" || return 1
  assert_eq 2 "$(wc -l <"$DSH_TEST_NPM_LOG" | tr -d ' ')" || return 1
  [ ! -e "$HOME/.local" ] || return 1
  [ ! -e "$HOME/Library" ] || return 1
  assert_no_install_transaction_artifacts
}

test_term_during_stage_restores_both_older_manager_files_and_lock() {
  prepare_install_case install-term-restore || return 1
  installed_cli="$HOME/.local/bin/dsh-mac"
  installed_runner="$HOME/Library/Application Support/dsh-mac/libexec/dsh-mac-run"
  /bin/mkdir -p "${installed_cli%/*}" "${installed_runner%/*}" || return 1
  printf 'older cli before TERM\n' >"$installed_cli" || return 1
  printf 'older runner before TERM\n' >"$installed_runner" || return 1
  /bin/chmod 0755 "$installed_cli" "$installed_runner" || return 1
  cli_identity=$(/usr/bin/stat -f '%i:%Lp' "$installed_cli") || return 1
  runner_identity=$(/usr/bin/stat -f '%i:%Lp' "$installed_runner") || return 1
  export DSH_TEST_NPM_SIGNAL=TERM

  run_cli install

  assert_eq 143 "$CLI_STATUS" || return 1
  assert_eq 'older cli before TERM' "$(<"$installed_cli")" || return 1
  assert_eq 'older runner before TERM' "$(<"$installed_runner")" || return 1
  assert_eq "$cli_identity" "$(/usr/bin/stat -f '%i:%Lp' "$installed_cli")" || return 1
  assert_eq "$runner_identity" "$(/usr/bin/stat -f '%i:%Lp' "$installed_runner")" || return 1
  [ ! -e "$HOME/Library/Application Support/dsh-mac/.lock" ] || return 1
  [ ! -e "$HOME/Library/Application Support/dsh-mac/releases" ] || return 1
  assert_no_install_transaction_artifacts
}

test_term_during_first_install_removes_manager_files_and_new_directories() {
  prepare_install_case install-term-first || return 1
  export DSH_TEST_NPM_SIGNAL=TERM

  run_cli install

  assert_eq 143 "$CLI_STATUS" || return 1
  [ ! -e "$HOME/.local" ] || return 1
  [ ! -e "$HOME/Library" ] || return 1
  assert_no_install_transaction_artifacts
}

test_cli_destination_directory_is_rejected_before_external_preflight() {
  prepare_install_case install-cli-directory || return 1
  cli_destination="$HOME/.local/bin/dsh-mac"
  /bin/mkdir -p "$cli_destination" || return 1
  printf 'cli directory marker\n' >"$cli_destination/marker" || return 1
  before=$(home_inventory) || return 1
  identity=$(/usr/bin/stat -f '%HT:%i:%m' "$cli_destination") || return 1

  run_cli install

  assert_eq 1 "$CLI_STATUS" || return 1
  assert_eq "$before" "$(home_inventory)" || return 1
  assert_eq "$identity" "$(/usr/bin/stat -f '%HT:%i:%m' "$cli_destination")" || return 1
  assert_eq 'cli directory marker' "$(<"$cli_destination/marker")" || return 1
  assert_eq '' "$(<"$DSH_TEST_COMMAND_LOG")" || return 1
  assert_eq '' "$(<"$DSH_TEST_NPM_LOG")" || return 1
  assert_eq '' "$(<"$DSH_TEST_OPEN_LOG")" || return 1
  assert_no_install_transaction_artifacts
}

test_runner_destination_directory_is_rejected_before_external_preflight() {
  prepare_install_case install-runner-directory || return 1
  runner_destination="$HOME/Library/Application Support/dsh-mac/libexec/dsh-mac-run"
  /bin/mkdir -p "$runner_destination" || return 1
  printf 'runner directory marker\n' >"$runner_destination/marker" || return 1
  before=$(home_inventory) || return 1
  identity=$(/usr/bin/stat -f '%HT:%i:%m' "$runner_destination") || return 1

  run_cli install

  assert_eq 1 "$CLI_STATUS" || return 1
  assert_eq "$before" "$(home_inventory)" || return 1
  assert_eq "$identity" "$(/usr/bin/stat -f '%HT:%i:%m' "$runner_destination")" || return 1
  assert_eq 'runner directory marker' "$(<"$runner_destination/marker")" || return 1
  assert_eq '' "$(<"$DSH_TEST_COMMAND_LOG")" || return 1
  assert_eq '' "$(<"$DSH_TEST_NPM_LOG")" || return 1
  assert_eq '' "$(<"$DSH_TEST_OPEN_LOG")" || return 1
  assert_no_install_transaction_artifacts
}

test_manager_staging_failure_preserves_both_older_files() {
  prepare_install_case install-stage-restore || return 1
  installed_cli="$HOME/.local/bin/dsh-mac"
  installed_runner="$HOME/Library/Application Support/dsh-mac/libexec/dsh-mac-run"
  /bin/mkdir -p "${installed_cli%/*}" "${installed_runner%/*}" || return 1
  printf 'older cli before staging\n' >"$installed_cli" || return 1
  printf 'older runner before staging\n' >"$installed_runner" || return 1
  /bin/chmod 0755 "$installed_cli" "$installed_runner" || return 1
  /bin/chmod 0555 "${installed_runner%/*}" || return 1

  run_cli install
  command_status=$CLI_STATUS
  command_output=$CLI_OUTPUT
  /bin/chmod 0755 "${installed_runner%/*}" || return 1

  assert_eq 1 "$command_status" || {
    printf '%s\n' "$command_output" >&2
    return 1
  }
  assert_eq 'older cli before staging' "$(<"$installed_cli")" || return 1
  assert_eq 'older runner before staging' "$(<"$installed_runner")"
}

test_repeated_installed_install_reuses_release_and_preserves_pid() {
  prepare_install_case install-repeat || return 1
  run_cli install
  assert_eq 0 "$CLI_STATUS" || return 1
  installed_cli="$HOME/.local/bin/dsh-mac"
  first_pid=$(<"$DSH_TEST_PID")
  first_count=$(release_count)
  first_identity=$(/usr/bin/stat -f '%i:%m' "$installed_cli") || return 1
  : >"$DSH_TEST_OPEN_LOG"

  CLI_OUTPUT=$(DSH_MAC_SOURCE_ONLY=0 /bin/bash "$installed_cli" install 2>&1)
  CLI_STATUS=$?

  assert_eq 0 "$CLI_STATUS" || {
    printf '%s\n' "$CLI_OUTPUT" >&2
    return 1
  }
  assert_eq "$first_count" "$(release_count)" || return 1
  assert_eq "$first_pid" "$(<"$DSH_TEST_PID")" || return 1
  assert_eq "$first_identity" "$(/usr/bin/stat -f '%i:%m' "$installed_cli")" || return 1
  assert_eq 'http://127.0.0.1:3080' "$(<"$DSH_TEST_OPEN_LOG")"
}

test_install_prints_path_hint_without_editing_profiles() {
  prepare_install_case install-path-hint || return 1
  export PATH="$TEST_ROOT/bin:/usr/bin:/bin"

  run_cli install

  assert_eq 0 "$CLI_STATUS" || return 1
  assert_contains "$CLI_OUTPUT" 'export PATH=' || return 1
  assert_contains "$CLI_OUTPUT" "$HOME/.local/bin" || return 1
  assert_contains "$CLI_OUTPUT" "$HOME/.local/bin/dsh-mac" || return 1
  [ ! -e "$HOME/.zshrc" ] && [ ! -e "$HOME/.bash_profile" ]
}

prepare_uninstall_case() {
  case_name=$1
  prepare_service_case "$case_name" || return 1
  manager_root="$HOME/Library/Application Support/dsh-mac"
  cli_dest="$HOME/.local/bin/dsh-mac"
  plist_path="$HOME/Library/LaunchAgents/dev.dsh-mac.web.plist"
  log_dir="$HOME/Library/Logs/dsh-mac"
  /bin/mkdir -p "$manager_root" "${cli_dest%/*}" "${plist_path%/*}" "$log_dir" "$HOME/.dsh" || return 1
  printf 'malformed journal proves recovery was skipped\n' >"$manager_root/activation.env" || return 1
  printf 'installed command\n' >"$cli_dest" || return 1
  /bin/chmod 0755 "$cli_dest" || return 1
  printf 'owned plist\n' >"$plist_path" || return 1
  printf 'stdout\n' >"$log_dir/stdout.log" || return 1
  printf 'stderr\n' >"$log_dir/stderr.log" || return 1
  printf 'preserve log sibling\n' >"$log_dir/preserve.log" || return 1
  printf 'preserve plist sibling\n' >"${plist_path%/*}/other.plist" || return 1
  printf 'preserve cli sibling\n' >"${cli_dest%/*}/other-command" || return 1
  printf 'private marker\n' >"$HOME/.dsh/marker" || return 1
  export DSH_TEST_EXPECT_CLI_DURING_BOOTOUT="$cli_dest"
}

test_uninstall_skips_recovery_and_removes_only_exact_owned_paths() {
  prepare_uninstall_case uninstall-exact || return 1

  run_cli uninstall

  assert_eq 0 "$CLI_STATUS" || {
    printf '%s\n' "$CLI_OUTPUT" >&2
    return 1
  }
  uid=$(/usr/bin/id -u)
  assert_line "$(<"$DSH_TEST_COMMAND_LOG")" "bootout|gui/$uid/dev.dsh-mac.web" || return 1
  [ ! -e "$HOME/Library/Application Support/dsh-mac" ] || return 1
  [ ! -e "$HOME/Library/LaunchAgents/dev.dsh-mac.web.plist" ] || return 1
  [ ! -e "$HOME/Library/Logs/dsh-mac/stdout.log" ] || return 1
  [ ! -e "$HOME/Library/Logs/dsh-mac/stderr.log" ] || return 1
  [ ! -e "$HOME/.local/bin/dsh-mac" ] || return 1
  assert_eq 'preserve log sibling' "$(<"$HOME/Library/Logs/dsh-mac/preserve.log")" || return 1
  assert_eq 'preserve plist sibling' "$(<"$HOME/Library/LaunchAgents/other.plist")" || return 1
  assert_eq 'preserve cli sibling' "$(<"$HOME/.local/bin/other-command")" || return 1
  assert_eq 'private marker' "$(<"$HOME/.dsh/marker")"
}

test_uninstall_is_repeatable() {
  prepare_uninstall_case uninstall-repeat || return 1
  run_cli uninstall
  assert_eq 0 "$CLI_STATUS" || return 1
  : >"$DSH_TEST_COMMAND_LOG"

  run_cli uninstall

  assert_eq 0 "$CLI_STATUS" || return 1
  assert_eq 'private marker' "$(<"$HOME/.dsh/marker")" || return 1
  [ ! -e "$HOME/Library/Application Support/dsh-mac" ] || return 1
  case "$(<"$DSH_TEST_COMMAND_LOG")" in
    *bootout*) return 1 ;;
  esac
}

home_fingerprint() {
  (CDPATH= cd -P -- "$HOME" && /usr/bin/tar -cf - . 2>/dev/null | /usr/bin/cksum)
}

start_real_lock_holder() {
  ready_file=$1
  DSH_MAC_SOURCE_ONLY=1 /bin/bash -c '
    . "$1" || exit 1
    init_paths
    acquire_lock || exit 1
    : >"$2"
    while :; do /bin/sleep 1; done
  ' lock-holder "$CLI_PATH" "$ready_file" &
  LOCK_HOLDER_PID=$!
  attempts=0
  while [ "$attempts" -lt 50 ] && [ ! -e "$ready_file" ]; do
    /bin/sleep 0.1
    attempts=$((attempts + 1))
  done
  [ -e "$ready_file" ] || {
    kill -KILL "$LOCK_HOLDER_PID" 2>/dev/null || :
    wait "$LOCK_HOLDER_PID" 2>/dev/null || :
    return 1
  }
}

stop_real_lock_holder() {
  kill -TERM "$LOCK_HOLDER_PID" 2>/dev/null || return 1
  wait "$LOCK_HOLDER_PID"
  [ "$?" -eq 143 ]
}

test_all_mutating_public_commands_reject_a_live_real_lock_without_mutation() {
  for locked_command in install start stop restart update uninstall; do
    prepare_install_case "locked-$locked_command" || return 1
    export DSH_TEST_MUTATION_ONLY_LOG=1
    manager_root="$HOME/Library/Application Support/dsh-mac"
    /bin/mkdir -p "$manager_root" "$HOME/.local/bin" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/dsh-mac" || return 1
    printf 'manager sentinel\n' >"$manager_root/sentinel" || return 1
    printf 'cli sentinel\n' >"$HOME/.local/bin/dsh-mac" || return 1
    printf 'plist sentinel\n' >"$HOME/Library/LaunchAgents/dev.dsh-mac.web.plist" || return 1
    printf 'log sentinel\n' >"$HOME/Library/Logs/dsh-mac/stdout.log" || return 1
    ready="$TEST_ROOT/locked-$locked_command-ready"
    start_real_lock_holder "$ready" || return 1
    before_home=$(home_fingerprint) || return 1
    before_commands=$(<"$DSH_TEST_COMMAND_LOG")
    before_npm=$(<"$DSH_TEST_NPM_LOG")
    before_open=$(<"$DSH_TEST_OPEN_LOG")

    run_cli "$locked_command"

    assert_eq 1 "$CLI_STATUS" || {
      printf 'locked command returned wrong status: %s\n' "$locked_command" >&2
      stop_real_lock_holder || :
      return 1
    }
    assert_contains "$CLI_OUTPUT" 'another dsh-mac operation is running' || {
      stop_real_lock_holder || :
      return 1
    }
    assert_eq "$before_home" "$(home_fingerprint)" || {
      printf 'locked command mutated HOME: %s\n' "$locked_command" >&2
      stop_real_lock_holder || :
      return 1
    }
    assert_eq "$before_commands" "$(<"$DSH_TEST_COMMAND_LOG")" || return 1
    assert_eq "$before_npm" "$(<"$DSH_TEST_NPM_LOG")" || return 1
    assert_eq "$before_open" "$(<"$DSH_TEST_OPEN_LOG")" || return 1
    stop_real_lock_holder || return 1
    unset DSH_TEST_MUTATION_ONLY_LOG
  done
}

run_test 'unknown commands exit 64 and print complete usage' test_unknown_command_exits_64_with_usage
run_test 'every public command rejects extra arguments with usage' test_every_public_command_rejects_extra_arguments
run_test 'help and version do not mutate HOME' test_help_and_version_are_read_only
run_test 'status prints manager, DSH, launchd, PID, URL, and health' test_status_prints_all_public_fields
run_test 'status reports an activation journal as interrupted' test_status_reports_an_activation_journal_as_interrupted
run_test 'open runs only after fresh verified health' test_open_requires_verified_health_and_no_activation_journal
run_test 'logs follows exactly both owned log files' test_logs_execs_tail_F_for_only_the_two_owned_logs
run_test 'logs gives signals directly to tail' test_logs_replaces_the_cli_process_with_tail
run_test 'install completes full preflight before mutation' test_install_finishes_preflight_before_creating_owned_paths
run_test 'install atomically publishes executable CLI and runner' test_install_atomically_publishes_executable_cli_and_runner
run_test 'failed first install removes manager files and empty root' test_failed_first_install_removes_new_manager_files_and_empty_root
run_test 'failed install restores both older manager files' test_failed_install_restores_both_older_manager_files
run_test 'true npm install failure removes every new empty install directory' test_true_npm_install_failure_removes_every_new_empty_install_directory
run_test 'TERM during staging restores both older manager files and lock' test_term_during_stage_restores_both_older_manager_files_and_lock
run_test 'TERM during first install removes manager files and new directories' test_term_during_first_install_removes_manager_files_and_new_directories
run_test 'CLI destination directory is rejected before external preflight' test_cli_destination_directory_is_rejected_before_external_preflight
run_test 'runner destination directory is rejected before external preflight' test_runner_destination_directory_is_rejected_before_external_preflight
run_test 'manager staging failure preserves both older files' test_manager_staging_failure_preserves_both_older_files
run_test 'repeated installed install reuses release and preserves PID' test_repeated_installed_install_reuses_release_and_preserves_pid
run_test 'install prints a PATH hint without editing profiles' test_install_prints_path_hint_without_editing_profiles
run_test 'uninstall skips recovery and removes only exact owned paths' test_uninstall_skips_recovery_and_removes_only_exact_owned_paths
run_test 'uninstall is repeatable' test_uninstall_is_repeatable
run_test 'all mutating public commands reject a live real lock without mutation' test_all_mutating_public_commands_reject_a_live_real_lock_without_mutation

finish_tests
