#!/bin/bash
# shellcheck disable=SC1091
set -u

TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$TESTS_DIR/.." && pwd)"

. "$TESTS_DIR/helpers.sh"

repository_is_complete() {
  [ ! -e "$REPO_ROOT/docs/superpowers" ] || {
    printf 'internal Superpowers documents must not be published: %s\n' "$REPO_ROOT/docs/superpowers" >&2
    return 1
  }

  for ignore_pattern in '.superpowers/' 'docs/research/' 'docs/superpowers/'; do
    /usr/bin/grep -Fqx -- "$ignore_pattern" "$REPO_ROOT/.gitignore" || {
      printf 'missing internal-document ignore rule: %s\n' "$ignore_pattern" >&2
      return 1
    }
  done

  for executable_path in \
    "$REPO_ROOT/bin/dsh-service" \
    "$REPO_ROOT/libexec/dsh-service-run" \
    "$REPO_ROOT/install.sh"; do
    [ -x "$executable_path" ] || {
      printf 'required executable is missing: %s\n' "$executable_path" >&2
      return 1
    }
  done

  for document_path in "$REPO_ROOT/README.md" "$REPO_ROOT/LICENSE"; do
    [ -s "$document_path" ] || {
      printf 'required document is missing or empty: %s\n' "$document_path" >&2
      return 1
    }
  done

  workflow_path="$REPO_ROOT/.github/workflows/ci.yml"
  [ -s "$workflow_path" ] || {
    printf 'required CI workflow is missing or empty: %s\n' "$workflow_path" >&2
    return 1
  }
  for workflow_requirement in macos-latest 'bash -n' shellcheck tests/run.sh; do
    /usr/bin/grep -F -- "$workflow_requirement" "$workflow_path" >/dev/null || {
      printf 'CI workflow is missing required content: %s\n' "$workflow_requirement" >&2
      return 1
    }
  done
}

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

run_test 'repository completeness' repository_is_complete
run_test 'foundation test suite' run_foundation_tests
run_test 'runtime test suite' run_runtime_tests
run_test 'launchd test suite' run_launchd_tests
run_test 'activation test suite' run_activation_tests
run_test 'command test suite' run_command_tests

finish_tests
