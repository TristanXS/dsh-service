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

OLD_RELEASE=1.0.0-1786630000-1200
CANDIDATE_RELEASE=1.1.0-1786640000-1201
UNRELATED_RELEASE=2.0.0-1786650000-1202
STALE_RELEASE=0.9.0-1786620000-1199

prepare_activation_home() {
  activation_name=$1
  export HOME="$TEST_ROOT/home-$activation_name"
  /bin/mkdir -p "$HOME" || return 1
  init_paths
  /bin/mkdir -p "$DSH_MAC_ROOT" || return 1
}

write_literal_activation() {
  literal_path=$1
  literal_old=$2
  literal_candidate=$3
  {
    printf 'SCHEMA_VERSION=1\n'
    printf 'OLD_RELEASE=%s\n' "$literal_old"
    printf 'CANDIDATE_RELEASE=%s\n' "$literal_candidate"
  } >"$literal_path"
}

install_activation_service_boundary() {
  service_loaded() {
    [ "$(<"$DSH_TEST_SERVICE_LOADED")" = 1 ]
  }

  health_state() {
    [ "$#" -eq 0 ] || return 1
    if ! service_loaded; then
      printf 'unloaded\n'
      return 1
    fi
    running_release=$(<"$DSH_TEST_SERVICE_RELEASE")
    linked_release=$(current_release_id 2>/dev/null) || {
      printf 'conflict\n'
      return 1
    }
    if [ "$running_release" != "$linked_release" ]; then
      printf 'conflict\n'
      return 1
    fi
    running_health=healthy
    if [ -f "$DSH_TEST_HEALTH_DIR/$running_release" ]; then
      running_health=$(<"$DSH_TEST_HEALTH_DIR/$running_release")
    fi
    if [ "$running_health" = healthy ]; then
      printf 'healthy\n'
      return 0
    fi
    printf 'unhealthy\n'
    return 1
  }

  wait_for_health() {
    [ "$#" -eq 0 ] || return 1
    health_state >/dev/null
  }

  transition_to_current_release() {
    transition_release=$(current_release_id) || return 1
    transition_pid=$(<"$DSH_TEST_SERVICE_PID")
    transition_pid=$((transition_pid + 1))
    printf '%s\n' "$transition_pid" >"$DSH_TEST_SERVICE_PID"
    printf '%s\n' "$transition_release" >"$DSH_TEST_SERVICE_RELEASE"
    printf '1\n' >"$DSH_TEST_SERVICE_LOADED"
    wait_for_health
  }

  start_service() {
    [ "$#" -eq 0 ] || return 1
    transition_to_current_release
  }

  restart_service() {
    [ "$#" -eq 0 ] || return 1
    transition_to_current_release
  }

  stop_service() {
    [ "$#" -eq 0 ] || return 1
    [ "${DSH_TEST_STOP_FAIL:-0}" != 1 ] || return 1
    printf '0\n' >"$DSH_TEST_SERVICE_LOADED"
    : >"$DSH_TEST_SERVICE_RELEASE"
  }
}

prepare_activation_case() {
  activation_name=$1
  prepare_activation_home "$activation_name" || return 1
  /bin/mkdir -p "$RELEASES_DIR" || return 1

  write_fake activation-node '
if [ "${1:-}" = --version ]; then
  printf "v22.19.0\n"
  exit 0
fi
cli_path=${1:-}
[ "${2:-}" = --version ] || exit 64
release_path=${cli_path%/node_modules/@deepseek-ai/dsh/lib/bin.js}
version=$(/usr/bin/sed -n "s/^DSH_VERSION=//p" "$release_path/manifest.env")
[ -n "$version" ] || exit 65
printf "@deepseek-ai/dsh %s\n" "$version"'
  ACTIVATION_NODE="$TEST_ROOT/bin/activation-node"

  export DSH_TEST_SERVICE_LOADED="$TEST_ROOT/$activation_name-service-loaded"
  export DSH_TEST_SERVICE_RELEASE="$TEST_ROOT/$activation_name-service-release"
  export DSH_TEST_SERVICE_PID="$TEST_ROOT/$activation_name-service-pid"
  export DSH_TEST_HEALTH_DIR="$TEST_ROOT/$activation_name-health"
  /bin/mkdir -p "$DSH_TEST_HEALTH_DIR" || return 1
  printf '0\n' >"$DSH_TEST_SERVICE_LOADED"
  : >"$DSH_TEST_SERVICE_RELEASE"
  printf '100\n' >"$DSH_TEST_SERVICE_PID"
  unset DSH_TEST_STOP_FAIL
  install_activation_service_boundary
}

make_complete_release() {
  complete_id=$1
  complete_version=${complete_id%%-*}
  complete_path="$RELEASES_DIR/$complete_id"
  /bin/mkdir -p "$complete_path/node_modules/@deepseek-ai/dsh/lib" || return 1
  printf 'entry\n' >"$complete_path/node_modules/@deepseek-ai/dsh/lib/bin.js" || return 1
  {
    printf 'SCHEMA_VERSION=1\n'
    printf 'DSH_VERSION=%s\n' "$complete_version"
    printf 'NODE_BIN=%s\n' "$ACTIVATION_NODE"
    printf 'CLI_RELATIVE=node_modules/@deepseek-ai/dsh/lib/bin.js\n'
    printf 'INSTALLED_AT=1786640000\n'
  } >"$complete_path/manifest.env" || return 1
  {
    printf '%s\n' '#!/bin/bash' 'set -u'
    printf '%s\n' '[ "${1:-}" = --check ] && [ "$#" -eq 1 ] || exit 64'
    printf '%s\n' 'release_dir="$(CDPATH= cd -P -- "$(dirname -- "$0")" && pwd)" || exit 1'
    printf '%s\n' '/usr/bin/sed -n "s/^DSH_VERSION=//p" "$release_dir/manifest.env"'
  } >"$complete_path/run" || return 1
  /bin/chmod 0755 "$complete_path/run" || return 1
  : >"$complete_path/.complete" || return 1
  printf 'healthy\n' >"$DSH_TEST_HEALTH_DIR/$complete_id"
}

link_release() {
  link_path=$1
  link_id=$2
  /bin/ln -s "releases/$link_id" "$link_path"
}

set_service_release() {
  service_release=$1
  printf '1\n' >"$DSH_TEST_SERVICE_LOADED"
  printf '%s\n' "$service_release" >"$DSH_TEST_SERVICE_RELEASE"
}

assert_release_link() {
  expected_id=$1
  actual_link=$2
  [ -L "$actual_link" ] || return 1
  assert_eq "releases/$expected_id" "$(/usr/bin/readlink "$actual_link")"
}

assert_journal_absent() {
  [ ! -e "$ACTIVATION_FILE" ] && [ ! -L "$ACTIVATION_FILE" ]
}

make_incomplete_staging_release() {
  staging_id=$1
  staging_path="$RELEASES_DIR/$staging_id"
  /bin/mkdir -p "$staging_path/partial" || return 1
  printf 'partial install\n' >"$staging_path/partial/sentinel"
}

test_no_journal_complete_current_wins_and_finishes_staging_cleanup() (
  prepare_activation_case no-journal-current-wins || return 1
  make_complete_release "$CANDIDATE_RELEASE" || return 1
  make_complete_release "$OLD_RELEASE" || return 1
  link_release "$CURRENT_LINK" "$CANDIDATE_RELEASE" || return 1
  link_release "$PREVIOUS_LINK" "$OLD_RELEASE" || return 1
  set_service_release "$CANDIDATE_RELEASE"
  staging_id=.staging-1786660000-1300
  make_incomplete_staging_release "$staging_id" || return 1
  old_pid=$(<"$DSH_TEST_SERVICE_PID")

  recover_activation || return 1

  assert_release_link "$CANDIDATE_RELEASE" "$CURRENT_LINK" || return 1
  assert_release_link "$OLD_RELEASE" "$PREVIOUS_LINK" || return 1
  validate_release "$RELEASES_DIR/$CANDIDATE_RELEASE" || return 1
  assert_eq "$old_pid" "$(<"$DSH_TEST_SERVICE_PID")" || return 1
  [ ! -e "$RELEASES_DIR/$staging_id" ] && [ ! -L "$RELEASES_DIR/$staging_id" ]
)

test_no_journal_missing_current_restores_complete_previous() (
  prepare_activation_case no-journal-missing-current || return 1
  make_complete_release "$OLD_RELEASE" || return 1
  link_release "$PREVIOUS_LINK" "$OLD_RELEASE" || return 1
  set_service_release "$OLD_RELEASE"
  old_pid=$(<"$DSH_TEST_SERVICE_PID")

  recover_activation || return 1

  assert_release_link "$OLD_RELEASE" "$CURRENT_LINK" || return 1
  assert_release_link "$OLD_RELEASE" "$PREVIOUS_LINK" || return 1
  assert_eq "$old_pid" "$(<"$DSH_TEST_SERVICE_PID")" || return 1
  health_state >/dev/null
)

test_no_journal_owned_incomplete_current_uses_complete_previous() (
  incomplete_kind=$1
  prepare_activation_case "no-journal-incomplete-$incomplete_kind" || return 1
  make_complete_release "$CANDIDATE_RELEASE" || return 1
  make_complete_release "$OLD_RELEASE" || return 1
  case "$incomplete_kind" in
    missing-complete)
      /bin/rm -f -- "$RELEASES_DIR/$CANDIDATE_RELEASE/.complete" || return 1
      ;;
    invalid-manifest)
      printf 'BROKEN=1\n' >"$RELEASES_DIR/$CANDIDATE_RELEASE/manifest.env" || return 1
      ;;
    *) return 1 ;;
  esac
  link_release "$CURRENT_LINK" "$CANDIDATE_RELEASE" || return 1
  link_release "$PREVIOUS_LINK" "$OLD_RELEASE" || return 1
  set_service_release "$OLD_RELEASE"
  old_pid=$(<"$DSH_TEST_SERVICE_PID")

  recover_activation || return 1

  assert_release_link "$OLD_RELEASE" "$CURRENT_LINK" || return 1
  assert_release_link "$OLD_RELEASE" "$PREVIOUS_LINK" || return 1
  [ -d "$RELEASES_DIR/$CANDIDATE_RELEASE" ] &&
    [ ! -L "$RELEASES_DIR/$CANDIDATE_RELEASE" ] || return 1
  assert_eq "$old_pid" "$(<"$DSH_TEST_SERVICE_PID")" || return 1
  health_state >/dev/null
)

test_no_journal_cleanup_removes_only_exact_incomplete_physical_staging_children() (
  prepare_activation_case no-journal-cleanup-boundary || return 1
  make_complete_release "$CANDIDATE_RELEASE" || return 1
  link_release "$CURRENT_LINK" "$CANDIDATE_RELEASE" || return 1
  set_service_release "$CANDIDATE_RELEASE"

  removable=.staging-1786660000-1301
  complete_staging=.staging-1786660000-1302
  staging_symlink=.staging-1786660000-1303
  unknown_staging=.staging-not-generated
  ordinary_incomplete=$STALE_RELEASE
  nested_parent="$RELEASES_DIR/nested"
  outside="$TEST_ROOT/no-journal-cleanup-outside"
  make_incomplete_staging_release "$removable" || return 1
  /bin/mkdir -p "$RELEASES_DIR/$complete_staging" || return 1
  : >"$RELEASES_DIR/$complete_staging/.complete" || return 1
  /bin/mkdir -p "$RELEASES_DIR/$unknown_staging" || return 1
  printf 'keep unknown\n' >"$RELEASES_DIR/$unknown_staging/sentinel" || return 1
  /bin/mkdir -p "$RELEASES_DIR/$ordinary_incomplete" || return 1
  printf 'keep ordinary\n' >"$RELEASES_DIR/$ordinary_incomplete/sentinel" || return 1
  /bin/mkdir -p "$nested_parent/.staging-1786660000-1304" || return 1
  printf 'keep nested\n' >"$nested_parent/.staging-1786660000-1304/sentinel" || return 1
  /bin/mkdir -p "$outside" || return 1
  printf 'keep outside\n' >"$outside/sentinel" || return 1
  /bin/ln -s "$outside" "$RELEASES_DIR/$staging_symlink" || return 1
  /bin/ln -s "$outside" "$RELEASES_DIR/$UNRELATED_RELEASE" || return 1

  recover_activation || return 1

  [ ! -e "$RELEASES_DIR/$removable" ] && [ ! -L "$RELEASES_DIR/$removable" ] || return 1
  [ -d "$RELEASES_DIR/$complete_staging" ] &&
    [ -f "$RELEASES_DIR/$complete_staging/.complete" ] || return 1
  assert_eq 'keep unknown' "$(<"$RELEASES_DIR/$unknown_staging/sentinel")" || return 1
  assert_eq 'keep ordinary' "$(<"$RELEASES_DIR/$ordinary_incomplete/sentinel")" || return 1
  assert_eq 'keep nested' "$(<"$nested_parent/.staging-1786660000-1304/sentinel")" || return 1
  [ -L "$RELEASES_DIR/$staging_symlink" ] || return 1
  [ -L "$RELEASES_DIR/$UNRELATED_RELEASE" ] || return 1
  assert_eq 'keep outside' "$(<"$outside/sentinel")"
)

test_no_journal_unsafe_link_fails_before_staging_cleanup() (
  unsafe_side=$1
  unsafe_kind=$2
  prepare_activation_case "no-journal-unsafe-$unsafe_side-$unsafe_kind" || return 1
  make_complete_release "$CANDIDATE_RELEASE" || return 1
  make_complete_release "$OLD_RELEASE" || return 1
  link_release "$CURRENT_LINK" "$CANDIDATE_RELEASE" || return 1
  link_release "$PREVIOUS_LINK" "$OLD_RELEASE" || return 1
  unsafe_path=$CURRENT_LINK
  safe_path=$PREVIOUS_LINK
  safe_id=$OLD_RELEASE
  if [ "$unsafe_side" = previous ]; then
    unsafe_path=$PREVIOUS_LINK
    safe_path=$CURRENT_LINK
    safe_id=$CANDIDATE_RELEASE
  fi
  /bin/rm -f -- "$unsafe_path" || return 1
  outside="$TEST_ROOT/no-journal-unsafe-$unsafe_side-$unsafe_kind-outside"
  /bin/mkdir -p "$outside" || return 1
  printf 'keep outside\n' >"$outside/sentinel" || return 1
  case "$unsafe_kind" in
    malformed)
      /bin/ln -s 'releases/not-a-release-id' "$unsafe_path" || return 1
      ;;
    out-of-root)
      /bin/ln -s "$outside" "$unsafe_path" || return 1
      ;;
    non-symlink)
      /bin/mkdir "$unsafe_path" || return 1
      printf 'keep link path\n' >"$unsafe_path/sentinel" || return 1
      ;;
    unowned)
      /bin/ln -s "$outside" "$RELEASES_DIR/$UNRELATED_RELEASE" || return 1
      /bin/ln -s "releases/$UNRELATED_RELEASE" "$unsafe_path" || return 1
      ;;
    *) return 1 ;;
  esac
  staging_id=.staging-1786660000-1305
  make_incomplete_staging_release "$staging_id" || return 1

  ! recover_activation || return 1

  assert_release_link "$safe_id" "$safe_path" || return 1
  [ -d "$RELEASES_DIR/$staging_id" ] || return 1
  assert_eq 'partial install' "$(<"$RELEASES_DIR/$staging_id/partial/sentinel")" || return 1
  assert_eq 'keep outside' "$(<"$outside/sentinel")" || return 1
  case "$unsafe_kind" in
    non-symlink) assert_eq 'keep link path' "$(<"$unsafe_path/sentinel")" ;;
    *) [ -L "$unsafe_path" ] ;;
  esac
)

test_read_only_commands_do_not_run_no_journal_cleanup() (
  prepare_update_case read-only-no-journal-cleanup || return 1
  make_complete_release "$CANDIDATE_RELEASE" || return 1
  link_release "$CURRENT_LINK" "$CANDIDATE_RELEASE" || return 1
  set_service_release "$CANDIDATE_RELEASE"
  staging_id=.staging-1786660000-1306
  make_incomplete_staging_release "$staging_id" || return 1

  cmd_status >/dev/null || return 1
  cmd_open || return 1

  [ -d "$RELEASES_DIR/$staging_id" ] || return 1
  assert_eq 'partial install' "$(<"$RELEASES_DIR/$staging_id/partial/sentinel")" || return 1
  [ ! -e "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ]
)

test_recovery_from_old_switches_restarts_and_commits_candidate() (
  prepare_activation_case recover-from-old || return 1
  type recover_activation >/dev/null 2>&1 || return 1
  make_complete_release "$OLD_RELEASE" || return 1
  make_complete_release "$CANDIDATE_RELEASE" || return 1
  make_complete_release "$STALE_RELEASE" || return 1
  link_release "$CURRENT_LINK" "$OLD_RELEASE" || return 1
  set_service_release "$OLD_RELEASE"
  write_literal_activation "$ACTIVATION_FILE" "$OLD_RELEASE" "$CANDIDATE_RELEASE"
  old_pid=$(<"$DSH_TEST_SERVICE_PID")

  recover_activation || return 1

  assert_release_link "$CANDIDATE_RELEASE" "$CURRENT_LINK" || return 1
  assert_release_link "$OLD_RELEASE" "$PREVIOUS_LINK" || return 1
  assert_eq "$CANDIDATE_RELEASE" "$(<"$DSH_TEST_SERVICE_RELEASE")" || return 1
  [ "$(<"$DSH_TEST_SERVICE_PID")" -gt "$old_pid" ] || return 1
  assert_journal_absent || return 1
  [ -d "$RELEASES_DIR/$OLD_RELEASE" ] || return 1
  [ -d "$RELEASES_DIR/$CANDIDATE_RELEASE" ] || return 1
  [ ! -e "$RELEASES_DIR/$STALE_RELEASE" ]
)

test_recovery_forces_restart_when_candidate_is_already_current() (
  prepare_activation_case recover-current-candidate || return 1
  type recover_activation >/dev/null 2>&1 || return 1
  make_complete_release "$OLD_RELEASE" || return 1
  make_complete_release "$CANDIDATE_RELEASE" || return 1
  link_release "$CURRENT_LINK" "$CANDIDATE_RELEASE" || return 1
  set_service_release "$CANDIDATE_RELEASE"
  write_literal_activation "$ACTIVATION_FILE" "$OLD_RELEASE" "$CANDIDATE_RELEASE"
  old_pid=$(<"$DSH_TEST_SERVICE_PID")
  health_state >/dev/null || return 1

  recover_activation || return 1

  assert_release_link "$CANDIDATE_RELEASE" "$CURRENT_LINK" || return 1
  assert_release_link "$OLD_RELEASE" "$PREVIOUS_LINK" || return 1
  [ "$(<"$DSH_TEST_SERVICE_PID")" -gt "$old_pid" ] || return 1
  assert_journal_absent
)

test_first_install_recovery_switches_starts_and_verifies_candidate() (
  prepare_activation_case recover-first-install || return 1
  type recover_activation >/dev/null 2>&1 || return 1
  make_complete_release "$CANDIDATE_RELEASE" || return 1
  write_literal_activation "$ACTIVATION_FILE" NONE "$CANDIDATE_RELEASE"

  recover_activation || return 1

  assert_release_link "$CANDIDATE_RELEASE" "$CURRENT_LINK" || return 1
  [ ! -e "$PREVIOUS_LINK" ] && [ ! -L "$PREVIOUS_LINK" ] || return 1
  assert_eq 1 "$(<"$DSH_TEST_SERVICE_LOADED")" || return 1
  assert_eq "$CANDIDATE_RELEASE" "$(<"$DSH_TEST_SERVICE_RELEASE")" || return 1
  health_state >/dev/null || return 1
  assert_journal_absent
)

test_recovery_rejects_unrelated_current_without_changing_links() (
  prepare_activation_case recover-unrelated || return 1
  type recover_activation >/dev/null 2>&1 || return 1
  make_complete_release "$OLD_RELEASE" || return 1
  make_complete_release "$CANDIDATE_RELEASE" || return 1
  make_complete_release "$UNRELATED_RELEASE" || return 1
  link_release "$CURRENT_LINK" "$UNRELATED_RELEASE" || return 1
  link_release "$PREVIOUS_LINK" "$OLD_RELEASE" || return 1
  set_service_release "$UNRELATED_RELEASE"
  write_literal_activation "$ACTIVATION_FILE" "$OLD_RELEASE" "$CANDIDATE_RELEASE"
  old_pid=$(<"$DSH_TEST_SERVICE_PID")

  ! recover_activation || return 1

  assert_release_link "$UNRELATED_RELEASE" "$CURRENT_LINK" || return 1
  assert_release_link "$OLD_RELEASE" "$PREVIOUS_LINK" || return 1
  assert_eq "$old_pid" "$(<"$DSH_TEST_SERVICE_PID")" || return 1
  [ -f "$ACTIVATION_FILE" ] || return 1
  [ -d "$RELEASES_DIR/$OLD_RELEASE" ] &&
    [ -d "$RELEASES_DIR/$CANDIDATE_RELEASE" ] &&
    [ -d "$RELEASES_DIR/$UNRELATED_RELEASE" ]
)

test_recovery_rejects_malformed_journal_without_following_targets() (
  prepare_activation_case recover-malformed || return 1
  type recover_activation >/dev/null 2>&1 || return 1
  make_complete_release "$OLD_RELEASE" || return 1
  make_complete_release "$CANDIDATE_RELEASE" || return 1
  link_release "$CURRENT_LINK" "$OLD_RELEASE" || return 1
  set_service_release "$OLD_RELEASE"
  outside="$TEST_ROOT/outside-release-sentinel"
  /bin/mkdir -p "$outside" || return 1
  printf 'keep\n' >"$outside/sentinel" || return 1
  {
    printf 'SCHEMA_VERSION=1\n'
    printf 'OLD_RELEASE=%s\n' "$OLD_RELEASE"
    printf 'CANDIDATE_RELEASE=../outside-release-sentinel\n'
  } >"$ACTIVATION_FILE"
  old_pid=$(<"$DSH_TEST_SERVICE_PID")

  ! recover_activation || return 1

  assert_release_link "$OLD_RELEASE" "$CURRENT_LINK" || return 1
  assert_eq "$old_pid" "$(<"$DSH_TEST_SERVICE_PID")" || return 1
  assert_eq keep "$(<"$outside/sentinel")" || return 1
  [ -f "$ACTIVATION_FILE" ] && [ -d "$RELEASES_DIR/$CANDIDATE_RELEASE" ]
)

test_candidate_failure_rolls_back_before_removing_candidate() (
  prepare_activation_case recover-candidate-fails || return 1
  type recover_activation >/dev/null 2>&1 || return 1
  make_complete_release "$OLD_RELEASE" || return 1
  make_complete_release "$CANDIDATE_RELEASE" || return 1
  printf 'unhealthy\n' >"$DSH_TEST_HEALTH_DIR/$CANDIDATE_RELEASE"
  link_release "$CURRENT_LINK" "$OLD_RELEASE" || return 1
  set_service_release "$OLD_RELEASE"
  write_literal_activation "$ACTIVATION_FILE" "$OLD_RELEASE" "$CANDIDATE_RELEASE"

  ! recover_activation || return 1

  assert_release_link "$OLD_RELEASE" "$CURRENT_LINK" || return 1
  assert_eq "$OLD_RELEASE" "$(<"$DSH_TEST_SERVICE_RELEASE")" || return 1
  health_state >/dev/null || return 1
  assert_journal_absent || return 1
  [ -d "$RELEASES_DIR/$OLD_RELEASE" ] || return 1
  [ ! -e "$RELEASES_DIR/$CANDIDATE_RELEASE" ] && [ ! -L "$RELEASES_DIR/$CANDIDATE_RELEASE" ]
)

test_failed_rollback_preserves_journal_and_both_releases() (
  prepare_activation_case recover-rollback-fails || return 1
  type recover_activation >/dev/null 2>&1 || return 1
  make_complete_release "$OLD_RELEASE" || return 1
  make_complete_release "$CANDIDATE_RELEASE" || return 1
  printf 'unhealthy\n' >"$DSH_TEST_HEALTH_DIR/$OLD_RELEASE"
  printf 'unhealthy\n' >"$DSH_TEST_HEALTH_DIR/$CANDIDATE_RELEASE"
  link_release "$CURRENT_LINK" "$OLD_RELEASE" || return 1
  set_service_release "$OLD_RELEASE"
  write_literal_activation "$ACTIVATION_FILE" "$OLD_RELEASE" "$CANDIDATE_RELEASE"

  ! recover_activation || return 1

  assert_release_link "$OLD_RELEASE" "$CURRENT_LINK" || return 1
  [ -f "$ACTIVATION_FILE" ] || return 1
  [ -d "$RELEASES_DIR/$OLD_RELEASE" ] && [ -d "$RELEASES_DIR/$CANDIDATE_RELEASE" ]
)

test_failed_first_install_stops_and_removes_candidate_safely() (
  prepare_activation_case recover-first-install-fails || return 1
  type recover_activation >/dev/null 2>&1 || return 1
  make_complete_release "$CANDIDATE_RELEASE" || return 1
  printf 'unhealthy\n' >"$DSH_TEST_HEALTH_DIR/$CANDIDATE_RELEASE"
  write_literal_activation "$ACTIVATION_FILE" NONE "$CANDIDATE_RELEASE"

  ! recover_activation || return 1

  assert_eq 0 "$(<"$DSH_TEST_SERVICE_LOADED")" || return 1
  [ ! -e "$CURRENT_LINK" ] && [ ! -L "$CURRENT_LINK" ] || return 1
  assert_journal_absent || return 1
  [ ! -e "$RELEASES_DIR/$CANDIDATE_RELEASE" ] && [ ! -L "$RELEASES_DIR/$CANDIDATE_RELEASE" ]
)

test_activate_writes_journal_and_links_before_restarting_candidate() (
  prepare_activation_case activate-order || return 1
  type activate_release >/dev/null 2>&1 || return 1
  make_complete_release "$OLD_RELEASE" || return 1
  make_complete_release "$CANDIDATE_RELEASE" || return 1
  make_complete_release "$STALE_RELEASE" || return 1
  link_release "$CURRENT_LINK" "$OLD_RELEASE" || return 1
  set_service_release "$OLD_RELEASE"
  order_checkpoint="$TEST_ROOT/activate-order-checkpoint"

  restart_service() {
    read_activation || return 1
    [ "$ACTIVATION_OLD_RELEASE" = "$OLD_RELEASE" ] || return 1
    [ "$ACTIVATION_CANDIDATE_RELEASE" = "$CANDIDATE_RELEASE" ] || return 1
    assert_release_link "$OLD_RELEASE" "$PREVIOUS_LINK" || return 1
    assert_release_link "$CANDIDATE_RELEASE" "$CURRENT_LINK" || return 1
    printf 'journal-and-links-ready\n' >"$order_checkpoint"
    transition_to_current_release
  }

  activate_release "$CANDIDATE_RELEASE" || return 1

  assert_eq journal-and-links-ready "$(<"$order_checkpoint")" || return 1
  assert_release_link "$CANDIDATE_RELEASE" "$CURRENT_LINK" || return 1
  assert_release_link "$OLD_RELEASE" "$PREVIOUS_LINK" || return 1
  health_state >/dev/null || return 1
  assert_journal_absent || return 1
  [ ! -e "$RELEASES_DIR/$STALE_RELEASE" ]
)

test_activate_rejects_invalid_candidate_without_publishing_journal() (
  prepare_activation_case activate-invalid || return 1
  type activate_release >/dev/null 2>&1 || return 1
  make_complete_release "$OLD_RELEASE" || return 1
  link_release "$CURRENT_LINK" "$OLD_RELEASE" || return 1
  set_service_release "$OLD_RELEASE"
  old_pid=$(<"$DSH_TEST_SERVICE_PID")

  ! activate_release '../outside' || return 1

  assert_release_link "$OLD_RELEASE" "$CURRENT_LINK" || return 1
  assert_eq "$old_pid" "$(<"$DSH_TEST_SERVICE_PID")" || return 1
  assert_journal_absent
)

test_prune_removes_only_unreferenced_physical_direct_release_children() (
  prepare_activation_case prune-direct-only || return 1
  type prune_releases >/dev/null 2>&1 || return 1
  make_complete_release "$OLD_RELEASE" || return 1
  make_complete_release "$CANDIDATE_RELEASE" || return 1
  make_complete_release "$STALE_RELEASE" || return 1
  link_release "$CURRENT_LINK" "$CANDIDATE_RELEASE" || return 1
  link_release "$PREVIOUS_LINK" "$OLD_RELEASE" || return 1

  outside="$TEST_ROOT/outside-prune-release"
  /bin/mkdir -p "$outside" || return 1
  printf 'outside sentinel\n' >"$outside/sentinel" || return 1
  /bin/ln -s "$outside" "$RELEASES_DIR/$UNRELATED_RELEASE" || return 1
  invalid_parent="$RELEASES_DIR/not-a-release"
  /bin/mkdir -p "$invalid_parent/$UNRELATED_RELEASE" || return 1
  printf 'nested sentinel\n' >"$invalid_parent/$UNRELATED_RELEASE/sentinel" || return 1

  prune_releases || return 1

  [ -d "$RELEASES_DIR/$OLD_RELEASE" ] || return 1
  [ -d "$RELEASES_DIR/$CANDIDATE_RELEASE" ] || return 1
  [ ! -e "$RELEASES_DIR/$STALE_RELEASE" ] || return 1
  [ -L "$RELEASES_DIR/$UNRELATED_RELEASE" ] || return 1
  assert_eq 'outside sentinel' "$(<"$outside/sentinel")" || return 1
  assert_eq 'nested sentinel' "$(<"$invalid_parent/$UNRELATED_RELEASE/sentinel")"
)

test_prune_rejects_empty_root_without_removing_anything() (
  prepare_activation_case prune-empty-root || return 1
  type prune_releases >/dev/null 2>&1 || return 1
  sentinel="$TEST_ROOT/prune-empty-sentinel"
  /bin/mkdir -p "$sentinel/$STALE_RELEASE" || return 1
  printf 'keep\n' >"$sentinel/$STALE_RELEASE/value" || return 1
  RELEASES_DIR=

  ! prune_releases || return 1

  assert_eq keep "$(<"$sentinel/$STALE_RELEASE/value")"
)

write_update_fakes() {
  write_fake node '
if [ "${1:-}" = --version ]; then
  printf "v22.19.0\n"
  exit 0
fi
if [ "${1:-}" = -e ]; then
  metadata_path=
  for metadata_arg in "$@"; do
    metadata_path=$metadata_arg
  done
  version=$(/usr/bin/sed -n '\''s/.*"version":"\([^" ]*\)".*/\1/p'\'' "$metadata_path")
  package_bin=$(/usr/bin/sed -n '\''s/.*"dsh":"\([^" ]*\)".*/\1/p'\'' "$metadata_path")
  [ -n "$version" ] && [ -n "$package_bin" ] || exit 65
  printf "%s\n%s\n" "$version" "$package_bin"
  exit 0
fi
cli_path=${1:-}
[ "${2:-}" = --version ] || exit 64
release_path=${cli_path%/node_modules/@deepseek-ai/dsh/lib/bin.js}
version=$(/usr/bin/sed -n "s/^DSH_VERSION=//p" "$release_path/manifest.env")
[ -n "$version" ] || exit 66
printf "@deepseek-ai/dsh %s\n" "$version"'

  write_fake npm '
if [ "${1:-}" = view ]; then
  [ "${2:-}" = @deepseek-ai/dsh@latest ] && [ "${3:-}" = version ] && [ "$#" -eq 3 ] || exit 70
  test_manager_root="$HOME/Library/Application Support/dsh-mac"
  [ -d "$test_manager_root/.lock" ] && [ ! -L "$test_manager_root/.lock" ] || exit 71
  [ -f "$test_manager_root/.lock/pid" ] || exit 72
  if [ -n "${DSH_TEST_EXPECT_CURRENT_BEFORE_VIEW:-}" ]; then
    [ ! -e "$test_manager_root/activation.env" ] && [ ! -L "$test_manager_root/activation.env" ] || exit 73
    [ "$(/usr/bin/readlink "$test_manager_root/current")" = "releases/$DSH_TEST_EXPECT_CURRENT_BEFORE_VIEW" ] || exit 74
  fi
  view_count=$(<"$DSH_TEST_VIEW_COUNT")
  view_count=$((view_count + 1))
  printf "%s\n" "$view_count" >"$DSH_TEST_VIEW_COUNT"
  printf "%s\n" "$DSH_TEST_LATEST_VERSION"
  exit 0
fi

[ "${1:-}" = install ] || exit 75
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
[ -n "$install_prefix" ] && [ -n "$package_spec" ] || exit 76
version=${package_spec#@deepseek-ai/dsh@}
/bin/mkdir -p "$install_prefix/node_modules/@deepseek-ai/dsh/lib" || exit 77
printf "{\"version\":\"%s\",\"bin\":{\"dsh\":\"lib/bin.js\"}}\n" "$version" >"$install_prefix/node_modules/@deepseek-ai/dsh/package.json" || exit 78
printf "entry\n" >"$install_prefix/node_modules/@deepseek-ai/dsh/lib/bin.js"'

  write_fake update-open '
printf "%s\n" "$*" >"$DSH_TEST_OPENED_URL"'
}

prepare_update_case() {
  update_name=$1
  prepare_activation_case "$update_name" || return 1
  write_update_fakes
  ACTIVATION_NODE="$TEST_ROOT/bin/node"
  export PATH="$TEST_ROOT/bin:/usr/bin:/bin"
  export DSH_TEST_VIEW_COUNT="$TEST_ROOT/$update_name-view-count"
  export DSH_TEST_OPENED_URL="$TEST_ROOT/$update_name-opened-url"
  export DSH_TEST_LATEST_VERSION=1.1.0
  printf '0\n' >"$DSH_TEST_VIEW_COUNT"
  : >"$DSH_TEST_OPENED_URL"
  unset DSH_TEST_EXPECT_CURRENT_BEFORE_VIEW

  /bin/mkdir -p "$DSH_MAC_ROOT/libexec" || return 1
  {
    printf '%s\n' '#!/bin/bash' 'set -u'
    printf '%s\n' '[ "${1:-}" = --check ] && [ "$#" -eq 1 ] || exit 64'
    printf '%s\n' 'release_dir="$(CDPATH= cd -P -- "$(dirname -- "$0")" && pwd)" || exit 1'
    printf '%s\n' '/usr/bin/sed -n "s/^DSH_VERSION=//p" "$release_dir/manifest.env"'
  } >"$RUNNER_TEMPLATE" || return 1
  /bin/chmod 0755 "$RUNNER_TEMPLATE" || return 1

  export DSH_MAC_LAUNCHCTL_BIN=/usr/bin/true
  export DSH_MAC_PLUTIL_BIN=/usr/bin/true
  export DSH_MAC_LSOF_BIN=/usr/bin/true
  export DSH_MAC_CURL_BIN=/usr/bin/true
  export DSH_MAC_OPEN_BIN="$TEST_ROOT/bin/update-open"
  export DSH_MAC_TAIL_BIN=/usr/bin/true
  init_command_paths
}

test_update_recovers_before_resolve_and_does_not_restart_healthy_same_version() (
  prepare_update_case update-recover-reuse || return 1
  type cmd_update >/dev/null 2>&1 || return 1
  make_complete_release "$OLD_RELEASE" || return 1
  make_complete_release "$CANDIDATE_RELEASE" || return 1
  link_release "$CURRENT_LINK" "$OLD_RELEASE" || return 1
  set_service_release "$OLD_RELEASE"
  write_literal_activation "$ACTIVATION_FILE" "$OLD_RELEASE" "$CANDIDATE_RELEASE"
  export DSH_TEST_EXPECT_CURRENT_BEFORE_VIEW="$CANDIDATE_RELEASE"
  old_pid=$(<"$DSH_TEST_SERVICE_PID")

  cmd_update || return 1

  assert_eq 1 "$(<"$DSH_TEST_VIEW_COUNT")" || return 1
  assert_eq $((old_pid + 1)) "$(<"$DSH_TEST_SERVICE_PID")" || return 1
  assert_release_link "$CANDIDATE_RELEASE" "$CURRENT_LINK" || return 1
  health_state >/dev/null || return 1
  assert_journal_absent || return 1
  [ ! -e "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ]
)

test_update_keeps_healthy_same_version_running_without_restart() (
  prepare_update_case update-healthy-reuse || return 1
  type cmd_update >/dev/null 2>&1 || return 1
  make_complete_release "$CANDIDATE_RELEASE" || return 1
  link_release "$CURRENT_LINK" "$CANDIDATE_RELEASE" || return 1
  set_service_release "$CANDIDATE_RELEASE"
  old_pid=$(<"$DSH_TEST_SERVICE_PID")

  cmd_update || return 1

  assert_eq 1 "$(<"$DSH_TEST_VIEW_COUNT")" || return 1
  assert_eq "$old_pid" "$(<"$DSH_TEST_SERVICE_PID")" || return 1
  health_state >/dev/null || return 1
  [ ! -e "$LOCK_DIR" ]
)

test_update_starts_and_verifies_a_stopped_same_version() (
  prepare_update_case update-stopped-reuse || return 1
  type cmd_update >/dev/null 2>&1 || return 1
  make_complete_release "$CANDIDATE_RELEASE" || return 1
  link_release "$CURRENT_LINK" "$CANDIDATE_RELEASE" || return 1
  old_pid=$(<"$DSH_TEST_SERVICE_PID")

  cmd_update || return 1

  assert_eq 1 "$(<"$DSH_TEST_VIEW_COUNT")" || return 1
  assert_eq 1 "$(<"$DSH_TEST_SERVICE_LOADED")" || return 1
  assert_eq "$CANDIDATE_RELEASE" "$(<"$DSH_TEST_SERVICE_RELEASE")" || return 1
  [ "$(<"$DSH_TEST_SERVICE_PID")" -gt "$old_pid" ] || return 1
  health_state >/dev/null || return 1
  [ ! -e "$LOCK_DIR" ]
)

test_update_stages_and_activates_a_new_release_transactionally() (
  prepare_update_case update-new-version || return 1
  type cmd_update >/dev/null 2>&1 || return 1
  make_complete_release "$OLD_RELEASE" || return 1
  link_release "$CURRENT_LINK" "$OLD_RELEASE" || return 1
  set_service_release "$OLD_RELEASE"

  cmd_update || return 1

  new_id=$(current_release_id) || return 1
  [ "$new_id" != "$OLD_RELEASE" ] || return 1
  read_manifest "$RELEASES_DIR/$new_id/manifest.env" || return 1
  assert_eq 1.1.0 "$MANIFEST_DSH_VERSION" || return 1
  assert_release_link "$OLD_RELEASE" "$PREVIOUS_LINK" || return 1
  assert_eq "$new_id" "$(<"$DSH_TEST_SERVICE_RELEASE")" || return 1
  health_state >/dev/null || return 1
  assert_eq 1 "$(<"$DSH_TEST_VIEW_COUNT")" || return 1
  assert_journal_absent || return 1
  [ ! -e "$LOCK_DIR" ]
)

test_read_only_status_and_open_report_and_preserve_activation_journal() (
  prepare_update_case readonly-journal || return 1
  type cmd_status >/dev/null 2>&1 || return 1
  type cmd_open >/dev/null 2>&1 || return 1
  make_complete_release "$OLD_RELEASE" || return 1
  make_complete_release "$CANDIDATE_RELEASE" || return 1
  link_release "$CURRENT_LINK" "$OLD_RELEASE" || return 1
  set_service_release "$OLD_RELEASE"
  write_literal_activation "$ACTIVATION_FILE" "$OLD_RELEASE" "$CANDIDATE_RELEASE"
  before=$(<"$ACTIVATION_FILE")

  status_output=$(cmd_status)
  status_result=$?
  assert_eq 1 "$status_result" || return 1
  case "$status_output" in
    *'Health: interrupted'*) ;;
    *) return 1 ;;
  esac
  assert_eq "$before" "$(<"$ACTIVATION_FILE")" || return 1
  ! cmd_open || return 1

  assert_eq '' "$(<"$DSH_TEST_OPENED_URL")" || return 1
  assert_eq "$before" "$(<"$ACTIVATION_FILE")" || return 1
  [ ! -e "$LOCK_DIR" ]
)

test_write_activation_publishes_a_strict_readable_journal() (
  prepare_activation_home journal-valid || return 1
  type write_activation >/dev/null 2>&1 || return 1

  write_activation "$OLD_RELEASE" "$CANDIDATE_RELEASE" || return 1
  read_activation || return 1

  expected=$(printf 'SCHEMA_VERSION=1\nOLD_RELEASE=%s\nCANDIDATE_RELEASE=%s' \
    "$OLD_RELEASE" "$CANDIDATE_RELEASE")
  assert_eq "$expected" "$(<"$ACTIVATION_FILE")" || return 1
  assert_eq "$OLD_RELEASE" "$ACTIVATION_OLD_RELEASE" || return 1
  assert_eq "$CANDIDATE_RELEASE" "$ACTIVATION_CANDIDATE_RELEASE" || return 1
  [ ! -e "$ACTIVATION_FILE.tmp.$$" ] && [ ! -L "$ACTIVATION_FILE.tmp.$$" ]
)

test_write_activation_invalid_input_preserves_existing_journal() (
  prepare_activation_home journal-invalid || return 1
  type write_activation >/dev/null 2>&1 || return 1
  write_literal_activation "$ACTIVATION_FILE" "$OLD_RELEASE" "$CANDIDATE_RELEASE"
  before=$(<"$ACTIVATION_FILE")

  ! write_activation "$OLD_RELEASE" '../outside' || return 1

  assert_eq "$before" "$(<"$ACTIVATION_FILE")" || return 1
  [ ! -e "$ACTIVATION_FILE.tmp.$$" ] && [ ! -L "$ACTIVATION_FILE.tmp.$$" ]
)

test_write_activation_does_not_follow_a_temporary_symlink() (
  prepare_activation_home journal-temp-symlink || return 1
  type write_activation >/dev/null 2>&1 || return 1
  outside="$TEST_ROOT/outside-journal-target"
  printf 'outside sentinel\n' >"$outside" || return 1
  /bin/ln -s "$outside" "$ACTIVATION_FILE.tmp.$$" || return 1

  ! write_activation "$OLD_RELEASE" "$CANDIDATE_RELEASE" || return 1

  assert_eq 'outside sentinel' "$(<"$outside")" || return 1
  [ -L "$ACTIVATION_FILE.tmp.$$" ] || return 1
  [ ! -e "$ACTIVATION_FILE" ] && [ ! -L "$ACTIVATION_FILE" ]
)

test_read_activation_rejects_a_journal_symlink_without_mutation() (
  prepare_activation_home journal-read-symlink || return 1
  outside="$TEST_ROOT/outside-readable-journal"
  write_literal_activation "$outside" "$OLD_RELEASE" "$CANDIDATE_RELEASE"
  before=$(<"$outside")
  /bin/ln -s "$outside" "$ACTIVATION_FILE" || return 1

  ! read_activation || return 1

  assert_eq "$before" "$(<"$outside")" || return 1
  [ -L "$ACTIVATION_FILE" ]
)

run_test 'journal write publishes exactly three strictly readable keys' test_write_activation_publishes_a_strict_readable_journal
run_test 'invalid journal input preserves the published journal' test_write_activation_invalid_input_preserves_existing_journal
run_test 'journal write never follows its temporary symlink' test_write_activation_does_not_follow_a_temporary_symlink
run_test 'journal reader refuses a symlink without mutation' test_read_activation_rejects_a_journal_symlink_without_mutation
run_test 'no-journal recovery keeps the complete current winner and cleans interrupted staging' test_no_journal_complete_current_wins_and_finishes_staging_cleanup
run_test 'no-journal recovery restores a missing current from complete previous' test_no_journal_missing_current_restores_complete_previous
run_test 'no-journal recovery replaces an owned current missing completion' test_no_journal_owned_incomplete_current_uses_complete_previous missing-complete
run_test 'no-journal recovery replaces an owned current with an invalid manifest' test_no_journal_owned_incomplete_current_uses_complete_previous invalid-manifest
run_test 'no-journal cleanup removes only exact incomplete physical staging children' test_no_journal_cleanup_removes_only_exact_incomplete_physical_staging_children
run_test 'malformed current fails before no-journal cleanup' test_no_journal_unsafe_link_fails_before_staging_cleanup current malformed
run_test 'out-of-root current fails before no-journal cleanup' test_no_journal_unsafe_link_fails_before_staging_cleanup current out-of-root
run_test 'non-symlink current fails before no-journal cleanup' test_no_journal_unsafe_link_fails_before_staging_cleanup current non-symlink
run_test 'unowned current target fails before no-journal cleanup' test_no_journal_unsafe_link_fails_before_staging_cleanup current unowned
run_test 'malformed previous fails before no-journal cleanup' test_no_journal_unsafe_link_fails_before_staging_cleanup previous malformed
run_test 'out-of-root previous fails before no-journal cleanup' test_no_journal_unsafe_link_fails_before_staging_cleanup previous out-of-root
run_test 'non-symlink previous fails before no-journal cleanup' test_no_journal_unsafe_link_fails_before_staging_cleanup previous non-symlink
run_test 'unowned previous target fails before no-journal cleanup' test_no_journal_unsafe_link_fails_before_staging_cleanup previous unowned
run_test 'recovery from old switches, restarts, verifies, commits, and prunes' test_recovery_from_old_switches_restarts_and_commits_candidate
run_test 'recovery force-restarts an already current healthy candidate' test_recovery_forces_restart_when_candidate_is_already_current
run_test 'first-install recovery switches, starts, and verifies candidate' test_first_install_recovery_switches_starts_and_verifies_candidate
run_test 'recovery rejects unrelated current without changing links' test_recovery_rejects_unrelated_current_without_changing_links
run_test 'recovery rejects malformed journal without following targets' test_recovery_rejects_malformed_journal_without_following_targets
run_test 'candidate failure restores and verifies old before deleting candidate' test_candidate_failure_rolls_back_before_removing_candidate
run_test 'failed rollback preserves journal and both releases' test_failed_rollback_preserves_journal_and_both_releases
run_test 'failed first install stops service and removes candidate safely' test_failed_first_install_stops_and_removes_candidate_safely
run_test 'activation journals and links before restarting candidate' test_activate_writes_journal_and_links_before_restarting_candidate
run_test 'activation rejects invalid candidate without publishing journal' test_activate_rejects_invalid_candidate_without_publishing_journal
run_test 'prune removes only unreferenced physical direct release children' test_prune_removes_only_unreferenced_physical_direct_release_children
run_test 'prune rejects an empty releases root without deletion' test_prune_rejects_empty_root_without_removing_anything
run_test 'update recovers before one latest resolve and avoids a second restart' test_update_recovers_before_resolve_and_does_not_restart_healthy_same_version
run_test 'update keeps a healthy same-version service PID unchanged' test_update_keeps_healthy_same_version_running_without_restart
run_test 'update starts and verifies a stopped same-version service' test_update_starts_and_verifies_a_stopped_same_version
run_test 'update stages and transactionally activates a new release' test_update_stages_and_activates_a_new_release_transactionally
run_test 'read-only status and open report and preserve an activation journal' test_read_only_status_and_open_report_and_preserve_activation_journal
run_test 'read-only status and open leave no-journal staging untouched' test_read_only_commands_do_not_run_no_journal_cleanup

finish_tests
