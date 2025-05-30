# Security Model: PAT vs Registration Token

## **Security Architecture**

Our Firecracker GitHub Actions runner implementation follows security best practices by maintaining **strict separation** between PAT tokens and registration tokens.

## **Token Security Model**

### **🔐 PAT (Personal Access Token)**
- **Location**: Host only (never passed to VMs)
- **Lifetime**: Long-lived (months/years)
- **Permissions**: Broad (repo/org/enterprise admin)
- **Usage**: GitHub API authentication on trusted hosts
- **Security Risk**: High (if compromised, full repo access)

### **🎫 Registration Token**
- **Location**: VM only (generated from PAT on host)
- **Lifetime**: Short-lived (~1 hour)
- **Permissions**: Limited (runner registration only)
- **Usage**: Runner registration with GitHub
- **Security Risk**: Low (limited scope, auto-expires)

## **Flow Diagram**

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   🏠 HOST       │    │  🌐 GitHub API  │    │   🔒 VM         │
│                 │    │                 │    │                 │
│ 1. PAT Token    │───▶│ 2. Generate     │    │ 4. Registration │
│    (ghp_xxx)    │    │    Registration │    │    Token Only   │
│                 │    │    Token        │    │                 │
│ 3. ✅ Keep PAT  │◀───│    (short-lived)│───▶│ 5. ❌ No PAT    │
│    on Host      │    │                 │    │    in VM        │
└─────────────────┘    └─────────────────┘    └─────────────────┘
```

## **Implementation Details**

### **Host-Side Token Generation**

```bash
# ✅ SECURE: PAT used only on host to generate registration token
./firecracker-complete.sh launch \
  --github-url https://github.com/org/repo \
  --github-pat ghp_xxxxxxxxxxxxxxxxxxxx \  # PAT stays on host
  --name runner

# Host generates registration token via GitHub API
registration_token=$(curl -X POST \
  -H "Authorization: Bearer $github_pat" \
  https://api.github.com/repos/org/repo/actions/runners/registration-token)
```

### **VM Environment (Secure)**

Inside the VM, only registration token is available:
```bash
# Environment variables in VM:
RUNNER_TOKEN=A1B2C3D4E5F6...  # ✅ Short-lived registration token
GITHUB_URL=https://github.com/org/repo
RUNNER_NAME=my-runner
RUNNER_LABELS=firecracker

# ❌ PAT is NOT available in VM environment
# No ghp_xxxx token anywhere in the VM
```

### **Runner Registration**

```bash
# VM uses only the registration token
./config.sh \
  --url "$GITHUB_URL" \
  --token "$RUNNER_TOKEN" \  # Short-lived, limited permissions
  --name "$RUNNER_NAME" \
  --unattended
```

## **Security Benefits**

### **🛡️ Principle of Least Privilege**
- VMs only get tokens with minimal required permissions
- PAT remains on trusted infrastructure only
- Registration tokens auto-expire

### **🔒 Reduced Attack Surface**
- Compromised VM cannot access PAT
- Registration token has limited scope
- Token expiration limits exposure window

### **📏 Compliance Ready**
- Follows GitHub's recommended patterns
- Matches ARC (Actions Runner Controller) security model
- Audit trail shows proper token usage

## **Comparison with ARC**

| Component | ARC Implementation | Our Implementation |
|-----------|-------------------|-------------------|
| **PAT Storage** | Kubernetes Secret | Host environment only |
| **Token Generation** | Controller pod | Host script |
| **VM/Pod Environment** | Registration token only | Registration token only |
| **Security Model** | ✅ Secure | ✅ Secure |

## **Attack Scenarios & Mitigations**

### **Scenario 1: VM Compromise**
- **Risk**: Attacker gains access to running VM
- **Mitigation**: Only registration token available (limited scope, auto-expires)
- **Impact**: ✅ PAT remains secure on host

### **Scenario 2: Token Interception**
- **Risk**: Network traffic interception
- **Mitigation**: HTTPS API calls, short-lived tokens
- **Impact**: ✅ Minimal exposure window

### **Scenario 3: Memory Dumps**
- **Risk**: VM memory analysis by attacker
- **Mitigation**: No PAT in VM memory, only registration token
- **Impact**: ✅ Limited token scope

## **Best Practices**

### **✅ DO**
- Generate registration tokens on trusted hosts only
- Use short-lived registration tokens in VMs
- Rotate PATs regularly
- Monitor token usage via GitHub audit logs
- Use minimal required PAT permissions

### **❌ DON'T**
- Pass PATs to VMs or containers
- Store PATs in VM filesystems
- Use long-lived tokens in untrusted environments
- Share PATs between multiple services
- Log tokens in plaintext

## **Verification Commands**

### **Check VM Environment**
```bash
# SSH into VM and verify no PAT
ssh -i instances/*/ssh_key runner@vm-ip

# Should only see registration token
env | grep -E '^(GITHUB_|RUNNER_)'
# Expected: RUNNER_TOKEN (starts with A-Z, short)
# Not expected: Any ghp_xxx tokens

# Check for PAT patterns
env | grep ghp_ && echo "❌ PAT FOUND IN VM!" || echo "✅ No PAT in VM"
```

### **Validate Token Types**
```bash
# Registration tokens are typically A-Z uppercase + numbers
echo "$RUNNER_TOKEN" | grep -E '^[A-Z0-9]+$' && echo "✅ Registration token format"

# PATs start with ghp_
echo "$token" | grep -E '^ghp_' && echo "❌ This is a PAT!" || echo "✅ Not a PAT"
```

## **Migration Guide**

### **Old (Insecure) Pattern**
```bash
# ❌ BAD: PAT passed directly to VM
./launch-vm.sh --github-token ghp_xxxx
```

### **New (Secure) Pattern**
```bash
# ✅ GOOD: PAT used to generate registration token on host
./firecracker-complete.sh launch --github-pat ghp_xxxx
```

## **Compliance & Auditing**

### **GitHub Audit Log**
- Token generation events logged to GitHub
- Can track which PAT generated which registration tokens
- Runner registration events are auditable

### **Infrastructure Logging**
- PAT usage only on trusted hosts
- VM environment contains no sensitive tokens
- Token generation events can be monitored

## **Conclusion**

This security model ensures that:
1. **PATs remain on trusted infrastructure** (host systems)
2. **VMs only receive minimal tokens** (registration tokens)
3. **Attack surface is minimized** (limited token scope)
4. **Compliance requirements are met** (proper token handling)

The implementation follows GitHub's recommended security practices and matches the security model used by Actions Runner Controller (ARC). 