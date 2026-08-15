#!/bin/bash
# shellcheck disable=SC1090,SC1091,SC2016,SC2030,SC2031,SC2034,SC2329
set -u

TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
CLI_PATH="$TESTS_DIR/../bin/dsh-service"

. "$TESTS_DIR/helpers.sh"

export DSH_SERVICE_PLATFORM=linux
export DSH_SERVICE_SOURCE_ONLY=1
if ! . "$CLI_PATH"; then
  printf 'could not source CLI: %s\n' "$CLI_PATH" >&2
  exit 1
fi

test_linux_paths_use_xdg_defaults() {
  (
    unset XDG_DATA_HOME XDG_CONFIG_HOME XDG_STATE_HOME
    detect_platform && init_command_paths && init_paths || return 1
    assert_eq "$HOME/.local/share/dsh-service" "$DSH_SERVICE_ROOT" &&
      assert_eq "$HOME/.config/systemd/user/dsh-service.service" "$SERVICE_DEFINITION_PATH" &&
      assert_eq "$HOME/.local/state/dsh-service" "$LOG_DIR" &&
      assert_eq dsh-service.service "$SERVICE_TARGET" &&
      assert_eq "$SS_BIN" "$LISTENER_BIN" &&
      assert_eq "$HOME/.local/share" "$ROOT_PARENT_DIR" &&
      assert_eq "$HOME/.local" "$ROOT_GRANDPARENT_DIR"
  )
}

test_linux_paths_honor_xdg_overrides() {
  (
    export XDG_DATA_HOME="$TEST_ROOT/xdg-data"
    export XDG_CONFIG_HOME="$TEST_ROOT/xdg-config"
    export XDG_STATE_HOME="$TEST_ROOT/xdg-state"
    detect_platform && init_command_paths && init_paths || return 1
    assert_eq "$TEST_ROOT/xdg-data/dsh-service" "$DSH_SERVICE_ROOT" &&
      assert_eq "$TEST_ROOT/xdg-config/systemd/user/dsh-service.service" "$SERVICE_DEFINITION_PATH" &&
      assert_eq "$TEST_ROOT/xdg-state/dsh-service" "$LOG_DIR" &&
      assert_eq '' "$ROOT_PARENT_DIR" &&
      assert_eq '' "$ROOT_GRANDPARENT_DIR"
  )
}

test_darwin_paths_unchanged_under_forced_platform() {
  (
    export DSH_SERVICE_PLATFORM=darwin
    detect_platform && init_command_paths && init_paths || return 1
    assert_eq "$HOME/Library/Application Support/dsh-service" "$DSH_SERVICE_ROOT" &&
      assert_eq "$HOME/Library/LaunchAgents/dev.dsh-service.web.plist" "$SERVICE_DEFINITION_PATH" &&
      assert_eq "$LSOF_BIN" "$LISTENER_BIN"
  )
}

test_unsupported_platform_fails_closed() {
  (
    export DSH_SERVICE_PLATFORM=plan9
    detect_platform 2>/dev/null && return 1
    return 0
  )
}

test_linux_preflight_requires_systemctl_not_plutil() {
  (
    export DSH_SERVICE_SYSTEMCTL_BIN="$TEST_ROOT/bin/systemctl"
    write_fake systemctl 'exit 0'
    detect_platform && init_command_paths && init_paths || return 1
    preflight_common 2>/dev/null || return 1
    export DSH_SERVICE_SYSTEMCTL_BIN="$TEST_ROOT/bin/absent-systemctl"
    init_command_paths || return 1
    preflight_common 2>/dev/null && return 1
    return 0
  )
}

run_test 'linux paths use XDG defaults' test_linux_paths_use_xdg_defaults
run_test 'linux paths honor XDG overrides' test_linux_paths_honor_xdg_overrides
run_test 'forced darwin platform keeps macOS paths' test_darwin_paths_unchanged_under_forced_platform
run_test 'unsupported platform fails closed' test_unsupported_platform_fails_closed
run_test 'linux preflight requires systemctl and drops plutil' test_linux_preflight_requires_systemctl_not_plutil

finish_tests
