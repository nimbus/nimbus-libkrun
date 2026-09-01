#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: smoke-test-release-runtime.sh --root <path>

Load the libkrun runtime from a trusted, locally built release root and prove
that it resolves the bundled libkrunfw without LD_LIBRARY_PATH.

This script executes code from the supplied root. Do not use it to inspect an
untrusted or externally supplied archive. Use verify-release-archive.sh for
static archive inspection.
EOF
}

root=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      root="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if [[ -z "${root}" ]]; then
  usage >&2
  exit 64
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "required command not found: python3" >&2
  exit 69
fi

root="$(cd "${root}" && pwd -P)"
libkrun="${root}/lib/libkrun.so.1.19.4"
libkrunfw="${root}/lib/libkrunfw.so.5.5.0"
test -f "${libkrun}"
test -f "${libkrunfw}"

env -u LD_LIBRARY_PATH python3 - "${libkrun}" "${libkrunfw}" <<'PY'
import ctypes
import os
import sys

libkrun_path = os.path.realpath(sys.argv[1])
libkrunfw_path = os.path.realpath(sys.argv[2])
libkrun = ctypes.CDLL(libkrun_path, mode=os.RTLD_LOCAL | os.RTLD_NOW)
libkrun.krun_create_ctx.restype = ctypes.c_int32
libkrun.krun_free_ctx.argtypes = [ctypes.c_uint32]
libkrun.krun_free_ctx.restype = ctypes.c_int32

ctx_id = libkrun.krun_create_ctx()
if ctx_id < 0:
    raise SystemExit(f"krun_create_ctx failed: {ctx_id}")

try:
    with open("/proc/self/maps", encoding="utf-8") as maps:
        loaded_paths = {line.rstrip().split(maxsplit=5)[-1] for line in maps if "/" in line}
    if libkrunfw_path not in {os.path.realpath(path) for path in loaded_paths}:
        raise SystemExit(f"bundled libkrunfw was not loaded: {libkrunfw_path}")
finally:
    result = libkrun.krun_free_ctx(ctx_id)
    if result != 0:
        raise SystemExit(f"krun_free_ctx failed: {result}")
PY

echo "smoke.runtime_root=${root}"
echo "smoke.libkrunfw_loaded=${libkrunfw}"
