#!/bin/bash
# shellcheck disable=SC1090,SC1091,SC2016,SC2030,SC2031,SC2034,SC2329
set -u

TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
CLI_PATH="$TESTS_DIR/../bin/dsh-service"

. "$TESTS_DIR/helpers.sh"

export DSH_SERVICE_PLATFORM=darwin

export DSH_SERVICE_SOURCE_ONLY=1
if ! . "$CLI_PATH"; then
  printf 'could not source CLI: %s\n' "$CLI_PATH" >&2
  exit 1
fi

write_launchd_fakes() {
  write_fake launchctl '
log_call() {
  log_line=
  for log_arg in "$@"; do
    if [ -n "$log_line" ]; then
      log_line="$log_line|$log_arg"
    else
      log_line=$log_arg
    fi
  done
  printf "%s\n" "$log_line" >>"$DSH_TEST_LAUNCHCTL_LOG"
}

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

log_call "$@"
command_name=${1:-}
case "$command_name" in
  print)
    [ "$#" -eq 2 ] || exit 90
    if [ "$(<"$DSH_TEST_PRINT_MODE_FILE")" = fail-with-pid ]; then
      printf "    pid = 9999\n"
      exit 113
    fi
    delay=$(<"$DSH_TEST_JOB_DELAY_FILE")
    if [ "$delay" -gt 0 ]; then
      delay=$((delay - 1))
      printf "%s\n" "$delay" >"$DSH_TEST_JOB_DELAY_FILE"
      if [ "$delay" -eq 0 ]; then
        printf "0\n" >"$DSH_TEST_LOADED_FILE"
        : >"$DSH_TEST_PID_FILE"
        exit 113
      fi
    fi
    [ "$(<"$DSH_TEST_LOADED_FILE")" = 1 ] || exit 113
    service_pid=$(<"$DSH_TEST_PID_FILE")
    if [ "$(<"$DSH_TEST_PRINT_MODE_FILE")" = decoys ]; then
      printf "pid = 17 trailing text\n"
      printf "  other pid = 18\n"
    fi
    printf "{\n"
    if [ -n "$service_pid" ]; then
      printf "    pid = %s\n" "$service_pid"
    fi
    printf "}\n"
    ;;
  bootstrap)
    [ "$#" -eq 3 ] || exit 91
    set_running "${DSH_TEST_NEXT_PID:-202}"
    ;;
  kickstart)
    [ "$#" -eq 2 ] || exit 92
    set_running "${DSH_TEST_NEXT_PID:-202}"
    ;;
  kill)
    [ "$#" -eq 3 ] || exit 93
    [ "$2" = SIGTERM ] || exit 94
    [ "${DSH_TEST_KILL_FAIL:-0}" != 1 ] || exit 95
    if [ "${DSH_TEST_GRACEFUL_MODE:-success}" = success ]; then
      set_running "${DSH_TEST_NEXT_PID:-202}"
    fi
    ;;
  bootout)
    [ "$#" -eq 2 ] || exit 96
    printf "%s\n" "${DSH_TEST_BOOTOUT_JOB_DELAY:-0}" >"$DSH_TEST_JOB_DELAY_FILE"
    printf "%s\n" "${DSH_TEST_BOOTOUT_LISTENER_DELAY:-0}" >"$DSH_TEST_LISTENER_DELAY_FILE"
    if [ "${DSH_TEST_BOOTOUT_JOB_DELAY:-0}" -eq 0 ]; then
      printf "0\n" >"$DSH_TEST_LOADED_FILE"
      : >"$DSH_TEST_PID_FILE"
    fi
    if [ "${DSH_TEST_BOOTOUT_LISTENER_DELAY:-0}" -eq 0 ]; then
      : >"$DSH_TEST_LISTENERS_FILE"
    fi
    ;;
  *) exit 97 ;;
esac'

  write_fake lsof '
log_line=
query=
has_np=0
has_listen=0
has_fields=0
for arg in "$@"; do
  if [ -n "$log_line" ]; then
    log_line="$log_line|$arg"
  else
    log_line=$arg
  fi
  case "$arg" in
    -nP) has_np=1 ;;
    -sTCP:LISTEN) has_listen=1 ;;
    -Fpn|-Fnp) has_fields=1 ;;
    -iTCP:3080) query=all ;;
    -iTCP@127.0.0.1:3080) query=loopback ;;
  esac
done
printf "%s\n" "$log_line" >>"$DSH_TEST_LSOF_LOG"
[ "$has_np" -eq 1 ] && [ "$has_listen" -eq 1 ] && [ "$has_fields" -eq 1 ] || exit 90
[ -n "$query" ] || exit 91

configured_status=$(<"$DSH_TEST_LSOF_STATUS_FILE")
configured_diagnostic=$(<"$DSH_TEST_LSOF_DIAGNOSTIC_FILE")
if [ -n "$configured_diagnostic" ]; then
  printf "%s\n" "$configured_diagnostic" >&2
fi
if [ "$configured_status" -ne 0 ]; then
  exit "$configured_status"
fi

delay=$(<"$DSH_TEST_LISTENER_DELAY_FILE")
if [ "$delay" -gt 0 ]; then
  delay=$((delay - 1))
  printf "%s\n" "$delay" >"$DSH_TEST_LISTENER_DELAY_FILE"
  if [ "$delay" -eq 0 ]; then
    : >"$DSH_TEST_LISTENERS_FILE"
  fi
fi

found=0
while IFS="|" read -r listener_pid listener_name || [ -n "$listener_pid$listener_name" ]; do
  [ -n "$listener_pid" ] && [ -n "$listener_name" ] || continue
  if [ "$query" = loopback ] && [ "$listener_name" != 127.0.0.1:3080 ]; then
    continue
  fi
  printf "p%s\n" "$listener_pid"
  printf "n%s\n" "$listener_name"
  found=1
done <"$DSH_TEST_LISTENERS_FILE"
[ "$found" -eq 1 ]'

  write_fake curl '
log_line=
has_fail=0
has_silent=0
has_show_error=0
has_max_time=0
has_two=0
output_path=
previous=
for arg in "$@"; do
  if [ -n "$log_line" ]; then
    log_line="$log_line|$arg"
  else
    log_line=$arg
  fi
  case "$arg" in
    --fail) has_fail=1 ;;
    --silent) has_silent=1 ;;
    --show-error) has_show_error=1 ;;
    --max-time) has_max_time=1 ;;
    --output) previous=output; continue ;;
  esac
  if [ "$previous" = output ]; then
    output_path=$arg
    previous=
  elif [ "$previous" = max-time ]; then
    [ "$arg" = 2 ] && has_two=1
    previous=
  elif [ "$arg" = --max-time ]; then
    previous=max-time
  fi
done
printf "%s\n" "$log_line" >>"$DSH_TEST_CURL_LOG"
[ "$has_fail" -eq 1 ] && [ "$has_silent" -eq 1 ] && [ "$has_show_error" -eq 1 ] || exit 90
[ "$has_max_time" -eq 1 ] && [ "$has_two" -eq 1 ] || exit 91
[ "$output_path" = /dev/null ] || exit 92
[ "$(<"$DSH_TEST_CURL_OK_FILE")" = 1 ] || exit 22
if [ "$output_path" != /dev/null ]; then
  printf "%s" "$(<"$DSH_TEST_CURL_BODY_FILE")"
fi'

  write_fake open '
log_line=
for arg in "$@"; do
  if [ -n "$log_line" ]; then
    log_line="$log_line|$arg"
  else
    log_line=$arg
  fi
done
printf "%s\n" "$log_line" >>"$DSH_TEST_OPEN_LOG"
exit "$(<"$DSH_TEST_OPEN_STATUS_FILE")"'
}

prepare_launchd_case() {
  case_name=$1
  export HOME="$TEST_ROOT/home-$case_name"
  /bin/mkdir -p "$HOME" || return 1
  init_paths

  export DSH_TEST_LAUNCHCTL_LOG="$TEST_ROOT/$case_name-launchctl.log"
  export DSH_TEST_LSOF_LOG="$TEST_ROOT/$case_name-lsof.log"
  export DSH_TEST_CURL_LOG="$TEST_ROOT/$case_name-curl.log"
  export DSH_TEST_OPEN_LOG="$TEST_ROOT/$case_name-open.log"
  export DSH_TEST_LOADED_FILE="$TEST_ROOT/$case_name-loaded"
  export DSH_TEST_PID_FILE="$TEST_ROOT/$case_name-pid"
  export DSH_TEST_PRINT_MODE_FILE="$TEST_ROOT/$case_name-print-mode"
  export DSH_TEST_LISTENERS_FILE="$TEST_ROOT/$case_name-listeners"
  export DSH_TEST_CURL_OK_FILE="$TEST_ROOT/$case_name-curl-ok"
  export DSH_TEST_CURL_BODY_FILE="$TEST_ROOT/$case_name-curl-body"
  export DSH_TEST_OPEN_STATUS_FILE="$TEST_ROOT/$case_name-open-status"
  export DSH_TEST_JOB_DELAY_FILE="$TEST_ROOT/$case_name-job-delay"
  export DSH_TEST_LISTENER_DELAY_FILE="$TEST_ROOT/$case_name-listener-delay"
  export DSH_TEST_LSOF_STATUS_FILE="$TEST_ROOT/$case_name-lsof-status"
  export DSH_TEST_LSOF_DIAGNOSTIC_FILE="$TEST_ROOT/$case_name-lsof-diagnostic"

  : >"$DSH_TEST_LAUNCHCTL_LOG"
  : >"$DSH_TEST_LSOF_LOG"
  : >"$DSH_TEST_CURL_LOG"
  : >"$DSH_TEST_OPEN_LOG"
  printf '0\n' >"$DSH_TEST_LOADED_FILE"
  : >"$DSH_TEST_PID_FILE"
  printf 'normal\n' >"$DSH_TEST_PRINT_MODE_FILE"
  : >"$DSH_TEST_LISTENERS_FILE"
  printf '1\n' >"$DSH_TEST_CURL_OK_FILE"
  : >"$DSH_TEST_CURL_BODY_FILE"
  printf '0\n' >"$DSH_TEST_OPEN_STATUS_FILE"
  printf '0\n' >"$DSH_TEST_JOB_DELAY_FILE"
  printf '0\n' >"$DSH_TEST_LISTENER_DELAY_FILE"
  printf '0\n' >"$DSH_TEST_LSOF_STATUS_FILE"
  : >"$DSH_TEST_LSOF_DIAGNOSTIC_FILE"

  unset DSH_TEST_AUTO_LISTENER DSH_TEST_HEALTH_AFTER_TRANSITION
  unset DSH_TEST_KILL_FAIL DSH_TEST_GRACEFUL_MODE DSH_TEST_NEXT_PID
  unset DSH_TEST_BOOTOUT_JOB_DELAY DSH_TEST_BOOTOUT_LISTENER_DELAY
  export DSH_TEST_AUTO_LISTENER=1
  export DSH_TEST_GRACEFUL_MODE=success

  write_launchd_fakes
  export DSH_SERVICE_LAUNCHCTL_BIN="$TEST_ROOT/bin/launchctl"
  export DSH_SERVICE_PLUTIL_BIN=/usr/bin/plutil
  export DSH_SERVICE_LSOF_BIN="$TEST_ROOT/bin/lsof"
  export DSH_SERVICE_CURL_BIN="$TEST_ROOT/bin/curl"
  export DSH_SERVICE_OPEN_BIN="$TEST_ROOT/bin/open"
  export DSH_SERVICE_WAIT_ATTEMPTS=6
  export DSH_SERVICE_WAIT_INTERVAL=0
  init_command_paths
}

set_job() {
  printf '%s\n' "$1" >"$DSH_TEST_LOADED_FILE"
  printf '%s\n' "$2" >"$DSH_TEST_PID_FILE"
}

set_listeners() {
  : >"$DSH_TEST_LISTENERS_FILE"
  shift_count=0
  for listener_record in "$@"; do
    printf '%s\n' "$listener_record" >>"$DSH_TEST_LISTENERS_FILE"
    shift_count=$((shift_count + 1))
  done
  [ "$shift_count" -eq "$#" ]
}

set_lsof_failure() {
  printf '%s\n' "$1" >"$DSH_TEST_LSOF_STATUS_FILE"
  printf '%s\n' "$2" >"$DSH_TEST_LSOF_DIAGNOSTIC_FILE"
}

plist_identity() {
  /usr/bin/stat -f '%i:%m' "$SERVICE_DEFINITION_PATH"
}

assert_log_has_line() {
  expected_line=$1
  log_path=$2
  while IFS= read -r actual_line || [ -n "$actual_line" ]; do
    [ "$actual_line" = "$expected_line" ] && return 0
  done <"$log_path"
  printf 'log <%s> did not contain <%s>\n' "$log_path" "$expected_line" >&2
  return 1
}

assert_log_has_no_mutation() {
  log_path=$1
  while IFS= read -r actual_line || [ -n "$actual_line" ]; do
    case "$actual_line" in
      bootstrap\|*|kickstart\|*|kill\|*|bootout\|*)
        printf 'unexpected launchctl mutation: %s\n' "$actual_line" >&2
        return 1
        ;;
    esac
  done <"$log_path"
}

assert_no_kickstart_k() {
  log_path=$1
  while IFS= read -r actual_line || [ -n "$actual_line" ]; do
    case "|$actual_line|" in
      *'|kickstart|'*'|-k|'*|*'|-k|kickstart|'*)
        printf 'forbidden kickstart -k call: %s\n' "$actual_line" >&2
        return 1
        ;;
    esac
  done <"$log_path"
}

assert_health() {
  expected_state=$1
  expected_status=$2
  actual_state=$(health_state)
  actual_status=$?
  assert_eq "$expected_status" "$actual_status" || return 1
  assert_eq "$expected_state" "$actual_state"
}

plist_raw() {
  /usr/bin/plutil -extract "$1" raw -o - "$SERVICE_DEFINITION_PATH"
}

test_plist_is_valid_and_preserves_special_paths() (
  prepare_launchd_case plist-special || return 1
  export HOME="$TEST_ROOT/home space ' apostrophe \" quote & amp < less > greater"
  /bin/mkdir -p "$HOME" || return 1
  init_paths
  export ANTHROPIC_API_KEY='secret-must-not-appear'
  export DEEPSEEK_API_KEY='another-secret'

  ensure_plist || return 1
  /usr/bin/plutil -lint "$SERVICE_DEFINITION_PATH" >/dev/null || return 1
  assert_eq dev.dsh-service.web "$(plist_raw Label)" || return 1
  assert_eq 2 "$(plist_raw ProgramArguments)" || return 1
  assert_eq /bin/bash "$(plist_raw ProgramArguments.0)" || return 1
  assert_eq "$CURRENT_LINK/run" "$(plist_raw ProgramArguments.1)" || return 1
  assert_eq "$WORKSPACE_DIR" "$(plist_raw WorkingDirectory)" || return 1
  assert_eq "$HOME" "$(plist_raw EnvironmentVariables.HOME)" || return 1
  assert_eq true "$(plist_raw KeepAlive)" || return 1
  assert_eq 10 "$(plist_raw ThrottleInterval)" || return 1
  assert_eq 15 "$(plist_raw ExitTimeOut)" || return 1
  assert_eq "$LOG_DIR/stdout.log" "$(plist_raw StandardOutPath)" || return 1
  assert_eq "$LOG_DIR/stderr.log" "$(plist_raw StandardErrorPath)" || return 1
  if /usr/bin/plutil -extract RunAtLoad raw -o - "$SERVICE_DEFINITION_PATH" >/dev/null 2>&1; then
    printf 'plist unexpectedly contains RunAtLoad\n' >&2
    return 1
  fi
  plist_text=$(<"$SERVICE_DEFINITION_PATH")
  case "$plist_text" in
    *secret-must-not-appear*|*another-secret*) return 1 ;;
  esac
)

test_failed_plist_lint_preserves_published_file() (
  prepare_launchd_case plist-atomic || return 1
  ensure_plist || return 1
  original_plist=$(<"$SERVICE_DEFINITION_PATH")
  export DSH_TEST_PLUTIL_LOG="$TEST_ROOT/plutil-failure.log"
  : >"$DSH_TEST_PLUTIL_LOG"
  write_fake plutil-reject '
printf "%s\n" "$*" >>"$DSH_TEST_PLUTIL_LOG"
exit 1'
  PLUTIL_BIN="$TEST_ROOT/bin/plutil-reject"
  WORKSPACE_DIR="$WORKSPACE_DIR/changed"

  ! ensure_plist || return 1
  assert_eq "$original_plist" "$(<"$SERVICE_DEFINITION_PATH")" || return 1
  [ -s "$DSH_TEST_PLUTIL_LOG" ] || return 1
  for temporary_plist in "$(dirname -- "$SERVICE_DEFINITION_PATH")"/.dev.dsh-service.web.plist.*; do
    [ ! -e "$temporary_plist" ] || return 1
  done
)

test_service_pid_accepts_only_valid_successful_print_line() (
  prepare_launchd_case pid-strict || return 1
  set_job 1 4321
  printf 'decoys\n' >"$DSH_TEST_PRINT_MODE_FILE"
  assert_eq 4321 "$(service_pid)" || return 1

  printf 'fail-with-pid\n' >"$DSH_TEST_PRINT_MODE_FILE"
  failed_output=$(service_pid)
  failed_status=$?
  assert_eq 1 "$failed_status" || return 1
  assert_eq '' "$failed_output"
)

test_health_is_healthy_only_for_matching_identity_and_http() (
  prepare_launchd_case health-healthy || return 1
  set_job 1 101
  set_listeners '101|127.0.0.1:3080' || return 1
  printf 'response body that must be discarded\n' >"$DSH_TEST_CURL_BODY_FILE"

  assert_health healthy 0 || return 1
  expected_curl='--fail|--silent|--show-error|--max-time|2|--output|/dev/null|http://127.0.0.1:3080'
  assert_log_has_line "$expected_curl" "$DSH_TEST_CURL_LOG"
)

test_health_reports_conflict_for_different_listener_pid() (
  prepare_launchd_case health-foreign || return 1
  set_job 1 101
  set_listeners '202|127.0.0.1:3080' || return 1
  assert_health conflict 1
)

test_health_reports_conflict_for_every_wildcard_listener() (
  prepare_launchd_case health-wildcards || return 1
  set_job 1 101
  for wildcard_address in '*:3080' '0.0.0.0:3080' '[::]:3080'; do
    set_listeners "101|$wildcard_address" || return 1
    assert_health conflict 1 || return 1
  done
)

test_health_reports_unhealthy_when_matching_http_fails() (
  prepare_launchd_case health-unhealthy || return 1
  set_job 1 101
  set_listeners '101|127.0.0.1:3080' || return 1
  printf '0\n' >"$DSH_TEST_CURL_OK_FILE"
  assert_health unhealthy 1
)

test_health_distinguishes_unloaded_and_starting() (
  prepare_launchd_case health-transitional || return 1
  assert_health unloaded 1 || return 1

  set_job 1 ''
  assert_health starting 1 || return 1

  set_job 1 101
  assert_health starting 1
)

test_health_fails_closed_for_lsof_status_two_without_output() (
  prepare_launchd_case health-lsof-status-two || return 1
  set_job 1 101
  set_listeners '101|127.0.0.1:3080' || return 1
  set_lsof_failure 2 ''

  assert_health conflict 1
)

test_health_fails_closed_for_lsof_status_one_with_diagnostic() (
  prepare_launchd_case health-lsof-diagnostic || return 1
  set_job 1 101
  set_listeners '101|127.0.0.1:3080' || return 1
  set_lsof_failure 1 'lsof: unexpected diagnostic'

  assert_health conflict 1
)

test_wait_for_health_stops_after_elapsed_deadline() (
  probe_log="$TEST_ROOT/slow-health-probes.log"
  : >"$probe_log"
  WAIT_ATTEMPTS=2
  WAIT_INTERVAL=1
  WAIT_TIMEOUT_SECONDS=1
  health_state() {
    printf 'probe\n' >>"$probe_log"
    /bin/sleep 1
    return 1
  }

  started_at=$SECONDS
  ! wait_for_health || return 1
  elapsed=$((SECONDS - started_at))
  assert_eq 1 "$(/usr/bin/awk 'END { print NR }' "$probe_log")" || return 1
  [ "$elapsed" -ge 1 ] && [ "$elapsed" -le 2 ]
)

test_start_bootstraps_an_unloaded_service() (
  prepare_launchd_case start-bootstrap || return 1
  export DSH_TEST_NEXT_PID=202
  start_service || return 1

  uid=$(/usr/bin/id -u)
  assert_log_has_line "bootstrap|gui/$uid|$SERVICE_DEFINITION_PATH" "$DSH_TEST_LAUNCHCTL_LOG" || return 1
  assert_health healthy 0 || return 1
  assert_no_kickstart_k "$DSH_TEST_LAUNCHCTL_LOG"
)

test_start_kickstarts_loaded_job_without_pid_and_without_k() (
  prepare_launchd_case start-kickstart || return 1
  set_job 1 ''
  export DSH_TEST_NEXT_PID=203
  start_service || return 1

  assert_log_has_line "kickstart|$SERVICE_TARGET" "$DSH_TEST_LAUNCHCTL_LOG" || return 1
  assert_health healthy 0 || return 1
  assert_no_kickstart_k "$DSH_TEST_LAUNCHCTL_LOG"
)

test_restart_uses_graceful_launchctl_signal_and_new_identity() (
  prepare_launchd_case restart-graceful || return 1
  set_job 1 101
  set_listeners '101|127.0.0.1:3080' || return 1
  export DSH_TEST_NEXT_PID=204
  shell_kill_log="$TEST_ROOT/restart-shell-kill.log"
  : >"$shell_kill_log"
  kill() { printf '%s\n' "$*" >>"$shell_kill_log"; }

  restart_service || return 1
  assert_log_has_line "kill|SIGTERM|$SERVICE_TARGET" "$DSH_TEST_LAUNCHCTL_LOG" || return 1
  assert_eq 204 "$(service_pid)" || return 1
  assert_eq '' "$(<"$shell_kill_log")" || return 1
  assert_health healthy 0 || return 1
  assert_no_kickstart_k "$DSH_TEST_LAUNCHCTL_LOG"
)

test_start_restarts_its_unhealthy_owned_listener_gracefully() (
  prepare_launchd_case start-unhealthy || return 1
  set_job 1 101
  set_listeners '101|127.0.0.1:3080' || return 1
  printf '0\n' >"$DSH_TEST_CURL_OK_FILE"
  export DSH_TEST_HEALTH_AFTER_TRANSITION=1
  export DSH_TEST_NEXT_PID=205

  start_service || return 1
  assert_log_has_line "kill|SIGTERM|$SERVICE_TARGET" "$DSH_TEST_LAUNCHCTL_LOG" || return 1
  assert_eq 205 "$(service_pid)" || return 1
  assert_health healthy 0
)

test_restart_falls_back_once_to_bootout_and_bootstrap() (
  prepare_launchd_case restart-fallback || return 1
  set_job 1 101
  set_listeners '101|127.0.0.1:3080' || return 1
  export DSH_TEST_GRACEFUL_MODE=stuck
  export DSH_TEST_NEXT_PID=206
  export DSH_SERVICE_WAIT_ATTEMPTS=2
  init_command_paths

  restart_service || return 1
  uid=$(/usr/bin/id -u)
  assert_log_has_line "kill|SIGTERM|$SERVICE_TARGET" "$DSH_TEST_LAUNCHCTL_LOG" || return 1
  assert_log_has_line "bootout|$SERVICE_TARGET" "$DSH_TEST_LAUNCHCTL_LOG" || return 1
  assert_log_has_line "bootstrap|gui/$uid|$SERVICE_DEFINITION_PATH" "$DSH_TEST_LAUNCHCTL_LOG" || return 1
  assert_eq 206 "$(service_pid)" || return 1
  assert_health healthy 0 || return 1
  assert_no_kickstart_k "$DSH_TEST_LAUNCHCTL_LOG"
)

test_stop_waits_for_job_and_old_listener_to_disappear() (
  prepare_launchd_case stop-waits || return 1
  set_job 1 101
  set_listeners '101|127.0.0.1:3080' || return 1
  export DSH_TEST_BOOTOUT_JOB_DELAY=2
  export DSH_TEST_BOOTOUT_LISTENER_DELAY=3
  export DSH_SERVICE_WAIT_ATTEMPTS=8
  init_command_paths
  shell_kill_log="$TEST_ROOT/stop-shell-kill.log"
  : >"$shell_kill_log"
  kill() { printf '%s\n' "$*" >>"$shell_kill_log"; }

  stop_service || return 1
  assert_log_has_line "bootout|$SERVICE_TARGET" "$DSH_TEST_LAUNCHCTL_LOG" || return 1
  assert_eq 0 "$(<"$DSH_TEST_LOADED_FILE")" || return 1
  assert_eq '' "$(<"$DSH_TEST_LISTENERS_FILE")" || return 1
  assert_eq 0 "$(<"$DSH_TEST_JOB_DELAY_FILE")" || return 1
  assert_eq 0 "$(<"$DSH_TEST_LISTENER_DELAY_FILE")" || return 1
  assert_eq '' "$(<"$shell_kill_log")"
)

test_stop_treats_an_unloaded_service_as_success() (
  prepare_launchd_case stop-unloaded || return 1
  stop_service || return 1
  assert_log_has_no_mutation "$DSH_TEST_LAUNCHCTL_LOG"
)

test_stop_does_not_treat_lsof_error_as_old_listener_release() (
  prepare_launchd_case stop-lsof-error || return 1
  set_job 1 101
  set_listeners '101|127.0.0.1:3080' || return 1
  export DSH_TEST_BOOTOUT_LISTENER_DELAY=99
  export DSH_SERVICE_WAIT_ATTEMPTS=2
  init_command_paths
  set_lsof_failure 2 ''

  ! stop_service || return 1
  assert_log_has_line "bootout|$SERVICE_TARGET" "$DSH_TEST_LAUNCHCTL_LOG" || return 1
  assert_eq '101|127.0.0.1:3080' "$(<"$DSH_TEST_LISTENERS_FILE")"
)

test_start_refuses_foreign_listener_without_mutation_or_kill() (
  prepare_launchd_case start-conflict || return 1
  type start_service >/dev/null 2>&1 || return 1
  set_listeners '909|127.0.0.1:3080' || return 1
  shell_kill_log="$TEST_ROOT/start-conflict-shell-kill.log"
  : >"$shell_kill_log"
  kill() { printf '%s\n' "$*" >>"$shell_kill_log"; }

  [ ! -e "$SERVICE_DEFINITION_PATH" ] || return 1
  ! start_service || return 1
  [ ! -e "$SERVICE_DEFINITION_PATH" ] || return 1
  [ ! -e "$LOG_DIR" ] || return 1
  [ ! -e "$WORKSPACE_DIR" ] || return 1
  assert_log_has_no_mutation "$DSH_TEST_LAUNCHCTL_LOG" || return 1
  assert_eq '' "$(<"$shell_kill_log")"
)

test_restart_refuses_foreign_listener_without_mutation_or_kill() (
  prepare_launchd_case restart-conflict || return 1
  type restart_service >/dev/null 2>&1 || return 1
  set_job 1 101
  set_listeners '909|127.0.0.1:3080' || return 1
  shell_kill_log="$TEST_ROOT/restart-conflict-shell-kill.log"
  : >"$shell_kill_log"
  kill() { printf '%s\n' "$*" >>"$shell_kill_log"; }

  /bin/mkdir -p "${SERVICE_DEFINITION_PATH%/*}" || return 1
  printf 'existing plist sentinel\n' >"$SERVICE_DEFINITION_PATH" || return 1
  /usr/bin/touch -t 200001010101 "$SERVICE_DEFINITION_PATH" || return 1
  before_identity=$(plist_identity) || return 1

  ! restart_service || return 1
  assert_eq 'existing plist sentinel' "$(<"$SERVICE_DEFINITION_PATH")" || return 1
  assert_eq "$before_identity" "$(plist_identity)" || return 1
  assert_log_has_no_mutation "$DSH_TEST_LAUNCHCTL_LOG" || return 1
  assert_eq '' "$(<"$shell_kill_log")"
)

test_start_lsof_error_makes_no_manager_owned_mutation() (
  prepare_launchd_case start-lsof-error || return 1
  set_lsof_failure 2 ''

  ! start_service || return 1
  [ ! -e "$SERVICE_DEFINITION_PATH" ] || return 1
  [ ! -e "$LOG_DIR" ] || return 1
  [ ! -e "$WORKSPACE_DIR" ] || return 1
  assert_log_has_no_mutation "$DSH_TEST_LAUNCHCTL_LOG"
)

test_restart_lsof_diagnostic_preserves_existing_plist() (
  prepare_launchd_case restart-lsof-error || return 1
  set_job 1 101
  set_listeners '101|127.0.0.1:3080' || return 1
  set_lsof_failure 1 'lsof: unexpected diagnostic'
  /bin/mkdir -p "${SERVICE_DEFINITION_PATH%/*}" || return 1
  printf 'existing plist sentinel\n' >"$SERVICE_DEFINITION_PATH" || return 1
  /usr/bin/touch -t 200001010101 "$SERVICE_DEFINITION_PATH" || return 1
  before_identity=$(plist_identity) || return 1

  ! restart_service || return 1
  assert_eq 'existing plist sentinel' "$(<"$SERVICE_DEFINITION_PATH")" || return 1
  assert_eq "$before_identity" "$(plist_identity)" || return 1
  assert_log_has_no_mutation "$DSH_TEST_LAUNCHCTL_LOG"
)

run_test 'plist is valid and preserves XML-sensitive paths' test_plist_is_valid_and_preserves_special_paths
run_test 'failed plist lint preserves the published plist' test_failed_plist_lint_preserves_published_file
run_test 'launchd PID parsing requires a valid successful print line' test_service_pid_accepts_only_valid_successful_print_line
run_test 'matching job, listener, and HTTP are healthy without body output' test_health_is_healthy_only_for_matching_identity_and_http
run_test 'different listener identity is a conflict' test_health_reports_conflict_for_different_listener_pid
run_test 'IPv4 and IPv6 wildcard listeners are conflicts' test_health_reports_conflict_for_every_wildcard_listener
run_test 'matching listener with failed HTTP is unhealthy' test_health_reports_unhealthy_when_matching_http_fails
run_test 'health distinguishes unloaded and starting states' test_health_distinguishes_unloaded_and_starting
run_test 'health fails closed for lsof status 2 without output' test_health_fails_closed_for_lsof_status_two_without_output
run_test 'health fails closed for lsof status 1 with diagnostics' test_health_fails_closed_for_lsof_status_one_with_diagnostic
run_test 'health wait stops after its elapsed deadline' test_wait_for_health_stops_after_elapsed_deadline
run_test 'start bootstraps an unloaded service' test_start_bootstraps_an_unloaded_service
run_test 'start kickstarts a loaded job without PID and without -k' test_start_kickstarts_loaded_job_without_pid_and_without_k
run_test 'restart uses graceful launchctl signaling and a new identity' test_restart_uses_graceful_launchctl_signal_and_new_identity
run_test 'start gracefully restarts its unhealthy owned listener' test_start_restarts_its_unhealthy_owned_listener_gracefully
run_test 'restart falls back once through bootout and bootstrap' test_restart_falls_back_once_to_bootout_and_bootstrap
run_test 'stop waits for job removal and old listener release' test_stop_waits_for_job_and_old_listener_to_disappear
run_test 'stop succeeds when already unloaded' test_stop_treats_an_unloaded_service_as_success
run_test 'stop does not mistake an lsof error for listener release' test_stop_does_not_treat_lsof_error_as_old_listener_release
run_test 'start refuses a foreign listener without mutation or kill' test_start_refuses_foreign_listener_without_mutation_or_kill
run_test 'restart refuses a foreign listener without mutation or kill' test_restart_refuses_foreign_listener_without_mutation_or_kill
run_test 'start makes no manager-owned mutation on lsof error' test_start_lsof_error_makes_no_manager_owned_mutation
run_test 'restart preserves an existing plist on lsof diagnostics' test_restart_lsof_diagnostic_preserves_existing_plist

finish_tests
