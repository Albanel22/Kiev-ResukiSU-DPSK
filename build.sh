#!/bin/bash
set -e
echo "=== Build ReSukiSU + SuSFS (JackA1ltman mainline) pour kiev (SM8250) ==="
df -h

# ==================== 0. ENVIRONNEMENT ====================
sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
sudo apt-get clean

sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true

sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev \
  libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld \
  device-tree-compiler zip unzip curl git python3 mkbootimg

cd $GITHUB_WORKSPACE

# ==================== 1. CLONAGE DU NOYAU ====================
echo "=== Clonage du kernel Albanel22 lineage-23.2-tactile ==="
git clone https://github.com/Albanel22/android_kernel_motorola_sm8250.git \
  -b lineage-23.2-tactile --depth=1 kernel_sources
cd kernel_sources
git log --oneline -1

# ==================== 2. INTÉGRATION ReSukiSU ====================
echo "=== Intégration ReSukiSU (épinglée au 17 août 2026) ==="
rm -rf drivers/kernelsu kernelSU susfs4ksu KernelSU || true
rm -rf /tmp/resukisu_pin
git clone https://github.com/ReSukiSU/ReSukiSU.git /tmp/resukisu_pin
RESUKISU_COMMIT=$(cd /tmp/resukisu_pin && git rev-list -n 1 --before="2026-08-17 23:59:59" main)
echo "Commit ReSukiSU épinglé : $RESUKISU_COMMIT"
curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash -s -- "$RESUKISU_COMMIT"

# --- Force Inclusion drivers/kernelsu ---
if ! grep -q "kernelsu" drivers/Makefile; then
    echo 'obj-$(CONFIG_KSU) += kernelsu/' >> drivers/Makefile
fi
if [ -f "drivers/kernelsu/Kconfig" ] && ! grep -q "kernelsu/Kconfig" drivers/Kconfig; then
    sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig 2>/dev/null || echo 'source "drivers/kernelsu/Kconfig"' >> drivers/Kconfig
fi

# ==================== 2b. DIAGNOSTIC KERNEL_COMPAT ====================
echo ""
echo "=== Diagnostic kernel_compat.mk ==="

if [ -f "drivers/kernelsu/tools/kernel_compat.mk" ]; then
    echo "✅ kernel_compat.mk présent"
else
    echo "❌ kernel_compat.mk ABSENT"
fi

echo ""
echo "=== Version kernel détectée ==="
grep -E "^(VERSION|PATCHLEVEL|SUBLEVEL)" Makefile

# ==================== 2c. PATCH SECCOMP POUR 4.19 ====================
echo ""
echo "=== Patch seccomp pour kernel 4.19 ==="

SECCOMP_HELPER="drivers/kernelsu/infra/seccomp_helper.c"
mkdir -p drivers/kernelsu/infra

cat > "$SECCOMP_HELPER" << 'SECCOMP_EOF'
#include <linux/module.h>
#include <linux/sched.h>
#include <linux/seccomp.h>
#include <linux/cred.h>
#include <linux/version.h>

#ifdef CONFIG_KSU
void ksu_disable_seccomp_for_current(void)
{
    struct task_struct *task = current;
    
    if (task && task->seccomp.mode != SECCOMP_MODE_DISABLED) {
        task->seccomp.mode = SECCOMP_MODE_DISABLED;
        task->seccomp.filter = NULL;
        clear_tsk_thread_flag(task, TIF_SECCOMP);
        pr_info("KernelSU: seccomp disabled for pid %d\n", task->pid);
    }
}
EXPORT_SYMBOL(ksu_disable_seccomp_for_current);
#endif
SECCOMP_EOF

echo "✅ seccomp_helper.c créé"

if [ -f "drivers/kernelsu/Kbuild" ]; then
    if ! grep -q "seccomp_helper.o" drivers/kernelsu/Kbuild; then
        sed -i '/^kernelsu-objs :=/a kernelsu-objs += infra/seccomp_helper.o' drivers/kernelsu/Kbuild
        echo "✅ seccomp_helper.o ajouté au Kbuild"
    fi
fi

SUPERCALL_FILE=""
for f in drivers/kernelsu/supercall/supercall.c drivers/kernelsu/uapi/supercall_dispatch.c drivers/kernelsu/supercalls.c; do
    if [ -f "$f" ]; then
        SUPERCALL_FILE="$f"
        break
    fi
done

if [ -z "$SUPERCALL_FILE" ]; then
    SUPERCALL_FILE=$(find drivers/kernelsu -name "supercall*.c" 2>/dev/null | head -1)
fi

if [ -n "$SUPERCALL_FILE" ]; then
    echo "→ Patch de $SUPERCALL_FILE"
    if ! grep -q "ksu_disable_seccomp_for_current" "$SUPERCALL_FILE"; then
        sed -i '1i extern void ksu_disable_seccomp_for_current(void);' "$SUPERCALL_FILE"
    fi
    python3 - "$SUPERCALL_FILE" << 'PYEOF'
import sys, re
filepath = sys.argv
with open(filepath, 'r') as f: content = f.read()
match = re.search(r'(int ksu_handle_sys_reboot\([^)]*\)\s*\{)', content)
if match:
    insert_pos = match.end()
    patch = '\n    /* Patch 4.19 : désactiver seccomp avant install fd */\n    ksu_disable_seccomp_for_current();'
    content = content[:insert_pos] + patch + content[insert_pos:]
    with open(filepath, 'w') as f: f.write(content)
PYEOF
fi

# ==================== 3. HOOKS MANUELS ReSukiSU ====================
echo "=== Hooks ReSukiSU ==="
# execveat
if ! grep -q "ksu_handle_execveat" fs/exec.c; then
  python3 - << 'PYEOF'
import re
with open('fs/exec.c', 'r') as f: content = f.read()
if 'ksu_handle_execveat' not in content:
    extern_decl = '\n#ifdef CONFIG_KSU_MANUAL_HOOK\n__attribute__((hot))\nextern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags);\n#endif\n'
    content = re.sub(r'(static int do_execveat_common\()', extern_decl + r'\1', content, count=1)
    old_code = 'struct user_arg_ptr argv = { .ptr.native = __argv };\n\tstruct user_arg_ptr envp = { .ptr.native = __envp };\n\treturn do_execveat_common(AT_FDCWD, filename, argv, envp, 0);'
    new_code = 'struct user_arg_ptr argv = { .ptr.native = __argv };\n\tstruct user_arg_ptr envp = { .ptr.native = __envp };\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);\n#endif\n\treturn do_execveat_common(AT_FDCWD, filename, argv, envp, 0);'
    if old_code in content: content = content.replace(old_code, new_code, 1)
with open('fs/exec.c', 'w') as f: f.write(content)
PYEOF
fi

# faccessat
if ! grep -q "ksu_handle_faccessat" fs/open.c; then
  python3 - << 'PYEOF'
import re
with open('fs/open.c', 'r') as f: content = f.read()
if 'ksu_handle_faccessat' not in content:
    extern_decl = '\n#ifdef CONFIG_KSU_MANUAL_HOOK\n__attribute__((hot))\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *flags);\n#endif\n'
    content = re.sub(r'(SYSCALL_DEFINE3\(faccessat)', extern_decl + r'\1', content, count=1)
with open('fs/open.c', 'w') as f: f.write(content)
PYEOF
fi

# reboot
if ! grep -q "ksu_handle_sys_reboot" kernel/reboot.c; then
  python3 - << 'PYEOF'
with open('kernel/reboot.c', 'r') as f: content = f.read()
if 'ksu_handle_sys_reboot' not in content:
    content = content.replace('char buffer[256];\n\tint ret = 0;', 'char buffer[256];\n\tint ret = 0;\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif')
with open('kernel/reboot.c', 'w') as f: f.write(content)
PYEOF
fi

# ==================== 4. INTÉGRATION SuSFS (JackA1ltman) ====================
echo ""
echo "=== Intégration SuSFS depuis JackA1ltman/NonGKI_Kernel_Build_2nd (mainline) ==="
cd "$GITHUB_WORKSPACE"
rm -rf /tmp/jack_repo
git clone --branch mainline https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git /tmp/jack_repo
JACK_COMMIT=$(cd /tmp/jack_repo && git rev-list -n 1 --before="2026-08-17 23:59:59" mainline)
(cd /tmp/jack_repo && git checkout "$JACK_COMMIT")

cd "$GITHUB_WORKSPACE/kernel_sources"
SUSFS_PATCH="/tmp/jack_repo/Patches/Patch/susfs_patch_to_4.19.patch"
patch -p1 --forward --batch < "$SUSFS_PATCH" 2>&1 | tee /tmp/susfs_patch.log || true

# Nettoyage .rej basique
rm -f fs/proc/task_mmu.c.rej fs/namespace.c.rej fs/super.c.rej 2>/dev/null || true

if [ -d "/tmp/jack_repo/Patches/fs" ]; then
    cp -rn /tmp/jack_repo/Patches/fs/* fs/ 2>/dev/null || true
fi
if [ -d "/tmp/jack_repo/Patches/include/linux" ]; then
    cp -rn /tmp/jack_repo/Patches/include/linux/* include/linux/ 2>/dev/null || true
fi
find . -name "*.orig" -type f -delete 2>/dev/null || true

if [ -f "fs/Makefile" ] && ! grep -q "susfs.o" fs/Makefile; then
    echo "obj-\$(CONFIG_KSU_SUSFS) += susfs.o" >> fs/Makefile
fi

# ==================== 5. CONFIGURATION & PERSISTANCE ====================
echo "=== Configuration ==="
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

mkdir -p out
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 vendor/lito-perf_defconfig

{
  echo "CONFIG_KSU=y"
  echo "CONFIG_KSU_MANUAL_HOOK=y"
  echo "CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK=y"
  echo "# CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK is not set"
  echo "# CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK is not set"
  echo "CONFIG_KPROBES=y"
  echo "CONFIG_HAVE_KPROBES=y"
  echo "CONFIG_KRETPROBES=y"
  echo "CONFIG_COMPAT=y"
  echo "CONFIG_COMPAT_32BIT_TIME=y"
  echo "CONFIG_KSU_SUSFS=y"
  echo "CONFIG_KSU_SUSFS_SUS_PATH=y"
  echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y"
  echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y"
  echo "CONFIG_KSU_SUSFS_SUS_MAP=y"
  echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y"
  echo "CONFIG_KSU_SUSFS_ENABLE_LOG=y"
  echo "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y"
  echo "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y"
  echo "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y"
  echo "CONFIG_KSU_SUSFS_TRY_UMOUNT=y"
  echo "CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y"
  echo "CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y"
  echo "CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y"
  echo "CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y"
} >> out/.config

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig

# Assertion de persistance CONFIG_KSU
if ! grep -q "^CONFIG_KSU=y" out/.config; then
    echo "❌ ÉCHEC CRITIQUE : olddefconfig a désactivé CONFIG_KSU !"
    grep -E "CONFIG_(KPROBES|KSU)" out/.config || true
    exit 1
fi
echo "✅ CONFIG_KSU confirmé actif dans .config"

# ==================== 6. PATCHES FINAUX ====================
echo "=== Patch signatures modules + tactile ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c

printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c

# ==================== 7. COMPILATION + CONTRÔLE SYMBOLS ====================
echo "=== Compilation finale ==="
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j$(nproc) Image 2>&1 | tee build.log

if [ -f "out/arch/arm64/boot/Image" ]; then
  echo "✅ Compilation Image réussie"
  if ! nm out/arch/arm64/boot/Image | grep -q "ksu_handle"; then
      echo "❌ ÉCHEC CRITIQUE : Le noyau Image ne contient aucun symbole ksu_handle !"
      exit 1
  fi
  echo "✅ Symboles ksu_handle validés dans le binaire Image."
  ls -lh out/arch/arm64/boot/
else
  echo "❌ BUILD FAILED"
  grep -iE "error:|fatal error:" build.log | head -40
  exit 1
fi

# ==================== 7b. COMPILATION KSUD ====================
echo "=== Compilation de ksud (ReSukiSU) ==="
cd "$GITHUB_WORKSPACE"

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

rustup toolchain install nightly
rustup default nightly
rustup target add aarch64-linux-android

wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip
unzip -q android-ndk-r26d-linux.zip

export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"
export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
export AARCH64_CLANG_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
export AR_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"

rm -rf "$GITHUB_WORKSPACE/ksud-src"
git clone https://github.com/ReSukiSU/ReSukiSU.git "$GITHUB_WORKSPACE/ksud-src"
cd "$GITHUB_WORKSPACE/ksud-src/userspace/ksud"

mkdir -p .cargo
cat > .cargo/config.toml <<EOF
[target.aarch64-linux-android]
linker = "$AARCH64_CLANG_PATH"

[env]
CC_aarch64_linux_android = "$AARCH64_CLANG_PATH"
CXX_aarch64_linux_android = "$AARCH64_CLANGXX_PATH"
AR_aarch64_linux_android = "$AR_PATH"
BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android = "$BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android"
EOF

export CARGO_NET_GIT_FETCH_WITH_CLI=true
cargo +nightly build --release --target aarch64-linux-android

KSUD_BINARY=$(find "$GITHUB_WORKSPACE/ksud-src" -type f -name "ksud" -executable 2>/dev/null | head -1)

if [ -z "$KSUD_BINARY" ]; then
    echo "❌ ksud introuvable"
    exit 1
fi

echo "✅ ksud trouvé : $KSUD_BINARY"
cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"
chmod 755 "$GITHUB_WORKSPACE/ksud"

cd "$GITHUB_WORKSPACE"

# ==================== 8. REPACK ====================
echo "=== Téléchargement des images stock ==="
cd $GITHUB_WORKSPACE

curl -fLo boot-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260830/boot.img" 2>/dev/null || true
curl -fLo dtbo-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260830/dtbo.img" 2>/dev/null || true

wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk-v27.0.apk
unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so
mkdir -p repack
mv lib/x86_64/libmagiskboot.so repack/magiskboot
chmod +x repack/magiskboot
rm -rf Magisk-v27.0.apk lib/

cp boot-stock.img repack/boot.img
cd repack
./magiskboot unpack boot.img
cp $GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image kernel

echo "=== Installation de ksud dans le ramdisk ==="
./magiskboot cpio ramdisk.cpio \
  "mkdir 0755 data" \
  "mkdir 0755 data/adb" \
  "mkdir 0755 data/adb/ksu" \
  "mkdir 0755 data/adb/ksu/bin" \
  "add 0755 data/adb/ksu/bin/ksud $GITHUB_WORKSPACE/ksud"

cp "$GITHUB_WORKSPACE/ksud" local_su_binary
chmod 755 local_su_binary
./magiskboot cpio ramdisk.cpio \
  "mkdir 0755 system" \
  "mkdir 0755 system/bin" \
  "add 06755 system/bin/su ./local_su_binary"
rm -f local_su_binary

echo "=== Ajout du déclencheur init.rc (sans seclabel conflictuel) ==="
INIT_RC_PATHS=(
  "first_stage_ramdisk/init.rc"
  "system/etc/init/hw/init.rc"
  "init.rc"
)

INIT_RC_FOUND=""
for CANDIDATE in "${INIT_RC_PATHS[@]}"; do
  ./magiskboot cpio ramdisk.cpio "extract $CANDIDATE /tmp/init.rc" 2>/dev/null && \
    [ -f /tmp/init.rc ] && [ -s /tmp/init.rc ] && {
      INIT_RC_FOUND="$CANDIDATE"
      break
    }
  rm -f /tmp/init.rc
done

if [ -z "$INIT_RC_FOUND" ]; then
  INIT_RC_FOUND="first_stage_ramdisk/init.rc"
  cat > /tmp/init.rc << 'RCEOF'
# init.rc créé par ReSukiSU build
RCEOF
fi

if ! grep -q "service ksud" /tmp/init.rc; then
  cat >> /tmp/init.rc << 'RCEOF'

on post-fs-data
    start ksud

service ksud /data/adb/ksu/bin/ksud daemon
    user root
    group root
    disabled
    oneshot
RCEOF
  echo "✅ Bloc service ksud ajouté"
fi

./magiskboot cpio ramdisk.cpio "add 0750 $INIT_RC_FOUND /tmp/init.rc"
./magiskboot repack boot.img new-boot.img
mv new-boot.img ../final_boot.img
cd ..

# ==================== 9. SORTIE ====================
echo "=== Copie vers output ==="
mkdir -p output
cp final_boot.img output/ReSukiSU-SusFS-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true

echo "=== BUILD TERMINÉ ==="
ls -lh output/
