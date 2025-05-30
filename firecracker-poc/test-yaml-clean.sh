#!/bin/bash

# Test script to validate cloud-init YAML is clean of ANSI escape codes
# Usage: ./test-yaml-clean.sh [yaml-file]

set -euo pipefail

YAML_FILE="${1:-}"

if [ -z "$YAML_FILE" ]; then
    echo "Usage: $0 <yaml-file>"
    echo "Example: $0 instances/vm-id/cloud-init/user-data"
    exit 1
fi

if [ ! -f "$YAML_FILE" ]; then
    echo "❌ File not found: $YAML_FILE"
    exit 1
fi

echo "🔍 Testing YAML file: $YAML_FILE"

# Check for ANSI escape codes
if grep -q $'\x1b' "$YAML_FILE"; then
    echo "❌ ANSI escape codes found in YAML!"
    echo "Problematic lines:"
    grep -n $'\x1b' "$YAML_FILE" | head -5
    echo ""
    echo "Cloud-init will fail to parse this YAML."
    exit 1
else
    echo "✅ No ANSI escape codes found"
fi

# Test YAML syntax if Python is available
if command -v python3 >/dev/null; then
    echo "🔍 Testing YAML syntax with Python..."
    if python3 -c "
import yaml
import sys
try:
    with open('$YAML_FILE', 'r') as f:
        yaml.safe_load(f)
    print('✅ YAML syntax is valid')
except yaml.YAMLError as e:
    print(f'❌ YAML syntax error: {e}')
    sys.exit(1)
except Exception as e:
    print(f'❌ Error reading file: {e}')
    sys.exit(1)
"; then
        echo "✅ YAML file is valid"
    else
        echo "❌ YAML validation failed"
        exit 1
    fi
else
    echo "⚠️  Python3 not available - skipping YAML syntax validation"
fi

# Check for common cloud-init issues
echo "🔍 Checking for common cloud-init issues..."

# Check indentation (should be consistent)
if grep -q $'^\t' "$YAML_FILE"; then
    echo "⚠️  Tab characters found - cloud-init prefers spaces"
fi

# Check for very long lines that might cause issues
if awk 'length > 200' "$YAML_FILE" | head -1 >/dev/null; then
    echo "⚠️  Very long lines found (>200 chars) - might cause issues"
fi

echo "✅ Cloud-init YAML validation complete" 