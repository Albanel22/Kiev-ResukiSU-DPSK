#!/bin/bash
set -e
echo "=== Début du build ReSukiSU + SusFS 2.3.0 (cyberc3dr MAJ) pour kiev (SM8250) ==="
df -h

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
sudo apt-get clean
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true

sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld device-tree-compiler zip unzip curl git python3 mkbootimg

cd $GITHUB_WORKSPACE

# ==================== 1. CLONAGE DU NOYAU ====================
echo "=== Clonage du kernel depuis le fork Albanel22 ==="
rm -rf kernel_sources
git clone --depth=1 --branch kiev-kernelsu-susfs https://github.com/Albanel22/android_kernel_motorola_sm8250.git kernel_sources
cd kernel_sources
git log --oneline -1
cd "$GITHUB_WORKSPACE"

# ==================== 2. INTÉGRATION RESUKISU ====================
cd "$GITHUB_WORKSPACE/kernel_sources"
echo "=== Intégration ReSukiSU ==="
rm -rf drivers/kernelsu kernelSU susfs4ksu || true
curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash

echo "=== Hooks ReSukiSU (Uniquement les hooks stables et non conflictuels) ==="

# 1. execveat
if ! grep -q "ksu_handle_execveat" fs/exec.c; then
  cat > /tmp/hook_execveat.py << 'PYEOF'
import re
with open('fs/exec.c', 'r') as f:
    content = f.read()
if 'ksu_handle_execveat' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
				void *argv, void *envp, int *flags);
#endif
'''
    pattern = r'(static int do_execveat_common\()'
    content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
    old_code = '''	struct user_arg_ptr argv = { .ptr.native = __argv };
	struct user_arg_ptr envp = { .ptr.native = __envp };
	return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);'''
    new_code = '''	struct user_arg_ptr argv = { .ptr.native = __argv };
	struct user_arg_ptr envp = { .ptr.native = __envp };
#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);
#endif
	return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: execveat")
with open('fs/exec.c', 'w') as f:
    f.write(content)
PYEOF
  python3 /tmp/hook_execveat.py
fi

# 2. faccessat
if ! grep -q "ksu_handle_faccessat" fs/open.c; then
  cat > /tmp/hook_faccessat.py << 'PYEOF'
import re
with open('fs/open.c', 'r') as f:
    content = f.read()
if 'ksu_handle_faccessat' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,
				int *mode, int *flags);
#endif
'''
    pattern = r'(SYSCALL_DEFINE3\(faccessat)'
    content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
    old_code = '''SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)
{
	return do_faccessat(dfd, filename, mode);'''
    new_code = '''SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)
{
#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
#endif
	return do_faccessat(dfd, filename, mode);'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: faccessat")
with open('fs/open.c', 'w') as f:
    f.write(content)
PYEOF
  python3 /tmp/hook_faccessat.py
fi

# 3. setresuid (Requis par ReSukiSU)
echo "=== Hook ksu_handle_setresuid ==="
if ! grep -q "ksu_handle_setresuid" kernel/sys.c; then
  cat > /tmp/hook_setresuid.py << 'PYEOF'
import re
with open('kernel/sys.c', 'r') as f:
    content = f.read()
if 'ksu_handle_setresuid' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_SUSFS
extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);
#endif
'''
    pattern = r'(long __sys_setresuid)'
    content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
    
    old_code = '''	bool ruid_new, euid_new, suid_new;'''
    new_code = '''	bool ruid_new, euid_new, suid_new;
#ifdef CONFIG_KSU_SUSFS
	(void)ksu_handle_setresuid(ruid, euid, suid);
#endif'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: setresuid")
with open('kernel/sys.c', 'w') as f:
    f.write(content)
PYEOF
  python3 /tmp/hook_setresuid.py
else
  echo "OK: ksu_handle_setresuid déjà présent"
fi

# 4. sys_reboot
if ! grep -q "ksu_handle_sys_reboot" kernel/reboot.c; then
  cat > /tmp/hook_reboot.py << 'PYEOF'
import re
with open('kernel/reboot.c', 'r') as f:
    content = f.read()

if 'ksu_handle_sys_reboot' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);
#endif
'''
    pattern = r'(SYSCALL_DEFINE4\(reboot)'
    content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
    
    old_code = '''	char buffer[256];
	int ret = 0;'''
    
    new_code = '''	char buffer[256];
	int ret = 0;

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif'''
    
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: sys_reboot")

with open('kernel/reboot.c', 'w') as f:
    f.write(content)
PYEOF
  python3 /tmp/hook_reboot.py
fi

# 🚨 NOTE : Les hooks stat, sys_read et input sont volontairement omis ici.
# Les derniers commits de cyberc3dr (xxksu susfs integration, deinlined support) 
# gèrent désormais ces aspects de manière native et compatible.

# ==================== 3. INTÉGRATION SUSFS 2.3.0 (cyberc3dr MAJ) ====================
cd "$GITHUB_WORKSPACE"
echo "=== Téléchargement du SuSFS 2.3.0 depuis cyberc3dr/nGKI_Kernel_Build (rebase) ==="
rm -rf /tmp/cyber_repo
git clone --depth=1 --branch rebase https://github.com/cyberc3dr/nGKI_Kernel_Build.git /tmp/cyber_repo

cd "$GITHUB_WORKSPACE/kernel_sources"

# 1. Patch de compatibilité xxksu (Mis à jour récemment par l'auteur)
if [ -f "/tmp/cyber_repo/Patches/Patch/xxksu_fix_compat.patch" ]; then
    echo "=== Application du patch de compatibilité xxksu ==="
    patch -p1 --forward --batch < "/tmp/cyber_repo/Patches/Patch/xxksu_fix_compat.patch" || true
fi

# 2. Patch principal SuSFS 4.19
SUSFS_PATCH="/tmp/cyber_repo/Patches/Patch/susfs_patch_to_4.19.patch"
echo "=== Application du patch SuSFS 4.19 ==="
patch -p1 --forward --batch < "$SUSFS_PATCH" 2>&1 | tee /tmp/susfs_patch.log || true

# 3. VÉRIFICATION STRICTE DES REJETS
if find . -name "*.rej" -type f | grep -q .; then
    echo "❌ ÉCHEC CRITIQUE : Des rejets de patch SuSFS persistent."
    find . -name "*.rej" -type f -exec echo "=== {} ===" \; -exec cat {} \;
    exit 1
fi
echo "✅ Patch SuSFS appliqué avec succès (aucun rejet)."

# 4. Copie des fichiers source SuSFS
if [ -d "/tmp/cyber_repo/Patches/fs" ]; then
    cp -rn /tmp/cyber_repo/Patches/fs/* fs/ 2>/dev/null || true
fi
if [ -d "/tmp/cyber_repo/Patches/include/linux" ]; then
    cp -rn /tmp/cyber_repo/Patches/include/linux/* include/linux/ 2>/dev/null || true
fi

# 5. Corrections Makefile et NETTOYAGE DES SYMBOLES DUPLIQUÉS
if [ -f "fs/Makefile" ] && ! grep -q "susfs.o" fs/Makefile; then
    echo "obj-\$(CONFIG_KSU_SUSFS) += susfs.o" >> fs/Makefile
    [ -f "fs/sus_su.c" ] && ! grep -q "sus_su.o" fs/Makefile && echo "obj-\$(CONFIG_KSU_SUSFS) += sus_su.o" >> fs/Makefile
fi

if [ -f "fs/susfs.c" ]; then
    echo "🔧 Nettoyage des symboles dupliqués dans fs/susfs.c..."
    sed -i '/^bool susfs_is_current_ksu_domain(void)/,/^}/d' fs/susfs.c
    sed -i '/^u32 susfs_ksu_sid = 0;/d' fs/susfs.c
    sed -i '/^u32 susfs_priv_app_sid = 0;/d' fs/susfs.c
    sed -i '/EXPORT_SYMBOL(susfs_is_current_ksu_domain);/d' fs/susfs.c
    sed -i '/EXPORT_SYMBOL(susfs_ksu_sid);/d' fs/susfs.c
    sed -i '/EXPORT_SYMBOL(susfs_priv_app_sid);/d' fs/susfs.c
    
    if ! grep -q "extern bool susfs_is_current_ksu_domain" fs/susfs.c; then
        sed -i '1i extern bool susfs_is_current_ksu_domain(void);\nextern u32 susfs_ksu_sid;\nextern u32 susfs_priv_app_sid;' fs/susfs.c
    fi
fi

# ==================== 4. KCONFIG SUSFS ====================
if [ -f "drivers/kernelsu/Kconfig" ] && ! grep -q "KSU_SUSFS" drivers/kernelsu/Kconfig; then
    cat >> drivers/kernelsu/Kconfig << 'KCONFIG_EOF'
menuconfig KSU_SUSFS
	bool "KernelSU SUSFS support"
	depends on KSU
	default y
if KSU_SUSFS
config KSU_SUSFS_SUS_PATH
	bool "sus_path"
	default y
config KSU_SUSFS_SUS_MOUNT
	bool "sus_mount"
	default y
config KSU_SUSFS_SUS_KSTAT
	bool "sus_kstat"
	default y
config KSU_SUSFS_SUS_MAP
	bool "sus_map"
	default y
config KSU_SUSFS_SPOOF_UNAME
	bool "spoof_uname"
	default y
config KSU_SUSFS_ENABLE_LOG
	bool "enable_log"
	default y
config KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
	bool "hide_ksu_susfs_symbols"
	default y
config KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
	bool "spoof_cmdline_or_bootconfig"
	default y
config KSU_SUSFS_OPEN_REDIRECT
	bool "open_redirect"
	default y
config KSU_SUSFS_TRY_UMOUNT
	bool "try_umount"
	default y
config KSU_SUSFS_HAS_MAGIC_MOUNT
	bool "has_magic_mount"
	default y
config KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT
	bool "auto_add_ksu_default_mount"
	default y
config KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT
	bool "auto_add_sus_bind_mount"
	default y
config KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT
	bool "auto_add_try_umount_for_bind_mount"
	default y
endif
KCONFIG_EOF
fi

# ==================== 5. CONFIGURATION (CIBLAGE EXPLICITE) ====================
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

mkdir -p out

CONFIG_NAME="vendor/lito-perf_defconfig"
if [ ! -f "arch/arm64/configs/$CONFIG_NAME" ]; then
    CONFIG_NAME="lito-perf_defconfig"
fi

echo "Config utilisée de manière explicite : $CONFIG_NAME"

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 $CONFIG_NAME

{
  echo "CONFIG_KSU=y"
  echo "CONFIG_KSU_MANUAL_HOOK=y"
  echo "CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK=y"
  # On désactive les hooks auto qui entrent en conflit avec notre méthode manuelle ou SuSFS
  echo "# CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK is not set"
  echo "# CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK is not set"
  echo "CONFIG_KPROBES=y"
  echo "CONFIG_HAVE_KPROBES=y"
  echo "CONFIG_KRETPROBES=y"
  echo "CONFIG_COMPAT=y"
  echo "CONFIG_COMPAT_32BIT_TIME=y"
  echo "# CONFIG_COMPAT_VDSO is not set"
  echo "# CONFIG_VDSO32 is not set"
  echo "CONFIG_KSU_SUSFS=y"
  echo "CONFIG_KSU_SUSFS_SUS_PATH=y"
  echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y"
  echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y"
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
  echo "CONFIG_KSU_SUSFS_SUS_MAP=y"
} >> out/.config

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig

echo "=== Vérification des configs SusFS ==="
grep "CONFIG_KSU_SUSFS" out/.config | head -20

# ==================== 6. PATCH SIGNATURES + TACTILE ====================
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c

# ==================== 7. COMPILATION ====================
echo "=== Compilation finale ==="
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j$(nproc) Image 2>&1 | tee build.log

if [ -f "out/arch/arm64/boot/Image" ]; then
  echo "✅ Compilation réussie"
  ls -lh out/arch/arm64/boot/
else
  echo "❌ BUILD FAILED"
  grep -i "error:" build.log | head -20
  exit 1
fi

# ==================== 8. REPACK ====================
cd $GITHUB_WORKSPACE
curl -fLo boot-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260830/boot.img" 2>/dev/null || {
  echo "Fallback mkbootimg..."
  mkbootimg --kernel kernel_sources/out/arch/arm64/boot/Image --ramdisk /dev/null --output final_boot.img --header_version 2 --pagesize 4096 --base 0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 --tags_offset 0x00000100 --cmdline "androidboot.hardware=kiev androidboot.selinux=permissive"
}
curl -fLo dtbo-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260830/dtbo.img" 2>/dev/null || true

if [ -f "boot-stock.img" ]; then
  echo "=== Repack avec magiskboot ==="
  mkdir -p repack
  cp boot-stock.img repack/boot.img
  wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk-v27.0.apk
  unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so
  mv lib/x86_64/libmagiskboot.so repack/magiskboot
  chmod +x repack/magiskboot
  rm -rf Magisk-v27.0.apk lib/
  cd repack
  ./magiskboot unpack boot.img
  cp $GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image kernel
  ./magiskboot repack boot.img new-boot.img
  mv new-boot.img ../final_boot.img
  cd ..
fi

echo "=== Copie vers output ==="
mkdir -p output
cp final_boot.img output/ReSukiSU-SusFS-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/

echo "=== BUILD TERMINÉ ==="
ls -lh output/
