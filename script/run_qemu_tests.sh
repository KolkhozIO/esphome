#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${1:-tests/qemu/openeth_qemu.yaml}"
QEMU_TIMEOUT="${QEMU_TIMEOUT:-60}"

if [[ -z "${IDF_PATH:-}" ]]; then
  echo "IDF_PATH is not set. Please source the ESP-IDF environment." >&2
  exit 1
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Configuration file $CONFIG_PATH not found." >&2
  exit 1
fi

CONFIG_DIR="$(dirname "$CONFIG_PATH")"
BUILD_ROOT="$CONFIG_DIR/.esphome"
PROJECT_ROOT="$BUILD_ROOT/build"

rm -rf "$BUILD_ROOT"

esphome compile --only-generate "$CONFIG_PATH"

if [[ ! -d "$PROJECT_ROOT" ]]; then
  echo "Failed to locate generated project directory at $PROJECT_ROOT" >&2
  exit 1
fi

PROJECT_DIR="$(find "$PROJECT_ROOT" -mindepth 1 -maxdepth 1 -type d | head -n1)"
if [[ -z "$PROJECT_DIR" ]]; then
  echo "Unable to determine IDF project directory inside $PROJECT_ROOT" >&2
  exit 1
fi

pushd "$PROJECT_DIR" >/dev/null

idf.py build

set +e
# Run QEMU and capture output for validation.
timeout --signal=SIGINT --preserve-status "$QEMU_TIMEOUT" idf.py qemu | tee qemu.log
status=${PIPESTATUS[0]}
set -e

case "$status" in
  0)
    echo "QEMU exited normally." ;;
  124)
    echo "QEMU reached the ${QEMU_TIMEOUT}s timeout, treating as success." ;;
  130)
    echo "QEMU interrupted after ${QEMU_TIMEOUT}s timeout." ;;
  *)
    echo "QEMU failed with status $status" >&2
    exit "$status"
    ;;
esac

if ! grep -q "Starting scheduler" qemu.log; then
  echo "QEMU output did not contain expected scheduler startup message." >&2
  exit 1
fi

popd >/dev/null
