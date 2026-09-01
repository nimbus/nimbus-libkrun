#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: prepare-libkrunfw-source.sh --output-dir <path> [options]

Prepare the complete corresponding source for the libkrunfw binary bundled in
the Nimbus libkrun release.

options:
  --output-dir <path>          output directory for the source archive
  --libkrunfw-version <ver>    pinned libkrunfw version (default: 5.5.0)
  -h, --help                   show this help
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

output_dir=""
libkrunfw_version="5.5.0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      output_dir="${2:-}"
      shift 2
      ;;
    --libkrunfw-version)
      libkrunfw_version="${2:-}"
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

case "${libkrunfw_version}" in
  5.5.0)
    libkrunfw_commit="ec4b297964877d83432f9ccda6dad8ff6e9de3e4"
    kernel_version="6.12.91"
    kernel_sha256="0ff2ab9e169f9f1948557471fbb450d3018f8c5b77caf288e1a3982582597969"
    ;;
  *)
    echo "no trusted source manifest for libkrunfw ${libkrunfw_version}" >&2
    exit 64
    ;;
esac

require_command curl
require_command git
require_command sha256sum
require_command tar

output_dir="$(resolve_dir "${output_dir}")"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/nimbus-libkrunfw-source.XXXXXX")"
cleanup() {
  rm -rf "${work_dir}"
}
trap cleanup EXIT

bundle_dir="${work_dir}/nimbus-libkrunfw-${libkrunfw_version}-corresponding-source"
source_dir="${bundle_dir}/libkrunfw-${libkrunfw_version}"
kernel_archive="${bundle_dir}/linux-${kernel_version}.tar.xz"
mkdir -p "${bundle_dir}"

git clone \
  --depth 1 \
  --branch "v${libkrunfw_version}" \
  https://github.com/libkrun/libkrunfw.git \
  "${source_dir}"

actual_commit="$(git -C "${source_dir}" rev-parse HEAD)"
if [[ "${actual_commit}" != "${libkrunfw_commit}" ]]; then
  echo "libkrunfw tag does not resolve to the pinned commit" >&2
  echo "expected: ${libkrunfw_commit}" >&2
  echo "actual:   ${actual_commit}" >&2
  exit 70
fi
rm -rf "${source_dir}/.git"

curl -fsSL \
  -o "${kernel_archive}" \
  "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${kernel_version}.tar.xz"
actual_kernel_sha256="$(sha256sum "${kernel_archive}")"
actual_kernel_sha256="${actual_kernel_sha256%% *}"
if [[ "${actual_kernel_sha256}" != "${kernel_sha256}" ]]; then
  echo "Linux kernel source digest mismatch" >&2
  echo "expected: ${kernel_sha256}" >&2
  echo "actual:   ${actual_kernel_sha256}" >&2
  exit 70
fi

cat > "${bundle_dir}/SOURCE_MANIFEST.txt" <<EOF
libkrunfw_version=${libkrunfw_version}
libkrunfw_commit=${libkrunfw_commit}
libkrunfw_source=https://github.com/libkrun/libkrunfw/tree/v${libkrunfw_version}
kernel_version=${kernel_version}
kernel_source=https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${kernel_version}.tar.xz
kernel_sha256=${kernel_sha256}
EOF

archive_path="${output_dir}/nimbus-libkrunfw-${libkrunfw_version}-corresponding-source.tar.gz"
tar -czf "${archive_path}" -C "${work_dir}" "$(basename "${bundle_dir}")"
archive_sha256="$(sha256sum "${archive_path}")"
archive_sha256="${archive_sha256%% *}"

echo "source.libkrunfw_version=${libkrunfw_version}"
echo "source.libkrunfw_commit=${libkrunfw_commit}"
echo "source.kernel_version=${kernel_version}"
echo "source.kernel_sha256=${kernel_sha256}"
echo "source.archive=${archive_path}"
echo "source.archive_sha256=${archive_sha256}"
