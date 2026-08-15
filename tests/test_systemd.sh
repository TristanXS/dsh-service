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

write_systemd_fakes() {
  write_fake systemctl '
log_line=
for log_arg in "$@"; do
  if [ -n "$log_line" ]; then log_line="$log_line|$log_arg"; else log_line=$log_arg; fi
done
printf "%s\n" "$log_line" >>"$DSH_TEST_SYSTEMCTL_LOG"

set_running() {
  new_pid=$1
  printf "1\n" >"$DSH_TEST_LOADED_FILE"
  printf "%s\n" "$new_pid" >"$DSH_TEST_PID_FILE"
  if [ "${DSH_TEST_AUTO_LISTENER:-1}" = 1 ]; then
    printf "%s|127.0.0.1:3080\n" "$new_pid" >"$DSH_TEST_LISTENERS_FILE"
  fi
  if [ "${DSH_TEST_HEALTH_AFTER_TRANSITION:-0}" = 1 ]; then
    printf "1\n" >"$DSH_TEST_CURL_OK_FILE"
  fi
}
set_stopped() {
  printf "0\n" >"$DSH_TEST_LOADED_FILE"
  : >"$DSH_TEST_PID_FILE"
  : >"$DSH_TEST_LISTENERS_FILE"
}

[ "${1:-}" = --user ] || exit 90
shift
verb=${1:-}
case "$verb" in
  is-active)
    [ "$2" = --quiet ] || exit 91
    [ "$(<"$DSH_TEST_LOADED_FILE")" = 1 ] || exit 3
    ;;
  show)
    [ "$2" = -p ] && [ "$3" = MainPID ] && [ "$4" = --value ] || exit 92
    if [ "$(<"$DSH_TEST_LOADED_FILE")" = 1 ]; then
      printf "%s\n" "$(<"$DSH_TEST_PID_FILE")"
    else
      printf "0\n"
    fi
    ;;
  daemon-reload)
    [ "${DSH_TEST_SYSTEMCTL_RELOAD_FAIL:-0}" != 1 ] || exit 93
    ;;
  enable)
    [ "$2" = --now ] || exit 94
    [ "${DSH_TEST_ENABLE_FAIL:-0}" != 1 ] || exit 95
    set_running "${DSH_TEST_NEXT_PID:-202}"
    ;;
  restart)
    [ "${DSH_TEST_RESTART_FAIL:-0}" != 1 ] || exit 96
    set_running "${DSH_TEST_NEXT_PID:-202}"
    ;;
  stop)
    set_stopped
    ;;
  disable)
    [ "$2" = --now ] || exit 97
    set_stopped
    ;;
  *) exit 98 ;;
esac'

  write_fake ss '
log_line=
for arg in "$@"; do
  if [ -n "$log_line" ]; then log_line="$log_line|$arg"; else log_line=$arg; fi
done
printf "%s\n" "$log_line" >>"$DSH_TEST_SS_LOG"
[ "${1:-}" = -H ] && [ "${2:-}" = -tlnp ] || exit 90
if [ "${DSH_TEST_SS_FAIL:-0}" = 1 ]; then
  printf "ss: exploded\n" >&2
  exit 1
fi
if [ -n "${DSH_TEST_SS_RAW_FILE:-}" ]; then
  /bin/cat "$DSH_TEST_SS_RAW_FILE"
  exit 0
fi
while IFS="|" read -r entry_pid entry_addr; do
  [ -n "$entry_addr" ] || continue
  if [ "$entry_pid" = unknown ]; then
    printf "LISTEN 0 4096 %s 0.0.0.0:*\n" "$entry_addr"
  else
    printf "LISTEN 0 4096 %s 0.0.0.0:* users:((\"node\",pid=%s,fd=18))\n" "$entry_addr" "$entry_pid"
  fi
done <"$DSH_TEST_LISTENERS_FILE"'

  write_fake curl '
[ -f "$DSH_TEST_CURL_OK_FILE" ] && [ "$(<"$DSH_TEST_CURL_OK_FILE")" = 1 ] && exit 0
exit 7'

  write_fake xdg-open 'printf "%s\n" "$*" >>"$DSH_TEST_XDG_OPEN_LOG"
exit "${DSH_TEST_XDG_OPEN_EXIT:-0}"'
}

prepare_systemd_case() {
  export HOME="$TEST_ROOT/home-$RANDOM$RANDOM"
  mkdir -p "$HOME"
  unset XDG_DATA_HOME XDG_CONFIG_HOME XDG_STATE_HOME
  export DSH_TEST_SYSTEMCTL_LOG="$HOME/systemctl.log"
  export DSH_TEST_SS_LOG="$HOME/ss.log"
  export DSH_TEST_XDG_OPEN_LOG="$HOME/xdg-open.log"
  export DSH_TEST_LOADED_FILE="$HOME/loaded"
  export DSH_TEST_PID_FILE="$HOME/pid"
  export DSH_TEST_LISTENERS_FILE="$HOME/listeners"
  export DSH_TEST_CURL_OK_FILE="$HOME/curl-ok"
  printf '0\n' >"$DSH_TEST_LOADED_FILE"
  : >"$DSH_TEST_PID_FILE"
  : >"$DSH_TEST_LISTENERS_FILE"
  printf '0\n' >"$DSH_TEST_CURL_OK_FILE"
  : >"$DSH_TEST_SYSTEMCTL_LOG"
  : >"$DSH_TEST_SS_LOG"
  : >"$DSH_TEST_XDG_OPEN_LOG"
  write_systemd_fakes
  export DSH_SERVICE_SYSTEMCTL_BIN="$TEST_ROOT/bin/systemctl"
  export DSH_SERVICE_SS_BIN="$TEST_ROOT/bin/ss"
  export DSH_SERVICE_CURL_BIN="$TEST_ROOT/bin/curl"
  export DSH_SERVICE_XDG_OPEN_BIN="$TEST_ROOT/bin/xdg-open"
  detect_platform && init_command_paths && init_paths || return 1
  /bin/mkdir -p "$DSH_SERVICE_ROOT"
}

set_job() {
  printf '%s\n' "$1" >"$DSH_TEST_LOADED_FILE"
  printf '%s\n' "$2" >"$DSH_TEST_PID_FILE"
}

set_listeners() {
  : >"$DSH_TEST_LISTENERS_FILE"
  for listener_entry in "$@"; do
    printf '%s\n' "$listener_entry" >>"$DSH_TEST_LISTENERS_FILE"
  done
}

assert_log_has_line() {
  /usr/bin/grep -Fqx -- "$2" "$1" || {
    printf 'log %s missing line <%s>\n' "$1" "$2" >&2
    return 1
  }
}

assert_health() {
  observed_health=$(health_state)
  assert_eq "$1" "$observed_health"
}

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

test_unit_renders_expected_template_and_escapes() {
  (
    export HOME="$TEST_ROOT/home with space%and\"quote"
    mkdir -p "$HOME"
    unset XDG_DATA_HOME XDG_CONFIG_HOME XDG_STATE_HOME
    detect_platform && init_command_paths && init_paths || return 1
    unit_text=$(render_unit) || return 1
    printf '%s\n' "$unit_text" | /usr/bin/grep -Fx 'Restart=on-failure' >/dev/null || return 1
    printf '%s\n' "$unit_text" | /usr/bin/grep -Fx 'WantedBy=default.target' >/dev/null || return 1
    printf '%s\n' "$unit_text" | /usr/bin/grep -Fx 'TimeoutStopSec=15' >/dev/null || return 1
    printf '%s\n' "$unit_text" |
      /usr/bin/grep -F 'ExecStart=/bin/bash "'"$TEST_ROOT"'/home with space%%and\"quote/.local/share/dsh-service/current/run"' >/dev/null || return 1
    printf '%s\n' "$unit_text" |
      /usr/bin/grep -F 'StandardOutput=append:'"$TEST_ROOT"'/home with space%%and"quote/.local/state/dsh-service/stdout.log' >/dev/null
  )
}

test_ensure_unit_publishes_0644_and_reloads() {
  (
    prepare_systemd_case || return 1
    ensure_service_definition || return 1
    [ -f "$SERVICE_DEFINITION_PATH" ] || return 1
    perms=$(/usr/bin/stat -f %Lp "$SERVICE_DEFINITION_PATH" 2>/dev/null) ||
      perms=$(/usr/bin/stat -c %a "$SERVICE_DEFINITION_PATH") || return 1
    assert_eq 644 "$perms" || return 1
    assert_log_has_line "$DSH_TEST_SYSTEMCTL_LOG" '--user|daemon-reload'
  )
}

test_ensure_unit_failed_reload_fails_closed() {
  (
    prepare_systemd_case || return 1
    export DSH_TEST_SYSTEMCTL_RELOAD_FAIL=1
    ensure_service_definition 2>/dev/null && return 1
    return 0
  )
}

run_test 'linux paths use XDG defaults' test_linux_paths_use_xdg_defaults
run_test 'linux paths honor XDG overrides' test_linux_paths_honor_xdg_overrides
run_test 'forced darwin platform keeps macOS paths' test_darwin_paths_unchanged_under_forced_platform
run_test 'unsupported platform fails closed' test_unsupported_platform_fails_closed
run_test 'linux preflight requires systemctl and drops plutil' test_linux_preflight_requires_systemctl_not_plutil
test_service_pid_parses_mainpid_strictly() {
  (
    prepare_systemd_case || return 1
    set_job 1 4321
    assert_eq 4321 "$(service_pid)" || return 1
    set_job 1 0
    service_pid 2>/dev/null && return 1
    set_job 1 ''
    service_pid 2>/dev/null && return 1
    printf 'garbage\n' >"$DSH_TEST_PID_FILE"
    service_pid 2>/dev/null && return 1
    return 0
  )
}

test_service_loaded_tracks_is_active() {
  (
    prepare_systemd_case || return 1
    set_job 1 4321
    service_loaded || return 1
    set_job 0 ''
    service_loaded && return 1
    return 0
  )
}

run_test 'service_pid parses MainPID strictly' test_service_pid_parses_mainpid_strictly
run_test 'service_loaded tracks is-active' test_service_loaded_tracks_is_active
run_test 'unit renders expected template with escaping' test_unit_renders_expected_template_and_escapes
run_test 'ensure_unit publishes 0644 and reloads systemd' test_ensure_unit_publishes_0644_and_reloads
run_test 'ensure_unit fails closed on reload failure' test_ensure_unit_failed_reload_fails_closed

finish_tests
