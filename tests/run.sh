#!/bin/bash
set -u

TESTS_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

. "$TESTS_DIR/helpers.sh"

run_foundation_tests() {
  /bin/bash "$TESTS_DIR/test_foundation.sh"
}

run_runtime_tests() {
  /bin/bash "$TESTS_DIR/test_runtime.sh"
}

run_test 'foundation test suite' run_foundation_tests
run_test 'runtime test suite' run_runtime_tests

finish_tests
