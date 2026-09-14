#!/bin/bash
set -e
echo "=== Build ReSukiSU + SuSFS pour kiev (SM8250, kernel 4.19.325) ==="
echo "=== Source : lineage-23.2-tactile (pure) ==="
echo "=== Cible : RBC + Desjardins ==="
df -h

# ==================== 0. ENVIRONNEMENT ====================
sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
sudo apt-get clean

sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true

sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev \
    libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld \
    device-tree-compiler zip unzip curl git python3 mkbootimg wget

cd $GITHUB_WORKSPACE

# ==================== 1. CLONAGE DU NOYAU ====================
echo "=== Clonage du kernel : lineage-23.2-tactile (commit du 23 août 2026) ==="
git clone https://github.com/Albanel22/android_kernel_motorola_sm8250.git \
    -b lineage-23.2-tactile --depth=1 kernel_sources
cd kernel_sources

echo "=== Version kernel ==="
head -5 Makefile
echo ""

if ! grep -q "SUBLEVEL = 325" Makefile; then
    echo "⚠️  Version kernel différente de 4.19.325 attendue — vérification"
fi

git log --oneline -1

# ==================== 2. INTÉGRATION ReSukiSU ====================
echo ""
echo "=== Intégration ReSukiSU ==="
rm -rf drivers/kernelsu kernelSU susfs4ksu || true
curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash

# ==================== 3. HOOKS MANUELS ReSukiSU ====================
echo ""
echo "=== Hooks ReSukiSU (execveat, faccessat, stat, reboot, setresuid, sys_read, input) ==="

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

# --- stat / newfstat / fstat64 ---
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
else
  echo "OK: ksu_handle_setresuid déjà présent"
fi

# --- sys_read (CRITIQUE : lance ksud via hook init.rc) ---
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
        print("OK: sys_read (appel inconditionnel)")
with open('fs/read_write.c', 'w') as f:
    f.write(content)
PYEOF
  python3 /tmp/hook_sys_read.py
else
  echo "OK: ksu_handle_sys_read déjà présent"
fi

# --- input_event (CRITIQUE : safe mode volume bas) ---
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
        print("OK: input_event (appel inconditionnel)")
with open('drivers/input/input.c', 'w') as f:
    f.write(content)
PYEOF
  python3 /tmp/hook_input.py
else
  echo "OK: ksu_handle_input_handle_event déjà présent"
fi

# ==================== 3.4. FONCTION disable_seccomp() ====================
echo ""
echo "=== Ajout de disable_seccomp() dans ReSukiSU ==="

if ! grep -rq "disable_seccomp" drivers/kernelsu/ 2>/dev/null; then
    KSU_CORE_FILE=""
    if [ -f "drivers/kernelsu/core_hook.c" ]; then
        KSU_CORE_FILE="drivers/kernelsu/core_hook.c"
    elif [ -f "drivers/kernelsu/ksu.c" ]; then
        KSU_CORE_FILE="drivers/kernelsu/ksu.c"
    fi
    
    if [ -n "$KSU_CORE_FILE" ]; then
        cat >> "$KSU_CORE_FILE" << 'SECCOMP_EOF'

/* Fonction pour désactiver seccomp dynamiquement */
static void disable_seccomp(void)
{
	assert_spin_locked(&current->sighand->siglock);
#if defined(CONFIG_GENERIC_ENTRY) &&                                           \
	LINUX_VERSION_CODE >= KERNEL_VERSION(5, 11, 0)
	current_thread_info()->syscall_work &= ~SYSCALL_WORK_SECCOMP;
#else
	current_thread_info()->flags &= ~(TIF_SECCOMP | _TIF_SECCOMP);
#endif

#ifdef CONFIG_SECCOMP
	current->seccomp.mode = 0;
	current->seccomp.filter = NULL;
#endif
}
SECCOMP_EOF
        echo "✅ disable_seccomp() ajoutée dans $KSU_CORE_FILE"
    fi
else
    echo "✅ disable_seccomp() déjà présente"
fi

# ==================== 3.5. SUSFS 2.3.0 (cyberc3dr) ====================
echo ""
echo "=== Intégration SuSFS 2.3.0 depuis cyberc3dr ==="
cd "$GITHUB_WORKSPACE"
rm -rf /tmp/cyber_repo
git clone --depth=1 --branch rebase https://github.com/cyberc3dr/nGKI_Kernel_Build.git /tmp/cyber_repo

cd "$GITHUB_WORKSPACE/kernel_sources"

if [ -f "/tmp/cyber_repo/Patches/Patch/xxksu_fix_compat.patch" ]; then
    echo "=== Application du patch xxksu_fix_compat ==="
    patch -p1 --forward --batch < "/tmp/cyber_repo/Patches/Patch/xxksu_fix_compat.patch" || true
fi

SUSFS_PATCH="/tmp/cyber_repo/Patches/Patch/susfs_patch_to_4.19.patch"
echo "=== Application du patch SuSFS (avec tolérance 4.19.325) ==="
patch -p1 --forward --batch < "$SUSFS_PATCH" 2>&1 | tee /tmp/susfs_patch.log || true

# ==================== 3.5b. CORRECTION GÉNÉRIQUE DES .rej SUSFS ====================
echo ""
echo "=== Correction automatique des .rej SuSFS ==="

# --- task_mmu.c (SUS_MAP) ---
if [ -f "fs/proc/task_mmu.c.rej" ]; then
    echo "→ Correction fs/proc/task_mmu.c..."
    python3 - << 'PYEOF'
import re, os
fp = 'fs/proc/task_mmu.c'
if os.path.exists(fp):
    with open(fp, 'r') as f: c = f.read()
    if 'SUSFS_IS_INODE_SUS_MAP' not in c:
        c = c.replace("ret = walk_page_range(start_vaddr, end, &pagemap_walk);",
            "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\t\tvma = find_vma(mm, start_vaddr);\n\t\tif (vma && vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n\t\t\tgoto bypass_orig_flow;\n#endif\n\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);")
        c = re.sub(r'(ret = walk_page_range.*?)(up_read\(&mm->mmap_sem\);|mmap_read_unlock\(mm\);)',
            r'\1#ifdef CONFIG_KSU_SUSFS_SUS_MAP\nbypass_orig_flow:\n#endif\n\t\2', c, flags=re.DOTALL)
        with open(fp, 'w') as f: f.write(c)
PYEOF
    rm -f fs/proc/task_mmu.c.rej
fi

# --- namespace.c (SUS_MOUNT) ---
if [ -f "fs/namespace.c.rej" ]; then
    echo "→ Correction fs/namespace.c..."
    python3 - << 'PYEOF'
import re, os
fp = 'fs/namespace.c'
if os.path.exists(fp):
    with open(fp, 'r') as f: c = f.read()
    if 'susfs_alloc_non_unshare_ksu_vfsmnt' not in c:
        c = re.sub(r'(\tif \(!type\)\n\t\treturn ERR_PTR\(-ENODEV\);\n)(\n\tmnt = alloc_vfsmnt\(name\);)',
            r'''\1
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
\tif (static_branch_unlikely(&susfs_is_sdcard_android_data_not_decrypted)) {
\t\tif (susfs_is_current_ksu_domain()) {
\t\t\tmnt = susfs_alloc_non_unshare_ksu_vfsmnt(name ?:"none");
\t\t\tgoto bypass_orig_flow;
\t\t}
\t}
#endif
\2
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
bypass_orig_flow:
#endif''', c)
        with open(fp, 'w') as f: f.write(c)
PYEOF
    rm -f fs/namespace.c.rej
fi

# --- super.c (SUS_MOUNT) ---
if [ -f "fs/super.c.rej" ]; then
    echo "→ Correction fs/super.c..."
    python3 - << 'PYEOF'
import os
fp = 'fs/super.c'
if os.path.exists(fp):
    with open(fp, 'r') as f: c = f.read()
    if '#include <linux/susfs_def.h>' not in c:
        for anchor in ['#include <linux/user_namespace.h>', '#include <linux/fsnotify.h>', '#include <linux/lockdep.h>']:
            if anchor in c:
                c = c.replace(anchor, anchor + '\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif', 1)
                break
    if 'extern bool susfs_is_current_ksu_domain' not in c:
        for anchor in ['#include "internal.h"', '#include <linux/user_namespace.h>']:
            if anchor in c:
                c = c.replace(anchor, anchor + '''

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
#endif''', 1)
                break
    with open(fp, 'w') as f: f.write(c)
PYEOF
    rm -f fs/super.c.rej
fi

# --- Boucle générique pour tout autre .rej SUSFS ---
for rej in $(find . -name "*.rej" -type f 2>/dev/null); do
    if grep -q "CONFIG_KSU_SUSFS\|susfs_def\.h\|susfs_is_current\|susfs_" "$rej"; then
        target="${rej%.rej}"
        echo "→ Correction générique : $target"
        python3 - "$target" "$rej" << 'PYEOF'
import sys, os
target, rej_path = sys.argv[1], sys.argv[2]
if not os.path.exists(target):
    print(f"  WARN: {target} introuvable"); sys.exit(0)
with open(target, 'r') as f: c = f.read()
with open(rej_path, 'r') as f: r = f.read()
mod = False

# Include susfs_def.h
if 'susfs_def.h' in r and '#include <linux/susfs_def.h>' not in c:
    for anchor in ['#include <linux/user_namespace.h>', '#include <linux/fsnotify.h>',
                   '#include <linux/lockdep.h>', '#include <linux/namei.h>',
                   '#include <linux/fs.h>', '#include "internal.h"']:
        if anchor in c:
            c = c.replace(anchor, anchor + '\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif', 1)
            print(f"  OK: include après '{anchor}'"); mod = True; break
    else:
        print(f"  WARN: anchor include introuvable")

# Externs SUS_MOUNT
if 'susfs_is_current_ksu_domain' in r and 'extern bool susfs_is_current_ksu_domain' not in c:
    for anchor in ['#include "internal.h"', '#include <linux/user_namespace.h>', '#include <linux/fs.h>']:
        if anchor in c:
            c = c.replace(anchor, anchor + '''

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
#endif''', 1)
            print(f"  OK: extern après '{anchor}'"); mod = True; break
    else:
        print(f"  WARN: anchor extern introuvable")

if mod:
    with open(target, 'w') as f: f.write(c)
PYEOF
        rm -f "$rej"
    fi
done

# Vérification finale
if find . -name "*.rej" -type f | grep -q .; then
    echo ""
    echo "❌ ÉCHEC : Des .rej SuSFS persistent après correction automatique."
    find . -name "*.rej" -type f -exec echo "=== {} ===" \; -exec head -30 {} \;
    exit 1
fi
echo "✅ Tous les .rej SuSFS traités"

# Copie des fichiers SuSFS complets
if [ -d "/tmp/cyber_repo/Patches/fs" ]; then
    cp -rn /tmp/cyber_repo/Patches/fs/* fs/ 2>/dev/null || true
fi
if [ -d "/tmp/cyber_repo/Patches/include/linux" ]; then
    cp -rn /tmp/cyber_repo/Patches/include/linux/* include/linux/ 2>/dev/null || true
fi

# Makefile
if [ -f "fs/Makefile" ] && ! grep -q "susfs.o" fs/Makefile; then
    echo "obj-\$(CONFIG_KSU_SUSFS) += susfs.o" >> fs/Makefile
    [ -f "fs/sus_su.c" ] && ! grep -q "sus_su.o" fs/Makefile && echo "obj-\$(CONFIG_KSU_SUSFS) += sus_su.o" >> fs/Makefile
fi

# Nettoyage fs/susfs.c
if [ -f "fs/susfs.c" ]; then
    echo "🔧 Nettoyage fs/susfs.c..."
    sed -i '/^bool susfs_is_current_ksu_domain(void)/,/^}/d' fs/susfs.c || true
    sed -i '/^u32 susfs_ksu_sid = 0;/d' fs/susfs.c || true
    sed -i '/^u32 susfs_priv_app_sid = 0;/d' fs/susfs.c || true
    sed -i '/EXPORT_SYMBOL(susfs_is_current_ksu_domain);/d' fs/susfs.c || true
    sed -i '/EXPORT_SYMBOL(susfs_ksu_sid);/d' fs/susfs.c || true
    sed -i '/EXPORT_SYMBOL(susfs_priv_app_sid);/d' fs/susfs.c || true
    if ! grep -q "extern bool susfs_is_current_ksu_domain" fs/susfs.c; then
        sed -i '1i extern bool susfs_is_current_ksu_domain(void);\nextern u32 susfs_ksu_sid;\nextern u32 susfs_priv_app_sid;' fs/susfs.c || true
    fi
fi

# Include susfs_def.h dans fs/stat.c
if [ -f "fs/stat.c" ] && ! grep -q "susfs_def.h" fs/stat.c; then
    sed -i '1i #ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n#include <linux/susfs_def.h>\n#endif' fs/stat.c
fi

# Correctif vma unused task_mmu.c
if [ -f "fs/proc/task_mmu.c" ]; then
    sed -i 's/struct vm_area_struct \*vma;/struct vm_area_struct *vma __maybe_unused;/g' fs/proc/task_mmu.c
fi

# namespace.c cleanup
python3 - << 'PYEOF'
import re
with open('fs/namespace.c', 'r') as f: c = f.read()
c = re.sub(r'^\s*n(?=#ifdef|#endif|#include|#define|extern)', '', c, flags=re.MULTILINE)
if '#include <linux/susfs_def.h>' not in c:
    c = c.replace('#include <linux/sched/task.h>', '#include <linux/sched/task.h>\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif')
if 'extern bool susfs_is_current_ksu_domain' not in c:
    c = c.replace('#include "pnode.h"', '#include "pnode.h"\n\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n#define CL_COPY_MNT_NS BIT(25)\n#endif')
with open('fs/namespace.c', 'w') as f: f.write(c)
PYEOF

# Kconfig SUSFS
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
	bool "
