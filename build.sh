#!/bin/bash
set -e
echo "=== Début du build ReSukiSU + SusFS (Méthode Python automatisée) pour kiev (SM8250) ==="
df -h

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
sudo apt-get clean

sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true

sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld device-tree-compiler zip unzip curl git python3 mkbootimg

cd $GITHUB_WORKSPACE

echo "=== Clonage du kernel sm8250 depuis le fork Albanel22 (Branche tactile) ==="
git clone https://github.com/Albanel22/android_kernel_motorola_sm8250.git -b lineage-23.2-tactile --depth=1 kernel_sources
cd kernel_sources

echo "=== Intégration du fork KernelSU : ReSukiSU ==="
rm -rf drivers/kernelsu kernelSU susfs4ksu || true
curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash

echo "=== Application des hooks manuels KernelSU (Python) ==="
if ! grep -q "ksu_handle_execveat" fs/exec.c; then
  python3 - << 'PYEOF'
import re
with open('fs/exec.c', 'r', encoding='utf-8', errors='ignore') as f:
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
with open('fs/exec.c', 'w', encoding='utf-8') as f:
    f.write(content)
PYEOF
fi

if ! grep -q "ksu_handle_faccessat" fs/open.c; then
  python3 - << 'PYEOF'
import re
with open('fs/open.c', 'r', encoding='utf-8', errors='ignore') as f:
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
with open('fs/open.c', 'w', encoding='utf-8') as f:
    f.write(content)
PYEOF
fi

if ! grep -q "ksu_handle_fstat64_ret" fs/stat.c; then
  python3 - << 'PYEOF'
import re
with open('fs/stat.c', 'r', encoding='utf-8', errors='ignore') as f:
    content = f.read()
if 'ksu_handle_stat' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_stat(int *dfd, const char __user **filename_user,
				int *flags);
extern void ksu_handle_newfstat_ret(unsigned int *fd, struct stat __user **statbuf_ptr);
#if defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_COMPAT_STAT64)
extern void ksu_handle_fstat64_ret(unsigned long *fd, struct stat64 __user **statbuf_ptr);
#endif
#endif
'''
    pattern = r'(SYSCALL_DEFINE4\(newfstatat)'
    content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
with open('fs/stat.c', 'w', encoding='utf-8') as f:
    f.write(content)
PYEOF
fi

if ! grep -q "ksu_handle_sys_reboot" kernel/reboot.c; then
  python3 - << 'PYEOF'
import re
with open('kernel/reboot.c', 'r', encoding='utf-8', errors='ignore') as f:
    content = f.read()
if 'ksu_handle_sys_reboot' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);
#endif
'''
    pattern = r'(SYSCALL_DEFINE4\(reboot)'
    content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
with open('kernel/reboot.c', 'w', encoding='utf-8') as f:
    f.write(content)
PYEOF
fi

echo "=== Téléchargement SusFS ==="
git clone --depth=1 https://gitlab.com/simonpunk/susfs4ksu.git /tmp/susfs4ksu

echo "=== Copie des fichiers SusFS ==="
cp /tmp/susfs4ksu/kernel_patches/fs/susfs.c fs/
cp /tmp/susfs4ksu/kernel_patches/include/linux/susfs.h include/linux/
cp /tmp/susfs4ksu/kernel_patches/include/linux/susfs_def.h include/linux/

echo "=== Application des patches SusFS via Python propre ==="
python3 - << 'PYEOF'
import os, re

# 1. Ajout de susfs.o dans fs/Makefile
if os.path.exists('fs/Makefile'):
    with open('fs/Makefile', 'r', encoding='utf-8', errors='ignore') as f:
        mf = f.read()
    if 'susfs.o' not in mf:
        with open('fs/Makefile', 'a', encoding='utf-8') as f:
            f.write('\n# SuSFS integration\nobj-$(CONFIG_KSU_SUSFS) += susfs.o\n')

# 2. Ajout de susfs_mnt_id_backup dans struct vfsmount / struct mount
for mfile in ['include/linux/mount.h', 'include/linux/fs.h']:
    if os.path.exists(mfile):
        with open(mfile, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
        if 'susfs_mnt_id_backup' not in content:
            snippet = '\n#ifdef CONFIG_KSU_SUSFS\n    int susfs_mnt_id_backup;\n#endif\n'
            match = re.search(r'(struct\s+(?:vfsmount|mount)\s*\{)(.*?)(\})', content, re.DOTALL)
            if match:
                start_s, body, end_s = match.groups()
                new_c = content[:match.start()] + start_s + body + snippet + end_s + content[match.end():]
                with open(mfile, 'w', encoding='utf-8') as f:
                    f.write(new_c)
                break

# 3. Patch fs/namespace.c (include + alloc_vfsmnt init)
if os.path.exists('fs/namespace.c'):
    with open('fs/namespace.c', 'r', encoding='utf-8', errors='ignore') as f:
        nsc = f.read()
    if '#include <linux/susfs.h>' not in nsc:
        nsc = nsc.replace('#include <linux/fs.h>', '#include <linux/fs.h>\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs.h>\n#endif', 1)
    if 'susfs_mnt_id_backup' not in nsc:
        target_pattern = r'(static\s+struct\s+mount\s*\*alloc_vfsmnt[^{]*\{)(.*?)(return\s+mnt;)'
        def add_susfs(m):
            return m.group(1) + m.group(2) + '\n#ifdef CONFIG_KSU_SUSFS\n    mnt->mnt.susfs_mnt_id_backup = 0;\n#endif\n' + m.group(3)
        nsc = re.sub(target_pattern, add_susfs, nsc, count=1, flags=re.DOTALL)
    with open('fs/namespace.c', 'w', encoding='utf-8') as f:
        f.write(nsc)

# 4. Patch fs/proc/task_mmu.c
if os.path.exists('fs/proc/task_mmu.c'):
    with open('fs/proc/task_mmu.c', 'r', encoding='utf-8', errors='ignore') as f:
        tmc = f.read()
    if 'susfs_def.h' not in tmc:
        tmc = tmc.replace('#include <linux/mm_inline.h>', '#include <linux/mm_inline.h>\n#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n#include <linux/susfs_def.h>\n#endif', 1)
        with open('fs/proc/task_mmu.c', 'w', encoding='utf-8') as f:
            f.write(tmc)
PYEOF

echo "=== Configuration ==="
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

mkdir -p out
CONFIG=$(find arch/arm64/configs/ -name "*kiev*" -o -name "*lito*" -o -name "*sm8250*" | head -1)
CONFIG_NAME=$(basename "$CONFIG")
cp "$CONFIG" arch/arm64/configs/$CONFIG_NAME
echo "Config utilisée: $CONFIG"

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 $CONFIG_NAME

{
  echo "CONFIG_KSU=y"
  echo "CONFIG_KSU_MANUAL_HOOK=y"
  echo "CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK=y"
  echo "CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK=y"
  echo "CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK=y"
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

echo "=== Patch signatures modules + tactile ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c

if ! grep -q "panel_register_notifier" techpack/display/msm/msm_drv.c; then
  printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c
fi

echo "=== Compilation finale ==="
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j$(nproc) Image 2>&1 | tee build.log

if [ -f "out/arch/arm64/boot/Image" ]; then
  echo "✅ Compilation réussie"
else
  echo "❌ BUILD FAILED"
  grep -i "error:" build.log | head -20
  exit 1
fi

echo "=== Téléchargement des images stock ==="
cd $GITHUB_WORKSPACE

curl -fLo boot-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260830/boot.img" 2>/dev/null || {
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
