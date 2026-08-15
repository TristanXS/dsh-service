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

test_linux_health_matrix() {
  (
    prepare_systemd_case || return 1
    assert_health unloaded || return 1
    set_job 1 ''
    assert_health starting || return 1
    set_job 1 555
    set_listeners
    assert_health starting || return 1
    set_listeners '555|127.0.0.1:3080'
    assert_health unhealthy || return 1
    printf '1\n' >"$DSH_TEST_CURL_OK_FILE"
    assert_health healthy || return 1
    set_listeners '556|127.0.0.1:3080'
    assert_health conflict || return 1
    set_listeners '555|0.0.0.0:3080'
    assert_health conflict || return 1
    set_listeners '555|[::]:3080'
    assert_health conflict || return 1
    set_listeners 'unknown|127.0.0.1:3080'
    assert_health conflict
  )
}

test_linux_health_fails_closed_on_ss_error() {
  (
    prepare_systemd_case || return 1
    set_job 1 555
    set_listeners '555|127.0.0.1:3080'
    printf '1\n' >"$DSH_TEST_CURL_OK_FILE"
    export DSH_TEST_SS_FAIL=1
    assert_health conflict
  )
}

test_ss_multi_pid_socket_yields_conflict() {
  (
    prepare_systemd_case || return 1
    set_job 1 555
    printf 'LISTEN 0 4096 127.0.0.1:3080 0.0.0.0:* users:(("node",pid=555,fd=18),("node",pid=556,fd=18))\n' >"$HOME/raw-ss"
    export DSH_TEST_SS_RAW_FILE="$HOME/raw-ss"
    printf '1\n' >"$DSH_TEST_CURL_OK_FILE"
    assert_health conflict
  )
}

test_ss_ignores_other_ports() {
  (
    prepare_systemd_case || return 1
    set_job 1 555
    set_listeners '555|127.0.0.1:3080' '700|127.0.0.1:30801' '701|127.0.0.1:8080'
    printf '1\n' >"$DSH_TEST_CURL_OK_FILE"
    assert_health healthy
  )
}

test_linux_start_enables_unloaded_service() {
  (
    prepare_systemd_case || return 1
    export DSH_TEST_HEALTH_AFTER_TRANSITION=1
    start_service || return 1
    assert_log_has_line "$DSH_TEST_SYSTEMCTL_LOG" '--user|enable|--now|dsh-service.service' || return 1
    assert_log_has_line "$DSH_TEST_SYSTEMCTL_LOG" '--user|daemon-reload'
  )
}

test_linux_restart_uses_systemctl_restart_with_new_pid() {
  (
    prepare_systemd_case || return 1
    set_job 1 300
    set_listeners '300|127.0.0.1:3080'
    printf '1\n' >"$DSH_TEST_CURL_OK_FILE"
    export DSH_TEST_NEXT_PID=301 DSH_TEST_HEALTH_AFTER_TRANSITION=1
    restart_service || return 1
    assert_log_has_line "$DSH_TEST_SYSTEMCTL_LOG" '--user|restart|dsh-service.service' || return 1
    assert_eq 301 "$(service_pid)"
  )
}

test_linux_stop_keeps_unit_file() {
  (
    prepare_systemd_case || return 1
    export DSH_TEST_HEALTH_AFTER_TRANSITION=1
    start_service || return 1
    stop_service || return 1
    assert_log_has_line "$DSH_TEST_SYSTEMCTL_LOG" '--user|stop|dsh-service.service' || return 1
    [ -f "$SERVICE_DEFINITION_PATH" ] || return 1
    assert_health unloaded
  )
}

test_linux_start_refuses_foreign_listener_without_mutation() {
  (
    prepare_systemd_case || return 1
    set_listeners '9999|127.0.0.1:3080'
    start_service 2>/dev/null && return 1
    /usr/bin/grep -E 'enable|restart|stop' "$DSH_TEST_SYSTEMCTL_LOG" >/dev/null && return 1
    [ ! -e "$SERVICE_DEFINITION_PATH" ]
  )
}

test_linux_restart_falls_back_to_stop_and_enable() {
  (
    prepare_systemd_case || return 1
    set_job 1 300
    set_listeners '300|127.0.0.1:3080'
    printf '1\n' >"$DSH_TEST_CURL_OK_FILE"
    export DSH_TEST_RESTART_FAIL=1 DSH_TEST_NEXT_PID=302 DSH_TEST_HEALTH_AFTER_TRANSITION=1
    restart_service || return 1
    assert_log_has_line "$DSH_TEST_SYSTEMCTL_LOG" '--user|stop|dsh-service.service' || return 1
    assert_log_has_line "$DSH_TEST_SYSTEMCTL_LOG" '--user|enable|--now|dsh-service.service' || return 1
    assert_eq 302 "$(service_pid)"
  )
}

test_linux_status_prints_systemd_label() {
  (
    prepare_systemd_case || return 1
    set_job 1 555
    set_listeners '555|127.0.0.1:3080'
    printf '1\n' >"$DSH_TEST_CURL_OK_FILE"
    status_output=$(cmd_status) || return 1
    printf '%s\n' "$status_output" | /usr/bin/grep -Fx 'Systemd: loaded' >/dev/null || return 1
    printf '%s\n' "$status_output" | /usr/bin/grep -Fx 'PID: 555' >/dev/null || return 1
    printf '%s\n' "$status_output" | /usr/bin/grep -F 'Launchd:' >/dev/null && return 1
    return 0
  )
}

test_linux_open_uses_xdg_open_when_available() {
  (
    prepare_systemd_case || return 1
    set_job 1 555
    set_listeners '555|127.0.0.1:3080'
    printf '1\n' >"$DSH_TEST_CURL_OK_FILE"
    cmd_open || return 1
    assert_log_has_line "$DSH_TEST_XDG_OPEN_LOG" 'http://127.0.0.1:3080'
  )
}

test_linux_open_degrades_without_xdg_open() {
  (
    prepare_systemd_case || return 1
    set_job 1 555
    set_listeners '555|127.0.0.1:3080'
    printf '1\n' >"$DSH_TEST_CURL_OK_FILE"
    export DSH_SERVICE_XDG_OPEN_BIN="$TEST_ROOT/bin/absent-xdg-open"
    open_output=$(cmd_open 2>/dev/null) || return 1
    assert_eq 'http://127.0.0.1:3080' "$open_output"
  )
}

test_linux_open_degrades_when_xdg_open_fails() {
  (
    prepare_systemd_case || return 1
    set_job 1 555
    set_listeners '555|127.0.0.1:3080'
    printf '1\n' >"$DSH_TEST_CURL_OK_FILE"
    export DSH_TEST_XDG_OPEN_EXIT=3
    open_output=$(cmd_open 2>/dev/null) || return 1
    assert_eq 'http://127.0.0.1:3080' "$open_output"
  )
}

test_linux_uninstall_disables_and_removes_unit() {
  (
    prepare_systemd_case || return 1
    export DSH_TEST_HEALTH_AFTER_TRANSITION=1
    start_service || return 1
    cmd_uninstall || return 1
    assert_log_has_line "$DSH_TEST_SYSTEMCTL_LOG" '--user|disable|--now|dsh-service.service' || return 1
    [ ! -e "$SERVICE_DEFINITION_PATH" ] || return 1
    [ ! -e "$DSH_SERVICE_ROOT" ]
  )
}

test_linux_uninstall_rejects_wrong_root() {
  (
    prepare_systemd_case || return 1
    DSH_SERVICE_ROOT="$TEST_ROOT/elsewhere"
    validate_uninstall_root && return 1
    return 0
  )
}

test_linux_install_dir_cleanup_removes_created_xdg_parents() {
  (
    prepare_systemd_case || return 1
    /bin/rm -rf -- "$DSH_SERVICE_ROOT" "$HOME/.local"
    prepare_install_lock_root || return 1
    assert_eq 1 "$INSTALL_CREATED_ROOT_GRANDPARENT" || return 1
    assert_eq 1 "$INSTALL_CREATED_ROOT_PARENT" || return 1
    cleanup_install_directories
    [ ! -e "$HOME/.local" ]
  )
}

test_linux_custom_xdg_data_home_must_exist() {
  (
    prepare_systemd_case || return 1
    export XDG_DATA_HOME="$TEST_ROOT/no-such-xdg"
    init_paths || return 1
    prepare_install_lock_root 2>/dev/null && return 1
    return 0
  )
}

test_linger_warning_only_when_disabled() {
  (
    prepare_systemd_case || return 1
    write_fake loginctl 'printf "%s\n" "${DSH_TEST_LINGER_STATE:-yes}"'
    export DSH_SERVICE_LOGINCTL_BIN="$TEST_ROOT/bin/loginctl"
    init_command_paths || return 1
    warn_output=$(warn_if_no_linger 2>&1) || return 1
    assert_eq '' "$warn_output" || return 1
    export DSH_TEST_LINGER_STATE=no
    warn_output=$(warn_if_no_linger 2>&1) || return 1
    printf '%s\n' "$warn_output" | /usr/bin/grep -F 'enable-linger' >/dev/null
  )
}

run_test 'linux status prints Systemd label' test_linux_status_prints_systemd_label
run_test 'linux open uses xdg-open when available' test_linux_open_uses_xdg_open_when_available
run_test 'linux open degrades without xdg-open' test_linux_open_degrades_without_xdg_open
run_test 'linux open degrades when xdg-open fails' test_linux_open_degrades_when_xdg_open_fails
run_test 'linux uninstall disables and removes the unit' test_linux_uninstall_disables_and_removes_unit
run_test 'linux uninstall rejects a wrong root' test_linux_uninstall_rejects_wrong_root
run_test 'linux install cleanup removes created xdg parents' test_linux_install_dir_cleanup_removes_created_xdg_parents
run_test 'custom XDG_DATA_HOME must already exist' test_linux_custom_xdg_data_home_must_exist
run_test 'linger warning appears only when disabled' test_linger_warning_only_when_disabled
run_test 'linux start enables an unloaded service' test_linux_start_enables_unloaded_service
run_test 'linux restart uses systemctl restart with new pid' test_linux_restart_uses_systemctl_restart_with_new_pid
run_test 'linux stop keeps the unit file' test_linux_stop_keeps_unit_file
run_test 'linux start refuses a foreign listener without mutation' test_linux_start_refuses_foreign_listener_without_mutation
run_test 'linux restart falls back to stop and enable' test_linux_restart_falls_back_to_stop_and_enable
run_test 'linux health matrix covers all states' test_linux_health_matrix
run_test 'linux health fails closed on ss error' test_linux_health_fails_closed_on_ss_error
run_test 'multi-pid socket is a conflict' test_ss_multi_pid_socket_yields_conflict
run_test 'ss probe ignores other ports' test_ss_ignores_other_ports
run_test 'service_pid parses MainPID strictly' test_service_pid_parses_mainpid_strictly
run_test 'service_loaded tracks is-active' test_service_loaded_tracks_is_active
run_test 'unit renders expected template with escaping' test_unit_renders_expected_template_and_escapes
run_test 'ensure_unit publishes 0644 and reloads systemd' test_ensure_unit_publishes_0644_and_reloads
run_test 'ensure_unit fails closed on reload failure' test_ensure_unit_failed_reload_fails_closed

finish_tests
