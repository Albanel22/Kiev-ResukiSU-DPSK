#!/bin/bash
set -e
echo "=== Début du build ReSukiSU (sans SuSFS source) pour kiev (SM8250) ==="
df -h

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
echo "=== Intégration ReSukiSU ==="
rm -rf drivers/kernelsu kernelSU susfs4ksu || true
curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash

# ==================== Contournement check SuSFS obligatoire ====================
echo "=== Contournement de l'exigence SuSFS ==="
if [ -f drivers/kernelsu/Kbuild ]; then
  sed -i '/You should integrate susfs in your kernel/d' drivers/kernelsu/Kbuild
  sed -i 's/$(error You should integrate susfs in your kernel.)/$(info SuSFS check bypassed)/g' drivers/kernelsu/Kbuild
  echo "✅ Check SuSFS contourné"
else
  echo "⚠️  drivers/kernelsu/Kbuild non trouvé"
fi

# ==================== 3. HOOKS MANUELS ReSukiSU ====================
echo "=== Hooks ReSukiSU ==="

# --- execveat ---
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

# --- faccessat ---
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

# --- stat ---
if ! grep -q "ksu_handle_fstat64_ret" fs/stat.c; then
  cat > /tmp/hook_stat_complete.py << 'PYEOF'
import re
with open('fs/stat.c', 'r') as f:
    content = f.read()
if 'ksu_handle_stat' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
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
with open('fs/stat.c', 'w') as f:
    f.write(content)
print("=== Hooks stat terminés ===")
PYEOF
  python3 /tmp/hook_stat_complete.py
fi

# --- reboot ---
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

# --- setresuid ---
if ! grep -q "ksu_handle_setresuid" kernel/sys.c; then
  cat > /tmp/hook_setresuid.py << 'PYEOF'
import re
with open('kernel/sys.c', 'r') as f:
    content = f.read()
if 'ksu_handle_setresuid' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);
#endif
'''
    pattern = r'(long __sys_setresuid)'
    content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
    old_code = '''	bool ruid_new, euid_new, suid_new;'''
    new_code = '''	bool ruid_new, euid_new, suid_new;
#ifdef CONFIG_KSU_MANUAL_HOOK
	(void)ksu_handle_setresuid(ruid, euid, suid);
#endif'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: setresuid")
with open('kernel/sys.c', 'w') as f:
    f.write(content)
PYEOF
  python3 /tmp/hook_setresuid.py
fi

# --- sys_read ---
if ! grep -q "ksu_handle_sys_read" fs/read_write.c; then
  cat > /tmp/hook_sys_read.py << 'PYEOF'
import re
with open('fs/read_write.c', 'r') as f:
    content = f.read()
if 'ksu_handle_sys_read' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr);
#endif
'''
    pattern = r'(SYSCALL_DEFINE3\(read)'
    content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
    old_code = '''SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)
{'''
    new_code = '''SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)
{
#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_sys_read(fd, &buf, &count);
#endif'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: sys_read")
with open('fs/read_write.c', 'w') as f:
    f.write(content)
PYEOF
  python3 /tmp/hook_sys_read.py
fi

# --- input ---
if ! grep -q "ksu_handle_input_handle_event" drivers/input/input.c; then
  cat > /tmp/hook_input.py << 'PYEOF'
import re
with open('drivers/input/input.c', 'r') as f:
    content = f.read()
if 'ksu_handle_input_handle_event' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);
#endif
'''
    pattern = r'(void input_event\(struct input_dev \*dev,)'
    content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
    old_code = '''void input_event(struct input_dev *dev,
		 unsigned int type, unsigned int code, int value)
{
	unsigned long flags;

	if (is_event_supported(type, dev->evbit, EV_MAX)) {'''
    new_code = '''void input_event(struct input_dev *dev,
		 unsigned int type, unsigned int code, int value)
{
	unsigned long flags;

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_input_handle_event(&type, &code, &value);
#endif

	if (is_event_supported(type, dev->evbit, EV_MAX)) {'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: input_event")
with open('drivers/input/input.c', 'w') as f:
    f.write(content)
PYEOF
  python3 /tmp/hook_input.py
fi

# ==================== 4. CONFIGURATION ====================
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
  echo "# CONFIG_COMPAT_VDSO is not set"
  echo "# CONFIG_VDSO32 is not set"
} >> out/.config

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig

# ==================== 5. PATCHES FINAUX ====================
echo "=== Patch signature modules (contournement vermagic) ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
echo "✅ Patch tactile msm_drv.c retiré (les modules /vendor s'occupent du panel)"

# ==================== 6. COMPILATION ====================
echo "=== Compilation finale ==="
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j$(nproc) Image 2>&1 | tee build.log

if [ -f "out/arch/arm64/boot/Image" ]; then
  echo "✅ Compilation réussie"
  ls -lh out/arch/arm64/boot/
else
  echo "❌ BUILD FAILED"
  grep -iE "error:|fatal error:" build.log | head -30
  exit 1
fi

# ==================== 7. REPACK ====================
echo "=== Téléchargement des images stock ==="
cd $GITHUB_WORKSPACE

if ! curl -fLo boot-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260920/boot.img"; then
  echo "❌ ERREUR : Échec du téléchargement de boot-stock.img."
  exit 1
fi

curl -fLo dtbo-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260920/dtbo.img" 2>/dev/null || true

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

# ==================== 8. SORTIE ====================
echo "=== Copie vers output ==="
mkdir -p output
cp final_boot.img output/ReSukiSU-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/

echo "=== BUILD TERMINÉ ==="
ls -lh output/
