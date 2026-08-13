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

run_launchd_tests() {
  /bin/bash "$TESTS_DIR/test_launchd.sh"
}

run_activation_tests() {
  /bin/bash "$TESTS_DIR/test_activation.sh"
}

run_command_tests() {
  /bin/bash "$TESTS_DIR/test_commands.sh"
}

run_test 'foundation test suite' run_foundation_tests
run_test 'runtime test suite' run_runtime_tests
run_test 'launchd test suite' run_launchd_tests
run_test 'activation test suite' run_activation_tests
run_test 'command test suite' run_command_tests

finish_tests
