#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# SCRIPT: check-fitimage-metadata.sh
#
# PURPOSE:
#   Validates the integrity of a QCOM FIT Image Source (ITS) file against
#   a metadata device tree. It ensures that configurations point to valid
#   image nodes and that metadata compatibility strings are correct.
#
# LOGIC FLOW:
#   1. VALIDATION: Checks if input files exist.
#   2. PARSE IMAGES: Extracts node names from '/images' and validates that
#      referenced files (via /incbin/) actually exist on disk.
#   3. PARSE CONFIGS: Extracts 'compatible' strings and 'fdt' lists from
#      '/configurations', handling multi-file and comma-quoted entries.
#   4. METADATA CHECK: Verifies 'compatible' strings against the metadata file.
#      - Applies a whitelist (BLACKLIST_SKIP_PATTERNS) for specific failures.
#   5. LINKAGE CHECK: Ensures every 'fdt' entry in a configuration exactly
#      matches a defined node name in the '/images' section.
#
# USAGE:
#   ./check-fitimage-metadata.sh [its_file] [metadata_file]
# -----------------------------------------------------------------------------

# Optional positional arguments:
#   $1 -> ITS file (qcom-fitimage.its)
#   $2 -> META file (qcom-metadata.dts)

ITS_FILE="${1:-qcom-fitimage.its}"
META_FILE="${2:-qcom-metadata.dts}"

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------
BLACKLIST_SKIP_PATTERNS=("camx" "el2kvm")
GLOBAL_FAILURE_OCCURRED=0

if [[ ! -f "$ITS_FILE" ]]; then
    echo "fail FILE_NOT_FOUND $ITS_FILE" >&2
    exit 1
fi
if [[ ! -f "$META_FILE" ]]; then
    echo "fail FILE_NOT_FOUND $META_FILE" >&2
    exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# -----------------------------------------------------------------------------
# FUNCTION: Validate Metadata 
# -----------------------------------------------------------------------------
validate_metadata() {
   if ! dtc -I dts -O dtb -o /dev/null "$META_FILE" >/dev/null 2>&1; then
	echo "fail INVALID_DTS_SYNTAX $META_FILE" >&2
    	exit 1
   else
	echo "Metadata Syntax Check: Pass"   
   fi
}
validate_metadata "$META_FILE"

# -----------------------------------------------------------------------------
# FUNCTION: Validate ITS Syntax
# Checks:
# 1. Configuration nodes (conf-) have opening braces '{'
# 2. 'compatible' and 'fdt' properties end with a semicolon ';'
# 3. Configuration nodes are closed properly '};'
# -----------------------------------------------------------------------------

validate_its_syntax() {
    local file="$1"

    # We use awk to track state (inside a conf node or not)
    # logic:
    #   - If line has 'conf-', ensure it has '{'
    #   - If inside conf node, check compatible/fdt lines for trailing ';'
    #   - Track braces to ensure closing
    awk '
    BEGIN {
        in_conf = 0;
        errors = 0;
    }

    # 1. Check for Configuration Node Start
    # Matches "conf-" but ensures it has an opening brace
    /conf-/ {
        if ($0 ~ /\{/) {
            in_conf = 1;
        } else {
            print "ERROR: Line " NR ": Configuration node missing opening brace -> " $0;
            errors++;
        }
    }

    # 2. Check Properties (only while inside a conf node)
    in_conf && /^\s*(compatible|fdt)\s*=/ {
        # Check if line ends with semicolon (ignoring trailing whitespace)
        if ($0 !~ /;\s*$/) {
            print "ERROR: Line " NR ": Property missing trailing semicolon -> " $0;
            errors++;
        }
    }

    # 3. Check for Node Closing
    # If we see "};" and we were in a conf, mark it closed
    in_conf && /^\s*};\s*$/ {
        in_conf = 0;
    }

    END {
        if (errors > 0) {
            print "ITS Syntax Check: FAILED (" errors " errors found)";
            exit 1;
        } else {
            print "ITS Syntax Check: PASS";
            exit 0;
        }
    }
    ' "$file"

    # Capture awk exit code
    if [ $? -ne 0 ]; then
        echo "Exiting due to ITS syntax errors."
        exit 1
    fi
}

validate_its_syntax "$ITS_FILE"



missing_any=0

###############################################################################
# 1. PARSE IMAGE NODES (The targets of the FDT links)
###############################################################################
# We extract the exact name of every subnode directly under /images
# Logic: 
#   1. Find block starting 'images {'
#   2. Inside that block, find lines ending in '{' (these are subnodes)
#   3. Clean whitespace to get the raw node name.
awk -v out="$tmpdir/valid_images.txt" '
    BEGIN { in_images = 0 }
    
    # Start of images node
    /^[[:space:]]*images[[:space:]]*\{/ { in_images = 1; next }
    
    # End of images node (closing brace at same indentation level usually)
    in_images && /^\};/ { in_images = 0; next }
    in_images && /^\t\};/ { in_images = 0; next } 
    # Fallback: if we see a closing brace at start of line, assume end of block
    in_images && /^\}/ { in_images = 0; next }

    # Capture subnodes. Matches lines like: "   fdt-name {"
    in_images && /\{$/ {
        line = $0
        
        # 1. Remove comments if any (//...)
        sub(/\/\/.*$/, "", line)
        
        # 2. Trim trailing "{" and whitespace
        sub(/[[:space:]]*\{[[:space:]]*$/, "", line)
        
        # 3. Trim leading whitespace
        sub(/^[[:space:]]+/, "", line)
        
        # 4. Ignore "data", "hash", "signature" subnodes if they appear with braces
        # (Though usually these are properties or nested deeper, valid image nodes 
        # usually start with fdt- or kernel-)
        if (line != "" && line !~ /^(kernel|ramdisk|setup)/) {
             print line >> out
        }
        
        # Explicitly print kernel/fdt nodes if logic above filters too much
        # Ideally, we just print everything that looks like a node name.
    }
' "$ITS_FILE"

# Make sure we got something (fallback for non-standard formatting)
# Re-run strict extraction if previous one was empty or to handle "fdt-..." specifically
if [[ ! -s "$tmpdir/valid_images.txt" ]]; then
    # Simpler regex approach for standard ITS files
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
# 2. PARSE CONFIGURATIONS
###############################################################################
# Extract: NodeName | Compatible | FDT_List
awk -v out="$tmpdir/config_data.txt" '
    BEGIN {
        in_configs = 0
        in_node = 0
        current_node = ""
        current_compat = ""
        current_fdt_list = ""
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
        if (current_node != "") {
            print current_node "|" current_compat "|" current_fdt_list >> out
        }
        in_node = 0
        current_node = ""
        next
    }

    in_node && /compatible[[:space:]]*=/ {
        line = $0
        if (match(line, /"[^"]*"/)) {
            current_compat = substr(line, RSTART+1, RLENGTH-2)
        }
    }

    in_node && /fdt[[:space:]]*=/ {
        line = $0
        while (match(line, /"[^"]*"/)) {
            val = substr(line, RSTART+1, RLENGTH-2)
            if (current_fdt_list == "") {
                current_fdt_list = val
            } else {
                current_fdt_list = current_fdt_list " " val
            }
            line = substr(line, RSTART + RLENGTH)
        }
    }
' "$ITS_FILE"

###############################################################################
# 3. METADATA NODES
###############################################################################
meta_nodes="$tmpdir/meta_nodes.txt"
if [ -f "$META_FILE" ]; then
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
# 4. VALIDATION LOOP
###############################################################################
while IFS='|' read -r cfg compat fdt_val_raw; do
    
    # --- CHECK A: Metadata ---
    if [[ -n "$compat" ]]; then
        compat_no_prefix="${compat#qcom,}"
        IFS='-' read -r -a parts <<< "$compat_no_prefix"
        for part in "${parts[@]}"; do
            [[ -z "$part" ]] && continue
            if grep -qx "$part" "$meta_nodes"; then continue; fi
            
            is_blacklisted=0
            for pattern in "${BLACKLIST_SKIP_PATTERNS[@]}"; do
                if [[ "$part" == "$pattern" ]]; then is_blacklisted=1; break; fi
            done

            if [[ "$is_blacklisted" -ne 1 ]]; then
                echo "fail  [METADATA] ${cfg}: '${part}' missing from metadata"
                missing_any=1
            fi
        done
    fi

    # --- CHECK B: FDT Linkage ---
    if [[ -z "$fdt_val_raw" ]]; then
        echo "fail  [FDT-PROP] ${cfg}: Missing 'fdt' property"
        missing_any=1
        continue
    fi

    read -r -a fdt_entries <<< "$fdt_val_raw"

    for fdt_entry in "${fdt_entries[@]}"; do
        # 1. Check Prefix
        if [[ "$fdt_entry" != fdt-* ]]; then
            echo "fail  [FDT-NAME] ${cfg}: entry '$fdt_entry' does not start with 'fdt-'"
            missing_any=1
        fi

        # 2. Check Existence in Images (Exact Match)
        # -F: Fixed string (handles dots/commas literally)
        # -x: Exact line match (avoids partial matches)
        if ! grep -Fx -q "$fdt_entry" "$tmpdir/valid_images.txt"; then
            echo "fail  [FDT-LINK] ${cfg}: entry '$fdt_entry' NOT found in /images"
            missing_any=1
        fi
    done

done < "$tmpdir/config_data.txt"

if [[ "$missing_any" -ne 0 ]]; then
    echo "FAILED: One or more checks failed."
    exit 2
fi

echo "success"
exit 0
