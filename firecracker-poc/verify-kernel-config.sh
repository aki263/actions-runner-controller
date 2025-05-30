#!/bin/bash
# Verify Kernel Config Usage from Build Log
# This script helps verify that your updated kernel config was actually used

set -euo pipefail

echo "🔍 Kernel Config Verification Guide"
echo "=================================="

echo ""
echo "📋 What to Look For in Kernel Build Logs:"
echo ""

echo "1. CONFIG FILE LOADING:"
echo "   Look for messages like:"
echo "   • 'configuration written to .config'"
echo "   • 'using defaults found in working-kernel-config'"
echo "   • '#' configuration written to '.config'"
echo ""

echo "2. SPECIFIC CONFIG VALIDATION:"
echo "   These configs should now be ENABLED (=y) in build log:"
echo ""

# Key configs that were changed from disabled to enabled
key_configs=(
    "CONFIG_USB"
    "CONFIG_BLK_DEV_SD" 
    "CONFIG_ATA"
    "CONFIG_TUN"
    "CONFIG_SECURITY_APPARMOR"
    "CONFIG_DRM"
    "CONFIG_FB"
    "CONFIG_SOUND"
    "CONFIG_VFAT_FS"
    "CONFIG_NETFILTER_XT_MATCH_STATE"
    "CONFIG_NET_CLS_CGROUP"
    "CONFIG_MACVLAN"
    "CONFIG_IPVLAN"
)

for config in "${key_configs[@]}"; do
    echo "   ✅ $config=y"
done

echo ""
echo "3. MODULE COMPILATION EVIDENCE:"
echo "   Look for compilation of these modules/subsystems:"
echo "   • CC [M]  drivers/usb/..."
echo "   • CC [M]  drivers/ata/..."
echo "   • CC [M]  drivers/net/..."
echo "   • CC [M]  sound/..."
echo "   • CC [M]  drivers/gpu/drm/..."
echo ""

echo "4. FEATURE BUILD MESSAGES:"
echo "   Look for subsystem initialization:"
echo "   • 'USB support enabled'"
echo "   • 'ATA subsystem'"
echo "   • 'DRM driver initialization'"
echo "   • 'Sound subsystem'"
echo ""

echo "🔧 COMMANDS TO VERIFY AFTER BUILD:"
echo ""

echo "# Check final .config in kernel build directory"
echo "grep -E '(CONFIG_USB|CONFIG_TUN|CONFIG_DRM)=' kernels/linux-*/\.config"
echo ""

echo "# Verify specific changed configs"
echo "echo 'USB Support:'; grep CONFIG_USB= kernels/linux-*/\.config"
echo "echo 'TUN Support:'; grep CONFIG_TUN= kernels/linux-*/\.config" 
echo "echo 'Graphics:'; grep CONFIG_DRM= kernels/linux-*/\.config"
echo ""

echo "# Check if key networking modules are enabled"
echo "grep -E 'CONFIG_(VETH|MACVLAN|BRIDGE_NETFILTER)=' kernels/linux-*/\.config"
echo ""

echo "🔍 LIVE VERIFICATION DURING BUILD:"
echo ""
echo "# Monitor build log for specific configs (run during build)"
echo "tail -f build.log | grep -E 'CONFIG_(USB|TUN|DRM|SOUND)'"
echo ""

echo "# Watch for module compilation"
echo "tail -f build.log | grep -E 'CC.*drivers/(usb|ata|gpu)'"
echo ""

echo "📊 BUILD LOG ANALYSIS COMMANDS:"
echo ""

build_log="build.log"
echo "# If you have a build log file, run these:"
echo ""
echo "# 1. Check config loading"
echo "grep -i 'configuration.*written' $build_log"
echo ""
echo "# 2. Verify key configs were processed"
echo "grep -E 'CONFIG_(USB|TUN|DRM|SOUND|ATA)' $build_log"
echo ""
echo "# 3. Check for USB subsystem compilation"
echo "grep -E 'CC.*drivers/usb' $build_log | head -5"
echo ""
echo "# 4. Check for networking module compilation"  
echo "grep -E 'CC.*net/(bridge|core)' $build_log | head -5"
echo ""
echo "# 5. Look for graphics driver compilation"
echo "grep -E 'CC.*drivers/gpu' $build_log | head -5"
echo ""

echo "⚠️  RED FLAGS (configs NOT being used):"
echo "   • Build log shows 'CONFIG_USB is not set'"
echo "   • No USB driver compilation messages"
echo "   • No DRM/graphics compilation"
echo "   • Build uses old .config instead of your working-kernel-config"
echo ""

echo "✅ GOOD SIGNS (your config IS being used):"
echo "   • Build log shows 'CONFIG_USB=y'"
echo "   • Many 'CC [M] drivers/usb/...' messages"
echo "   • 'CC [M] drivers/gpu/drm/...' messages"
echo "   • 'CC [M] net/bridge/...' messages"
echo "   • Build time is longer (more modules being compiled)"
echo ""

echo "🚀 QUICK VERIFICATION AFTER CLEANUP:"
echo ""
echo "When you run: ./firecracker-complete.sh build-kernel --rebuild-kernel"
echo ""
echo "Watch for these in the output:"
echo "1. 'Using kernel config: working-kernel-config'"
echo "2. 'Applying kernel configuration...'"
echo "3. 'Resolving kernel configuration dependencies...'"
echo "4. Lots of 'CC [M] drivers/...' messages (more than before)"
echo "5. Build taking longer due to more enabled modules"
echo ""

echo "📝 EXAMPLE VERIFICATION WORKFLOW:"
echo ""
echo "# 1. Start build and capture log"
echo "./firecracker-complete.sh build-kernel --rebuild-kernel 2>&1 | tee kernel-build.log"
echo ""
echo "# 2. During build, monitor key modules"
echo "tail -f kernel-build.log | grep -E '(CONFIG_USB|CC.*drivers/usb)'"
echo ""
echo "# 3. After build, verify final config"
echo "grep -E 'CONFIG_(USB|TUN|DRM|SOUND)=' kernels/linux-*/\.config"
echo ""
echo "# 4. Compare with our cleaned config"
echo "grep -E 'CONFIG_(USB|TUN|DRM|SOUND)=' working-kernel-config"
echo ""

echo "The configs should match between working-kernel-config and the built .config!"
echo ""
echo "🎯 Bottom line: If USB, graphics, sound drivers are being compiled,"
echo "   then your cleaned config is definitely being used! 🎉" 