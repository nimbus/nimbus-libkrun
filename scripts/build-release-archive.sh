#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: build-release-archive.sh --output-dir <path> [options]

Build a Nimbus-private libkrun runtime archive for Linux.

options:
  --source-dir <path>          libkrun source checkout to build (default: repo root)
  --output-dir <path>          output directory for archive and checksums
  --arch <amd64|arm64>         archive architecture (default: detect host)
  --version <tag>              Nimbus release tag/version for metadata
  --libkrunfw-version <ver>    pinned libkrunfw version (default: 5.5.0)
  --libkrunfw-archive <path>   use a predownloaded libkrunfw archive
  -h, --help                   Show this help
EOF
}

require_command() {
  local name="$1"

  if ! command -v "${name}" >/dev/null 2>&1; then
    echo "required command not found: ${name}" >&2
    exit 69
  fi
}

resolve_dir() {
  local path="$1"

  mkdir -p "${path}"
  (
    cd "${path}"
    pwd -P
  )
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source_dir="${repo_root}"
output_dir=""
arch=""
release_version=""
libkrunfw_version="5.5.0"
libkrunfw_archive=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-dir)
      source_dir="${2:-}"
      shift 2
      ;;
    --output-dir)
      output_dir="${2:-}"
      shift 2
      ;;
    --arch)
      arch="${2:-}"
      shift 2
      ;;
    --version)
      release_version="${2:-}"
      shift 2
      ;;
    --libkrunfw-version)
      libkrunfw_version="${2:-}"
      shift 2
      ;;
    --libkrunfw-archive)
      libkrunfw_archive="${2:-}"
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

if [[ -z "${output_dir}" ]]; then
  usage >&2
  exit 64
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "build-release-archive.sh builds Linux artifacts and must run on Linux" >&2
  exit 69
fi

case "${arch:-$(uname -m)}" in
  amd64|x86_64)
    archive_arch="amd64"
    fw_arch="x86_64"
    ;;
  arm64|aarch64)
    archive_arch="arm64"
    fw_arch="aarch64"
    ;;
  *)
    echo "unsupported architecture: ${arch:-$(uname -m)}" >&2
    exit 64
    ;;
esac

case "$(uname -m)" in
  x86_64)
    host_arch="amd64"
    ;;
  aarch64|arm64)
    host_arch="arm64"
    ;;
  *)
    echo "unsupported host architecture: $(uname -m)" >&2
    exit 64
    ;;
esac

if [[ "${archive_arch}" != "${host_arch}" ]]; then
  echo "native build host ${host_arch} cannot produce ${archive_arch} archive" >&2
  exit 64
fi

case "${libkrunfw_version}:${fw_arch}" in
  5.5.0:x86_64)
    expected_libkrunfw_sha256="c169206b01c89fbe134f1728bf4f988702bc7f73b4cf73e6fdece447d6fceca1"
    ;;
  5.5.0:aarch64)
    expected_libkrunfw_sha256="b04c9a5520a1ea52b5b35d87559566872246145961c4b6978034c9b9be54b89b"
    ;;
  *)
    echo "no trusted libkrunfw digest for ${libkrunfw_version}:${fw_arch}" >&2
    exit 64
    ;;
esac

require_command cargo
require_command curl
require_command make
require_command nm
require_command patchelf
require_command pkg-config
require_command readelf
require_command sha256sum
require_command tar

source_dir="$(resolve_dir "${source_dir}")"
output_dir="$(resolve_dir "${output_dir}")"

if [[ ! -f "${source_dir}/Makefile" ]]; then
  echo "source directory does not look like libkrun: ${source_dir}" >&2
  exit 66
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/nimbus-libkrun-release.XXXXXX")"
cleanup() {
  rm -rf "${work_dir}"
}
trap cleanup EXIT

dest_dir="${work_dir}/dest"
payload_dir="${work_dir}/payload"
fw_dir="${work_dir}/libkrunfw"
mkdir -p "${dest_dir}" "${payload_dir}" "${fw_dir}"

if [[ -z "${libkrunfw_archive}" ]]; then
  libkrunfw_archive="${work_dir}/libkrunfw-${fw_arch}.tgz"
  curl -fsSL \
    -o "${libkrunfw_archive}" \
    "https://github.com/libkrun/libkrunfw/releases/download/v${libkrunfw_version}/libkrunfw-${fw_arch}.tgz"
fi

libkrunfw_sha256="$(sha256sum "${libkrunfw_archive}")"
libkrunfw_sha256="${libkrunfw_sha256%% *}"
if [[ "${libkrunfw_sha256}" != "${expected_libkrunfw_sha256}" ]]; then
  echo "libkrunfw archive digest mismatch" >&2
  echo "expected: ${expected_libkrunfw_sha256}" >&2
  echo "actual:   ${libkrunfw_sha256}" >&2
  exit 70
fi
tar -xzf "${libkrunfw_archive}" -C "${fw_dir}"

echo "release.source_dir=${source_dir}"
echo "release.output_dir=${output_dir}"
echo "release.arch=${archive_arch}"
echo "release.libkrunfw_version=${libkrunfw_version}"
echo "release.libkrunfw_sha256=${libkrunfw_sha256}"

(
  cd "${source_dir}"
  cargo test -p libkrun port_map_tests -- --nocapture
  make PREFIX=/usr/libexec/nimbus LIBDIR_Linux=lib
  make PREFIX=/usr/libexec/nimbus LIBDIR_Linux=lib DESTDIR="${dest_dir}" install
)

mkdir -p "${payload_dir}/lib" "${payload_dir}/include"
cp -a "${dest_dir}/usr/libexec/nimbus/lib/." "${payload_dir}/lib/"
cp -a "${dest_dir}/usr/libexec/nimbus/include/." "${payload_dir}/include/"

cat > "${payload_dir}/lib/pkgconfig/libkrun.pc" <<'EOF'
prefix=${pcfiledir}/../..
libdir=${prefix}/lib
includedir=${prefix}/include

Name: libkrun
Version: 1.19.4
Description: Library providing Virtualization-based process isolation
Requires:
Cflags: -I${includedir}
Libs: -L${libdir} -lkrun
EOF

if [[ -d "${fw_dir}/lib64" ]]; then
  cp -a "${fw_dir}/lib64"/libkrunfw.so* "${payload_dir}/lib/"
elif [[ -d "${fw_dir}/lib" ]]; then
  cp -a "${fw_dir}/lib"/libkrunfw.so* "${payload_dir}/lib/"
else
  echo "libkrunfw archive does not contain lib/ or lib64/" >&2
  exit 70
fi

origin_runpath="\$ORIGIN"
patchelf --set-rpath "${origin_runpath}" "${payload_dir}/lib/libkrun.so.1.19.4"

cat > "${payload_dir}/NIMBUS_LIBKRUN_RELEASE.txt" <<EOF
nimbus-libkrun=${release_version:-unknown}
libkrun=1.19.4
libkrunfw=${libkrunfw_version}
libkrunfw_sha256=${libkrunfw_sha256}
arch=${archive_arch}
prefix=/usr/libexec/nimbus
EOF

"${repo_root}/scripts/verify-release-archive.sh" \
  --root "${payload_dir}" \
  --expected-libkrunfw-version "${libkrunfw_version}" \
  --expected-arch "${archive_arch}"
"${repo_root}/scripts/smoke-test-release-runtime.sh" --root "${payload_dir}"

archive_name="nimbus-libkrun-linux-${archive_arch}.tar.gz"
archive_path="${output_dir}/${archive_name}"
tar --owner=0 --group=0 --numeric-owner -czf "${archive_path}" -C "${payload_dir}" .

(
  cd "${output_dir}"
  find . -maxdepth 1 -type f -name 'nimbus-libkrun-linux-*.tar.gz' -print |
    sed 's|^\./||' |
    sort |
    xargs sha256sum > checksums.txt
)

echo "release.archive=${archive_path}"
echo "release.checksums=${output_dir}/checksums.txt"
