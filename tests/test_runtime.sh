#!/bin/bash
# shellcheck disable=SC1090,SC1091,SC2016,SC2030,SC2031
set -u

TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
CLI_PATH="$TESTS_DIR/../bin/dsh-service"
RUNNER_SOURCE="$TESTS_DIR/../libexec/dsh-service-run"

. "$TESTS_DIR/helpers.sh"

export DSH_SERVICE_PLATFORM=darwin

export DSH_SERVICE_SOURCE_ONLY=1
if ! . "$CLI_PATH"; then
  printf 'could not source CLI: %s\n' "$CLI_PATH" >&2
  exit 1
fi

write_runtime_fakes() {
  write_fake node '
log_line=
for arg in "$@"; do
  if [ -n "$log_line" ]; then
    log_line="$log_line|$arg"
  else
    log_line=$arg
  fi
done
printf "%s\n" "$log_line" >>"$DSH_TEST_NODE_LOG"

if [ "${1:-}" = --version ]; then
  printf "v22.19.0\n"
  exit 0
fi

if [ "${1:-}" = -e ] || [ "${1:-}" = -p ]; then
  metadata_path=
  for metadata_arg in "$@"; do
    metadata_path=$metadata_arg
  done
  [ -f "$metadata_path" ] || exit 65
  package_version=$(/usr/bin/sed -n '\''s/.*"version":"\([^" ]*\)".*/\1/p'\'' "$metadata_path")
  package_bin=$(/usr/bin/sed -n '\''s/.*"dsh":"\([^" ]*\)".*/\1/p'\'' "$metadata_path")
  [ -n "$package_version" ] && [ -n "$package_bin" ] || exit 66
  printf "%s\n%s\n" "$package_version" "$package_bin"
  exit 0
fi

cli_path=${1:-}
case "$cli_path" in
  */node_modules/@deepseek-ai/dsh/lib/bin.js)
    release_path=${cli_path%/node_modules/@deepseek-ai/dsh/lib/bin.js}
    if [ "${2:-}" = --version ]; then
      if [ "${DSH_TEST_REJECT_COMPLETE_DURING_VERSION:-0}" = 1 ] && [ -e "$release_path/.complete" ]; then
        exit 70
      fi
      [ "${DSH_TEST_CLI_FAIL:-0}" != 1 ] || exit 71
      if [ "${DSH_TEST_CLI_OUTPUT+x}" = x ]; then
        printf "%s\n" "$DSH_TEST_CLI_OUTPUT"
        exit 0
      elif [ -n "${DSH_TEST_CLI_VERSION_OVERRIDE:-}" ]; then
        cli_version=$DSH_TEST_CLI_VERSION_OVERRIDE
      else
        cli_version=$(/usr/bin/sed -n '\''s/.*"version":"\([^" ]*\)".*/\1/p'\'' "$release_path/node_modules/@deepseek-ai/dsh/package.json")
      fi
      printf "@deepseek-ai/dsh %s\n" "$cli_version"
      exit 0
    fi
    [ "${2:-}" = web ] || exit 72
    exit 0
    ;;
esac

exit 73'

  write_fake npm '
log_line=
for arg in "$@"; do
  if [ -n "$log_line" ]; then
    log_line="$log_line|$arg"
  else
    log_line=$arg
  fi
done
printf "%s\n" "$log_line" >>"$DSH_TEST_NPM_LOG"

if [ "${1:-}" = view ] && [ "${2:-}" = @deepseek-ai/dsh@latest ] && [ "${3:-}" = version ] && [ "$#" -eq 3 ]; then
  [ "${DSH_TEST_NPM_FAIL_VIEW:-0}" != 1 ] || exit 80
  printf "%s\n" "${DSH_TEST_LATEST_VERSION:-0.1.0-rc.6}"
  exit 0
fi

[ "${1:-}" = install ] || exit 81
[ "${DSH_TEST_NPM_FAIL_INSTALL:-0}" != 1 ] || exit 82
shift
install_prefix=
package_spec=
lock_disabled=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix)
      [ "$#" -ge 2 ] || exit 83
      install_prefix=$2
      shift 2
      ;;
    @deepseek-ai/dsh@*)
      package_spec=$1
      shift
      ;;
    --package-lock=false)
      lock_disabled=1
      shift
      ;;
    *) shift ;;
  esac
done
[ -n "$install_prefix" ] && [ -n "$package_spec" ] || exit 84
package_version=${DSH_TEST_PACKAGE_VERSION:-${package_spec#@deepseek-ai/dsh@}}
/bin/mkdir -p "$install_prefix/node_modules/@deepseek-ai/dsh/lib" || exit 85
printf "{\"version\":\"%s\",\"bin\":{\"dsh\":\"lib/bin.js\"}}\n" "$package_version" >"$install_prefix/node_modules/@deepseek-ai/dsh/package.json" || exit 86
printf "entry\n" >"$install_prefix/node_modules/@deepseek-ai/dsh/lib/bin.js" || exit 87
if [ "$lock_disabled" -ne 1 ]; then
  printf "lock\n" >"$install_prefix/package-lock.json" || exit 88
fi
exit 0'
}

prepare_runtime_home() {
  runtime_name=$1
  export HOME="$TEST_ROOT/home-$runtime_name"
  /bin/mkdir -p "$HOME" || return 1
  init_paths
  export DSH_TEST_NPM_LOG="$TEST_ROOT/$runtime_name-npm.log"
  export DSH_TEST_NODE_LOG="$TEST_ROOT/$runtime_name-node.log"
  : >"$DSH_TEST_NPM_LOG"
  : >"$DSH_TEST_NODE_LOG"
  unset DSH_TEST_NPM_FAIL_VIEW DSH_TEST_NPM_FAIL_INSTALL
  unset DSH_TEST_PACKAGE_VERSION DSH_TEST_CLI_FAIL
  unset DSH_TEST_CLI_OUTPUT DSH_TEST_CLI_VERSION_OVERRIDE
  unset DSH_TEST_REJECT_COMPLETE_DURING_VERSION
  export DSH_TEST_LATEST_VERSION=0.1.0-rc.6
  write_runtime_fakes
  export PATH="$TEST_ROOT/bin:/usr/bin:/bin"
  NODE_BIN="$TEST_ROOT/bin/node"
  NPM_BIN="$TEST_ROOT/bin/npm"
  NODE_VERSION=22.19.0
}

install_manager_runner() {
  [ -f "$RUNNER_SOURCE" ] && [ -x "$RUNNER_SOURCE" ] || return 1
  /bin/mkdir -p "$DSH_SERVICE_ROOT/libexec" || return 1
  /bin/cp "$RUNNER_SOURCE" "$DSH_SERVICE_ROOT/libexec/dsh-service-run" || return 1
  /bin/chmod 0755 "$DSH_SERVICE_ROOT/libexec/dsh-service-run"
}

count_log_line() {
  wanted_line=$1
  log_path=$2
  matched_lines=0
  while IFS= read -r actual_line || [ -n "$actual_line" ]; do
    if [ "$actual_line" = "$wanted_line" ]; then
      matched_lines=$((matched_lines + 1))
    fi
  done <"$log_path"
  printf '%s\n' "$matched_lines"
}

count_log_prefix() {
  wanted_prefix=$1
  log_path=$2
  matched_lines=0
  while IFS= read -r actual_line || [ -n "$actual_line" ]; do
    case "$actual_line" in
      "$wanted_prefix"*) matched_lines=$((matched_lines + 1)) ;;
    esac
  done <"$log_path"
  printf '%s\n' "$matched_lines"
}

count_log_suffix() {
  wanted_suffix=$1
  log_path=$2
  matched_lines=0
  while IFS= read -r actual_line || [ -n "$actual_line" ]; do
    case "$actual_line" in
      *"$wanted_suffix") matched_lines=$((matched_lines + 1)) ;;
    esac
  done <"$log_path"
  printf '%s\n' "$matched_lines"
}

first_log_line_with_prefix() {
  wanted_prefix=$1
  log_path=$2
  while IFS= read -r actual_line || [ -n "$actual_line" ]; do
    case "$actual_line" in
      "$wanted_prefix"*) printf '%s\n' "$actual_line"; return 0 ;;
    esac
  done <"$log_path"
  return 1
}

assert_call_has_token() {
  call_line=$1
  wanted_token=$2
  case "|$call_line|" in
    *"|$wanted_token|"*) return 0 ;;
  esac
  printf 'call <%s> did not contain argv token <%s>\n' "$call_line" "$wanted_token" >&2
  return 1
}

assert_no_release_link_temps() {
  temp_parent=$1
  for temp_path in "$temp_parent"/.release-link-*; do
    if [ -e "$temp_path" ] || [ -L "$temp_path" ]; then
      printf 'unexpected release-link temp: %s\n' "$temp_path" >&2
      return 1
    fi
  done
}

stage_successfully() {
  stage_release || return 1
  [ -n "${STAGED_RELEASE_ID:-}" ] || {
    printf 'stage_release did not set STAGED_RELEASE_ID\n' >&2
    return 1
  }
  [ -d "$RELEASES_DIR/$STAGED_RELEASE_ID" ] || return 1
}

write_runner_manifest() {
  runner_release=$1
  runner_node=$2
  runner_cli=$3
  runner_version=${4:-0.1.0-rc.6}
  {
    printf 'SCHEMA_VERSION=1\n'
    printf 'DSH_VERSION=%s\n' "$runner_version"
    printf 'NODE_BIN=%s\n' "$runner_node"
    printf 'CLI_RELATIVE=%s\n' "$runner_cli"
    printf 'INSTALLED_AT=1786640000\n'
  } >"$runner_release/manifest.env"
}

prepare_runner_release() {
  runner_name=$1
  prepare_runtime_home "runner-$runner_name" || return 1
  [ -f "$RUNNER_SOURCE" ] && [ -x "$RUNNER_SOURCE" ] || return 1
  RUNNER_RELEASE="$TEST_ROOT/release $runner_name & data"
  /bin/mkdir -p "$RUNNER_RELEASE/node_modules/@deepseek-ai/dsh/lib" || return 1
  /bin/cp "$RUNNER_SOURCE" "$RUNNER_RELEASE/run" || return 1
  /bin/chmod 0755 "$RUNNER_RELEASE/run" || return 1
  printf 'entry\n' >"$RUNNER_RELEASE/node_modules/@deepseek-ai/dsh/lib/bin.js" || return 1
  printf '{"version":"0.1.0-rc.6","bin":{"dsh":"lib/bin.js"}}\n' >"$RUNNER_RELEASE/node_modules/@deepseek-ai/dsh/package.json" || return 1
  write_runner_manifest "$RUNNER_RELEASE" "$NODE_BIN" 'node_modules/@deepseek-ai/dsh/lib/bin.js'
}

test_resolve_node_and_npm_sets_absolute_supported_tools() (
  prepare_runtime_home resolve-tools || return 1
  NODE_BIN=
  NPM_BIN=
  NODE_VERSION=
  resolve_node_and_npm || return 1
  assert_eq "$TEST_ROOT/bin/node" "$NODE_BIN" || return 1
  assert_eq "$TEST_ROOT/bin/npm" "$NPM_BIN" || return 1
  assert_eq 22.19.0 "$NODE_VERSION"
)

test_stage_resolves_latest_once_and_installs_exact_package() (
  prepare_runtime_home exact-install || return 1
  install_manager_runner || return 1
  stage_successfully || return 1

  assert_eq 1 "$(count_log_line 'view|@deepseek-ai/dsh@latest|version' "$DSH_TEST_NPM_LOG")" || return 1
  assert_eq 1 "$(count_log_prefix 'install|' "$DSH_TEST_NPM_LOG")" || return 1
  install_call=$(first_log_line_with_prefix 'install|' "$DSH_TEST_NPM_LOG") || return 1
  assert_call_has_token "$install_call" '@deepseek-ai/dsh@0.1.0-rc.6' || return 1
  assert_call_has_token "$install_call" '--no-save' || return 1
  assert_call_has_token "$install_call" '--package-lock=false' || return 1
  assert_call_has_token "$install_call" '--omit=dev' || return 1
  assert_call_has_token "$install_call" '--no-audit' || return 1
  assert_call_has_token "$install_call" '--no-fund' || return 1
  [ ! -e "$RELEASES_DIR/$STAGED_RELEASE_ID/package-lock.json" ]
)

test_stage_rejects_malformed_latest_without_installing() (
  prepare_runtime_home malformed-latest || return 1
  install_manager_runner || return 1
  export DSH_TEST_LATEST_VERSION='0.1.0;touch-pwned'
  ! stage_release || return 1
  assert_eq 1 "$(count_log_line 'view|@deepseek-ai/dsh@latest|version' "$DSH_TEST_NPM_LOG")" || return 1
  assert_eq 0 "$(count_log_prefix 'install|' "$DSH_TEST_NPM_LOG")" || return 1
  [ ! -e "$RELEASES_DIR" ]
)

test_stage_rejects_package_cli_symlink_escape() (
  prepare_runtime_home cli-symlink || return 1
  install_manager_runner || return 1
  real_npm="$NPM_BIN"
  write_fake npm-symlink '
"$DSH_TEST_REAL_NPM" "$@" || exit $?
if [ "${1:-}" != install ]; then
  exit 0
fi
shift
install_prefix=
while [ "$#" -gt 0 ]; do
  if [ "$1" = --prefix ]; then
    install_prefix=$2
    break
  fi
  shift
done
[ -n "$install_prefix" ] || exit 91
/bin/rm -f "$install_prefix/node_modules/@deepseek-ai/dsh/lib/bin.js" || exit 92
/bin/ln -s /bin/true "$install_prefix/node_modules/@deepseek-ai/dsh/lib/bin.js"'
  export DSH_TEST_REAL_NPM="$real_npm"
  NPM_BIN="$TEST_ROOT/bin/npm-symlink"

  ! stage_release || return 1
  for staged_path in "$RELEASES_DIR"/.staging-* "$RELEASES_DIR"/0.1.0-rc.6-*; do
    [ ! -e "$staged_path" ] || [ -L "$staged_path" ] || return 1
  done
)

test_stage_records_runtime_and_validated_cli_before_completion() (
  prepare_runtime_home manifest || return 1
  install_manager_runner || return 1
  export DSH_TEST_REJECT_COMPLETE_DURING_VERSION=1
  stage_successfully || return 1
  release_path="$RELEASES_DIR/$STAGED_RELEASE_ID"

  read_manifest "$release_path/manifest.env" || return 1
  assert_eq 0.1.0-rc.6 "$MANIFEST_DSH_VERSION" || return 1
  assert_eq "$TEST_ROOT/bin/node" "$MANIFEST_NODE_BIN" || return 1
  assert_eq 'node_modules/@deepseek-ai/dsh/lib/bin.js' "$MANIFEST_CLI_RELATIVE" || return 1
  [ -f "$release_path/.complete" ] || return 1
  assert_eq 1 "$(count_log_suffix '/node_modules/@deepseek-ai/dsh/lib/bin.js|--version' "$DSH_TEST_NODE_LOG")" || return 1
  check_output=$("$release_path/run" --check) || return 1
  assert_eq 0.1.0-rc.6 "$check_output"
)

test_stage_writes_completion_only_after_runner_check() (
  prepare_runtime_home runner-order || return 1
  /bin/mkdir -p "$DSH_SERVICE_ROOT/libexec" || return 1
  runner_probe_log="$TEST_ROOT/runner-probe.log"
  export DSH_TEST_RUNNER_PROBE_LOG="$runner_probe_log"
  {
    printf '%s\n' '#!/bin/bash' 'set -u'
    printf '%s\n' 'probe_dir="$(CDPATH= cd -P -- "$(dirname -- "$0")" && pwd)" || exit 1'
    printf '%s\n' '[ "${1:-}" = --check ] && [ "$#" -eq 1 ] || exit 64'
    printf '%s\n' '[ ! -e "$probe_dir/.complete" ] || exit 90'
    printf '%s\n' 'printf "checked\n" >>"$DSH_TEST_RUNNER_PROBE_LOG"'
    printf '%s\n' 'printf "0.1.0-rc.6\n"'
  } >"$DSH_SERVICE_ROOT/libexec/dsh-service-run" || return 1
  /bin/chmod 0755 "$DSH_SERVICE_ROOT/libexec/dsh-service-run" || return 1

  stage_successfully || return 1
  assert_eq checked "$(<"$runner_probe_log")" || return 1
  [ -f "$RELEASES_DIR/$STAGED_RELEASE_ID/.complete" ]
)

test_stage_requires_cli_version_to_match_package() (
  prepare_runtime_home version-mismatch || return 1
  install_manager_runner || return 1
  export DSH_TEST_CLI_VERSION_OVERRIDE=9.9.9
  ! stage_release || return 1
  for staged_path in "$RELEASES_DIR"/.staging-* "$RELEASES_DIR"/0.1.0-rc.6-*; do
    [ ! -e "$staged_path" ] || return 1
  done
)

test_stage_rejects_version_prefix_collision() (
  prepare_runtime_home stage-prefix-collision || return 1
  install_manager_runner || return 1
  export DSH_TEST_CLI_OUTPUT='@deepseek-ai/dsh 0.1.0-rc.60'

  ! stage_release || return 1
  for staged_path in "$RELEASES_DIR"/.staging-* "$RELEASES_DIR"/0.1.0-rc.6-*; do
    [ ! -e "$staged_path" ] || return 1
  done
)

test_validate_release_rejects_version_prefix_collision() (
  prepare_runtime_home validate-prefix-collision || return 1
  install_manager_runner || return 1
  stage_successfully || return 1
  release_path="$RELEASES_DIR/$STAGED_RELEASE_ID"
  export DSH_TEST_CLI_OUTPUT='@deepseek-ai/dsh 0.1.0-rc.60'

  ! validate_release "$release_path"
)

test_current_matches_rejects_version_prefix_collision() (
  prepare_runtime_home current-prefix-collision || return 1
  install_manager_runner || return 1
  stage_successfully || return 1
  release_id=$STAGED_RELEASE_ID
  atomic_release_link "$CURRENT_LINK" "$release_id" || return 1
  export DSH_TEST_CLI_OUTPUT='@deepseek-ai/dsh 0.1.0-rc.60'

  ! current_matches 0.1.0-rc.6
)

test_validate_release_rejects_ambiguous_version_output() (
  prepare_runtime_home ambiguous-version || return 1
  install_manager_runner || return 1
  stage_successfully || return 1
  release_path="$RELEASES_DIR/$STAGED_RELEASE_ID"

  export DSH_TEST_CLI_OUTPUT='dsh 0.1.0-rc.6 next 0.1.0-rc.7'
  ! validate_release "$release_path" || return 1
  export DSH_TEST_CLI_OUTPUT='dsh 0.1.0-rc.6
extra output'
  ! validate_release "$release_path"
)

test_stage_creates_unique_final_releases() (
  prepare_runtime_home unique || return 1
  install_manager_runner || return 1
  stage_successfully || return 1
  first_release=$STAGED_RELEASE_ID
  stage_successfully || return 1
  second_release=$STAGED_RELEASE_ID
  [ "$first_release" != "$second_release" ] || return 1
  [ -d "$RELEASES_DIR/$first_release" ] && [ -d "$RELEASES_DIR/$second_release" ]
)

test_npm_failure_leaves_current_release_untouched() (
  prepare_runtime_home npm-failure || return 1
  install_manager_runner || return 1
  old_release=0.0.9-1786630000-1200
  /bin/mkdir -p "$RELEASES_DIR/$old_release" || return 1
  /bin/ln -s "releases/$old_release" "$CURRENT_LINK" || return 1
  export DSH_TEST_NPM_FAIL_INSTALL=1
  ! stage_release || return 1
  assert_eq "releases/$old_release" "$(/usr/bin/readlink "$CURRENT_LINK")"
)

test_validation_failure_leaves_current_release_untouched() (
  prepare_runtime_home validation-failure || return 1
  install_manager_runner || return 1
  old_release=0.0.9-1786630000-1200
  /bin/mkdir -p "$RELEASES_DIR/$old_release" || return 1
  /bin/ln -s "releases/$old_release" "$CURRENT_LINK" || return 1
  export DSH_TEST_CLI_FAIL=1
  ! stage_release || return 1
  assert_eq "releases/$old_release" "$(/usr/bin/readlink "$CURRENT_LINK")" || return 1
  for staged_path in "$RELEASES_DIR"/.staging-* "$RELEASES_DIR"/0.1.0-rc.6-*; do
    [ ! -e "$staged_path" ] || return 1
  done
)

test_current_matches_returns_healthy_release_without_reinstalling() (
  prepare_runtime_home current-match || return 1
  install_manager_runner || return 1
  stage_successfully || return 1
  first_release=$STAGED_RELEASE_ID
  atomic_release_link "$CURRENT_LINK" "$first_release" || return 1
  : >"$DSH_TEST_NPM_LOG"
  : >"$DSH_TEST_NODE_LOG"

  stage_successfully || return 1
  assert_eq "$first_release" "$STAGED_RELEASE_ID" || return 1
  assert_eq "$first_release" "$(current_matches 0.1.0-rc.6)" || return 1
  assert_eq 1 "$(count_log_line 'view|@deepseek-ai/dsh@latest|version' "$DSH_TEST_NPM_LOG")" || return 1
  assert_eq 0 "$(count_log_prefix 'install|' "$DSH_TEST_NPM_LOG")"
)

test_current_matches_rejects_releases_symlink_outside_root() (
  prepare_runtime_home current-outside-releases || return 1
  install_manager_runner || return 1
  stage_successfully || return 1
  release_id=$STAGED_RELEASE_ID
  atomic_release_link "$CURRENT_LINK" "$release_id" || return 1
  outside_releases="$TEST_ROOT/outside-current-releases"
  /bin/mv "$RELEASES_DIR" "$outside_releases" || return 1
  /bin/ln -s "$outside_releases" "$RELEASES_DIR" || return 1

  ! current_matches 0.1.0-rc.6
)

test_release_validation_requires_completion_marker() (
  prepare_runtime_home validate-release || return 1
  install_manager_runner || return 1
  stage_successfully || return 1
  release_path="$RELEASES_DIR/$STAGED_RELEASE_ID"
  validate_release "$release_path" || return 1
  /bin/rm -f "$release_path/.complete" || return 1
  ! validate_release "$release_path"
)

test_atomic_links_and_current_release_id_use_release_ids() (
  prepare_runtime_home links || return 1
  first_release=0.1.0-1786630000-1200
  second_release=0.1.1-1786640000-1201
  /bin/mkdir -p "$RELEASES_DIR/$first_release" "$RELEASES_DIR/$second_release" || return 1
  atomic_release_link "$CURRENT_LINK" "$first_release" || return 1
  assert_eq "$first_release" "$(current_release_id)" || return 1
  atomic_release_link "$PREVIOUS_LINK" "$second_release" || return 1
  assert_eq "releases/$second_release" "$(/usr/bin/readlink "$PREVIOUS_LINK")"
)

test_atomic_release_link_rejects_releases_symlink_outside_root() (
  prepare_runtime_home link-outside-releases || return 1
  release_id=0.1.0-1786630000-1200
  /bin/mkdir -p "$RELEASES_DIR/$release_id" || return 1
  outside_releases="$TEST_ROOT/outside-link-releases"
  /bin/mv "$RELEASES_DIR" "$outside_releases" || return 1
  /bin/ln -s "$outside_releases" "$RELEASES_DIR" || return 1

  ! atomic_release_link "$CURRENT_LINK" "$release_id" || return 1
  [ ! -e "$CURRENT_LINK" ] && [ ! -L "$CURRENT_LINK" ]
)

test_atomic_release_link_rejects_current_directory_target() (
  prepare_runtime_home current-directory-target || return 1
  release_id=0.1.0-1786630000-1200
  /bin/mkdir -p "$RELEASES_DIR/$release_id" "$CURRENT_LINK" || return 1

  ! atomic_release_link "$CURRENT_LINK" "$release_id" || return 1
  [ -d "$CURRENT_LINK" ] && [ ! -L "$CURRENT_LINK" ]
)

test_atomic_release_link_rejects_previous_directory_target() (
  prepare_runtime_home previous-directory-target || return 1
  release_id=0.1.0-1786630000-1200
  /bin/mkdir -p "$RELEASES_DIR/$release_id" "$PREVIOUS_LINK" || return 1

  ! atomic_release_link "$PREVIOUS_LINK" "$release_id" || return 1
  [ -d "$PREVIOUS_LINK" ] && [ ! -L "$PREVIOUS_LINK" ]
)

test_atomic_release_link_replaces_existing_current_symlink() (
  prepare_runtime_home replace-current || return 1
  old_release=0.1.0-1786630000-1200
  new_release=0.1.1-1786640000-1201
  /bin/mkdir -p "$RELEASES_DIR/$old_release" "$RELEASES_DIR/$new_release" || return 1
  atomic_release_link "$CURRENT_LINK" "$old_release" || return 1

  test_status=0
  atomic_release_link "$CURRENT_LINK" "$new_release" || test_status=1
  actual_target=$(/usr/bin/readlink "$CURRENT_LINK" 2>/dev/null) || actual_target=NOT_A_LINK
  assert_eq "releases/$new_release" "$actual_target" || test_status=1
  assert_no_release_link_temps "$RELEASES_DIR/$old_release" || test_status=1
  assert_no_release_link_temps "$RELEASES_DIR" || test_status=1
  assert_no_release_link_temps "$DSH_SERVICE_ROOT" || test_status=1
  return "$test_status"
)

test_atomic_release_link_replaces_existing_previous_symlink() (
  prepare_runtime_home replace-previous || return 1
  old_release=0.1.0-1786630000-1200
  new_release=0.1.1-1786640000-1201
  /bin/mkdir -p "$RELEASES_DIR/$old_release" "$RELEASES_DIR/$new_release" || return 1
  atomic_release_link "$PREVIOUS_LINK" "$old_release" || return 1

  test_status=0
  atomic_release_link "$PREVIOUS_LINK" "$new_release" || test_status=1
  actual_target=$(/usr/bin/readlink "$PREVIOUS_LINK" 2>/dev/null) || actual_target=NOT_A_LINK
  assert_eq "releases/$new_release" "$actual_target" || test_status=1
  assert_no_release_link_temps "$RELEASES_DIR/$old_release" || test_status=1
  assert_no_release_link_temps "$RELEASES_DIR" || test_status=1
  assert_no_release_link_temps "$DSH_SERVICE_ROOT" || test_status=1
  return "$test_status"
)

test_installed_cli_uses_manager_owned_runner_without_sibling_libexec() (
  prepare_runtime_home installed-copy || return 1
  install_manager_runner || return 1
  installed_cli="$HOME/.local/bin/dsh-service"
  /bin/mkdir -p "$(dirname "$installed_cli")" || return 1
  /bin/cp "$CLI_PATH" "$installed_cli" || return 1
  /bin/chmod 0755 "$installed_cli" || return 1
  [ ! -e "$HOME/.local/libexec" ] || return 1

  DSH_SERVICE_SOURCE_ONLY=1 /bin/bash -c '
    . "$1" || exit 1
    NODE_BIN=$2
    NPM_BIN=$3
    NODE_VERSION=22.19.0
    stage_release
  ' installed-runtime "$installed_cli" "$NODE_BIN" "$NPM_BIN" || return 1

  release_count=0
  for release_path in "$RELEASES_DIR"/0.1.0-rc.6-*; do
    [ -d "$release_path" ] || continue
    release_count=$((release_count + 1))
    [ -x "$release_path/run" ] || return 1
  done
  assert_eq 1 "$release_count"
)

test_runner_check_accepts_special_release_path_without_completion() (
  prepare_runner_release special || return 1
  output=$("$RUNNER_RELEASE/run" --check) || return 1
  assert_eq 0.1.0-rc.6 "$output" || return 1
  assert_eq '' "$(<"$DSH_TEST_NODE_LOG")"
)

test_runner_normal_mode_requires_completion_before_exec() (
  prepare_runner_release incomplete || return 1
  ! "$RUNNER_RELEASE/run" || return 1
  assert_eq '' "$(<"$DSH_TEST_NODE_LOG")" || return 1
  : >"$RUNNER_RELEASE/.complete"
  "$RUNNER_RELEASE/run" || return 1
  physical_release=$(CDPATH='' cd -P -- "$RUNNER_RELEASE" && pwd) || return 1
  expected_call="$physical_release/node_modules/@deepseek-ai/dsh/lib/bin.js|web|--host|127.0.0.1|--port|3080"
  assert_eq "$expected_call" "$(<"$DSH_TEST_NODE_LOG")"
)

test_runner_rejects_missing_node_without_execution() (
  prepare_runner_release missing-node || return 1
  write_runner_manifest "$RUNNER_RELEASE" "$TEST_ROOT/does-not-exist" 'node_modules/@deepseek-ai/dsh/lib/bin.js'
  ! "$RUNNER_RELEASE/run" --check || return 1
  assert_eq '' "$(<"$DSH_TEST_NODE_LOG")"
)

test_runner_rejects_malformed_manifest_without_execution() (
  prepare_runner_release malformed || return 1
  printf 'SURPRISE=value\n' >>"$RUNNER_RELEASE/manifest.env"
  ! "$RUNNER_RELEASE/run" --check || return 1
  assert_eq '' "$(<"$DSH_TEST_NODE_LOG")"
)

test_runner_rejects_parent_walking_cli_without_execution() (
  prepare_runner_release parent-walk || return 1
  printf 'outside\n' >"$RUNNER_RELEASE/../outside.js"
  write_runner_manifest "$RUNNER_RELEASE" "$NODE_BIN" '../outside.js'
  ! "$RUNNER_RELEASE/run" --check || return 1
  assert_eq '' "$(<"$DSH_TEST_NODE_LOG")"
)

test_runner_rejects_cli_symlink_escape_without_execution() (
  prepare_runner_release symlink-escape || return 1
  /bin/rm -f "$RUNNER_RELEASE/node_modules/@deepseek-ai/dsh/lib/bin.js" || return 1
  /bin/ln -s /bin/true "$RUNNER_RELEASE/node_modules/@deepseek-ai/dsh/lib/bin.js" || return 1
  ! "$RUNNER_RELEASE/run" --check || return 1
  assert_eq '' "$(<"$DSH_TEST_NODE_LOG")"
)

run_test 'Node and npm resolver returns supported absolute tools' test_resolve_node_and_npm_sets_absolute_supported_tools
run_test 'staging resolves latest once and installs the exact package with safe npm flags' test_stage_resolves_latest_once_and_installs_exact_package
run_test 'staging rejects malformed latest before npm install' test_stage_rejects_malformed_latest_without_installing
run_test 'staging rejects a package CLI symlink escape' test_stage_rejects_package_cli_symlink_escape
run_test 'staging records absolute Node and safe CLI then probes before completion' test_stage_records_runtime_and_validated_cli_before_completion
run_test 'staging writes completion only after the copied runner check' test_stage_writes_completion_only_after_runner_check
run_test 'staging rejects a CLI version that does not match the package' test_stage_requires_cli_version_to_match_package
run_test 'staging rejects a CLI version prefix collision' test_stage_rejects_version_prefix_collision
run_test 'release validation rejects a CLI version prefix collision' test_validate_release_rejects_version_prefix_collision
run_test 'current match rejects a CLI version prefix collision' test_current_matches_rejects_version_prefix_collision
run_test 'release validation rejects ambiguous CLI version output' test_validate_release_rejects_ambiguous_version_output
run_test 'staging gives successive installs unique final release IDs' test_stage_creates_unique_final_releases
run_test 'npm failure leaves current untouched' test_npm_failure_leaves_current_release_untouched
run_test 'validation failure leaves current untouched' test_validation_failure_leaves_current_release_untouched
run_test 'healthy matching current release avoids npm install' test_current_matches_returns_healthy_release_without_reinstalling
run_test 'current match rejects releases symlinked outside manager root' test_current_matches_rejects_releases_symlink_outside_root
run_test 'release validation requires the completion marker' test_release_validation_requires_completion_marker
run_test 'atomic release links expose validated current IDs' test_atomic_links_and_current_release_id_use_release_ids
run_test 'atomic release link rejects releases symlinked outside manager root' test_atomic_release_link_rejects_releases_symlink_outside_root
run_test 'atomic release link rejects current directory target' test_atomic_release_link_rejects_current_directory_target
run_test 'atomic release link rejects previous directory target' test_atomic_release_link_rejects_previous_directory_target
run_test 'atomic release link replaces existing current symlink' test_atomic_release_link_replaces_existing_current_symlink
run_test 'atomic release link replaces existing previous symlink' test_atomic_release_link_replaces_existing_previous_symlink
run_test 'installed CLI stages with manager-owned runner and no sibling libexec' test_installed_cli_uses_manager_owned_runner_without_sibling_libexec
run_test 'runner check accepts spaces and ampersand before completion' test_runner_check_accepts_special_release_path_without_completion
run_test 'runner normal mode requires completion before Web exec' test_runner_normal_mode_requires_completion_before_exec
run_test 'runner rejects missing Node without executing' test_runner_rejects_missing_node_without_execution
run_test 'runner rejects malformed manifest without executing' test_runner_rejects_malformed_manifest_without_execution
run_test 'runner rejects parent-walking CLI without executing' test_runner_rejects_parent_walking_cli_without_execution
run_test 'runner rejects CLI symlink escape without executing' test_runner_rejects_cli_symlink_escape_without_execution

finish_tests
