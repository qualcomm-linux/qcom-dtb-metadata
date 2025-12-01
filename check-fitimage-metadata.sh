#!/usr/bin/env bash
set -euo pipefail

# Optional positional arguments:
#   $1 -> ITS file (qcom-fitimage.its)
#   $2 -> META file (qcom-metadata.dts)
ITS_FILE="${1:-qcom-fitimage.its}"
META_FILE="${2:-qcom-metadata.dts}"

if [[ ! -f "$ITS_FILE" ]]; then
    echo "fail FILE_NOT_FOUND $ITS_FILE" >&2
    exit 1
fi

if [[ ! -f "$META_FILE" ]]; then
    echo "fail FILE_NOT_FOUND $META_FILE" >&2
    exit 1
fi

if ! dtc -I dts -O dtb -o /dev/null "$META_FILE" >/dev/null 2>&1; then
	    echo "fail INVALID_DTS_SYNTAX $META_FILE" >&2
	    exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

missing_any=0

###############################################################################
# 1. Collect all configuration subnodes and their compatible strings
###############################################################################
awk -v out="$tmpdir/config_compat.txt" '
    BEGIN {
        in_configs = 0
        in_node = 0
        node_name = ""
    }

    /configurations[[:space:]]*\{/ {
        in_configs = 1
        next
    }

    in_configs && /^\}/ {
        in_configs = 0
        next
    }

    # Match a configuration subnode: "<cfg_name> {"
    in_configs && /^[[:space:]]*[^[:space:]]+[[:space:]]*\{/ {
        node_name = $1
        sub(/:$/, "", node_name)
        in_node = 1
        next
    }

    in_node && /};[[:space:]]*$/ {
        in_node = 0
        node_name = ""
        next
    }

    # Extract compatible = "<string>";
    in_node && /compatible[[:space:]]*=/ {
        line = $0
        if (match(line, /"[^"]*"/)) {
            compat = substr(line, RSTART+1, RLENGTH-2)
            print node_name, compat >> out
        }
    }
' "$ITS_FILE"

if [[ ! -s "$tmpdir/config_compat.txt" ]]; then
    echo "fail NO_CONFIG_COMPAT $ITS_FILE"
    exit 1
fi

###############################################################################
# 2. Collect only node (subnode) names from qcom-metadata.dts
#    - Ignore labels
#    - Take the last identifier before "{"
###############################################################################

meta_nodes="$tmpdir/meta_nodes.txt"

awk '
    # Any node definition line ending with "{"
    /^[[:space:]]*[^&].*\{/ {
        line = $0

        # Remove everything from "{" onward
        sub(/\{.*/, "", line)

        # Trim leading/trailing whitespace
        sub(/^[[:space:]]+/, "", line)
        sub(/[[:space:]]+$/, "", line)

        # Split on whitespace; last field is the node name (after optional label:)
        n = split(line, a, /[[:space:]]+/)
        if (n < 1)
            next

        node = a[n]

        # Strip trailing ":" if any (defensive, though labels should be before node)
        sub(/:$/, "", node)

        if (node != "") {
            print node
        }
    }
' "$META_FILE" | sort -u > "$meta_nodes"

###############################################################################
# 3. For each configuration, check substrings against node names only
###############################################################################

while read -r cfg compat; do
    compat_no_prefix="${compat#qcom,}"
    IFS='-' read -r -a parts <<< "$compat_no_prefix"

    for part in "${parts[@]}"; do
        [[ -z "$part" ]] && continue

        if ! grep -qx "$part" "$meta_nodes"; then
            echo "fail ${part} ${cfg}"
            missing_any=1
        fi
    done
done < "$tmpdir/config_compat.txt"

if [[ "$missing_any" -ne 0 ]]; then
    exit 2
fi

echo "success"
