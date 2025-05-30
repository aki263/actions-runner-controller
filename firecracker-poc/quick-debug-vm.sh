#!/bin/bash

# Quick remote debug script - runs debug commands via SSH
set -euo pipefail

if [ $# -eq 0 ]; then
    echo "Usage: $0 <vm-ip> [ssh-key-path]"
    echo "Example: $0 172.16.0.10 instances/ak-vm-9/ssh_key"
    exit 1
fi

VM_IP="$1"
SSH_KEY="${2:-instances/*/ssh_key}"

# Find the SSH key if not specified
if [[ "$SSH_KEY" == "instances/*/ssh_key" ]]; then
    SSH_KEY=$(find instances -name "ssh_key" | head -1)
    if [ -z "$SSH_KEY" ]; then
        echo "❌ No SSH key found in instances/"
        exit 1
    fi
    echo "ℹ️  Using SSH key: $SSH_KEY"
fi

echo "🔍 Debugging GitHub configuration on VM: $VM_IP"
echo "=============================================="

# Debug commands to run remotely
ssh -i "$SSH_KEY" -o ConnectTimeout=5 -o StrictHostKeyChecking=no runner@"$VM_IP" '
echo "📋 Environment Variables:"
echo "GITHUB_URL: ${GITHUB_URL:-\"(not set)\"}"
echo "GITHUB_TOKEN: ${GITHUB_TOKEN:0:10}... (first 10 chars)"
echo "RUNNER_NAME: ${RUNNER_NAME:-\"(not set)\"}"

echo -e "\n📁 /etc/environment contents:"
if [ -f /etc/environment ]; then
    cat /etc/environment | grep -E "^(GITHUB_|RUNNER_)" || echo "No GITHUB_/RUNNER_ variables found"
else
    echo "❌ /etc/environment not found"
fi

echo -e "\n🔗 GitHub URL Format Check:"
if [ -n "${GITHUB_URL:-}" ]; then
    echo "✅ GITHUB_URL is set: $GITHUB_URL"
    
    if [[ "$GITHUB_URL" =~ ^https://github\.com/[^/]+/?$ ]]; then
        echo "✅ Organization URL format detected"
    elif [[ "$GITHUB_URL" =~ ^https://github\.com/[^/]+/[^/]+/?$ ]]; then
        echo "✅ Repository URL format detected"
    elif [[ "$GITHUB_URL" =~ ^https://github\.com/enterprises/[^/]+/?$ ]]; then
        echo "✅ Enterprise URL format detected"
    else
        echo "❌ Invalid GitHub URL format!"
        echo "   Expected: https://github.com/owner/repo OR https://github.com/org"
    fi
else
    echo "❌ GITHUB_URL not set in environment"
fi

echo -e "\n🔑 Token Check:"
if [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "✅ GITHUB_TOKEN is set (length: ${#GITHUB_TOKEN})"
    if [[ "$GITHUB_TOKEN" =~ ^ghp_ ]]; then
        echo "✅ Classic PAT format (ghp_)"
    elif [[ "$GITHUB_TOKEN" =~ ^github_pat_ ]]; then
        echo "✅ Fine-grained PAT format (github_pat_)"
    else
        echo "⚠️  Unusual token format (should start with ghp_ or github_pat_)"
    fi
else
    echo "❌ GITHUB_TOKEN not set in environment"
fi

echo -e "\n🌐 GitHub API Test:"
if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_URL:-}" ]; then
    echo "Testing GitHub API access..."
    
    # Parse URL to get API endpoint
    if [[ "$GITHUB_URL" =~ github\.com/([^/]+)/?$ ]]; then
        # Organization URL
        ORG="${BASH_REMATCH[1]}"
        API_URL="https://api.github.com/orgs/$ORG"
        echo "Testing org access: $ORG"
    elif [[ "$GITHUB_URL" =~ github\.com/([^/]+)/([^/]+)/?$ ]]; then
        # Repository URL
        OWNER="${BASH_REMATCH[1]}"
        REPO="${BASH_REMATCH[2]}"
        API_URL="https://api.github.com/repos/$OWNER/$REPO"
        echo "Testing repo access: $OWNER/$REPO"
    else
        echo "❌ Cannot parse GitHub URL for API testing"
        API_URL=""
    fi
    
    if [ -n "$API_URL" ]; then
        HTTP_CODE=$(curl -s -w "%{http_code}" -H "Authorization: Bearer $GITHUB_TOKEN" "$API_URL" -o /dev/null)
        case $HTTP_CODE in
            200) echo "✅ API access successful ($HTTP_CODE)" ;;
            401) echo "❌ Authentication failed ($HTTP_CODE) - Invalid token" ;;
            403) echo "❌ Access forbidden ($HTTP_CODE) - Insufficient permissions" ;;
            404) echo "❌ Not found ($HTTP_CODE) - Repo/org doesnt exist or no access" ;;
            *) echo "❌ Unexpected response: $HTTP_CODE" ;;
        esac
    fi
else
    echo "⚠️  Skipping API test - missing GITHUB_URL or GITHUB_TOKEN"
fi

echo -e "\n📜 Recent Setup Logs:"
if [ -f /var/log/setup-runner.log ]; then
    echo "Last 5 lines from setup-runner.log:"
    tail -5 /var/log/setup-runner.log | sed "s/^/   /"
else
    echo "❌ No setup-runner.log found"
fi

echo -e "\n🔧 Runner Registration Command Test:"
if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_URL:-}" ]; then
    echo "Would run:"
    echo "   cd /opt/runner"
    echo "   ./config.sh --url \"$GITHUB_URL\" --token \"${GITHUB_TOKEN:0:10}...\" --name \"${RUNNER_NAME:-$(hostname)}\" --labels \"${RUNNER_LABELS:-firecracker}\" --unattended"
else
    echo "❌ Cannot test - missing GITHUB_URL or GITHUB_TOKEN"
fi
'

echo -e "\n💡 **Next Steps:**"
echo "1. If environment variables are missing, check your launch command"
echo "2. If URL format is wrong, use: https://github.com/owner/repo or https://github.com/org"  
echo "3. If token fails, verify permissions and try: curl -H 'Authorization: Bearer YOUR_TOKEN' https://api.github.com/user"
echo "4. Check cloud-init logs: ssh -i $SSH_KEY runner@$VM_IP 'journalctl -u cloud-final'" 