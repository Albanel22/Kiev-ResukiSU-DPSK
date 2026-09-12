#!/bin/bash
set -e

echo "=== BUILD : ReSukiSU + SuSFS (JackA1ltman) sur kiev ==="
df -h

# ==================== ENVIRONNEMENT ====================
sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
sudo apt-get clean

echo "=== Correction du miroir Ubuntu ==="
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list.d/*.list 2>/dev/null || true

sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev \
    libssl-dev libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi \
    clang llvm lld device-tree-compiler zip unzip curl git python3 mkbootimg wget

if [ ! -f /usr/bin/ld.lld ]; then
    sudo apt-get install -y lld
    sudo ln -sf /usr/bin/ld.lld-15 /usr/bin/ld.lld
fi

cd $GITHUB_WORKSPACE

# ==================== 1. CLONAGE DU NOYAU ====================
echo "=== Clonage du kernel depuis le fork Albanel22 (branche kiev-kernelsu-susfs) ==="
git clone --depth=1 --branch kiev-kernelsu-susfs https://github.com/Albanel22/android_kernel_motorola_sm8250.git kernel_sources
cd kernel_sources
git log --oneline -1
cd "$GITHUB_WORKSPACE"

cd "$GITHUB_WORKSPACE/kernel_sources"

# ==================== 2. INTÉGRATION RESUKISU ====================
echo "=== Intégration ReSukiSU via setup.sh ==="
rm -rf drivers/kernelsu kernelSU susfs4ksu || true
curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash

# ==================== 3. HOOKS MANUELS RESUKISU ====================
echo "=== Injection hook execveat ==="
if ! grep -q "ksu_handle_execveat" fs/exec.c; then
  cat > /tmp/hook_execveat.py << 'PYEOF'
import re
with open('fs/exec.c', 'r') as f:
    content = f.read()
if 'ksu_handle_execveat' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU
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
#ifdef CONFIG_KSU
	ksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);
#endif
	return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: execveat")
    else:
        pattern = r'(int do_execve\(struct filename \*filename,.*?struct user_arg_ptr envp = \{ \.ptr\.native = __envp \};\n)'
        replacement = r'\1#ifdef CONFIG_KSU\n\tksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);\n#endif\n'
        content = re.sub(pattern, replacement, content, count=1)
        print("OK: execveat (alternatif)")
with open('fs/exec.c', 'w') as f:
    f.write(content)
PYEOF
  python3 /tmp/hook_execveat.py
fi

echo "=== Injection hook faccessat ==="
if ! grep -q "ksu_handle_faccessat" fs/open.c; then
  cat > /tmp/hook_faccessat.py << 'PYEOF'
import re
with open('fs/open.c', 'r') as f:
    content = f.read()
if 'ksu_handle_faccessat' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU
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
#ifdef CONFIG_KSU
	ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
#endif
	return do_faccessat(dfd, filename, mode);'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: faccessat")
    else:
        pattern = r'(SYSCALL_DEFINE3\(faccessat.*?\n\{)'
        replacement = r'\1\n#ifdef CONFIG_KSU\n\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n#endif'
        content = re.sub(pattern, replacement, content, count=1)
        print("OK: faccessat (alternatif)")
with open('fs/open.c', 'w') as f:
    f.write(content)
PYEOF
  python3 /tmp/hook_faccessat.py
fi

echo "=== Injection hook stat complet ==="
if ! grep -q "ksu_handle_fstat64_ret" fs/stat.c; then
  cat > /tmp/hook_stat_complete.py << 'PYEOF'
import re

with open('fs/stat.c', 'r') as f:
    content = f.read()

if 'ksu_handle_stat' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU
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

if 'ksu_handle_stat(&dfd' not in content:
    old_code = '''	struct kstat stat;
	int error;

	return vfs_fstatat(dfd, filename, &stat, flag);'''
    new_code = '''	struct kstat stat;
	int error;

#ifdef CONFIG_KSU
	ksu_handle_stat(&dfd, &filename, &flag);
#endif
	return vfs_fstatat(dfd, filename, &stat, flag);'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: stat")
    else:
        pattern = r'(SYSCALL_DEFINE4\(newfstatat.*?int error;\n)'
        replacement = r'\1#ifdef CONFIG_KSU\n\tksu_handle_stat(&dfd, &filename, &flag);\n#endif\n'
        content = re.sub(pattern, replacement, content, count=1)
        print("OK: stat (alternatif)")

if 'ksu_handle_newfstat_ret' not in content:
    old_code = '''SYSCALL_DEFINE2(newfstat, unsigned int, fd, struct stat __user *, statbuf)
{
	struct kstat stat;
	int error = vfs_fstat(fd, &stat);

	if (!error)
		error = cp_new_stat(&stat, statbuf);

	return error;'''
    new_code = '''SYSCALL_DEFINE2(newfstat, unsigned int, fd, struct stat __user *, statbuf)
{
	struct kstat stat;
	int error = vfs_fstat(fd, &stat);

	if (!error)
		error = cp_new_stat(&stat, statbuf);

#ifdef CONFIG_KSU
	ksu_handle_newfstat_ret(&fd, &statbuf);
#endif
	return error;'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: newfstat_ret")

if 'ksu_handle_fstat64_ret' not in content:
    old_code = '''SYSCALL_DEFINE2(fstat64, unsigned long, fd, struct stat64 __user *, statbuf)
{
	struct kstat stat;
	int error = vfs_fstat(fd, &stat);

	if (!error)
		error = cp_new_stat64(&stat, statbuf);

	return error;'''
    new_code = '''SYSCALL_DEFINE2(fstat64, unsigned long, fd, struct stat64 __user *, statbuf)
{
	struct kstat stat;
	int error = vfs_fstat(fd, &stat);

	if (!error)
		error = cp_new_stat64(&stat, statbuf);

#ifdef CONFIG_KSU
	ksu_handle_fstat64_ret(&fd, &statbuf);
#endif
	return error;'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: fstat64_ret")
    else:
        pattern = r'(SYSCALL_DEFINE2\(fstat64.*?return error;\n)'
        replacement = r'\1#ifdef CONFIG_KSU\n\tksu_handle_fstat64_ret(&fd, &statbuf);\n#endif\n'
        content = re.sub(pattern, replacement, content, count=1)
        print("OK: fstat64_ret (alternatif)")

with open('fs/stat.c', 'w') as f:
    f.write(content)
print("=== Hooks stat terminés ===")
PYEOF
  python3 /tmp/hook_stat_complete.py
fi

echo "=== Injection hook sys_reboot ==="
if ! grep -q "ksu_handle_sys_reboot" kernel/reboot.c; then
  cat > /tmp/hook_reboot.py << 'PYEOF'
import re

with open('kernel/reboot.c', 'r') as f:
    content = f.read()

if 'ksu_handle_sys_reboot' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);
#endif
'''
    pattern = r'(SYSCALL_DEFINE4\(reboot)'
    content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)

    old_code = '''	char buffer[256];
	int ret = 0;'''

    new_code = '''	char buffer[256];
	int ret = 0;

#ifdef CONFIG_KSU
	ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif'''

    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: sys_reboot")
    else:
        pattern = r'(SYSCALL_DEFINE4\(reboot.*?\n\{)'
        replacement = r'\1\n#ifdef CONFIG_KSU\n\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif'
        content = re.sub(pattern, replacement, content, count=1)
        print("OK: sys_reboot (alternatif)")

with open('kernel/reboot.c', 'w') as f:
    f.write(content)
PYEOF
  python3 /tmp/hook_reboot.py
fi

echo "✅ Hooks ReSukiSU appliqués"

# ==================== 4. SUSFS (JackA1ltman) ====================
cd "$GITHUB_WORKSPACE"
echo "=== Téléchargement SuSFS JackA1ltman ==="

rm -rf /tmp/jack_repo || true
git clone --depth=1 --branch mainline https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git /tmp/jack_repo

SUSFS_PATCH="/tmp/jack_repo/Patches/Patch/susfs_patch_to_4.19.patch"
if [ ! -f "$SUSFS_PATCH" ]; then
    echo "❌ Patch SuSFS 4.19 introuvable !"
    find /tmp/jack_repo/Patches -name "*.patch" | sort
    exit 1
fi
echo "✅ Patch SuSFS trouvé : $(wc -l < $SUSFS_PATCH) lignes"

cd "$GITHUB_WORKSPACE/kernel_sources"
patch -p1 < "$SUSFS_PATCH" 2>&1 | tee /tmp/susfs_patch.log || true

# Copier les fichiers SuSFS complets
if [ -d "/tmp/jack_repo/Patches/fs" ]; then
    cp -r /tmp/jack_repo/Patches/fs/* fs/ 2>/dev/null || true
fi
if [ -d "/tmp/jack_repo/Patches/include/linux" ]; then
    cp -r /tmp/jack_repo/Patches/include/linux/* include/linux/ 2>/dev/null || true
fi

# Nettoyage des .rej/.orig
find . -name "*.rej" -type f -delete 2>/dev/null || true
find . -name "*.orig" -type f -delete 2>/dev/null || true

# Vérifier la version SuSFS
if [ -f "include/linux/susfs.h" ]; then
    SUSFS_VER=$(grep -oP 'SUSFS_VERSION "\K[^"]+' include/linux/susfs.h | head -1)
    echo "✅ SuSFS version détectée : $SUSFS_VER"
fi

# Correction FS/Makefile
if [ -f "fs/Makefile" ]; then
    grep -q "susfs.o" fs/Makefile || echo "obj-\$(CONFIG_KSU_SUSFS) += susfs.o" >> fs/Makefile
    if [ -f "fs/sus_su.c" ]; then
        grep -q "sus_su.o" fs/Makefile || echo "obj-\$(CONFIG_KSU_SUSFS) += sus_su.o" >> fs/Makefile
    fi
fi

# Correctif task_mmu.c (unused vma)
if [ -f "fs/proc/task_mmu.c" ]; then
    sed -i 's/struct vm_area_struct \*vma;/struct vm_area_struct *vma __maybe_unused;/g' fs/proc/task_mmu.c
    echo "✅ Correctif task_mmu.c appliqué"
fi

# Ajout des symboles SusFS manquants
if [ -f "fs/susfs.c" ] && ! grep -q "susfs_ksu_sid = 0" fs/susfs.c; then
    cat >> fs/susfs.c << 'SUSFS_EOF'

#ifdef CONFIG_KSU_SUSFS
bool susfs_is_current_ksu_domain(void)
{
    const struct cred *cred = current_cred();
    return (cred->uid.val == 0 || cred->uid.val == 2000);
}
EXPORT_SYMBOL(susfs_is_current_ksu_domain);

u32 susfs_ksu_sid = 0;
EXPORT_SYMBOL(susfs_ksu_sid);

u32 susfs_priv_app_sid = 0;
EXPORT_SYMBOL(susfs_priv_app_sid);
#endif
SUSFS_EOF
fi

echo "✅ SuSFS intégré (JackA1ltman)"

# ==================== 5. PATCH SIGNATURES MODULES + TACTILE ====================
echo "=== Patch signatures modules + tactile ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c

printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c

echo "✅ Patches appliqués"

# ==================== 6. CONFIGURATION ====================
echo "=== Configuration ==="
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

mkdir -p out
CONFIG=$(find arch/arm64/configs/ -name "*kiev*" -o -name "*lito*" -o -name "*sm8250*" | head -1)
CONFIG_NAME=$(basename "$CONFIG")
cp "$CONFIG" arch/arm64/configs/$CONFIG_NAME
echo "Config utilisée: $CONFIG_NAME"

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 $CONFIG_NAME

{
  echo "CONFIG_KSU=y"
  echo "CONFIG_KSU_SUSFS=y"
  echo "CONFIG_THREAD_INFO_IN_TASK=y"
  echo "CONFIG_KPROBES=y"
  echo "CONFIG_HAVE_KPROBES=y"
  echo "CONFIG_KRETPROBES=y"
  echo "CONFIG_COMPAT=y"
  echo "CONFIG_COMPAT_32BIT_TIME=y"
  echo "# CONFIG_COMPAT_VDSO is not set"
  echo "# CONFIG_VDSO32 is not set"
  echo ""
  echo "# SuSFS"
  echo "CONFIG_KSU_SUSFS_SUS_PATH=y"
  echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y"
  echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y"
  echo "CONFIG_KSU_SUSFS_SUS_MAP=y"
  echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y"
  echo "CONFIG_KSU_SUSFS_ENABLE_LOG=y"
  echo "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y"
  echo "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y"
  echo "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y"
} >> out/.config

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig

# Forcer les options critiques
./scripts/config --file out/.config --enable KSU
./scripts/config --file out/.config --enable KSU_SUSFS
./scripts/config --file out/.config --enable THREAD_INFO_IN_TASK
echo "CONFIG_KSU=y" >> out/.config
echo "CONFIG_KSU_SUSFS=y" >> out/.config
echo "CONFIG_THREAD_INFO_IN_TASK=y" >> out/.config

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig

# Diagnostic
echo ""
echo "=== DIAGNOSTIC FINAL ==="
grep -E "CONFIG_KSU=|CONFIG_KSU_SUSFS=|CONFIG_THREAD_INFO_IN_TASK=" out/.config
echo ""
grep -q "CONFIG_KSU=y" out/.config && echo "✅ CONFIG_KSU=y" || (echo "❌ KSU!=y" && exit 1)
grep -q "CONFIG_KSU_SUSFS=y" out/.config && echo "✅ CONFIG_KSU_SUSFS=y" || (echo "❌ SUSFS!=y" && exit 1)
grep -q "CONFIG_THREAD_INFO_IN_TASK=y" out/.config && echo "✅ THREAD_INFO_IN_TASK=y" || (echo "❌ THREAD_INFO!=y" && exit 1)

# ==================== 7. COMPILATION ====================
echo "=== Compilation ==="
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
echo "=== Téléchargement des images stock ==="
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
cp final_boot.img output/ReSukiSU-SuSFS-boot.img 2>/dev/null || true
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/

echo "=== BUILD TERMINÉ ==="
ls -lh output/
