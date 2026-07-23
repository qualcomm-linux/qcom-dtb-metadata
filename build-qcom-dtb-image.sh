#!/usr/bin/env bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
#
# build-qcom-dtb-image.sh
#
# Clone qcom-next kernel, build ARM64 DTBs (defconfig + make dtbs),
# then invoke build-dtb-image.sh to produce a FAT FIT DTB image (dtb.bin).
#
# Usage:
#   ./build-qcom-dtb-image.sh [--kernel-repo <url>] [--kernel-branch <branch>]
#                             [--kernel-dir <path>] [--kobj <path>]
#                             [--out <file>] [--size <MB>]
#                             [--soc <soc-name>...] [--board <board-name>...]
#                             [--family <soc-family>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KERNEL_REPO="https://github.com/qualcomm-linux/kernel.git"
KERNEL_BRANCH="qcom-next"
KERNEL_DIR="kernel-src"
KOBJ="kobj"
DTB_BIN="dtb.bin"
DTB_BIN_SIZE=4
SOC_FILTER=()
BOARD_FILTER=()
FAMILY_FILTER=""
PLATFORM_DATA="${SCRIPT_DIR}/qcom-platform.yaml"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kernel-repo)   KERNEL_REPO="$2";   shift 2 ;;
        --kernel-branch) KERNEL_BRANCH="$2"; shift 2 ;;
        --kernel-dir)    KERNEL_DIR="$2";    shift 2 ;;
        --kobj)          KOBJ="$2";          shift 2 ;;
        --out)           DTB_BIN="$2";       shift 2 ;;
        --size)          DTB_BIN_SIZE="$2";  shift 2 ;;
        --soc)
            shift
            while [[ $# -gt 0 && "$1" != --* && "$1" != -* ]]; do
                SOC_FILTER+=("$1"); shift
            done
            ;;
        --board)
            shift
            while [[ $# -gt 0 && "$1" != --* && "$1" != -* ]]; do
                BOARD_FILTER+=("$1"); shift
            done
            ;;
        --family)  FAMILY_FILTER="$2"; shift 2 ;;
        *) echo "[ERROR] Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Resolve --family into SOC_FILTER entries via qcom-platform.yaml
if [[ -n "${FAMILY_FILTER}" ]]; then
    if [[ ! -f "${PLATFORM_DATA}" ]]; then
        echo "[ERROR] qcom-platform.yaml not found at: ${PLATFORM_DATA}" >&2
        exit 1
    fi
    # Collect all valid family names for validation
    mapfile -t _all_families < <(python3 -c "
import yaml
d = yaml.safe_load(open('${PLATFORM_DATA}'))
for p in d['platforms']:
    print(p['soc_family'])
")
    # Find a case-insensitive match
    _matched_family=""
    for _f in "${_all_families[@]}"; do
        if [[ "${_f,,}" == "${FAMILY_FILTER,,}" ]]; then
            _matched_family="${_f}"
            break
        fi
    done
    if [[ -z "${_matched_family}" ]]; then
        echo "[ERROR] Unknown --family '${FAMILY_FILTER}'." >&2
        echo "        Valid families listed in qcom-platform.yaml:" >&2
        for _f in "${_all_families[@]}"; do
            echo "          ${_f}" >&2
        done
        exit 1
    fi
    # Expand family to its soc_details and append to SOC_FILTER
    mapfile -t _family_socs < <(python3 -c "
import yaml
d = yaml.safe_load(open('${PLATFORM_DATA}'))
for p in d['platforms']:
    if p['soc_family'].lower() == '${_matched_family,,}':
        for s in p['soc_details']:
            print(s.lower())
        break
")
    echo "[INFO] --family '${_matched_family}' expands to SOCs: ${_family_socs[*]}"
    SOC_FILTER+=("${_family_socs[@]}")
fi

# Step 1: Clone kernel (skip if already present)
if [[ ! -d "${KERNEL_DIR}/.git" ]]; then
    echo "[INFO] Cloning ${KERNEL_REPO} (branch: ${KERNEL_BRANCH}) ..."
    git clone --depth=1 --branch "${KERNEL_BRANCH}" "${KERNEL_REPO}" "${KERNEL_DIR}"
fi

# Step 2: Configure — defconfig + qcom.config if present
mkdir -p "${KOBJ}"
if [[ -f "${KERNEL_DIR}/arch/arm64/configs/qcom.config" ]]; then
    (cd "${KERNEL_DIR}" && env -u KCONFIG_CONFIG \
        ./scripts/kconfig/merge_config.sh -m -O "../${KOBJ}" \
        arch/arm64/configs/defconfig arch/arm64/configs/qcom.config)
    make -C "${KERNEL_DIR}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- O="../${KOBJ}" olddefconfig
else
    make -C "${KERNEL_DIR}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- O="../${KOBJ}" defconfig
fi

# Step 3: Build DTBs only
make -C "${KERNEL_DIR}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- O="../${KOBJ}" -j"$(nproc)" dtbs

DTB_SRC="${KOBJ}/arch/arm64/boot/dts/qcom"
echo "[INFO] Built $(find "${DTB_SRC}" \( -name '*.dtb' -o -name '*.dtbo' \) | wc -l) qcom DTB(s)"

# Step 4: Build FAT DTB image (pass --soc / --board when given)
_extra_args=()
for _s in "${SOC_FILTER[@]+"${SOC_FILTER[@]}"}";   do _extra_args+=(--soc   "$_s"); done
for _b in "${BOARD_FILTER[@]+"${BOARD_FILTER[@]}"}"; do _extra_args+=(--board "$_b"); done

"${SCRIPT_DIR}/build-dtb-image.sh" \
    --dtb-src "${DTB_SRC}" \
    --out "${DTB_BIN}" \
    --size "${DTB_BIN_SIZE}" \
    "${_extra_args[@]}"

echo "[INFO] Done: $(ls -lh "${DTB_BIN}" | awk '{print $5, $9}')"
