#!/bin/bash
set -e
echo "=== Début du build ReSukiSU + SusFS (JackA1ltman) pour kiev (SM8250) ==="
df -h

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
sudo apt-get clean

sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true

sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld device-tree-compiler zip unzip curl git python3 mkbootimg

cd $GITHUB_WORKSPACE

echo "=== Clonage du kernel depuis le fork Albanel22 ==="
git clone https://github.com/Albanel22/android_kernel_motorola_sm8250.git -b kiev-kernelsu-susfs --depth=1 kernel_sources
cd kernel_sources

echo "=== Intégration ReSukiSU ==="
rm -rf drivers/kernelsu kernelSU susfs4ksu || true
curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash

echo "=== Hooks ReSukiSU ==="
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
    else:
        pattern = r'(int do_execve\(struct filename \*filename,.*?struct user_arg_ptr envp = \{ \.ptr\.native = __envp \};\n)'
        replacement = r'\1#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);\n#endif\n'
        content = re.sub(pattern, replacement, content, count=1)
        print("OK: execveat (alternatif)")
with open('fs/exec.c', 'w') as f:
    f.write(content)
PYEOF
  python3 /tmp/hook_execveat.py
fi

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
    else:
        pattern = r'(SYSCALL_DEFINE3\(faccessat.*?\n\{)'
        replacement = r'\1\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n#endif'
        content = re.sub(pattern, replacement, content, count=1)
        print("OK: faccessat (alternatif)")
with open('fs/open.c', 'w') as f:
    f.write(content)
PYEOF
  python3 /tmp/hook_faccessat.py
fi

if ! grep -q "ksu_handle_fstat64_ret" fs/stat.c; then
  cat > /tmp/hook_stat_complete.py << 'PYEOF'
import re

with open('fs/stat.c', 'r') as f:
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

if 'ksu_handle_stat(&dfd' not in content:
    old_code = '''	struct kstat stat;
	int error;

	return vfs_fstatat(dfd, filename, &stat, flag);'''
    new_code = '''	struct kstat stat;
	int error;

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_stat(&dfd, &filename, &flag);
#endif
	return vfs_fstatat(dfd, filename, &stat, flag);'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: stat")
    else:
        pattern = r'(SYSCALL_DEFINE4\(newfstatat.*?int error;\n)'
        replacement = r'\1#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_stat(&dfd, &filename, &flag);\n#endif\n'
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

#ifdef CONFIG_KSU_MANUAL_HOOK
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

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_fstat64_ret(&fd, &statbuf);
#endif
	return error;'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: fstat64_ret")
    else:
        pattern = r'(SYSCALL_DEFINE2\(fstat64.*?return error;\n)'
        replacement = r'\1#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_fstat64_ret(&fd, &statbuf);\n#endif\n'
        content = re.sub(pattern, replacement, content, count=1)
        print("OK: fstat64_ret (alternatif)")

with open('fs/stat.c', 'w') as f:
    f.write(content)
print("=== Hooks stat terminés ===")
PYEOF
  python3 /tmp/hook_stat_complete.py
fi

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
    else:
        pattern = r'(SYSCALL_DEFINE4\(reboot.*?\n\{)'
        replacement = r'\1\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif'
        content = re.sub(pattern, replacement, content, count=1)
        print("OK: sys_reboot (alternatif)")

with open('kernel/reboot.c', 'w') as f:
    f.write(content)
PYEOF
  python3 /tmp/hook_reboot.py
fi

echo "=== Téléchargement SuSFS (JackA1ltman) ==="
cd $GITHUB_WORKSPACE
git clone --depth=1 https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git /tmp/jacka1ltman_repo

echo "=== Application du patch SuSFS 4.19 (JackA1ltman) ==="
cd kernel_sources
PATCH_FILE="/tmp/jacka1ltman_repo/Patches/Patch/susfs_patch_to_4.19.patch"
if [ -f "$PATCH_FILE" ]; then
  echo "Application: $PATCH_FILE"
  patch -p1 < "$PATCH_FILE" 2>&1 | tee /tmp/susfs_patch.log || true
else
  echo "ERREUR: Patch 4.19 non trouvé !"
  echo "Fichiers disponibles :"
  ls -la /tmp/jacka1ltman_repo/Patches/Patch/*.patch
  exit 1
fi

echo "=== Vérification des .rej ==="
find . -name "*.rej" -type f | while read rej; do
  echo "REJ: $rej"
done

echo "=== Correction variable vma non utilisée dans task_mmu.c ==="
if [ -f "fs/proc/task_mmu.c" ]; then
  sed -i 's/struct vm_area_struct \*vma;/struct vm_area_struct *vma __maybe_unused;/g' fs/proc/task_mmu.c
  echo "OK: Correction appliquée"
fi

echo "=== Correction automatique de fs/super.c ==="
if [ -f "fs/super.c" ]; then
  python3 - << 'PYEOF'
import re, os
file_path = 'fs/super.c'
if os.path.exists(file_path):
    with open(file_path, 'r') as f:
        content = f.read()
    
    # 1. Ajouter l'include susfs_def.h après les premiers includes
    if '#include <linux/susfs_def.h>' not in content:
        lines = content.split('\n')
        last_include_idx = -1
        for i, line in enumerate(lines[:50]):
            if line.startswith('#include <linux/'):
                last_include_idx = i
        
        if last_include_idx >= 0:
            lines.insert(last_include_idx + 1, '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif')
            content = '\n'.join(lines)
    
    # 2. Ajouter les déclarations extern pour les fonctions SuSFS
    # NE PAS redéfinir DEFAULT_KSU_MNT_MINOR_DEV car il existe déjà dans susfs_def.h
    if 'extern bool susfs_is_current_ksu_domain' not in content:
        extern_decl = '''
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
#endif
'''
        lines = content.split('\n')
        last_include_idx = -1
        for i, line in enumerate(lines):
            if line.startswith('#include'):
                last_include_idx = i
        
        if last_include_idx >= 0:
            lines.insert(last_include_idx + 1, extern_decl)
            content = '\n'.join(lines)
    
    with open(file_path, 'w') as f:
        f.write(content)
    print("OK: fs/super.c corrigé")
PYEOF
fi

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

echo "=== Vérification des configs SusFS ==="
grep "CONFIG_KSU_SUSFS" out/.config | head -20

echo "=== Patch signatures modules + tactile ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\
