#!/bin/bash

# Debug script to check GitHub configuration in Firecracker VM
# Run this inside the VM via SSH to diagnose GitHub registration issues

echo "🔍 GitHub Actions Runner Configuration Debug"
echo "=============================================="

# Check environment variables
echo "📋 Environment Variables:"
echo "GITHUB_URL: ${GITHUB_URL:-'(not set)'}"
echo "GITHUB_TOKEN: ${GITHUB_TOKEN:0:10}... (showing first 10 chars)"
echo "RUNNER_NAME: ${RUNNER_NAME:-'(not set)'}"
echo "RUNNER_LABELS: ${RUNNER_LABELS:-'(not set)'}"

# Check /etc/environment
echo -e "\n📁 /etc/environment contents:"
if [ -f /etc/environment ]; then
    grep "GITHUB_" /etc/environment || echo "No GITHUB_ variables found"
else
    echo "❌ /etc/environment not found"
fi

# Validate GitHub URL format
echo -e "\n🔗 GitHub URL Validation:"
if [ -n "${GITHUB_URL}" ]; then
    echo "✅ GITHUB_URL is set"
    
    # Check URL format
    if [[ "${GITHUB_URL}" =~ ^https://github\.com/[^/]+/?$ ]]; then
        echo "✅ Organization URL format detected"
    elif [[ "${GITHUB_URL}" =~ ^https://github\.com/[^/]+/[^/]+/?$ ]]; then
        echo "✅ Repository URL format detected" 
    elif [[ "${GITHUB_URL}" =~ ^https://github\.com/enterprises/[^/]+/?$ ]]; then
        echo "✅ Enterprise URL format detected"
    else
        echo "❌ Invalid GitHub URL format"
        echo "   Expected: https://github.com/owner/repo OR https://github.com/org"
        echo "   Got: ${GITHUB_URL}"
    fi
else
    echo "❌ GITHUB_URL not set"
fi

# Check token format
echo -e "\n🔑 GitHub Token Validation:"
if [ -n "${GITHUB_TOKEN}" ]; then
    echo "✅ GITHUB_TOKEN is set"
    
    # Check token format
    if [[ "${GITHUB_TOKEN}" =~ ^ghp_ ]]; then
        echo "✅ Classic personal access token format"
    elif [[ "${GITHUB_TOKEN}" =~ ^github_pat_ ]]; then
        echo "✅ Fine-grained personal access token format"  
    elif [[ "${GITHUB_TOKEN}" =~ ^ghs_ ]]; then
        echo "✅ GitHub App installation token format"
    else
        echo "⚠️  Unrecognized token format (should start with ghp_, github_pat_, or ghs_)"
    fi
    
    echo "   Token length: ${#GITHUB_TOKEN} characters"
else
    echo "❌ GITHUB_TOKEN not set"
fi

# Test GitHub API connectivity
echo -e "\n🌐 GitHub API Connectivity Test:"
if command -v curl >/dev/null; then
    echo "Testing basic GitHub API access..."
    
    # Test without authentication first
    if curl -s --connect-timeout 5 https://api.github.com/zen >/dev/null; then
        echo "✅ Can reach GitHub API"
    else
        echo "❌ Cannot reach GitHub API (network issue)"
        exit 1
    fi
    
    # Test with token
    if [ -n "${GITHUB_TOKEN}" ] && [ -n "${GITHUB_URL}" ]; then
        echo "Testing authenticated access..."
        
        # Extract owner/repo from URL
        if [[ "${GITHUB_URL}" =~ github\.com/([^/]+)/?$ ]]; then
            # Organization URL
            ORG_OR_OWNER="${BASH_REMATCH[1]}"
            API_URL="https://api.github.com/orgs/${ORG_OR_OWNER}"
            echo "Testing organization access: ${ORG_OR_OWNER}"
        elif [[ "${GITHUB_URL}" =~ github\.com/([^/]+)/([^/]+)/?$ ]]; then
            # Repository URL  
            OWNER="${BASH_REMATCH[1]}"
            REPO="${BASH_REMATCH[2]}"
            API_URL="https://api.github.com/repos/${OWNER}/${REPO}"
            echo "Testing repository access: ${OWNER}/${REPO}"
        else
            echo "❌ Cannot parse GitHub URL for API testing"
            exit 1
        fi
        
        # Test API access
        RESPONSE=$(curl -s -w "%{http_code}" -H "Authorization: Bearer ${GITHUB_TOKEN}" "${API_URL}")
        HTTP_CODE="${RESPONSE: -3}"
        BODY="${RESPONSE%???}"
        
        case $HTTP_CODE in
            200)
                echo "✅ Authenticated API access successful"
                echo "   Repository/Organization exists and token has access"
                ;;
            401)
                echo "❌ Authentication failed (401)"
                echo "   Token is invalid or expired"
                ;;
            403)
                echo "❌ Access forbidden (403)" 
                echo "   Token lacks required permissions"
                ;;
            404)
                echo "❌ Not found (404)"
                echo "   Repository/Organization doesn't exist or token lacks access"
                ;;
            *)
                echo "❌ Unexpected response: $HTTP_CODE"
                echo "   Response: $BODY"
                ;;
        esac
    else
        echo "⚠️  Skipping authenticated test (missing token or URL)"
    fi
else
    echo "❌ curl not available for testing"
fi

# Check runner directory and permissions
echo -e "\n📂 Runner Directory Check:"
if [ -d "/opt/runner" ]; then
    echo "✅ /opt/runner directory exists"
    echo "   Owner: $(stat -c '%U:%G' /opt/runner)"
    echo "   Permissions: $(stat -c '%a' /opt/runner)"
    
    if [ -f "/opt/runner/config.sh" ]; then
        echo "✅ config.sh exists"
    else
        echo "❌ config.sh not found"
    fi
else
    echo "❌ /opt/runner directory not found"
fi

# Check previous registration attempts
echo -e "\n📜 Previous Registration Logs:"
if [ -f "/var/log/setup-runner.log" ]; then
    echo "Last few setup log entries:"
    tail -10 /var/log/setup-runner.log | sed 's/^/   /'
else
    echo "❌ No setup logs found"
fi

echo -e "\n💡 Recommendations:"
if [ -z "${GITHUB_URL}" ] || [ -z "${GITHUB_TOKEN}" ]; then
    echo "1. Ensure GitHub URL and token are properly set in launch command"
    echo "2. Check cloud-init logs: journalctl -u cloud-final"
fi

echo "3. Verify token permissions match your GitHub URL type (repo/org/enterprise)"
echo "4. Test token manually: curl -H 'Authorization: Bearer YOUR_TOKEN' https://api.github.com/user"
echo "5. Check GitHub API rate limits and service status" 