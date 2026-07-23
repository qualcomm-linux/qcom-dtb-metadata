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
#   2. PARSE CONFIGS: Extracts 'compatible' strings and 'fdt' lists from
#      '/configurations', handling multi-file and comma-quoted entries.
#   4. METADATA CHECK: Verifies 'compatible' strings against the metadata file.
#      - Applies a whitelist (BLACKLIST_SKIP_PATTERNS) for specific failures.
#   5. LINKAGE CHECK: Ensures every 'fdt' entry in a configuration exactly
#      matches a defined node name in the '/images' section.
#   6. PLATFORM YAML CHECK: Verifies every 'compatible' string in the ITS has
#      a corresponding entry in qcom-platform.yaml. Fails with a clear message
#      identifying the missing compatible and the soc_family it should belong to.
#
# USAGE:
#   ./check-fitimage-metadata.sh [its_file] [metadata_file] [platform_yaml]
# -----------------------------------------------------------------------------

# Optional positional arguments:
#   $1 -> ITS file (qcom-fitimage.its)
#   $2 -> META file (qcom-metadata.dts)
#   $3 -> Platform YAML (qcom-platform.yaml)

ITS_FILE="${1:-qcom-fitimage.its}"
META_FILE="${2:-qcom-metadata.dts}"
PLATFORM_YAML="${3:-qcom-platform.yaml}"

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------
BLACKLIST_SKIP_PATTERNS=("camx" "el2kvm" "staging")

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

		#4. Extract image node names to exclude kernel, ramdisk, and setup entries
		if (line != "" && line !~ /^(kernel|ramdisk|setup)/) {
             print line >> out
        }
		
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

###############################################################################
# 5. PLATFORM YAML CHECK
###############################################################################
# For every 'compatible' string found in the ITS configurations block,
# verify it exists in qcom-platform.yaml. If a compatible is missing,
# fail with a message identifying which soc_family it most likely belongs to,
# so the contributor knows exactly where to add the entry.
check_platform_yaml() {
    if [[ ! -f "${PLATFORM_YAML}" ]]; then
        echo "warn  [PLATFORM-YAML] ${PLATFORM_YAML} not found — skipping platform YAML check."
        return 0
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        echo "warn  [PLATFORM-YAML] python3 not available — skipping platform YAML check."
        return 0
    fi

    python3 - "${ITS_FILE}" "${PLATFORM_YAML}" << 'PYEOF'
import sys, re, yaml

its_file    = sys.argv[1]
yaml_file   = sys.argv[2]

# --- collect all compatible strings from ITS configurations block ---
# Use brace-depth tracking so nested conf-N closing braces do not
# prematurely end the configurations block scan.
its_compats = []
in_configs  = False
depth       = 0
with open(its_file) as f:
    for line in f:
        stripped = line.strip()
        if not in_configs:
            if re.search(r'configurations\s*\{', stripped):
                in_configs = True
                depth = 1
            continue
        depth += stripped.count('{') - stripped.count('}')
        if depth <= 0:
            in_configs = False
            continue
        if stripped.startswith('compatible'):
            m = re.search(r'"([^"]+)"', stripped)
            if m:
                its_compats.append(m.group(1))

# --- build lookup: compatible -> soc_family from YAML ---
data = yaml.safe_load(open(yaml_file))
yaml_compat_to_family = {}
for platform in data['platforms']:
    family = platform['soc_family']
    for board in platform['boards']:
        for compat in board['compatible']:
            yaml_compat_to_family[compat] = family

# --- infer likely soc_family for an unknown compatible ---
# Strategy: match the SoC token (first segment after "qcom,") against
# soc_details entries (case-insensitive) across all families.
soc_to_family = {}
for platform in data['platforms']:
    family = platform['soc_family']
    for soc in platform['soc_details']:
        soc_to_family[soc.lower()] = family

def infer_family(compat):
    # strip "qcom," prefix, then try progressively shorter prefixes
    token = compat.removeprefix('qcom,')
    parts = re.split(r'[-_]', token)
    # try longest-first prefix matches against known soc names
    for length in range(len(parts), 0, -1):
        candidate = ''.join(parts[:length]).lower()
        if candidate in soc_to_family:
            return soc_to_family[candidate]
    # fallback: substring search
    for soc, family in soc_to_family.items():
        if soc in token.lower():
            return family
    return None

failures = []
for compat in its_compats:
    if compat not in yaml_compat_to_family:
        suggested_family = infer_family(compat)
        failures.append((compat, suggested_family))

if failures:
    print()
    print("fail  [PLATFORM-YAML] The following compatible string(s) in the ITS have no")
    print("      corresponding entry in qcom-platform.yaml:")
    print()
    for compat, family in failures:
        print(f"        compatible: \"{compat}\"")
        if family:
            print(f"        → Please add this entry under soc_family: '{family}' in qcom-platform.yaml")
        else:
            print(f"        → Could not infer soc_family — refer to IPCAT to identify the correct")
            print(f"          soc_family, then add a new entry in qcom-platform.yaml.")
        print()
    print("      Every compatible string added to qcom-next-fitimage.its must have a")
    print("      matching board entry (with compatible, soc, board, dtb fields) in")
    print("      qcom-platform.yaml under the appropriate soc_family.")
    print("      To identify the correct soc_family, refer to IPCAT.")
    sys.exit(1)

print(f"Platform YAML Check: Pass ({len(its_compats)} compatible(s) verified against {yaml_file})")
sys.exit(0)
PYEOF
}

check_platform_yaml
if [[ $? -ne 0 ]]; then
    missing_any=1
fi


echo "success"
exit 0
