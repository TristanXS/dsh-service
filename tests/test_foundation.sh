#!/bin/bash
set -u

TESTS_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CLI_PATH="$TESTS_DIR/../bin/dsh-mac"

. "$TESTS_DIR/helpers.sh"

export DSH_MAC_SOURCE_ONLY=1
if ! . "$CLI_PATH"; then
  printf 'could not source CLI: %s\n' "$CLI_PATH" >&2
  exit 1
fi

test_die_reports_failure() {
  actual=$(die 'broken operation' 2>&1)
  status=$?
  assert_eq 1 "$status" || return 1
  assert_eq 'dsh-mac: error: broken operation' "$actual"
}

test_note_reports_progress() {
  actual=$(note 'working' 2>&1)
  status=$?
  assert_eq 0 "$status" || return 1
  assert_eq 'dsh-mac: working' "$actual"
}

test_init_paths_uses_home() {
  init_paths
  uid=$(/usr/bin/id -u)
  assert_eq "$HOME/Library/Application Support/dsh-mac" "$DSH_MAC_ROOT" || return 1
  assert_eq "$DSH_MAC_ROOT/releases" "$RELEASES_DIR" || return 1
  assert_eq "$DSH_MAC_ROOT/current" "$CURRENT_LINK" || return 1
  assert_eq "$DSH_MAC_ROOT/previous" "$PREVIOUS_LINK" || return 1
  assert_eq "$DSH_MAC_ROOT/activation.env" "$ACTIVATION_FILE" || return 1
  assert_eq "$DSH_MAC_ROOT/.lock" "$LOCK_DIR" || return 1
  assert_eq "$DSH_MAC_ROOT/workspace" "$WORKSPACE_DIR" || return 1
  assert_eq "$HOME/.local/bin/dsh-mac" "$CLI_DEST" || return 1
  assert_eq "$HOME/Library/LaunchAgents/dev.dsh-mac.web.plist" "$PLIST_PATH" || return 1
  assert_eq "$HOME/Library/Logs/dsh-mac" "$LOG_DIR" || return 1
  assert_eq "gui/$uid/dev.dsh-mac.web" "$SERVICE_TARGET"
}

test_command_overrides_are_honored_in_tests() (
  DSH_MAC_LAUNCHCTL_BIN="$TEST_ROOT/bin/launchctl-override"
  DSH_MAC_PLUTIL_BIN="$TEST_ROOT/bin/plutil-override"
  DSH_MAC_LSOF_BIN="$TEST_ROOT/bin/lsof-override"
  DSH_MAC_CURL_BIN="$TEST_ROOT/bin/curl-override"
  DSH_MAC_OPEN_BIN="$TEST_ROOT/bin/open-override"
  DSH_MAC_TAIL_BIN="$TEST_ROOT/bin/tail-override"
  DSH_MAC_WAIT_ATTEMPTS=7
  DSH_MAC_WAIT_INTERVAL=2
  init_command_paths
  assert_eq "$DSH_MAC_LAUNCHCTL_BIN" "$LAUNCHCTL_BIN" || return 1
  assert_eq "$DSH_MAC_PLUTIL_BIN" "$PLUTIL_BIN" || return 1
  assert_eq "$DSH_MAC_LSOF_BIN" "$LSOF_BIN" || return 1
  assert_eq "$DSH_MAC_CURL_BIN" "$CURL_BIN" || return 1
  assert_eq "$DSH_MAC_OPEN_BIN" "$OPEN_BIN" || return 1
  assert_eq "$DSH_MAC_TAIL_BIN" "$TAIL_BIN" || return 1
  assert_eq 7 "$WAIT_ATTEMPTS" || return 1
  assert_eq 2 "$WAIT_INTERVAL"
)

test_command_overrides_are_ignored_in_production() (
  DSH_MAC_TESTING=0
  DSH_MAC_LAUNCHCTL_BIN="$TEST_ROOT/bin/not-launchctl"
  DSH_MAC_WAIT_ATTEMPTS=99
  DSH_MAC_WAIT_INTERVAL=99
  init_command_paths
  assert_eq /bin/launchctl "$LAUNCHCTL_BIN" || return 1
  assert_eq /usr/bin/plutil "$PLUTIL_BIN" || return 1
  assert_eq /usr/sbin/lsof "$LSOF_BIN" || return 1
  assert_eq /usr/bin/curl "$CURL_BIN" || return 1
  assert_eq /usr/bin/open "$OPEN_BIN" || return 1
  assert_eq /usr/bin/tail "$TAIL_BIN" || return 1
  assert_eq 30 "$WAIT_ATTEMPTS" || return 1
  assert_eq 1 "$WAIT_INTERVAL"
)

test_node_22_19_is_supported() {
  assert_eq yes "$(node_version_supported 22.19.0 && printf yes || printf no)"
}

test_node_22_18_is_rejected() {
  assert_eq no "$(node_version_supported 22.18.0 && printf yes || printf no)"
}

test_node_23_is_rejected() {
  assert_eq no "$(node_version_supported 23.9.0 && printf yes || printf no)"
}

test_node_24_is_supported() {
  assert_eq yes "$(node_version_supported 24.0.0 && printf yes || printf no)"
}

test_node_prerelease_is_rejected() {
  assert_eq no "$(node_version_supported 24.0.0-rc.1 && printf yes || printf no)"
}

test_oversized_node_component_is_supported_cleanly() {
  output=$(node_version_supported 999999999999999999999.0.0 2>&1)
  status=$?
  assert_eq 0 "$status" || return 1
  assert_eq '' "$output"
}

test_release_id_accepts_generated_shape() {
  validate_release_id '0.1.0-rc.6-1786640000-1234'
}

test_release_id_rejects_parent_traversal() {
  ! validate_release_id '../outside'
}

test_release_id_rejects_child_path() {
  ! validate_release_id 'release/child'
}

write_manifest() {
  manifest_path=$1
  node_path=$2
  dsh_version=$3
  cli_relative=$4
  installed_at=$5
  {
    printf 'SCHEMA_VERSION=1\n'
    printf 'DSH_VERSION=%s\n' "$dsh_version"
    printf 'NODE_BIN=%s\n' "$node_path"
    printf 'CLI_RELATIVE=%s\n' "$cli_relative"
    printf 'INSTALLED_AT=%s\n' "$installed_at"
  } >"$manifest_path"
}

prepare_manifest() {
  write_fake manifest-node 'exit 0'
  MANIFEST_PATH="$TEST_ROOT/manifest.env"
  MANIFEST_NODE_PATH="$TEST_ROOT/bin/manifest-node"
  write_manifest "$MANIFEST_PATH" "$MANIFEST_NODE_PATH" '0.1.0' 'bin/dsh-mac' '1786640000'
}

test_manifest_reads_valid_values() {
  prepare_manifest
  read_manifest "$MANIFEST_PATH" || return 1
  assert_eq 1 "$MANIFEST_SCHEMA_VERSION" || return 1
  assert_eq '0.1.0' "$MANIFEST_DSH_VERSION" || return 1
  assert_eq "$MANIFEST_NODE_PATH" "$MANIFEST_NODE_BIN" || return 1
  assert_eq 'bin/dsh-mac' "$MANIFEST_CLI_RELATIVE" || return 1
  assert_eq '1786640000' "$MANIFEST_INSTALLED_AT"
}

test_manifest_rejects_duplicate_keys() {
  prepare_manifest
  printf 'SCHEMA_VERSION=1\n' >>"$MANIFEST_PATH"
  ! read_manifest "$MANIFEST_PATH"
}

test_manifest_rejects_unknown_keys() {
  prepare_manifest
  printf 'SURPRISE=value\n' >>"$MANIFEST_PATH"
  ! read_manifest "$MANIFEST_PATH"
}

test_manifest_rejects_missing_keys() {
  prepare_manifest
  {
    printf 'SCHEMA_VERSION=1\n'
    printf 'DSH_VERSION=0.1.0\n'
    printf 'NODE_BIN=%s\n' "$MANIFEST_NODE_PATH"
    printf 'CLI_RELATIVE=bin/dsh-mac\n'
  } >"$MANIFEST_PATH"
  ! read_manifest "$MANIFEST_PATH"
}

test_manifest_rejects_relative_node_bin() {
  prepare_manifest
  write_manifest "$MANIFEST_PATH" 'relative/node' '0.1.0' 'bin/dsh-mac' '1786640000'
  ! read_manifest "$MANIFEST_PATH"
}

test_manifest_rejects_unsafe_cli_relative() {
  prepare_manifest
  write_manifest "$MANIFEST_PATH" "$MANIFEST_NODE_PATH" '0.1.0' '../outside' '1786640000'
  ! read_manifest "$MANIFEST_PATH"
}

test_manifest_does_not_execute_substitutions() {
  prepare_manifest
  marker="$TEST_ROOT/injected"
  payload='$(touch '"$marker"')'
  write_manifest "$MANIFEST_PATH" "$MANIFEST_NODE_PATH" "$payload" 'bin/dsh-mac' '1786640000'
  read_manifest "$MANIFEST_PATH" || return 1
  assert_eq "$payload" "$MANIFEST_DSH_VERSION" || return 1
  [ ! -e "$marker" ]
}

test_manifest_preserves_spaces_and_equals() {
  write_fake 'node = executable' 'exit 0'
  manifest_path="$TEST_ROOT/manifest with spaces.env"
  node_path="$TEST_ROOT/bin/node = executable"
  dsh_version='release candidate = six'
  write_manifest "$manifest_path" "$node_path" "$dsh_version" 'bin/dsh-mac' '1786640000'
  read_manifest "$manifest_path" || return 1
  assert_eq "$node_path" "$MANIFEST_NODE_BIN" || return 1
  assert_eq "$dsh_version" "$MANIFEST_DSH_VERSION"
}

write_activation() {
  activation_path=$1
  old_release=$2
  candidate_release=$3
  {
    printf 'SCHEMA_VERSION=1\n'
    printf 'OLD_RELEASE=%s\n' "$old_release"
    printf 'CANDIDATE_RELEASE=%s\n' "$candidate_release"
  } >"$activation_path"
}

test_activation_accepts_none_old_release() {
  activation_path="$TEST_ROOT/activation.env"
  write_activation "$activation_path" NONE '0.1.0-rc.6-1786640000-1234'
  read_activation "$activation_path" || return 1
  assert_eq 1 "$ACTIVATION_SCHEMA_VERSION" || return 1
  assert_eq NONE "$ACTIVATION_OLD_RELEASE" || return 1
  assert_eq '0.1.0-rc.6-1786640000-1234' "$ACTIVATION_CANDIDATE_RELEASE"
}

test_activation_accepts_valid_release_ids() {
  activation_path="$TEST_ROOT/activation.env"
  write_activation "$activation_path" '0.1.0-1786630000-1200' '0.1.0-1786640000-1234'
  read_activation "$activation_path" || return 1
  assert_eq '0.1.0-1786630000-1200' "$ACTIVATION_OLD_RELEASE" || return 1
  assert_eq '0.1.0-1786640000-1234' "$ACTIVATION_CANDIDATE_RELEASE"
}

test_activation_rejects_unknown_key() {
  activation_path="$TEST_ROOT/activation.env"
  write_activation "$activation_path" NONE '0.1.0-1786640000-1234'
  printf 'SURPRISE=value\n' >>"$activation_path"
  ! read_activation "$activation_path"
}

test_activation_rejects_out_of_root_release() {
  activation_path="$TEST_ROOT/activation.env"
  write_activation "$activation_path" NONE '../outside'
  ! read_activation "$activation_path"
}

test_activation_rejects_duplicate_keys() {
  activation_path="$TEST_ROOT/activation.env"
  write_activation "$activation_path" NONE '0.1.0-1786640000-1234'
  printf 'OLD_RELEASE=NONE\n' >>"$activation_path"
  ! read_activation "$activation_path"
}

test_activation_rejects_missing_keys() {
  activation_path="$TEST_ROOT/activation.env"
  {
    printf 'SCHEMA_VERSION=1\n'
    printf 'OLD_RELEASE=NONE\n'
  } >"$activation_path"
  ! read_activation "$activation_path"
}

prepare_preflight_fakes() {
  write_fake launchctl 'exit 0'
  write_fake command-noop 'exit 0'
  DSH_MAC_LAUNCHCTL_BIN="$TEST_ROOT/bin/launchctl"
  DSH_MAC_PLUTIL_BIN="$TEST_ROOT/bin/command-noop"
  DSH_MAC_LSOF_BIN="$TEST_ROOT/bin/command-noop"
  DSH_MAC_CURL_BIN="$TEST_ROOT/bin/command-noop"
  DSH_MAC_OPEN_BIN="$TEST_ROOT/bin/command-noop"
  DSH_MAC_TAIL_BIN="$TEST_ROOT/bin/command-noop"
  init_command_paths
}

test_common_preflight_accepts_valid_environment_without_mutation() (
  prepare_preflight_fakes
  init_paths
  [ ! -e "$DSH_MAC_ROOT" ] || return 1
  preflight_common "$PLUTIL_BIN" "$LSOF_BIN" "$CURL_BIN" || return 1
  [ ! -e "$DSH_MAC_ROOT" ]
)

test_common_preflight_rejects_relative_home() (
  prepare_preflight_fakes
  HOME='relative/home'
  ! preflight_common
)

test_common_preflight_rejects_home_with_newline() (
  prepare_preflight_fakes
  HOME="$TEST_ROOT/bad
home"
  ! preflight_common
)

test_common_preflight_requires_launchd_domain() (
  write_fake launchctl-fail 'exit 1'
  DSH_MAC_LAUNCHCTL_BIN="$TEST_ROOT/bin/launchctl-fail"
  init_command_paths
  ! preflight_common
)

test_common_preflight_rejects_missing_requested_command() (
  prepare_preflight_fakes
  ! preflight_common "$TEST_ROOT/bin/does-not-exist"
)

test_install_preflight_resolves_caller_node_and_npm() (
  prepare_preflight_fakes
  write_fake node 'if [ "${1:-}" = --version ]; then printf "v22.19.0\\n"; else exit 1; fi'
  write_fake npm 'exit 0'
  PATH="$TEST_ROOT/bin:/usr/bin:/bin"
  init_paths
  [ ! -e "$DSH_MAC_ROOT" ] || return 1
  preflight_install || return 1
  assert_eq "$TEST_ROOT/bin/node" "$NODE_BIN" || return 1
  assert_eq "$TEST_ROOT/bin/npm" "$NPM_BIN" || return 1
  assert_eq '22.19.0' "$NODE_VERSION" || return 1
  [ ! -e "$DSH_MAC_ROOT" ]
)

test_install_preflight_rejects_node_function() (
  prepare_preflight_fakes
  write_fake npm 'exit 0'
  PATH="$TEST_ROOT/bin:/usr/bin:/bin"
  node() { printf 'v22.19.0\n'; }
  ! preflight_install
)

test_install_preflight_rejects_relative_node_path() (
  prepare_preflight_fakes
  write_fake node 'printf "v22.19.0\\n"'
  write_fake npm 'exit 0'
  cd "$TEST_ROOT" || return 1
  PATH='bin:/usr/bin:/bin'
  ! preflight_install
)

test_install_preflight_rejects_unsupported_node() (
  prepare_preflight_fakes
  write_fake node 'printf "v23.9.0\\n"'
  write_fake npm 'exit 0'
  PATH="$TEST_ROOT/bin:/usr/bin:/bin"
  ! preflight_install
)

use_lock_home() {
  HOME="$TEST_ROOT/home-$1"
  mkdir -p "$HOME" || return 1
  init_paths
}

test_lock_is_exclusive_and_releasable() (
  use_lock_home exclusive || return 1
  mkdir -p "$DSH_MAC_ROOT" || return 1
  acquire_lock || return 1
  ! ( acquire_lock ) || return 1
  release_lock || return 1
  [ ! -e "$DSH_MAC_ROOT/.lock" ]
)

test_stale_lock_is_reclaimed() (
  use_lock_home stale || return 1
  mkdir -p "$DSH_MAC_ROOT/.lock" || return 1
  printf '99999999\n' >"$DSH_MAC_ROOT/.lock/pid"
  acquire_lock || return 1
  assert_eq "$$" "$(<"$DSH_MAC_ROOT/.lock/pid")" || return 1
  release_lock
)

test_malformed_lock_is_not_reclaimed() (
  use_lock_home malformed || return 1
  mkdir -p "$DSH_MAC_ROOT/.lock" || return 1
  printf 'not-a-pid\n' >"$DSH_MAC_ROOT/.lock/pid"
  ! acquire_lock
)

test_multiline_lock_owner_is_not_reclaimed() (
  use_lock_home multiline || return 1
  mkdir -p "$DSH_MAC_ROOT/.lock" || return 1
  printf '99999999\n\n' >"$DSH_MAC_ROOT/.lock/pid"
  ! acquire_lock || return 1
  [ -d "$DSH_MAC_ROOT/.lock" ]
)

test_lock_symlink_does_not_remove_outside_pid() (
  use_lock_home symlink || return 1
  outside_lock="$TEST_ROOT/outside-lock"
  mkdir -p "$DSH_MAC_ROOT" "$outside_lock" || return 1
  printf '99999999\n' >"$outside_lock/pid"
  ln -s "$outside_lock" "$LOCK_DIR" || return 1
  ! acquire_lock || return 1
  [ -f "$outside_lock/pid" ]
)

test_release_rejects_lock_symlink_without_outside_mutation() (
  use_lock_home release-symlink || return 1
  outside_lock="$TEST_ROOT/outside-release-lock"
  mkdir -p "$DSH_MAC_ROOT" "$outside_lock" || return 1
  printf '%s\n' "$$" >"$outside_lock/pid"
  ln -s "$outside_lock" "$LOCK_DIR" || return 1
  ! release_lock || return 1
  [ -f "$outside_lock/pid" ]
)

test_exit_cleanup_ignores_lock_symlink() (
  use_lock_home cleanup-symlink || return 1
  outside_lock="$TEST_ROOT/outside-cleanup-lock"
  mkdir -p "$DSH_MAC_ROOT" "$outside_lock" || return 1
  printf '%s\n' "$$" >"$outside_lock/pid"
  ln -s "$outside_lock" "$LOCK_DIR" || return 1
  release_lock_if_owned
  [ -f "$outside_lock/pid" ]
)

test_release_does_not_remove_another_owner_lock() (
  use_lock_home another-owner || return 1
  mkdir -p "$DSH_MAC_ROOT/.lock" || return 1
  printf '1\n' >"$DSH_MAC_ROOT/.lock/pid"
  ! release_lock || return 1
  [ -d "$DSH_MAC_ROOT/.lock" ]
)

test_term_releases_lock_and_stops_later_mutation() {
  use_lock_home signal || return 1
  mkdir -p "$DSH_MAC_ROOT" || return 1
  mutation_log="$TEST_ROOT/mutation.log"
  fake_pid_file="$TEST_ROOT/mutating-fake.pid"
  write_fake mutating-fake '
log_path=$1
pid_path=$2
printf "started\\n" >>"$log_path"
printf "%s\\n" "$$" >"$pid_path"
trap "exit 143" TERM
while :; do
  /bin/sleep 1
done'

  /bin/bash -c '
    export DSH_MAC_SOURCE_ONLY=1
    . "$1" || exit 1
    init_paths
    acquire_lock || exit 1
    "$2" "$3" "$4"
    printf "later\\n" >>"$3"
  ' signal-child "$CLI_PATH" "$TEST_ROOT/bin/mutating-fake" "$mutation_log" "$fake_pid_file" &
  child_pid=$!

  attempts=0
  while [ "$attempts" -lt 50 ] && { [ ! -s "$fake_pid_file" ] || [ ! -d "$LOCK_DIR" ]; }; do
    /bin/sleep 0.1
    attempts=$((attempts + 1))
  done

  if [ ! -s "$fake_pid_file" ] || [ ! -d "$LOCK_DIR" ]; then
    kill -KILL "$child_pid" 2>/dev/null || :
    wait "$child_pid" 2>/dev/null || :
    printf 'signal child did not become ready\n' >&2
    return 1
  fi

  fake_pid=$(<"$fake_pid_file")
  kill -TERM "$child_pid" 2>/dev/null || return 1
  kill -TERM "$fake_pid" 2>/dev/null || :
  wait "$child_pid"
  child_status=$?
  kill -KILL "$fake_pid" 2>/dev/null || :

  assert_eq 143 "$child_status" || return 1
  [ ! -e "$LOCK_DIR" ] || return 1
  assert_eq started "$(<"$mutation_log")"
}

test_version_command_prints_manager_version() {
  actual=$(DSH_MAC_SOURCE_ONLY=0 /bin/bash "$CLI_PATH" version 2>&1)
  status=$?
  assert_eq 0 "$status" || return 1
  assert_eq '0.1.0' "$actual"
}

test_unknown_command_fails() {
  DSH_MAC_SOURCE_ONLY=0 /bin/bash "$CLI_PATH" unknown >/dev/null 2>&1
  [ "$?" -ne 0 ]
}

run_test 'die reports failure' test_die_reports_failure
run_test 'note reports progress' test_note_reports_progress
run_test 'init_paths derives owned paths from HOME' test_init_paths_uses_home
run_test 'test command overrides are honored' test_command_overrides_are_honored_in_tests
run_test 'production command paths ignore overrides' test_command_overrides_are_ignored_in_production
run_test 'Node 22.19.0 is supported' test_node_22_19_is_supported
run_test 'Node 22.18.0 is rejected' test_node_22_18_is_rejected
run_test 'Node 23.9.0 is rejected' test_node_23_is_rejected
run_test 'Node 24.0.0 is supported' test_node_24_is_supported
run_test 'Node prereleases are rejected' test_node_prerelease_is_rejected
run_test 'oversized Node components are compared cleanly' test_oversized_node_component_is_supported_cleanly
run_test 'generated release ID is valid' test_release_id_accepts_generated_shape
run_test 'release ID rejects parent traversal' test_release_id_rejects_parent_traversal
run_test 'release ID rejects child paths' test_release_id_rejects_child_path
run_test 'manifest reads valid values' test_manifest_reads_valid_values
run_test 'manifest rejects duplicate keys' test_manifest_rejects_duplicate_keys
run_test 'manifest rejects unknown keys' test_manifest_rejects_unknown_keys
run_test 'manifest rejects missing keys' test_manifest_rejects_missing_keys
run_test 'manifest rejects relative NODE_BIN' test_manifest_rejects_relative_node_bin
run_test 'manifest rejects unsafe CLI_RELATIVE' test_manifest_rejects_unsafe_cli_relative
run_test 'manifest does not execute substitutions' test_manifest_does_not_execute_substitutions
run_test 'manifest preserves spaces and equals' test_manifest_preserves_spaces_and_equals
run_test 'activation accepts OLD_RELEASE=NONE' test_activation_accepts_none_old_release
run_test 'activation accepts valid release IDs' test_activation_accepts_valid_release_ids
run_test 'activation rejects unknown keys' test_activation_rejects_unknown_key
run_test 'activation rejects out-of-root release IDs' test_activation_rejects_out_of_root_release
run_test 'activation rejects duplicate keys' test_activation_rejects_duplicate_keys
run_test 'activation rejects missing keys' test_activation_rejects_missing_keys
run_test 'common preflight has no filesystem mutation' test_common_preflight_accepts_valid_environment_without_mutation
run_test 'common preflight rejects relative HOME' test_common_preflight_rejects_relative_home
run_test 'common preflight rejects HOME newline' test_common_preflight_rejects_home_with_newline
run_test 'common preflight requires launchd domain' test_common_preflight_requires_launchd_domain
run_test 'common preflight requires requested commands' test_common_preflight_rejects_missing_requested_command
run_test 'install preflight resolves Node and npm' test_install_preflight_resolves_caller_node_and_npm
run_test 'install preflight rejects a Node function' test_install_preflight_rejects_node_function
run_test 'install preflight rejects relative Node path' test_install_preflight_rejects_relative_node_path
run_test 'install preflight rejects unsupported Node' test_install_preflight_rejects_unsupported_node
run_test 'lock is exclusive and releasable' test_lock_is_exclusive_and_releasable
run_test 'stale lock is reclaimed' test_stale_lock_is_reclaimed
run_test 'malformed lock is retained' test_malformed_lock_is_not_reclaimed
run_test 'multiline lock owner is retained as malformed' test_multiline_lock_owner_is_not_reclaimed
run_test 'lock symlink cannot remove an outside PID file' test_lock_symlink_does_not_remove_outside_pid
run_test 'release rejects lock symlink without outside mutation' test_release_rejects_lock_symlink_without_outside_mutation
run_test 'exit cleanup ignores lock symlink' test_exit_cleanup_ignores_lock_symlink
run_test 'release retains another owner lock' test_release_does_not_remove_another_owner_lock
run_test 'TERM releases lock before later mutation' test_term_releases_lock_and_stops_later_mutation
run_test 'version prints the manager version' test_version_command_prints_manager_version
run_test 'unknown command fails' test_unknown_command_fails

finish_tests
