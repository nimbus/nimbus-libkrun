#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: verify-release-archive.sh (--archive <path> | --root <path>) [options]

Verify a Nimbus libkrun runtime archive or extracted archive root.

options:
  --archive <path>                  archive to extract and verify
  --root <path>                     already-extracted archive root
  --expected-arch <amd64|arm64>     expected ELF architecture (default: host)
  --expected-libkrunfw-version <v>  expected libkrunfw version (default: 5.5.0)
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
expected_libkrunfw_version="5.5.0"
expected_arch=""

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
    --expected-arch)
      expected_arch="${2:-}"
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
require_command readelf
require_command tar

case "${expected_arch:-$(uname -m)}" in
  amd64|x86_64)
    archive_arch="amd64"
    expected_elf_machine="Advanced Micro Devices X86-64"
    ;;
  arm64|aarch64)
    archive_arch="arm64"
    expected_elf_machine="AArch64"
    ;;
  *)
    echo "unsupported expected architecture: ${expected_arch:-$(uname -m)}" >&2
    exit 64
    ;;
esac

case "${expected_libkrunfw_version}:${archive_arch}" in
  5.5.0:amd64)
    expected_libkrunfw_sha256="c169206b01c89fbe134f1728bf4f988702bc7f73b4cf73e6fdece447d6fceca1"
    ;;
  5.5.0:arm64)
    expected_libkrunfw_sha256="b04c9a5520a1ea52b5b35d87559566872246145961c4b6978034c9b9be54b89b"
    ;;
  *)
    echo "no trusted libkrunfw digest for ${expected_libkrunfw_version}:${archive_arch}" >&2
    exit 64
    ;;
esac

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

libkrun="${root}/lib/libkrun.so.1.19.4"
libkrunfw="${root}/lib/libkrunfw.so.${expected_libkrunfw_version}"
pc_file="${root}/lib/pkgconfig/libkrun.pc"
release_manifest="${root}/NIMBUS_LIBKRUN_RELEASE.txt"

test -f "${libkrun}"
test -e "${root}/lib/libkrun.so.1"
test -e "${root}/lib/libkrun.so"
test -f "${libkrunfw}"
test -e "${root}/lib/libkrunfw.so.5"
test -e "${root}/lib/libkrunfw.so"
test -f "${root}/include/libkrun.h"
test -f "${pc_file}"
test -f "${release_manifest}"

for elf_file in "${libkrun}" "${libkrunfw}"; do
  elf_machine="$(readelf -h "${elf_file}" | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p')"
  if [[ "${elf_machine}" != "${expected_elf_machine}" ]]; then
    echo "ELF architecture mismatch: ${elf_file}" >&2
    echo "expected: ${expected_elf_machine}" >&2
    echo "actual:   ${elf_machine}" >&2
    exit 70
  fi
done

runpath="$(readelf -d "${libkrun}" | sed -n 's/.*(RUNPATH).*Library runpath: \[\(.*\)\]/\1/p')"
expected_runpath="\$ORIGIN"
if [[ "${runpath}" != "${expected_runpath}" ]]; then
  echo "libkrun RUNPATH does not resolve bundled dependencies" >&2
  echo "expected: \$ORIGIN" >&2
  echo "actual:   ${runpath:-<missing>}" >&2
  exit 70
fi

grep -Fx "arch=${archive_arch}" "${release_manifest}" >/dev/null
grep -Fx "libkrunfw_sha256=${expected_libkrunfw_sha256}" "${release_manifest}" >/dev/null

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
echo "verified.arch=${archive_arch}"
echo "verified.pkg_config=${pkg_output}"
