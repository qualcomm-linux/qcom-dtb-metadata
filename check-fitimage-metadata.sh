#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# SCRIPT: check-fitimage-metadata.sh
#
# PURPOSE:
#   Validates the integrity of a QCOM FIT Image Source (ITS) file against
#   metadata DTS, validates /configurations linkage, optionally validates FIT
#   creation with mkimage, and optionally validates overlay application order.
#
# CHECKS PERFORMED:
#   1) Input/dependency checks (files, awk/grep, mode values).
#   2) Metadata DTS syntax validation using dtc.
#   3) ITS configuration syntax sanity checks.
#   4) /images and /configurations consistency/linkage checks.
#   5) Overlay application/order validation (auto/strict/off).
#   6) FIT build validation with mkimage (auto/strict/off).
#
# USAGE:
#   ./check-fitimage-metadata.sh [its_file] [metadata_file]
#
# ENV:
#   FIT_OVERLAY_CHECK_MODE=auto|strict|off (default: auto)
#   FIT_BUILD_CHECK_MODE=auto|strict|off   (default: auto)
#   FIT_DTB_DIR=<path> (default: <its_dir>/kobj/arch/arm64/boot/dts/qcom)
# -----------------------------------------------------------------------------

ITS_FILE="${1:-qcom-fitimage.its}"
META_FILE="${2:-qcom-metadata.dts}"
ITS_DIR="$(cd "$(dirname "$ITS_FILE")" && pwd)"

BLACKLIST_SKIP_PATTERNS=("camx" "el2kvm" "staging")
OVERLAY_CHECK_MODE="${FIT_OVERLAY_CHECK_MODE:-auto}" # auto|strict|off
FIT_BUILD_CHECK_MODE="${FIT_BUILD_CHECK_MODE:-auto}" # auto|strict|off
FIT_DTB_DIR="${FIT_DTB_DIR:-${ITS_DIR}/kobj/arch/arm64/boot/dts/qcom}"

if [[ ! -f "$ITS_FILE" ]]; then
    echo "fail FILE_NOT_FOUND $ITS_FILE" >&2
    exit 1
fi
if [[ ! -f "$META_FILE" ]]; then
    echo "fail FILE_NOT_FOUND $META_FILE" >&2
    exit 1
fi

if ! command -v awk >/dev/null 2>&1 || ! command -v grep >/dev/null 2>&1; then
    echo "fail MISSING_DEPENDENCY awk/grep" >&2
    exit 1
fi

if [[ "$OVERLAY_CHECK_MODE" != "auto" && "$OVERLAY_CHECK_MODE" != "strict" && "$OVERLAY_CHECK_MODE" != "off" ]]; then
    echo "fail INVALID_OVERLAY_MODE '$OVERLAY_CHECK_MODE' (expected: auto|strict|off)" >&2
    exit 1
fi
if [[ "$FIT_BUILD_CHECK_MODE" != "auto" && "$FIT_BUILD_CHECK_MODE" != "strict" && "$FIT_BUILD_CHECK_MODE" != "off" ]]; then
    echo "fail INVALID_FIT_BUILD_MODE '$FIT_BUILD_CHECK_MODE' (expected: auto|strict|off)" >&2
    exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

validate_metadata() {
    if ! dtc -I dts -O dtb -o /dev/null "$META_FILE" >/dev/null 2>&1; then
        echo "fail INVALID_DTS_SYNTAX $META_FILE" >&2
        exit 1
    fi
    echo "Metadata Syntax Check: Pass"
}

validate_its_syntax() {
    local file="$1"
    awk '
    BEGIN { in_conf = 0; errors = 0 }
    /conf-/ {
        if ($0 ~ /\{/) in_conf = 1
        else {
            print "ERROR: Line " NR ": Configuration node missing opening brace -> " $0
            errors++
        }
    }
    in_conf && /^\s*(compatible|fdt)\s*=/ {
        if ($0 !~ /;\s*$/) {
            print "ERROR: Line " NR ": Property missing trailing semicolon -> " $0
            errors++
        }
    }
    in_conf && /^\s*};\s*$/ { in_conf = 0 }
    END {
        if (errors > 0) {
            print "ITS Syntax Check: FAILED (" errors " errors found)"
            exit 1
        }
        print "ITS Syntax Check: PASS"
        exit 0
    }
    ' "$file"
}

validate_metadata
validate_its_syntax "$ITS_FILE"

can_apply_overlay=1
if [[ "$OVERLAY_CHECK_MODE" != "off" ]] && ! command -v fdtoverlay >/dev/null 2>&1; then
    if [[ "$OVERLAY_CHECK_MODE" == "strict" ]]; then
        echo "fail MISSING_DEPENDENCY fdtoverlay (required for strict overlay validation)" >&2
        exit 1
    fi
    can_apply_overlay=0
fi

can_build_fit=1
if [[ "$FIT_BUILD_CHECK_MODE" != "off" ]] && ! command -v mkimage >/dev/null 2>&1; then
    if [[ "$FIT_BUILD_CHECK_MODE" == "strict" ]]; then
        echo "fail MISSING_DEPENDENCY mkimage (required for strict fit build validation)" >&2
        exit 1
    fi
    can_build_fit=0
fi

can_run_overlay_diag=1
if ! command -v fdtget >/dev/null 2>&1; then
    can_run_overlay_diag=0
fi

missing_any=0

diagnose_overlay_notfound() {
    local cfg="$1"
    local base_blob="$2"
    local overlay_blob="$3"
    local missing_labels=()
    local missing_paths=()
    local labels_list="" fragments_list="" label="" fragment="" tpath=""

    if [[ "$can_run_overlay_diag" -ne 1 ]]; then
        return
    fi

    if labels_list="$(fdtget -p "$overlay_blob" /__fixups__ 2>/dev/null)"; then
        while IFS= read -r label; do
            [[ -z "$label" ]] && continue
            if ! fdtget -t s "$base_blob" /__symbols__ "$label" >/dev/null 2>&1; then
                missing_labels+=("$label")
            fi
        done <<< "$labels_list"
    fi

    if fragments_list="$(fdtget -l "$overlay_blob" / 2>/dev/null)"; then
        while IFS= read -r fragment; do
            [[ "$fragment" != fragment@* ]] && continue
            tpath="$(fdtget -t s "$overlay_blob" "/${fragment}" target-path 2>/dev/null || true)"
            [[ -z "$tpath" ]] && continue
            if ! fdtget -l "$base_blob" "$tpath" >/dev/null 2>&1; then
                missing_paths+=("$tpath")
            fi
        done <<< "$fragments_list"
    fi

    if [[ "${#missing_labels[@]}" -gt 0 ]]; then
        echo "fail  [OVERLAY-NOTFOUND] ${cfg}: missing base __symbols__ labels required by overlay: ${missing_labels[*]}"
    fi
    if [[ "${#missing_paths[@]}" -gt 0 ]]; then
        echo "fail  [OVERLAY-NOTFOUND] ${cfg}: missing base nodes referenced by overlay target-path: ${missing_paths[*]}"
    fi
    if [[ "${#missing_labels[@]}" -eq 0 && "${#missing_paths[@]}" -eq 0 ]]; then
        echo "fail  [OVERLAY-NOTFOUND] ${cfg}: unable to isolate missing symbol/path; likely unresolved phandle target in base dtb"
    fi
}

###############################################################################
# 1. PARSE IMAGE NODES under /images
###############################################################################
awk -v out="$tmpdir/valid_images.txt" '
    BEGIN { in_images = 0 }
    /^[[:space:]]*images[[:space:]]*\{/ { in_images = 1; next }
    in_images && /^\};/ { in_images = 0; next }
    in_images && /^\t\};/ { in_images = 0; next }
    in_images && /^\}/ { in_images = 0; next }
    in_images && /\{$/ {
        line = $0
        sub(/\/\/.*$/, "", line)
        sub(/[[:space:]]*\{[[:space:]]*$/, "", line)
        sub(/^[[:space:]]+/, "", line)
        if (line != "" && line !~ /^(kernel|ramdisk|setup)/) print line >> out
    }
' "$ITS_FILE"

if [[ ! -s "$tmpdir/valid_images.txt" ]]; then
    awk '
        /images[[:space:]]*\{/ { in_img=1; next }
        in_img && /\};/ { in_img=0; next }
        in_img && /^[[:space:]]*fdt-.*\{/ {
            node=$1
            sub(/\{/, "", node)
            print node
        }
    ' "$ITS_FILE" > "$tmpdir/valid_images.txt"
fi

###############################################################################
# 1B. MAP /images node -> resolved blob path
###############################################################################
awk -v out="$tmpdir/image_to_file_raw.txt" -v its_dir="$ITS_DIR" '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    BEGIN { in_images = 0; depth = 0; cur = "" }
    /^[[:space:]]*images[[:space:]]*\{/ { in_images = 1; depth = 1; next }
    !in_images { next }
    {
        line = $0
        gsub(/\/\/.*$/, "", line)
        opens = gsub(/\{/, "{", line)
        closes = gsub(/\}/, "}", line)

        if (depth == 1 && line ~ /^[[:space:]]*[^[:space:]][^{}]*\{[[:space:]]*$/) {
            node = line
            sub(/[[:space:]]*\{[[:space:]]*$/, "", node)
            node = trim(node)
            if (node != "" && node !~ /^(kernel|ramdisk|setup)$/) cur = node
        }

        if (cur != "" && match(line, /data[[:space:]]*=[[:space:]]*\/incbin\/\("([^"]+)"\)/, m)) {
            p = m[1]
            if (p ~ /^\.\//) p = substr(p, 3)
            print cur "|" its_dir "/" p >> out
        }

        depth += opens
        depth -= closes
        if (depth <= 0) { in_images = 0; cur = "" }
        else if (depth == 1) cur = ""
    }
' "$ITS_FILE"

: > "$tmpdir/image_to_file.txt"
while IFS='|' read -r node abs_path; do
    [[ -z "$node" ]] && continue
    if [[ -f "$abs_path" ]]; then
        printf "%s|%s\n" "$node" "$abs_path" >> "$tmpdir/image_to_file.txt"
    else
        bname="$(basename "$abs_path")"
        alt_path="${FIT_DTB_DIR}/${bname}"
        if [[ -f "$alt_path" ]]; then
            printf "%s|%s\n" "$node" "$alt_path" >> "$tmpdir/image_to_file.txt"
        else
            printf "%s|%s\n" "$node" "$abs_path" >> "$tmpdir/image_to_file.txt"
        fi
    fi
done < "$tmpdir/image_to_file_raw.txt"

###############################################################################
# 2. PARSE CONFIGURATIONS
###############################################################################
awk -v out="$tmpdir/config_data.txt" '
    BEGIN {
        in_configs = 0; in_node = 0
        current_node = ""; current_compat = ""; current_fdt_list = ""
    }
    /configurations[[:space:]]*\{/ { in_configs = 1; next }
    in_configs && /^\}/ { in_configs = 0; next }
    in_configs && /^[[:space:]]*[^[:space:]]+[[:space:]]*\{/ {
        current_node = $1
        sub(/:$/, "", current_node)
        in_node = 1
        current_compat = ""
        current_fdt_list = ""
        next
    }
    in_node && /};[[:space:]]*$/ {
        if (current_node != "") print current_node "|" current_compat "|" current_fdt_list >> out
        in_node = 0
        current_node = ""
        next
    }
    in_node && /compatible[[:space:]]*=/ {
        line = $0
        if (match(line, /"[^"]*"/)) current_compat = substr(line, RSTART+1, RLENGTH-2)
    }
    in_node && /fdt[[:space:]]*=/ {
        line = $0
        while (match(line, /"[^"]*"/)) {
            val = substr(line, RSTART+1, RLENGTH-2)
            if (current_fdt_list == "") current_fdt_list = val
            else current_fdt_list = current_fdt_list " " val
            line = substr(line, RSTART + RLENGTH)
        }
    }
' "$ITS_FILE"

###############################################################################
# 2B. DETECT DUPLICATE CONFIGURATION NODE NAMES
###############################################################################
awk -v out="$tmpdir/config_dups.txt" '
    BEGIN { in_configs = 0 }
    /configurations[[:space:]]*\{/ { in_configs = 1; next }
    in_configs && /^\}/ { in_configs = 0; next }
    in_configs && /^[[:space:]]*[^[:space:]]+[[:space:]]*\{/ {
        node = $1
        sub(/:$/, "", node)
        count[node]++
        if (lines[node] == "") lines[node] = NR
        else lines[node] = lines[node] "," NR
    }
    END {
        for (n in count) {
            if (count[n] > 1) print n "|" lines[n] >> out
        }
    }
' "$ITS_FILE"

###############################################################################
# 2C. EXTRACT CONF-* NODE ORDER/INDEX FOR SEQUENCE VALIDATION
###############################################################################
awk -v out="$tmpdir/config_seq.txt" '
    BEGIN { in_configs = 0 }
    /configurations[[:space:]]*\{/ { in_configs = 1; next }
    in_configs && /^\}/ { in_configs = 0; next }
    in_configs && /^[[:space:]]*[^[:space:]]+[[:space:]]*\{/ {
        node = $1
        sub(/:$/, "", node)
        if (node ~ /^conf-[0-9]+$/) {
            num = node
            sub(/^conf-/, "", num)
            print node "|" num "|" NR >> out
        }
    }
' "$ITS_FILE"

###############################################################################
# 3. METADATA NODES
###############################################################################
meta_nodes="$tmpdir/meta_nodes.txt"
if [[ -f "$META_FILE" ]]; then
    awk '
        /^[[:space:]]*[^&].*\{/ {
            line = $0
            sub(/\{.*/, "", line)
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            n = split(line, a, /[[:space:]]+/)
            if (n >= 1) {
                node = a[n]
                sub(/:$/, "", node)
                if (node != "") print node
            }
        }
    ' "$META_FILE" | sort -u > "$meta_nodes"
else
    touch "$meta_nodes"
fi

###############################################################################
# 3B. FIT BUILD CREATION CHECK (mkimage)
###############################################################################
if [[ "$FIT_BUILD_CHECK_MODE" != "off" ]]; then
    if [[ "$can_build_fit" -ne 1 ]]; then
        echo "info  [FIT-SKIP] mkimage not found; skipping fit image creation validation"
    else
        meta_blob_for_fit=""
        if [[ ! -f "${ITS_DIR}/qcom-metadata.dtb" && -f "$META_FILE" ]]; then
            if dtc -I dts -O dtb -o "$tmpdir/qcom-metadata.dtb" "$META_FILE" >/dev/null 2>&1; then
                meta_blob_for_fit="$tmpdir/qcom-metadata.dtb"
            fi
        fi

        resolved_its="$tmpdir/resolved-fitimage.its"
        unresolved_incbins="$tmpdir/fit-unresolved-incbin.txt"
        : > "$unresolved_incbins"
        awk -v fallback="$FIT_DTB_DIR" -v its_dir="$ITS_DIR" -v meta_blob="$meta_blob_for_fit" -v unresolved="$unresolved_incbins" '
            function q(s,   t) {
                t = s
                gsub(/\\/, "\\\\", t)
                gsub(/"/, "\\\"", t)
                return t
            }
            function file_exists(p,   cmd, rc) {
                cmd = "test -f \"" q(p) "\""
                rc = system(cmd)
                return (rc == 0)
            }
            function resolve_path(src,   rel, base, cand, n, parts, alt) {
                rel = src
                sub(/^\.\//, "", rel)
                cand = its_dir "/" rel
                if (file_exists(cand)) return cand
                n = split(rel, parts, "/")
                base = parts[n]
                if (base == "qcom-metadata.dtb" && meta_blob != "" && file_exists(meta_blob)) return meta_blob
                alt = fallback "/" base
                if (file_exists(alt)) return alt
                return ""
            }
            {
                line = $0
                if (match(line, /\/incbin\/\("([^"]+)"\)/, m)) {
                    r = resolve_path(m[1])
                    if (r != "") {
                        esc = r
                        gsub(/\\/, "\\\\", esc)
                        gsub(/&/, "\\&", esc)
                        line = substr(line, 1, RSTART - 1) "/incbin/(\"" esc "\")" substr(line, RSTART + RLENGTH)
                    } else {
                        print m[1] >> unresolved
                    }
                }
                print line
            }
        ' "$ITS_FILE" > "$resolved_its"

        mkimage_log="$tmpdir/mkimage-fit-build.log"
        if mkimage -f "$resolved_its" "$tmpdir/fit-check.itb" >/dev/null 2>"$mkimage_log"; then
            echo "FIT Build Check: PASS"
        else
            reason="mkimage returned non-zero exit status"
            if [[ -s "$unresolved_incbins" ]]; then
                first_missing="$(head -n 1 "$unresolved_incbins")"
                reason="unresolved /incbin/ path '$first_missing'"
            elif [[ -s "$mkimage_log" ]]; then
                mk_err="$(grep -m1 -v '^[[:space:]]*$' "$mkimage_log" || true)"
                if [[ -n "$mk_err" ]]; then
                    reason="$mk_err"
                fi
            fi
            msg="fail  [FIT-BUILD] unable to create FIT image from ITS: $reason"
            echo "$msg"
            missing_any=1
        fi
    fi
fi

###############################################################################
# 4. VALIDATION LOOP
###############################################################################
if [[ -s "$tmpdir/config_dups.txt" ]]; then
    while IFS='|' read -r cfg_name dup_lines; do
        [[ -z "$cfg_name" ]] && continue
        echo "fail  [CONF-DUP] duplicate configuration node '$cfg_name' (lines: $dup_lines)"
        missing_any=1
    done < "$tmpdir/config_dups.txt"
fi

if [[ -s "$tmpdir/config_seq.txt" ]]; then
    expected_conf=1
    while IFS='|' read -r conf_node conf_num conf_line; do
        [[ -z "$conf_node" || -z "$conf_num" ]] && continue
        if [[ "$conf_num" -ne "$expected_conf" ]]; then
            echo "fail  [CONF-SEQ] expected conf-${expected_conf}, found ${conf_node} (line: ${conf_line})"
            missing_any=1
        fi
        expected_conf=$((expected_conf + 1))
    done < "$tmpdir/config_seq.txt"
fi

while IFS='|' read -r cfg compat fdt_val_raw; do
    if [[ -n "$compat" ]]; then
        compat_no_prefix="${compat#qcom,}"
        IFS='-' read -r -a parts <<< "$compat_no_prefix"
        for part in "${parts[@]}"; do
            [[ -z "$part" ]] && continue
            if grep -qx "$part" "$meta_nodes"; then
                continue
            fi

            is_blacklisted=0
            for pattern in "${BLACKLIST_SKIP_PATTERNS[@]}"; do
                if [[ "$part" == "$pattern" ]]; then
                    is_blacklisted=1
                    break
                fi
            done

            if [[ "$is_blacklisted" -ne 1 ]]; then
                echo "fail  [METADATA] ${cfg}: '${part}' missing from metadata"
                missing_any=1
            fi
        done
    fi

    if [[ -z "$fdt_val_raw" ]]; then
        echo "fail  [FDT-PROP] ${cfg}: Missing 'fdt' property"
        missing_any=1
        continue
    fi

    read -r -a fdt_entries <<< "$fdt_val_raw"

    for fdt_entry in "${fdt_entries[@]}"; do
        if [[ "$fdt_entry" != fdt-* ]]; then
            echo "fail  [FDT-NAME] ${cfg}: entry '$fdt_entry' does not start with 'fdt-'"
            missing_any=1
        fi

        if ! grep -Fx -q "$fdt_entry" "$tmpdir/valid_images.txt"; then
            echo "fail  [FDT-LINK] ${cfg}: entry '$fdt_entry' NOT found in /images"
            missing_any=1
        fi
    done

    if [[ "$OVERLAY_CHECK_MODE" != "off" && "${#fdt_entries[@]}" -gt 1 ]]; then
        if [[ "$can_apply_overlay" -ne 1 ]]; then
            echo "info  [OVERLAY-SKIP] ${cfg}: fdtoverlay not found; skipping overlay apply validation"
            continue
        fi

        base_entry="${fdt_entries[0]}"
        base_blob="$(awk -F'|' -v k="$base_entry" '$1==k { print $2; exit }' "$tmpdir/image_to_file.txt")"
        if [[ -z "$base_blob" || ! -f "$base_blob" ]]; then
            msg="fail  [OVERLAY-BASE] ${cfg}: base '$base_entry' blob missing for overlay validation"
            if [[ "$OVERLAY_CHECK_MODE" == "strict" ]]; then
                echo "$msg"
                missing_any=1
            else
                echo "info  [OVERLAY-SKIP] ${cfg}: ${msg#fail  }"
            fi
            continue
        fi

        work_dtb="$tmpdir/${cfg}.work.dtb"
        out_dtb="$tmpdir/${cfg}.out.dtb"
        cp "$base_blob" "$work_dtb"

        for ((idx=1; idx<${#fdt_entries[@]}; idx++)); do
            overlay_entry="${fdt_entries[idx]}"
            overlay_blob="$(awk -F'|' -v k="$overlay_entry" '$1==k { print $2; exit }' "$tmpdir/image_to_file.txt")"

            if [[ -z "$overlay_blob" || ! -f "$overlay_blob" ]]; then
                msg="fail  [OVERLAY-BLOB] ${cfg}: overlay '$overlay_entry' blob missing for validation"
                if [[ "$OVERLAY_CHECK_MODE" == "strict" ]]; then
                    echo "$msg"
                    missing_any=1
                    break
                fi
                echo "info  [OVERLAY-SKIP] ${cfg}: ${msg#fail  }"
                continue 2
            fi

            overlay_err=""
            if ! overlay_err="$(fdtoverlay -i "$work_dtb" -o "$out_dtb" "$overlay_blob" 2>&1 >/dev/null)"; then
                echo "fail  [OVERLAY-APPLY] ${cfg}: failed applying '$overlay_entry' on '$base_entry'"
                if [[ -n "$overlay_err" ]]; then
                    echo "fail  [OVERLAY-ISSUE] ${cfg}: ${overlay_err}"
                fi
                if [[ "$overlay_err" == *"FDT_ERR_NOTFOUND"* ]]; then
                    diagnose_overlay_notfound "$cfg" "$work_dtb" "$overlay_blob"
                fi
                missing_any=1
                break
            fi
            mv "$out_dtb" "$work_dtb"
        done
    fi
done < "$tmpdir/config_data.txt"

if [[ "$missing_any" -ne 0 ]]; then
    echo "FAILED: One or more checks failed."
    exit 2
fi

echo "success"
exit 0
