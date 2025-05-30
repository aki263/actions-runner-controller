#!/bin/bash

# GitHub Runner Token Generator
# Generates short-lived registration tokens using GitHub API (like ARC does)
# 
# SECURITY: This script uses your PAT to generate short-lived registration tokens.
# The registration token should be passed to VMs/containers, NOT the PAT.
# PATs have broader permissions and should remain on trusted hosts only.
#
# Usage: ./generate-runner-token.sh --github-url <url> --github-pat <pat>

set -euo pipefail

GITHUB_URL=""
GITHUB_PAT=""
RUNNER_NAME=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --github-url) GITHUB_URL="$2"; shift 2 ;;
        --github-pat) GITHUB_PAT="$2"; shift 2 ;;
        --runner-name) RUNNER_NAME="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$GITHUB_URL" ] || [ -z "$GITHUB_PAT" ]; then
    echo "Usage: $0 --github-url <url> --github-pat <pat> [--runner-name <name>]"
    echo ""
    echo "Examples:"
    echo "  $0 --github-url https://github.com/owner/repo --github-pat ghp_xxx"
    echo "  $0 --github-url https://github.com/org --github-pat ghp_xxx"
    echo "  $0 --github-url https://github.com/enterprises/ent --github-pat ghp_xxx"
    exit 1
fi

# Validate GitHub URL format and extract components
if [[ "$GITHUB_URL" =~ ^https://github\.com/enterprises/([^/]+)/?$ ]]; then
    # Enterprise URL
    ENTERPRISE="${BASH_REMATCH[1]}"
    API_URL="https://api.github.com/enterprises/${ENTERPRISE}/actions/runners/registration-token"
    SCOPE="enterprise"
    TARGET="$ENTERPRISE"
elif [[ "$GITHUB_URL" =~ ^https://github\.com/([^/]+)/?$ ]]; then
    # Organization URL
    ORG="${BASH_REMATCH[1]}"
    API_URL="https://api.github.com/orgs/${ORG}/actions/runners/registration-token"
    SCOPE="organization"
    TARGET="$ORG"
elif [[ "$GITHUB_URL" =~ ^https://github\.com/([^/]+)/([^/]+)/?$ ]]; then
    # Repository URL
    OWNER="${BASH_REMATCH[1]}"
    REPO="${BASH_REMATCH[2]}"
    API_URL="https://api.github.com/repos/${OWNER}/${REPO}/actions/runners/registration-token"
    SCOPE="repository"
    TARGET="$OWNER/$REPO"
else
    echo "❌ Invalid GitHub URL format!"
    echo "Expected:"
    echo "  Repository: https://github.com/owner/repo"
    echo "  Organization: https://github.com/org"
    echo "  Enterprise: https://github.com/enterprises/enterprise"
    echo "Got: $GITHUB_URL"
    exit 1
fi

echo "🔑 Generating registration token for $SCOPE: $TARGET"

# Test basic API access first
echo "Testing GitHub API connectivity..."
if ! curl -s --fail -H "Authorization: Bearer $GITHUB_PAT" \
    https://api.github.com/user >/dev/null; then
    echo "❌ Failed to authenticate with GitHub API"
    echo "Check your PAT token and permissions"
    exit 1
fi

echo "✅ GitHub API authentication successful"

# Generate registration token
echo "Requesting registration token from: $API_URL"

RESPONSE=$(curl -s -w "%{http_code}" -X POST \
    -H "Authorization: Bearer $GITHUB_PAT" \
    -H "Accept: application/vnd.github.v3+json" \
    "$API_URL")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

case $HTTP_CODE in
    201)
        echo "✅ Registration token generated successfully"
        
        # Parse JSON response
        TOKEN=$(echo "$BODY" | jq -r '.token')
        EXPIRES_AT=$(echo "$BODY" | jq -r '.expires_at')
        
        if [ "$TOKEN" = "null" ] || [ -z "$TOKEN" ]; then
            echo "❌ Failed to parse token from response"
            echo "Response: $BODY"
            exit 1
        fi
        
        echo ""
        echo "📋 Registration Token Details:"
        echo "Token: $TOKEN"
        echo "Expires: $EXPIRES_AT"
        echo "GitHub URL: $GITHUB_URL"
        echo "Scope: $SCOPE ($TARGET)"
        
        # Output in env format for easy sourcing
        echo ""
        echo "🔧 Environment Variables (source this):"
        echo "export RUNNER_TOKEN='$TOKEN'"
        echo "export GITHUB_URL='$GITHUB_URL'"
        echo "export RUNNER_NAME='${RUNNER_NAME:-$(hostname)}'"
        echo "export TOKEN_EXPIRES_AT='$EXPIRES_AT'"
        
        # Save to file for easy access
        cat > runner-token-env.sh <<EOF
#!/bin/bash
# Generated $(date)
# Expires: $EXPIRES_AT
export RUNNER_TOKEN='$TOKEN'
export GITHUB_URL='$GITHUB_URL'
export RUNNER_NAME='${RUNNER_NAME:-$(hostname)}'
export TOKEN_EXPIRES_AT='$EXPIRES_AT'
EOF
        chmod +x runner-token-env.sh
        
        echo ""
        echo "💾 Saved to: runner-token-env.sh"
        echo "Usage: source runner-token-env.sh && ./config.sh --url \$GITHUB_URL --token \$RUNNER_TOKEN --name \$RUNNER_NAME"
        ;;
    401)
        echo "❌ Authentication failed (401)"
        echo "Your PAT token is invalid or expired"
        echo "Generate a new PAT at: https://github.com/settings/tokens"
        exit 1
        ;;
    403)
        echo "❌ Access forbidden (403)"
        echo "Your PAT token lacks required permissions for $SCOPE runners"
        echo ""
        echo "Required permissions:"
        case $SCOPE in
            repository)
                echo "  • repo (full repository access)"
                echo "  OR public_repo + admin:repo_hook (for public repos)"
                ;;
            organization)
                echo "  • admin:org (organization administration)"
                echo "  • repo (repository access)"
                ;;
            enterprise)
                echo "  • admin:enterprise (enterprise administration)"
                ;;
        esac
        exit 1
        ;;
    404)
        echo "❌ Not found (404)"
        echo "The $SCOPE '$TARGET' doesn't exist or your PAT lacks access"
        echo "Check:"
        echo "  1. The GitHub URL is correct"
        echo "  2. Your PAT has access to the $SCOPE"
        echo "  3. The $SCOPE exists and allows self-hosted runners"
        exit 1
        ;;
    422)
        echo "❌ Unprocessable entity (422)"
        echo "The $SCOPE may not support self-hosted runners"
        echo "Response: $BODY"
        exit 1
        ;;
    *)
        echo "❌ Unexpected response: $HTTP_CODE"
        echo "Response: $BODY"
        exit 1
        ;;
esac 