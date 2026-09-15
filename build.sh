#!/bin/bash
set -e
echo "=== Début du build ReSukiSU + SuSFS pour kiev (SM8250) ==="
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

# ==================== 4. INTÉGRATION SuSFS (JackA1ltman) ====================
echo ""
echo "=== Intégration SuSFS depuis JackA1ltman ==="
cd "$GITHUB_WORKSPACE"
rm -rf /tmp/jacka1ltman_repo
git clone --depth=1 https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git /tmp/jacka1ltman_repo

cd "$GITHUB_WORKSPACE/kernel_sources"

SUSFS_PATCH="/tmp/jacka1ltman_repo/Patches/Patch/susfs_patch_to_4.19.patch"
echo "=== Application du patch SuSFS ==="
patch -p1 --forward --batch < "$SUSFS_PATCH" 2>&1 | tee /tmp/susfs_patch.log || true

# ---------- Corrections des .rej ----------
echo "=== Corrections des patchs échoués ==="

# 1. Nettoyage des .rej
find . -name "*.rej" -type f | while read rej; do
  echo "REJ: $rej"
  rm -f "$rej"
done

# 2. Correction variable vma non utilisée dans task_mmu.c
if [ -f "fs/proc/task_mmu.c" ]; then
  sed -i 's/struct vm_area_struct \*vma;/struct vm_area_struct *vma __maybe_unused;/g' fs/proc/task_mmu.c
  echo "OK: Correction vma appliquée"
fi

# 3. Correction automatique de fs/super.c
if [ -f "fs/super.c" ]; then
  python3 - << 'PYEOF'
import re, os
file_path = 'fs/super.c'
if os.path.exists(file_path):
    with open(file_path, 'r') as f:
        content = f.read()
    
    # Ajouter l'include susfs_def.h après les premiers includes
    if '#include <linux/susfs_def.h>' not in content:
        lines = content.split('\n')
        last_include_idx = -1
        for i, line in enumerate(lines[:50]):
            if line.startswith('#include <linux/'):
                last_include_idx = i
        
        if last_include_idx >= 0:
            lines.insert(last_include_idx + 1, '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif')
            content = '\n'.join(lines)
    
    # Ajouter les déclarations extern pour les fonctions SuSFS
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

# 4. Correction automatique de fs/stat.c
if [ -f "fs/stat.c" ]; then
  python3 - << 'PYEOF'
import re, os
file_path = 'fs/stat.c'
if os.path.exists(file_path):
    with open(file_path, 'r') as f:
        content = f.read()
    
    # 1. Ajouter l'include susfs_def.h APRÈS les premiers includes
    if '#include <linux/susfs_def.h>' not in content:
        lines = content.split('\n')
        insert_idx = -1
        
        # Chercher le dernier #include dans les 50 premières lignes
        for i, line in enumerate(lines[:50]):
            if line.strip().startswith('#include <linux/'):
                insert_idx = i + 1
        
        if insert_idx > 0:
            lines.insert(insert_idx, '#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT')
            lines.insert(insert_idx + 1, '#include <linux/susfs_def.h>')
            lines.insert(insert_idx + 2, '#endif')
            content = '\n'.join(lines)
    
    # 2. Ajouter les déclarations extern pour les fonctions SuSFS
    if 'extern bool susfs_is_current_app_uid' not in content:
        extern_decl = '''
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
extern bool susfs_is_current_app_uid(void);
extern void susfs_sus_kstat_spoof_generic_fillattr(struct inode *inode, struct kstat *stat, unsigned int mask);
#endif
'''
        lines = content.split('\n')
        last_include_idx = -1
        for i, line in enumerate(lines):
            if line.strip().startswith('#include'):
                last_include_idx = i
        
        if last_include_idx >= 0:
            lines.insert(last_include_idx + 1, extern_decl)
            content = '\n'.join(lines)
    
    with open(file_path, 'w') as f:
        f.write(content)
    print("OK: fs/stat.c corrigé")
PYEOF
fi

# 6. Correction automatique de fs/namespace.c
if [ -f "fs/namespace.c" ]; then
  python3 - << 'PYEOF'
import re, os
file_path = 'fs/namespace.c'
if os.path.exists(file_path):
    with open(file_path, 'r') as f:
        content = f.read()
    
    # 1. Ajouter l'include susfs_def.h APRÈS les premiers includes
    if '#include <linux/susfs_def.h>' not in content:
        lines = content.split('\n')
        insert_idx = -1
        
        # Chercher le dernier #include dans les 50 premières lignes
        for i, line in enumerate(lines[:50]):
            if line.strip().startswith('#include <linux/'):
                insert_idx = i + 1
        
        if insert_idx > 0:
            lines.insert(insert_idx, '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT')
            lines.insert(insert_idx + 1, '#include <linux/susfs_def.h>')
            lines.insert(insert_idx + 2, '#endif')
            content = '\n'.join(lines)
    
    # 2. Ajouter les déclarations extern pour les fonctions SuSFS
    if 'extern bool susfs_is_current_ksu_domain' not in content:
        extern_decl = '''
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern bool susfs_is_current_proc_umounted_for_zygote_next(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
#endif
'''
        lines = content.split('\n')
        last_include_idx = -1
        for i, line in enumerate(lines):
            if line.strip().startswith('#include'):
                last_include_idx = i
        
        if last_include_idx >= 0:
            lines.insert(last_include_idx + 1, extern_decl)
            content = '\n'.join(lines)
    
    with open(file_path, 'w') as f:
        f.write(content)
    print("OK: fs/namespace.c corrigé")
PYEOF
fi

# 7. Correction CL_COPY_MNT_NS dans fs/namespace.c
if [ -f "fs/namespace.c" ]; then
  python3 - << 'PYEOF'
import re, os
file_path = 'fs/namespace.c'
if os.path.exists(file_path):
    with open(file_path, 'r') as f:
        content = f.read()
    
    # Vérifier si CL_COPY_MNT_NS est déjà défini
    if 'CL_COPY_MNT_NS' not in content or '#define CL_COPY_MNT_NS' not in content:
        # Ajouter la définition après les includes
        lines = content.split('\n')
        insert_idx = -1
        
        # Chercher le dernier #include
        for i, line in enumerate(lines):
            if line.strip().startswith('#include'):
                insert_idx = i + 1
        
        if insert_idx > 0:
            # Vérifier si c'est déjà dans susfs_def.h
            if not os.path.exists('include/linux/susfs_def.h') or 'CL_COPY_MNT_NS' not in open('include/linux/susfs_def.h').read():
                lines.insert(insert_idx, '')
                lines.insert(insert_idx + 1, '#ifndef CL_COPY_MNT_NS')
                lines.insert(insert_idx + 2, '#define CL_COPY_MNT_NS 0x10000000UL /* SuSFS specific */')
                lines.insert(insert_idx + 3, '#endif')
                content = '\n'.join(lines)
    
    with open(file_path, 'w') as f:
        f.write(content)
    print("OK: CL_COPY_MNT_NS défini dans fs/namespace.c")
PYEOF
fi

# 5. Ajout dans Makefile
if [ -f "fs/Makefile" ] && ! grep -q "susfs.o" fs/Makefile; then
  echo "obj-\$(CONFIG_KSU_SUSFS) += susfs.o" >> fs/Makefile
  [ -f "fs/sus_su.c" ] && echo "obj-\$(CONFIG_KSU_SUSFS) += sus_su.o" >> fs/Makefile
  echo "OK: Makefile mis à jour"
fi

echo "✅ SuSFS patch + corrections appliquées"

# ==================== VÉRIFICATION DES HOOKS APRÈS SUSFS ====================
echo ""
echo "=== Vérification des hooks après SuSFS ==="

HOOKS_MISSING=""

# Vérifier execveat
if ! grep -q "ksu_handle_execveat" fs/exec.c; then
  HOOKS_MISSING="$HOOKS_MISSING execveat"
  echo "❌ Hook execveat MANQUANT dans fs/exec.c"
else
  echo "✅ Hook execveat présent"
fi

# Vérifier faccessat
if ! grep -q "ksu_handle_faccessat" fs/open.c; then
  HOOKS_MISSING="$HOOKS_MISSING faccessat"
  echo "❌ Hook faccessat MANQUANT dans fs/open.c"
else
  echo "✅ Hook faccessat présent"
fi

# Vérifier stat
if ! grep -q "ksu_handle_stat" fs/stat.c; then
  HOOKS_MISSING="$HOOKS_MISSING stat"
  echo "❌ Hook stat MANQUANT dans fs/stat.c"
else
  echo "✅ Hook stat présent"
fi

# Vérifier reboot
if ! grep -q "ksu_handle_sys_reboot" kernel/reboot.c; then
  HOOKS_MISSING="$HOOKS_MISSING reboot"
  echo "❌ Hook reboot MANQUANT dans kernel/reboot.c"
else
  echo "✅ Hook reboot présent"
fi

# Vérifier setresuid
if ! grep -q "ksu_handle_setresuid" kernel/sys.c; then
  HOOKS_MISSING="$HOOKS_MISSING setresuid"
  echo "❌ Hook setresuid MANQUANT dans kernel/sys.c"
else
  echo "✅ Hook setresuid présent"
fi

# Vérifier sys_read
if ! grep -q "ksu_handle_sys_read" fs/read_write.c; then
  HOOKS_MISSING="$HOOKS_MISSING sys_read"
  echo "❌ Hook sys_read MANQUANT dans fs/read_write.c"
else
  echo "✅ Hook sys_read présent"
fi

# Vérifier input
if ! grep -q "ksu_handle_input_handle_event" drivers/input/input.c; then
  HOOKS_MISSING="$HOOKS_MISSING input"
  echo "❌ Hook input MANQUANT dans drivers/input/input.c"
else
  echo "✅ Hook input présent"
fi

# Vérifier le dossier drivers/kernelsu
if [ ! -d "drivers/kernelsu" ]; then
  echo "❌ drivers/kernelsu MANQUANT !"
  HOOKS_MISSING="$HOOKS_MISSING kernelsu_folder"
else
  echo "✅ drivers/kernelsu présent"
fi

# Vérifier si CONFIG_KSU est activé
if ! grep -q "CONFIG_KSU=y" out/.config; then
  echo "❌ CONFIG_KSU non activé dans .config !"
  HOOKS_MISSING="$HOOKS_MISSING config_ksu"
else
  echo "✅ CONFIG_KSU activé"
fi

if [ -n "$HOOKS_MISSING" ]; then
  echo ""
  echo "⚠️ ATTENTION: Éléments manquants:$HOOKS_MISSING"
  echo "Le patch SuSFS a peut-être écrasé les hooks."
else
  echo ""
  echo "✅ Tous les hooks sont présents"
fi

# ==================== 5. CONFIGURATION ====================
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
  echo ""
  echo "CONFIG_KSU_SUSFS=y"
  echo "CONFIG_KSU_SUSFS_SUS_PATH=y"
  echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y"
  echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y"
  echo "# CONFIG_KSU_SUSFS_SUS_MAP is not set"
  echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y"
  echo "# CONFIG_KSU_SUSFS_ENABLE_LOG is not set"
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

# ==================== 6. PATCHES FINAUX ====================
echo "=== Patch signatures modules + tactile ==="
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
  grep -iE "error:|fatal error:" build.log | head -40
  exit 1
fi

# ==================== 8. REPACK ====================
echo "=== Téléchargement des images stock ==="
cd $GITHUB_WORKSPACE

# Nettoyer les anciens fichiers
rm -f boot-stock.img dtbo-stock.img final_boot.img 2>/dev/null || true

echo "--- Téléchargement boot.img ---"
curl -fLo boot-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260830/boot.img" 2>/dev/null || {
  echo "⚠️ Fallback mkbootimg..."
  mkbootimg --kernel kernel_sources/out/arch/arm64/boot/Image --ramdisk /dev/null --output final_boot.img \
    --header_version 2 --pagesize 4096 --base 0x00000000 --kernel_offset 0x00008000 \
    --ramdisk_offset 0x01000000 --tags_offset 0x00000100 \
    --cmdline "androidboot.hardware=kiev androidboot.selinux=permissive"
  exit 0  # Sortir car on ne peut pas faire le repack
}

echo "--- Téléchargement dtbo.img ---"
curl -fLo dtbo-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260830/dtbo.img" 2>/dev/null || true

echo ""
echo "=== Vérification des fichiers téléchargés ==="
if [ -f "boot-stock.img" ]; then
  BOOT_SIZE=$(stat -c%s boot-stock.img 2>/dev/null || stat -f%z boot-stock.img)
  BOOT_SIZE_MB=$((BOOT_SIZE / 1024 / 1024))
  echo "✅ boot-stock.img: $BOOT_SIZE bytes ($BOOT_SIZE_MB MB)"
else
  echo "❌ boot-stock.img non trouvé !"
  exit 1
fi

if [ -f "dtbo-stock.img" ]; then
  DTBO_SIZE=$(stat -c%s dtbo-stock.img 2>/dev/null || stat -f%z dtbo-stock.img)
  DTBO_SIZE_MB=$((DTBO_SIZE / 1024 / 1024))
  echo "✅ dtbo-stock.img: $DTBO_SIZE bytes ($DTBO_SIZE_MB MB)"
fi

echo ""
echo "=== Repack avec magiskboot ==="
mkdir -p repack
cp boot-stock.img repack/boot.img

wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk-v27.0.apk
unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so
mv lib/x86_64/libmagiskboot.so repack/magiskboot
chmod +x repack/magiskboot
rm -rf Magisk-v27.0.apk lib/

cd repack
echo "--- Unpack ---"
./magiskboot unpack boot.img
ls -lh kernel ramdisk.cpio 2>/dev/null || ls -lh kernel

echo ""
echo "--- Remplacement du kernel ---"
cp $GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image kernel
KERNEL_SIZE=$(stat -c%s kernel 2>/dev/null || stat -f%z kernel)
KERNEL_SIZE_MB=$((KERNEL_SIZE / 1024 / 1024))
echo "✅ Nouveau kernel: $KERNEL_SIZE bytes ($KERNEL_SIZE_MB MB)"

echo ""
echo "--- Repack ---"
./magiskboot repack boot.img new-boot.img
mv new-boot.img ../final_boot.img
cd ..

echo ""
echo "=== Vérification finale ==="
FINAL_SIZE=$(stat -c%s final_boot.img 2>/dev/null || stat -f%z final_boot.img)
FINAL_SIZE_MB=$((FINAL_SIZE / 1024 / 1024))
echo "✅ final_boot.img: $FINAL_SIZE bytes ($FINAL_SIZE_MB MB)"

if [ "$FINAL_SIZE_MB" -lt 50 ]; then
  echo ""
  echo "⚠️ ATTENTION: final_boot.img fait moins de 50MB !"
  echo "Cela peut indiquer un problème avec le repack."
  echo "Vérifiez que le ramdisk.cpio existe dans le dossier repack/"
fi

# ==================== 9. SORTIE ====================
echo ""
echo "=== Copie vers output ==="
mkdir -p output
cp final_boot.img output/ReSukiSU-SusFS-JackA1ltman-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/

echo ""
echo "=== BUILD TERMINÉ ==="
ls -lh output/
