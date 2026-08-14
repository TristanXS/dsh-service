#!/bin/bash
set -u

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dsh-service-tests.XXXXXX")"
export HOME="$TEST_ROOT/home"
export DSH_SERVICE_TESTING=1
mkdir -p "$HOME" "$TEST_ROOT/bin"

cleanup_test_root() {
  case "$TEST_ROOT" in
    "${TMPDIR:-/tmp}"/dsh-service-tests.*) /bin/rm -rf -- "$TEST_ROOT" ;;
    *) printf 'unsafe test root: %s\n' "$TEST_ROOT" >&2; return 1 ;;
  esac
}
trap cleanup_test_root EXIT INT TERM

assert_eq() {
  [ "$1" = "$2" ] || {
    printf 'expected <%s>, got <%s>\n' "$1" "$2" >&2
    return 1
  }
}

FAILURES=0
run_test() {
  test_name=$1
  shift
  if "$@"; then
    printf 'ok - %s\n' "$test_name"
  else
    printf 'not ok - %s\n' "$test_name" >&2
    FAILURES=$((FAILURES + 1))
  fi
}
finish_tests() {
  [ "$FAILURES" -eq 0 ]
}

write_fake() {
  fake_name=$1
  fake_body=$2
  fake_path="$TEST_ROOT/bin/$fake_name"
  {
    printf '%s\n' '#!/bin/bash' 'set -u'
    printf '%s\n' "$fake_body"
  } >"$fake_path"
  chmod 0755 "$fake_path"
}
