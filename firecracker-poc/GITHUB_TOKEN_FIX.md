# GitHub Token Fix: PAT vs Registration Token

## **Issue Description**

The error `Http response code: NotFound from 'POST https://api.github.com/actions/runner-registration'` occurs because GitHub Actions runners require **short-lived registration tokens**, not long-lived Personal Access Tokens (PATs).

## **Root Cause**

**Before (❌ Wrong):**
```bash
# Using PAT directly with runner config
./config.sh --url https://github.com/org/repo --token ghp_xxxx --name runner
# Result: 404 Not Found - PATs cannot be used for runner registration
```

**After (✅ Correct):**
```bash
# 1. Use PAT to generate short-lived registration token via GitHub API
curl -X POST -H "Authorization: Bearer ghp_xxxx" \
  https://api.github.com/repos/owner/repo/actions/runners/registration-token
# Returns: {"token": "A1B2C3...", "expires_at": "2024-01-01T12:00:00Z"}

# 2. Use registration token with runner config  
./config.sh --url https://github.com/org/repo --token A1B2C3... --name runner
# Result: ✅ Successfully registers runner
```

## **GitHub Token Types**

| Token Type | Use Case | Lifetime | API Endpoint |
|------------|----------|----------|--------------|
| **PAT** (Personal Access Token) | GitHub API authentication | Months/Years | General API access |
| **Registration Token** | Runner registration only | ~1 hour | `/actions/runner-registration` |
| **App Token** | GitHub App authentication | Hours | General API access |

## **ARC (Actions Runner Controller) Flow**

ARC correctly implements this pattern:

```go
// 1. ARC uses PAT/App token to authenticate with GitHub API
client := github.NewClient(httpClient.WithAuth(pat))

// 2. ARC calls registration token API
regToken, err := client.Actions.CreateRegistrationToken(ctx, owner, repo)

// 3. ARC injects registration token into runner pod
pod.Env = append(pod.Env, corev1.EnvVar{
    Name:  "RUNNER_TOKEN", 
    Value: regToken.GetToken(),
})
```

## **Fixed Implementation**

### **New Command Structure**

**Old (Broken):**
```bash
./firecracker-complete.sh launch \
  --github-url https://github.com/org/repo \
  --github-token ghp_xxxx  # ❌ PAT used directly
```

**New (Working):**
```bash
./firecracker-complete.sh launch \
  --github-url https://github.com/org/repo \
  --github-pat ghp_xxxx    # ✅ PAT used to generate registration token
```

### **Token Generation Function**

Added `generate_registration_token()` function that:

1. **Validates GitHub URL** format (repo/org/enterprise)
2. **Authenticates with GitHub API** using PAT
3. **Calls registration token endpoint** based on scope:
   - Repository: `POST /repos/{owner}/{repo}/actions/runners/registration-token`
   - Organization: `POST /orgs/{org}/actions/runners/registration-token`  
   - Enterprise: `POST /enterprises/{enterprise}/actions/runners/registration-token`
4. **Returns short-lived token** (expires in ~1 hour)

### **Error Handling**

Comprehensive error handling for common issues:

| HTTP Code | Meaning | Solution |
|-----------|---------|----------|
| **401** | Invalid PAT | Check token validity |
| **403** | Insufficient permissions | Add required scopes |
| **404** | Resource not found | Verify URL and access |
| **422** | Self-hosted runners disabled | Enable in settings |

## **Required PAT Permissions**

| Scope | Repository | Organization | Enterprise |
|-------|------------|--------------|------------|
| **repo** | ✅ Full access | ✅ Required | ❌ N/A |
| **admin:org** | ❌ N/A | ✅ Required | ❌ N/A |
| **admin:enterprise** | ❌ N/A | ❌ N/A | ✅ Required |

## **Usage Examples**

### **Repository Runner**
```bash
# Generate PAT with 'repo' scope at https://github.com/settings/tokens
./firecracker-complete.sh launch \
  --github-url https://github.com/owner/repo \
  --github-pat ghp_xxxxxxxxxxxxxxxxxxxx \
  --name my-runner
```

### **Organization Runner**
```bash
# Generate PAT with 'admin:org' + 'repo' scopes
./firecracker-complete.sh launch \
  --github-url https://github.com/myorg \
  --github-pat ghp_xxxxxxxxxxxxxxxxxxxx \
  --name org-runner
```

### **Enterprise Runner**
```bash
# Generate PAT with 'admin:enterprise' scope
./firecracker-complete.sh launch \
  --github-url https://github.com/enterprises/myenterprise \
  --github-pat ghp_xxxxxxxxxxxxxxxxxxxx \
  --name enterprise-runner
```

## **Testing & Debugging**

### **Manual Token Generation**
```bash
# Test token generation standalone
./generate-runner-token.sh \
  --github-url https://github.com/owner/repo \
  --github-pat ghp_xxxx
```

### **Debug VM Registration**
```bash
# Debug VM remotely
./quick-debug-vm.sh 172.16.0.10

# Debug inside VM
ssh -i instances/*/ssh_key runner@vm-ip
./debug-github-config.sh  # (copy script to VM)
```

### **Manual Runner Registration**
```bash
# Inside VM - test registration manually
source runner-token-env.sh  # From generate-runner-token.sh
cd /opt/runner
./config.sh --url $GITHUB_URL --token $RUNNER_TOKEN --name $RUNNER_NAME --unattended
```

## **Backwards Compatibility**

The `--github-token` flag is still supported for direct token injection (testing):

```bash
# For testing with pre-generated registration token
./firecracker-complete.sh launch \
  --github-url https://github.com/org/repo \
  --github-token A1B2C3D4E5F6...  # Direct registration token
```

## **Key Benefits**

1. **✅ Correct API Usage**: Matches GitHub's expected runner registration flow
2. **✅ Automatic Token Management**: Generates fresh tokens for each VM
3. **✅ Better Security**: Short-lived tokens reduce exposure risk
4. **✅ ARC Compatibility**: Uses same pattern as Actions Runner Controller
5. **✅ Comprehensive Error Handling**: Clear feedback on permission issues

## **Migration Guide**

**Old Command:**
```bash
./firecracker-complete.sh launch --github-token ghp_xxx --github-url URL
```

**New Command:**
```bash
./firecracker-complete.sh launch --github-pat ghp_xxx --github-url URL
```

That's it! The script now handles token generation automatically. 