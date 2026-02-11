#!/usr/bin/env bash
set -euo pipefail

QEMU_TIMEOUT="${QEMU_TIMEOUT:-60}"

if [[ -z "${IDF_PATH:-}" ]]; then
  echo "IDF_PATH is not set. Please source the ESP-IDF environment." >&2
  exit 1
fi

declare -a CONFIG_TARGETS=()

if [[ "$#" -eq 0 ]]; then
  while IFS= read -r config; do
    CONFIG_TARGETS+=("$config")
  done < <(find tests/qemu -maxdepth 1 -type f -name '*.yaml' | sort)
else
  CONFIG_TARGETS=("$@")
fi

if [[ "${#CONFIG_TARGETS[@]}" -eq 0 ]]; then
  echo "No QEMU configuration files were found." >&2
  exit 1
fi

for CONFIG_PATH in "${CONFIG_TARGETS[@]}"; do
  if [[ ! -f "$CONFIG_PATH" ]]; then
    echo "Configuration file $CONFIG_PATH not found." >&2
    exit 1
  fi

  echo "=== Building QEMU scenario: $CONFIG_PATH ==="
  CONFIG_DIR="$(dirname "$CONFIG_PATH")"
  BUILD_ROOT="$CONFIG_DIR/.esphome"
  PROJECT_ROOT="$BUILD_ROOT/build"
  LOG_ROOT="$BUILD_ROOT/logs"

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

  mkdir -p "$LOG_ROOT"

  pushd "$PROJECT_DIR" >/dev/null

  idf.py build

  RUN_LOG="$PROJECT_DIR/qemu.log"

  set +e
  timeout --signal=SIGINT --preserve-status "$QEMU_TIMEOUT" idf.py qemu | tee "$RUN_LOG"
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

  if ! grep -q "Starting scheduler" "$RUN_LOG"; then
    echo "QEMU output did not contain expected scheduler startup message." >&2
    exit 1
  fi

  SCENARIO_NAME="$(basename "$CONFIG_PATH" .yaml)"
  cp "$RUN_LOG" "$LOG_ROOT/${SCENARIO_NAME}.log"

  popd >/dev/null

  echo "=== Completed QEMU scenario: $CONFIG_PATH ==="
done
