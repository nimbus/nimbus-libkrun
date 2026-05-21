#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: verify-release-archive.sh (--archive <path> | --root <path>) [options]

Verify a Nimbus libkrun runtime archive or extracted archive root.

options:
  --archive <path>                  archive to extract and verify
  --root <path>                     already-extracted archive root
  --expected-libkrunfw-version <v>  expected libkrunfw version (default: 5.3.0)
  -h, --help                        Show this help
EOF
}

require_command() {
  local name="$1"

  if ! command -v "${name}" >/dev/null 2>&1; then
    echo "required command not found: ${name}" >&2
    exit 69
  fi
}

archive=""
root=""
expected_libkrunfw_version="5.3.0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive)
      archive="${2:-}"
      shift 2
      ;;
    --root)
      root="${2:-}"
      shift 2
      ;;
    --expected-libkrunfw-version)
      expected_libkrunfw_version="${2:-}"
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

if [[ -n "${archive}" && -n "${root}" ]]; then
  echo "choose only one of --archive or --root" >&2
  exit 64
fi

if [[ -z "${archive}" && -z "${root}" ]]; then
  usage >&2
  exit 64
fi

require_command nm
require_command pkg-config
require_command tar

work_dir=""
if [[ -n "${archive}" ]]; then
  if [[ ! -f "${archive}" ]]; then
    echo "archive not found: ${archive}" >&2
    exit 66
  fi
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/nimbus-libkrun-verify.XXXXXX")"
  cleanup() {
    rm -rf "${work_dir}"
  }
  trap cleanup EXIT
  tar -xzf "${archive}" -C "${work_dir}"
  root="${work_dir}"
fi

if [[ ! -d "${root}" ]]; then
  echo "archive root not found: ${root}" >&2
  exit 66
fi

libkrun="${root}/lib/libkrun.so.1.17.4"
libkrunfw="${root}/lib/libkrunfw.so.${expected_libkrunfw_version}"
pc_file="${root}/lib/pkgconfig/libkrun.pc"

test -f "${libkrun}"
test -e "${root}/lib/libkrun.so.1"
test -e "${root}/lib/libkrun.so"
test -f "${libkrunfw}"
test -e "${root}/lib/libkrunfw.so.5"
test -e "${root}/lib/libkrunfw.so"
test -f "${root}/include/libkrun.h"
test -f "${pc_file}"

nm -D "${libkrun}" | grep -F "krun_set_port_map_with_bind_address" >/dev/null

pkg_output="$(
  PKG_CONFIG_PATH="${root}/lib/pkgconfig" pkg-config --define-prefix --libs libkrun
)"
case "${pkg_output}" in
  *"${root}/lib"*"-lkrun"*) ;;
  *)
    echo "pkg-config did not resolve against archive root: ${pkg_output}" >&2
    exit 70
    ;;
esac

echo "verified.archive_root=${root}"
echo "verified.libkrun=${libkrun}"
echo "verified.libkrunfw=${libkrunfw}"
echo "verified.pkg_config=${pkg_output}"
