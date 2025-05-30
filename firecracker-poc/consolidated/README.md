# ⚠️ **DEPRECATED - Use Parent Directory** ⚠️

This `consolidated/` directory contains the previous version of the Firecracker runner.

## **🎯 Use the New Version Instead:**

```bash
# Go to parent directory
cd ..

# Use the new all-in-one script
./firecracker-complete.sh --help
```

## **New Benefits:**

✅ **Kernel Building**: Custom kernel with Ubuntu 24.04 support  
✅ **Simplified Networking**: Shared bridge, no TAP conflicts  
✅ **Cloud-Init Fix**: No networking conflicts  
✅ **All-in-One**: Build → Snapshot → Launch → Manage  

## **Migration:**

The old `firecracker-runner.sh` in this directory still works, but the new `../firecracker-complete.sh` is:

- **More comprehensive** (includes kernel building)
- **Better networking** (shared bridge approach)
- **Cleaner code** (single script for everything)
- **Fixed cloud-init** (no network config conflicts)

---

**Use `../firecracker-complete.sh` for new deployments!** 🚀 