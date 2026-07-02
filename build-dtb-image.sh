#!/usr/bin/env bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
#
# SPDX-License-Identifier: BSD-3-Clause-Clear
#
# =============================================================================
# build-dtb-image.sh
#
# Description:
#   Build a FAT-formatted FIT DTB image for Qualcomm ARM64 platforms.
#
#   This script is part of the qcom-dtb-metadata repository.  The ITS file
#   (qcom-next-fitimage.its) and platform metadata DTS (qcom-metadata.dts)
#   are read directly from the repository directory containing this script —
#   no network access or repository cloning is required at build time.
#
#   The script produces a FIT DTB image (qclinux_fit.img) suitable for
#   booting multiple Qualcomm platforms from a single DTB image, using the
#   multi-DTB selection mechanism defined by qcom-dtb-metadata.
#
#   ─────────────────────────────────────────────────────────────────────────
#   DTB Source Modes
#   ─────────────────────────────────────────────────────────────────────────
#
#     (A) Kernel .deb mode (recommended / upstream-friendly)
#         - Provide a Debian kernel package (.deb) as input.
#         - The script extracts the .deb via `dpkg-deb -R` into a temp directory.
#         - DTBs are located by probing the following paths in order:
#             1. $DEB_DIR/usr/lib/linux-image-*/   (Debian standard — direct, no symlink)
#             2. $DEB_DIR/usr/lib/firmware/*/device-tree  (Ubuntu compat, usrmerge layout)
#             3. $DEB_DIR/lib/firmware/*/device-tree      (Ubuntu compat, legacy layout)
#           Probing the Debian standard path first ensures correct operation on
#           both Debian and Ubuntu regardless of whether the compat symlink exists.
#         - The script assumes there is exactly ONE matching directory.
#
#     (B) DTB source directory mode (dev/kernel-tree mode)
#         - Provide the DTB source directory directly (e.g. a kernel build tree):
#             arch/arm64/boot/dts/qcom
#
#   ─────────────────────────────────────────────────────────────────────────
#   Build Steps
#   ─────────────────────────────────────────────────────────────────────────
#     1. Set up a temporary staging directory with the ITS, compiled DTS,
#        and all DTBs laid out as the ITS /incbin/ paths expect.
#     2. Compile qcom-metadata.dts → qcom-metadata.dtb  (via dtc).
#     3. Copy qcom-next-fitimage.its into the staging directory.
#     4. Run mkimage to produce qclinux_fit.img  (-E -B 8).
#        NOTE: The output filename is hardcoded in UEFI firmware:
#              #define FIT_BINARY_FILE    L"\\qclinux_fit.img"
#              #define COMBINED_DTB_FILE  L"\\combined-dtb.dtb"
#              #define SECONDARY_DTB_FILE L"\\secondary-dtb.dtb"
#     5. Pack qclinux_fit.img into a FAT image.
#
# Usage:
#   ./build-dtb-image.sh \
#       (--kernel-deb <path/to/kernel.deb> | --dtb-src <path/to/dtb/dir>) \
#       [--size <MB>] [--out <file>]
#
# ─────────────────────────────────────────────────────────────────────────────
# Arguments:
#   --kernel-deb / -kernel-deb
#              Path to a Debian kernel package (.deb). DTBs are taken from the
#              extracted payload, probed in order:
#                1. usr/lib/linux-image-*/        (Debian standard)
#                2. usr/lib/firmware/*/device-tree (Ubuntu compat, usrmerge)
#                3. lib/firmware/*/device-tree     (Ubuntu compat, legacy)
#
#   --dtb-src / -dtb-src
#              Path to DTB source directory
#              e.g., arch/arm64/boot/dts/qcom
#
#   --fit-image / -fit-image
#              [Accepted for backward compatibility] FIT image mode is the
#              default and only mode; this flag is a no-op.
#
#   --size / -size
#              FAT image size in MB (integer > 0, default: 4)
#
#   --out / -out
#              Output image filename (default: dtb.bin)
#
# Requirements / Assumptions:
#   - Linux host with:
#       * bash
#       * dd
#       * mtools (mformat, mcopy, mdir) — FAT image creation without root
#       * dtc
#       * mkimage
#       * dpkg-deb (only required for --kernel-deb mode)
#   - No root privileges required.
#
# Notes:
#   - The resulting FAT image contains qclinux_fit.img at its root.
#   - FAT image creation uses mtools (mformat + mcopy); no loop device,
#     no mount point, no elevated privileges required at any step.
#   - The script installs a cleanup trap to remove all temporary
#     directories on any exit path.
#
# =============================================================================

set -euo pipefail

# Resolve the directory containing this script (the qcom-dtb-metadata root).
# All metadata files (ITS, DTS) are read from this directory at runtime —
# no cloning or network access is required.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ----------------------------- Defaults --------------------------------------

DTB_BIN_SIZE=4         # Default FAT image size (MB)
DTB_BIN="dtb.bin"      # Default output image filename
PRUNE=0                # Prune ITS entries whose DTB/DTBO is absent from source

DTB_SRC=""             # DTB source directory (resolved; required via one mode)

KERNEL_DEB=""          # Optional: kernel .deb input (preferred mode)
DEB_DIR=""             # Temporary extraction directory when using --kernel-deb

FIT_WORK_DIR=""        # Temporary staging directory for FIT build artefacts

# ITS file used for FIT image generation — must exist in SCRIPT_DIR.
DEFAULT_ITS_FILE="qcom-next-fitimage.its"

# ---------------------------- Helper Functions -------------------------------

usage() {
    cat <<EOF
Usage: $0 (--kernel-deb <kernel.deb> | --dtb-src <path>) [--size <MB>] [--out <file>]

  --kernel-deb, -kernel-deb  Path to Debian kernel package (.deb). DTBs located by probing:
                             1. <extract>/usr/lib/linux-image-*/        (Debian standard)
                             2. <extract>/usr/lib/firmware/*/device-tree (Ubuntu, usrmerge)
                             3. <extract>/lib/firmware/*/device-tree     (Ubuntu, legacy)
                             Exactly one directory must be found across all search paths.

  --dtb-src,   -dtb-src      Path to DTB source directory
                             (e.g. arch/arm64/boot/dts/qcom)

  --fit-image, -fit-image    Accepted for backward compatibility; FIT image
                             mode is the default and only mode (no-op).

  --size,      -size         FAT image size in MB (default: 4)

  --out,       -out          Output image filename (default: dtb.bin)

  --prune,     -prune        Prune ITS entries of dtb(o) based on kernel provided.
                             dtb.bin is created from reduced its file. there is
                             risk of missing dtb(o) due to kernel and finding it out during boot.

Notes:
  - Exactly one of --kernel-deb or --dtb-src must be provided.
  - The output FAT image contains qclinux_fit.img at its root.
  - Metadata files (ITS, DTS) are read from: ${SCRIPT_DIR}
EOF
    exit 1
}

require_cmd() {
    local c="$1"
    if ! command -v "$c" >/dev/null 2>&1; then
        echo "[ERROR] Required command not found: $c" >&2
        exit 1
    fi
}

cleanup() {
    local status=$?

    if [[ -n "${DEB_DIR:-}" && -d "$DEB_DIR" ]]; then
        rm -rf "$DEB_DIR" || true
    fi

    if [[ -n "${FIT_WORK_DIR:-}" && -d "$FIT_WORK_DIR" ]]; then
        rm -rf "$FIT_WORK_DIR" || true
    fi

    exit "$status"
}

trap cleanup EXIT

# ------------------------------ Arg Parsing ----------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        -dtb-src|--dtb-src)
            DTB_SRC="${2:-}"
            shift 2
            ;;
        -kernel-deb|--kernel-deb)
            KERNEL_DEB="${2:-}"
            shift 2
            ;;
        -size|--size)
            DTB_BIN_SIZE="${2:-}"
            shift 2
            ;;
        -fit-image|--fit-image)
            # FIT image mode is the default; accepted for backward compatibility.
            shift 1
            ;;
        -out|--out)
            DTB_BIN="${2:-}"
            shift 2
            ;;
        -prune|--prune)
            PRUNE=1
            shift 1
            ;;
        -h|--help)
            usage
            ;;
        *)
            usage
            ;;
    esac
done

# ----------------------------- Validation ------------------------------------

# Exactly one source mode must be selected
if [[ -n "${KERNEL_DEB}" && -n "${DTB_SRC}" ]]; then
    echo "[ERROR] Provide only one of --kernel-deb or --dtb-src (not both)." >&2
    usage
fi
if [[ -z "${KERNEL_DEB}" && -z "${DTB_SRC}" ]]; then
    echo "[ERROR] Provide one of --kernel-deb or --dtb-src." >&2
    usage
fi

# Validate image size is a positive integer
if ! [[ "${DTB_BIN_SIZE}" =~ ^[0-9]+$ ]] || (( DTB_BIN_SIZE <= 0 )); then
    echo "[ERROR] --size must be a positive integer (MB), got '${DTB_BIN_SIZE}'." >&2
    exit 1
fi

# Validate that required metadata files are present in the repository
if [[ ! -f "${SCRIPT_DIR}/qcom-metadata.dts" ]]; then
    echo "[ERROR] qcom-metadata.dts not found in metadata directory: ${SCRIPT_DIR}" >&2
    exit 1
fi
if [[ ! -f "${SCRIPT_DIR}/${DEFAULT_ITS_FILE}" ]]; then
    echo "[ERROR] ITS file '${DEFAULT_ITS_FILE}' not found in metadata directory: ${SCRIPT_DIR}" >&2
    exit 1
fi

# Command requirements
require_cmd dd
require_cmd mformat
require_cmd mcopy
require_cmd mdir
require_cmd mktemp
require_cmd cp
require_cmd dtc
require_cmd mkimage

# ----------------------------- Resolve DTB_SRC -------------------------------

if [[ -n "${KERNEL_DEB}" ]]; then
    if [[ ! -f "${KERNEL_DEB}" ]]; then
        echo "[ERROR] Kernel .deb '${KERNEL_DEB}' not found." >&2
        exit 1
    fi

    require_cmd dpkg-deb

    DEB_DIR="$(mktemp -d -t kernel-deb-XXXXXX)"
    echo "[INFO] Extracting kernel .deb to: ${DEB_DIR}"
    dpkg-deb -R "${KERNEL_DEB}" "${DEB_DIR}"

    # Locate the DTB directory from the extracted .deb.
    # Probe in order (most to least preferred):
    #   1. usr/lib/linux-image-*/  — Debian standard install location (direct, no symlink).
    #                                Works on both Debian and Ubuntu regardless of usrmerge.
    #   2. usr/lib/firmware/*/device-tree — Ubuntu compat symlink (usrmerge layout).
    #   3. lib/firmware/*/device-tree     — Ubuntu compat symlink (legacy layout).
    # Searching the Debian standard path first avoids any dependency on the Ubuntu
    # compat symlink and is correct on pure Debian systems that never install it.
    shopt -s nullglob
    dt_dirs=( "${DEB_DIR}/usr/lib/linux-image-"*/ )
    if (( ${#dt_dirs[@]} == 0 )); then
        dt_dirs=( "${DEB_DIR}/usr/lib/firmware"/*/device-tree )
    fi
    if (( ${#dt_dirs[@]} == 0 )); then
        dt_dirs=( "${DEB_DIR}/lib/firmware"/*/device-tree )
    fi
    shopt -u nullglob

    if (( ${#dt_dirs[@]} == 0 )); then
        echo "[ERROR] No DTB directory found under:" >&2
        echo "        '${DEB_DIR}/usr/lib/linux-image-*/'" >&2
        echo "        '${DEB_DIR}/usr/lib/firmware/*/device-tree'" >&2
        echo "        '${DEB_DIR}/lib/firmware/*/device-tree'" >&2
        exit 1
    fi
    if (( ${#dt_dirs[@]} > 1 )); then
        echo "[ERROR] Multiple DTB directories found; expected exactly one:" >&2
        for d in "${dt_dirs[@]}"; do
            echo "        - $d" >&2
        done
        exit 1
    fi

    DTB_SRC="${dt_dirs[0]}"
    echo "[INFO] Using DTB source directory from .deb payload: ${DTB_SRC}"
else
    if [[ ! -d "${DTB_SRC}" ]]; then
        echo "[ERROR] DTB source directory '${DTB_SRC}' not found." >&2
        exit 1
    fi
    echo "[INFO] Using DTB source directory: ${DTB_SRC}"
fi

# ==============================================================================
# FIT DTB Image Build
# ==============================================================================

echo "[INFO] Building FIT DTB image."
echo "[INFO] Using metadata from: ${SCRIPT_DIR}"

# -----------------------------------------------------------------------
# Step 1. Create staging directory and lay out the build tree
# -----------------------------------------------------------------------
# mkimage resolves /incbin/ paths relative to the directory it is invoked
# from, so all artefacts (ITS, compiled metadata DTB, and per-platform
# DTBs) must be assembled under a single staging tree before mkimage runs.
FIT_WORK_DIR="$(mktemp -d -t fit-build-XXXXXX)"
echo "[INFO] FIT build staging directory: ${FIT_WORK_DIR}"

FIT_STAGE="${FIT_WORK_DIR}/fit_image"
mkdir -p "${FIT_STAGE}"

# Create the directory tree that the ITS /incbin/ paths reference:
#   arch/arm64/boot/dts/qcom/<platform>.dtb
DTB_STAGE="${FIT_STAGE}/arch/arm64/boot/dts/qcom"
mkdir -p "${DTB_STAGE}"

# Copy DTBs from the resolved DTB source directory.
# DTBs may be nested under vendor subdirectories (e.g. qcom/), so use
# find -L (follow symlinks) rather than a flat glob to collect them all
# into the staging dir flat — the ITS file references them by basename
# under arch/arm64/boot/dts/qcom/.
echo "[INFO] Copying DTBs from ${DTB_SRC} ..."
dtb_count=0
while IFS= read -r dtb; do
    cp -p "${dtb}" "${DTB_STAGE}/"
    (( dtb_count++ )) || true
done < <(find -L "${DTB_SRC}" \( -name '*.dtb' -o -name '*.dtbo' \) -type f)

if (( dtb_count == 0 )); then
    echo "[ERROR] No DTB files found under ${DTB_SRC}" >&2
    echo "        Verify the kernel package was built with DTB support" >&2
    echo "        and that usr/lib/linux-image-*/ is present in the package." >&2
    exit 1
fi
echo "[INFO] Staged ${dtb_count} DTB file(s) to ${DTB_STAGE}"
echo "[INFO] Staged DTBs:"
ls "${DTB_STAGE}"/*.dtb 2>/dev/null | xargs -n1 basename | sort | sed 's/^/        /'

# -----------------------------------------------------------------------
# Step 2. Compile qcom-metadata.dts → qcom-metadata.dtb
# -----------------------------------------------------------------------
echo "[INFO] Compiling qcom-metadata.dts..."
dtc -I dts -O dtb \
    -o "${FIT_STAGE}/qcom-metadata.dtb" \
    "${SCRIPT_DIR}/qcom-metadata.dts"
echo "[INFO] qcom-metadata.dtb generated:"
ls -lh "${FIT_STAGE}/qcom-metadata.dtb"

# -----------------------------------------------------------------------
# Step 3. Copy ITS file into the staging directory
# -----------------------------------------------------------------------
cp "${SCRIPT_DIR}/${DEFAULT_ITS_FILE}" "${FIT_STAGE}/${DEFAULT_ITS_FILE}"

# -----------------------------------------------------------------------
# Step 3b. Prune ITS (only when --prune is given)
#
# For every image entry whose /incbin/ DTB/DTBO is absent from the staged
# source, the entry is dropped.  Any configuration referencing a dropped
# label is also dropped. The staged ITS is overwritten in-place so that
# Step 4 (mkimage) sees the reduced file.
# fdt label is also dropped. Remaining configurations are
# renumbered sequentially (conf-1, conf-2, …) to close any gaps left by
# dropped entries.
# -----------------------------------------------------------------------
if (( PRUNE )); then
    echo "[INFO] --prune: rewriting ITS to include only DTBs present in source..."

    _pruned_its="${FIT_STAGE}/${DEFAULT_ITS_FILE}.pruned"

    # Two-file awk: first input = available DTB basenames (via find); second = ITS.
    # NR==FNR processes the first file to build avail_dtbs[]; the rest rewrites the ITS.
    awk '
NR == FNR { avail_dtbs[$1] = 1; next }
BEGIN { avail_labels["fdt-qcom-metadata.dtb"] = 1
        in_block=0; skip_block=0; is_conf=0; buf=""; cur_label=""
        cur_compat=""; conf_counter=0 }
/^\t\tfdt-[^ ]+ \{$/ {
    in_block=1; is_conf=0; skip_block=0; cur_label=$1; buf=$0"\n"; next }
/^[[:space:]]+conf-[0-9]+ \{$/ {
    in_block=1; is_conf=1; skip_block=0; cur_compat=""; buf=$0"\n"; next }
in_block {
    buf=buf $0"\n"
    if (is_conf && /compatible =/) {
        match($0, /"[^"]+"/); cur_compat=substr($0,RSTART+1,RLENGTH-2) }
    if (!is_conf && /\/incbin\//) {
        if (!(cur_label in avail_labels)) {
            split($0,q,"\""); n=split(q[2],p,"/"); dtb=p[n]
            if (dtb in avail_dtbs) avail_labels[cur_label]=1
            else { skip_block=1; print "[WARN] --prune: dropped fdt: "dtb >"/dev/stderr" }
        }
    }
    if (is_conf && /fdt =/) {
        tmp=$0
        while (match(tmp,/"fdt-[^"]+"/)>0) {
            ref=substr(tmp,RSTART+1,RLENGTH-2)
            if (!(ref in avail_labels)) skip_block=1
            tmp=substr(tmp,RSTART+RLENGTH)
        }
    }
    if (/^\t\t\};$/) {
        if (!skip_block) {
            if (is_conf) {
                conf_counter++
                sub(/conf-[0-9]+/, "conf-" conf_counter, buf)
            }
            sub(/\n$/, "", buf); print buf
        } else if (is_conf) {
            print "[WARN] --prune: dropped conf (compatible=\"" cur_compat "\"): missing DTB(s)" >"/dev/stderr"
        }
        in_block=0; buf=""; skip_block=0; is_conf=0; cur_label=""; cur_compat=""
    }
    next
}
{ print }
' <(find "${DTB_STAGE}" -maxdepth 1 \( -name "*.dtb" -o -name "*.dtbo" \) -type f \
      -exec basename {} \;) \
  "${FIT_STAGE}/${DEFAULT_ITS_FILE}" > "${_pruned_its}"

    if ! grep -q 'conf-[0-9]' "${_pruned_its}"; then
        echo "[ERROR] --prune: no configuration entries remain after pruning." >&2
        echo "        Verify the source contains DTBs referenced by the ITS." >&2
        exit 1
    fi

    mv "${_pruned_its}" "${FIT_STAGE}/${DEFAULT_ITS_FILE}"
    echo "[INFO] --prune: ITS rewritten successfully."
    echo "[INFO] Remaining ITS image entries:"
    grep -P $'^\t\tfdt-' "${FIT_STAGE}/${DEFAULT_ITS_FILE}" | \
        sed 's/^[[:space:]]*/        /' || true
    echo "[INFO] Dropped conf entries:"
    grep -o 'compatible = "[^"]*"' "${SCRIPT_DIR}/${DEFAULT_ITS_FILE}" | \
        grep -vxF -f <(grep -o 'compatible = "[^"]*"' "${FIT_STAGE}/${DEFAULT_ITS_FILE}") | \
        sed 's/compatible = "//;s/"$//;s/^/        /' || true

    unset _pruned_its
fi
# -----------------------------------------------------------------------
# Step 4. Generate qclinux_fit.img via mkimage
# -----------------------------------------------------------------------
# mkimage is invoked from FIT_STAGE so that all /incbin/ relative paths
# in the ITS file resolve correctly.
#
# Output filename MUST be qclinux_fit.img — hardcoded in UEFI firmware:
#   #define FIT_BINARY_FILE    L"\\qclinux_fit.img"
#   #define COMBINED_DTB_FILE  L"\\combined-dtb.dtb"
#   #define SECONDARY_DTB_FILE L"\\secondary-dtb.dtb"
mkdir -p "${FIT_STAGE}/out"
echo "[INFO] Running mkimage to generate qclinux_fit.img..."
(
    cd "${FIT_STAGE}"
    mkimage -f "${DEFAULT_ITS_FILE}" out/qclinux_fit.img -E -B 8
)
echo "[INFO] qclinux_fit.img generated:"
ls -lh "${FIT_STAGE}/out/qclinux_fit.img"
file "${FIT_STAGE}/out/qclinux_fit.img"

# -----------------------------------------------------------------------
# Step 5. Pack qclinux_fit.img into a FAT image
# -----------------------------------------------------------------------
# mtools (mformat + mcopy) operates directly on the image file — no loop
# device, no mount point, no root privileges required.
echo "[INFO] Creating FAT image '${DTB_BIN}' (${DTB_BIN_SIZE} MB)..."
dd if=/dev/zero of="${DTB_BIN}" bs=1M count="${DTB_BIN_SIZE}" status=progress

echo "[INFO] Formatting '${DTB_BIN}' as FAT (4 KiB sector size)..."
# -S 5: sector size code → 2^(5+7) = 4096 bytes (matches original mkfs.vfat -S 4096)
# No -F: let mformat auto-select FAT type based on image size, matching mkfs.vfat behaviour
mformat -i "${DTB_BIN}" -S 5 ::

echo "[INFO] Copying qclinux_fit.img into FAT image..."
mcopy -i "${DTB_BIN}" "${FIT_STAGE}/out/qclinux_fit.img" ::

echo "[INFO] Deployed qclinux_fit.img into FAT image."
echo "[INFO] Files in image:"
mdir -i "${DTB_BIN}" ::

# Normal exit (cleanup will still run, but now everything should succeed).
exit 0
