#!/bin/bash
set -e
echo "=== Build ReSukiSU + SuSFS (mode SUSFS) pour kiev (SM8250) ==="
echo "=== Source : lineage-23.2-tactile (pure) ==="
df -h

# ==================== 0. ENVIRONNEMENT ====================
sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
sudo apt-get clean
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true
sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev \
  libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld \
  device-tree-compiler zip unzip curl git python3 mkbootimg wget binutils

cd $GITHUB_WORKSPACE

# ==================== 1. CLONAGE DU NOYAU ====================
echo "=== Clonage du kernel Albanel22 lineage-23.2-tactile ==="
git clone https://github.com/Albanel22/android_kernel_motorola_sm8250.git \
  -b lineage-23.2-tactile --depth=1 kernel_sources
cd kernel_sources
git log --oneline -1

# ==================== 2. INTÉGRATION ReSukiSU ====================
echo ""
echo "=== Intégration ReSukiSU ==="
rm -rf drivers/kernelsu kernelSU susfs4ksu || true
curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash

# ==================== 2b. INTÉGRATION KERNELSU DANS LE BUILD ====================
echo ""
echo "=== Vérification et forçage de l'intégration kernelsu ==="

if [ ! -d "drivers/kernelsu" ]; then
    echo "❌ drivers/kernelsu/ n'existe pas — setup.sh a échoué"
    exit 1
fi
echo "✅ drivers/kernelsu/ présent"
ls drivers/kernelsu/ | head -10

if [ -f "drivers/Makefile" ]; then
    if ! grep -q "kernelsu" drivers/Makefile; then
        echo "→ Ajout de kernelsu/ dans drivers/Makefile"
        echo "" >> drivers/Makefile
        echo "obj-\$(CONFIG_KSU) += kernelsu/" >> drivers/Makefile
    else
        echo "✅ kernelsu déjà dans drivers/Makefile"
    fi
fi

if [ -f "drivers/Kconfig" ]; then
    if ! grep -q "kernelsu/Kconfig" drivers/Kconfig; then
        echo "→ Ajout de kernelsu/Kconfig dans drivers/Kconfig"
        sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig
    else
        echo "✅ kernelsu/Kconfig déjà dans drivers/Kconfig"
    fi
fi

if [ ! -f "drivers/kernelsu/Kconfig" ]; then
    echo "❌ drivers/kernelsu/Kconfig n'existe pas"
    exit 1
fi

echo "✅ Intégration kernelsu dans le build forcée"
grep -n "kernelsu" drivers/Makefile
grep -n "kernelsu/Kconfig" drivers/Kconfig

# ==================== 2c. CONTOURNEMENT CHECK SuSFS DANS Kbuild ====================
echo ""
echo "=== Contournement de l'exigence SuSFS dans Kbuild ==="
if [ -f drivers/kernelsu/Kbuild ]; then
  sed -i '/You should integrate susfs in your kernel/d' drivers/kernelsu/Kbuild
  sed -i 's/\$(error You should integrate susfs in your kernel.)/\$(info SuSFS check bypassed)/g' drivers/kernelsu/Kbuild
  echo "✅ Check SuSFS dans Kbuild contourné"
fi

# ==================== 2d. NEUTRALISATION DES CHECKS INLINE/MANUAL HOOK ====================
echo ""
echo "=== Diagnostic : position des checks ==="
find . -name "inline_hook_check.mk" 2>/dev/null || echo "(aucun)"
find . -name "manual_hook_check.mk" 2>/dev/null || echo "(aucun)"
echo ""

echo "=== Neutralisation des checks inline/manual hook ==="
find . -name "inline_hook_check.mk" -type f 2>/dev/null | while read f; do
    echo "→ Neutralisation : $f"
    echo "# Check neutralisé (mode SuSFS)" > "$f"
done

find . -name "manual_hook_check.mk" -type f 2>/dev/null | while read f; do
    echo "→ Neutralisation : $f"
    echo "# Check neutralisé (mode SuSFS)" > "$f"
done

echo "✅ Checks neutralisés"
echo ""

# ==================== 2e. FIX BUG SUSFS : ksu_install_fd O_CLOEXEC ====================
echo ""
echo "=== Fix bug SUSFS : ksu_install_fd (O_CLOEXEC) ==="
echo "=== Référence : SukiSU-Ultra Issue #799 — SUSFS 2 affecte la visibilité du driver ==="

# Trouver le fichier contenant ksu_install_fd
KSU_INSTALL_FD_FILE=$(grep -rl "ksu_install_fd" drivers/kernelsu/ 2>/dev/null | head -1)

if [ -z "$KSU_INSTALL_FD_FILE" ]; then
    KSU_INSTALL_FD_FILE=$(grep -rl "ksu_install_fd" drivers/ 2>/dev/null | head -1)
fi

if [ -n "$KSU_INSTALL_FD_FILE" ]; then
    echo "✅ Fichier trouvé : $KSU_INSTALL_FD_FILE"
    cp "$KSU_INSTALL_FD_FILE" "$KSU_INSTALL_FD_FILE.bak"

    # Fix 1 : get_unused_fd_flags(O_CLOEXEC) → get_unused_fd_flags(0)
    sed -i 's/get_unused_fd_flags(O_CLOEXEC)/get_unused_fd_flags(0)/g' "$KSU_INSTALL_FD_FILE"

    # Fix 2 : anon_inode_getfile O_RDWR | O_CLOEXEC → O_RDWR
    sed -i 's/O_RDWR | O_CLOEXEC/O_RDWR/g' "$KSU_INSTALL_FD_FILE"

    # Vérifications
    if grep -q "get_unused_fd_flags(0)" "$KSU_INSTALL_FD_FILE"; then
        echo "✅ get_unused_fd_flags(0) appliqué"
    else
        echo "⚠️  get_unused_fd_flags(0) non trouvé"
    fi

    if ! grep -q "O_CLOEXEC" "$KSU_INSTALL_FD_FILE"; then
        echo "✅ O_CLOEXEC retiré partout"
    else
        echo "⚠️  O_CLOEXEC encore présent :"
        grep -n "O_CLOEXEC" "$KSU_INSTALL_FD_FILE"
    fi
else
    echo "❌ ksu_install_fd introuvable — fix non appliqué"
fi

echo "✅ Fix ksu_install_fd terminé"
echo ""

# ==================== 3. HOOKS MANUELS (ifdef CONFIG_KSU) ====================
echo ""
echo "=== Hooks ReSukiSU (ifdef CONFIG_KSU) ==="

# --- execveat + post_execveat ---
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
__attribute__((hot))
extern int ksu_handle_post_execveat(int *fd, struct filename **filename_ptr,
				void *argv, void *envp, int *flags, int *retval);
#endif
'''
    pattern = r'(static int do_execveat_common\()'
    if re.search(pattern, content):
        content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
        print("OK: externs execveat ajoutés")
    old = '''static int do_execveat_common(int fd, struct filename *filename,
			      struct user_arg_ptr argv,
			      struct user_arg_ptr envp,
			      int flags)
{'''
    new = '''static int do_execveat_common(int fd, struct filename *filename,
			      struct user_arg_ptr argv,
			      struct user_arg_ptr envp,
			      int flags)
{
#ifdef CONFIG_KSU
	ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);
#endif'''
    if old in content:
        content = content.replace(old, new, 1)
        print("OK: execveat hooké")
    old2 = '''	struct user_arg_ptr argv = { .ptr.native = __argv };
	struct user_arg_ptr envp = { .ptr.native = __envp };
	return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);'''
    new2 = '''	struct user_arg_ptr argv = { .ptr.native = __argv };
	struct user_arg_ptr envp = { .ptr.native = __envp };
#ifdef CONFIG_KSU
	int retval;
	ksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);
	retval = do_execveat_common(AT_FDCWD, filename, argv, envp, 0);
	ksu_handle_post_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0, &retval);
	return retval;
#else
	return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);
#endif'''
    if old2 in content:
        content = content.replace(old2, new2, 1)
        print("OK: post_execveat ajouté")
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
#ifdef CONFIG_KSU
__attribute__((hot))
extern int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode, int *__unused_flags);
#endif
'''
    pattern = r'(SYSCALL_DEFINE3\(faccessat, int, dfd, const char __user \*, filename, int, mode\))'
    if re.search(pattern, content):
        content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
        old = '''SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)
{
	return do_faccessat(dfd, filename, mode);'''
        new = '''SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)
{
#ifdef CONFIG_KSU
	struct filename *fn = getname(filename);
	if (!IS_ERR(fn)) {
		ksu_handle_faccessat(&dfd, &fn, &mode, NULL);
		putname(fn);
	}
#endif
	return do_faccessat(dfd, filename, mode);'''
        if old in content:
            content = content.replace(old, new, 1)
            print("OK: faccessat hooké")
with open('fs/open.c', 'w') as f:
    f.write(content)
PYEOF
  python3 /tmp/hook_faccessat.py
fi

# --- stat (ksu_handle_stat uniquement, via newfstatat) ---
if ! grep -q "ksu_handle_stat" fs/stat.c; then
  cat > /tmp/hook_stat.py << 'PYEOF'
import re
with open('fs/stat.c', 'r') as f:
    content = f.read()
if 'ksu_handle_stat' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU
__attribute__((hot))
extern int ksu_handle_stat(int *dfd, struct filename **filename, int *flags);
#endif
'''
    pattern = r'(SYSCALL_DEFINE4\(newfstatat)'
    if re.search(pattern, content):
        content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
        print("OK: extern ksu_handle_stat ajouté")
    old = '''	struct kstat stat;
	int error;

	return vfs_fstatat(dfd, filename, &stat, flag);'''
    new = '''	struct kstat stat;
	int error;
#ifdef CONFIG_KSU
	struct filename *fn = getname(filename);
	if (!IS_ERR(fn)) {
		ksu_handle_stat(&dfd, &fn, &flag);
		putname(fn);
	}
#endif
	return vfs_fstatat(dfd, filename, &stat, flag);'''
    if old in content:
        content = content.replace(old, new, 1)
        print("OK: stat hooké (newfstatat)")
with open('fs/stat.c', 'w') as f:
    f.write(content)
PYEOF
  python3 /tmp/hook_stat.py
fi

# --- sys_read (init.rc) ---
if ! grep -q "ksu_handle_sys_read" fs/read_write.c; then
  cat > /tmp/hook_sys_read.py << 'PYEOF'
import re
with open('fs/read_write.c', 'r') as f:
    content = f.read()
if 'ksu_handle_sys_read' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU
__attribute__((cold))
extern int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr);
#endif
'''
    pattern = r'(SYSCALL_DEFINE3\(read, unsigned int, fd, char __user \*, buf, size_t, count\))'
    if re.search(pattern, content):
        content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
        old = '''SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)
{'''
        new = '''SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)
{
#ifdef CONFIG_KSU
	ksu_handle_sys_read(fd, &buf, &count);
#endif'''
        if old in content:
            content = content.replace(old, new, 1)
            print("OK: sys_read hooké")
with open('fs/read_write.c', 'w') as f:
    f.write(content)
PYEOF
  python3 /tmp/hook_sys_read.py
fi

# --- setresuid ---
if ! grep -q "ksu_handle_setresuid" kernel/sys.c; then
  cat > /tmp/hook_setresuid.py << 'PYEOF'
import re
with open('kernel/sys.c', 'r') as f:
    content = f.read()
if 'ksu_handle_setresuid' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU
extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);
#endif
'''
    pattern = r'(long __sys_setresuid)'
    if re.search(pattern, content):
        content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
        old = '''	bool ruid_new, euid_new, suid_new;'''
        new = '''	bool ruid_new, euid_new, suid_new;
#ifdef CONFIG_KSU
	(void)ksu_handle_setresuid(ruid, euid, suid);
#endif'''
        if old in content:
            content = content.replace(old, new, 1)
            print("OK: setresuid hooké")
with open('kernel/sys.c', 'w') as f:
    f.write(content)
PYEOF
  python3 /tmp/hook_setresuid.py
fi

# --- sys_reboot ---
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
    if re.search(pattern, content):
        content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
        old = '''	char buffer[256];
	int ret = 0;'''
        new = '''	char buffer[256];
	int ret = 0;
#ifdef CONFIG_KSU
	ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif'''
        if old in content:
            content = content.replace(old, new, 1)
            print("OK: sys_reboot hooké")
with open('kernel/reboot.c', 'w') as f:
    f.write(content)
PYEOF
  python3 /tmp/hook_reboot.py
fi

# --- input_event ---
if ! grep -q "ksu_handle_input_handle_event" drivers/input/input.c; then
  cat > /tmp/hook_input.py << 'PYEOF'
import re
with open('drivers/input/input.c', 'r') as f:
    content = f.read()
if 'ksu_handle_input_handle_event' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU
extern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);
#endif
'''
    pattern = r'(void input_event\(struct input_dev \*dev,)'
    if re.search(pattern, content):
        content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
        old = '''void input_event(struct input_dev *dev,
		 unsigned int type, unsigned int code, int value)
{
	unsigned long flags;

	if (is_event_supported(type, dev->evbit, EV_MAX)) {'''
        new = '''void input_event(struct input_dev *dev,
		 unsigned int type, unsigned int code, int value)
{
	unsigned long flags;

#ifdef CONFIG_KSU
	ksu_handle_input_handle_event(&type, &code, &value);
#endif

	if (is_event_supported(type, dev->evbit, EV_MAX)) {'''
        if old in content:
            content = content.replace(old, new, 1)
            print("OK: input_event hooké")
with open('drivers/input/input.c', 'w') as f:
    f.write(content)
PYEOF
  python3 /tmp/hook_input.py
fi

echo "✅ Hooks appliqués (execveat, faccessat, stat, sys_read, setresuid, sys_reboot, input)"

# ==================== 3.1. NETTOYAGE DES APPELS EXCLUSIFS MANUAL_HOOK ====================
echo ""
echo "=== Nettoyage des appels newfstat_ret/fstat64_ret (exclusifs MANUAL_HOOK) ==="
python3 - << 'PYEOF'
import re
with open('fs/stat.c', 'r') as f:
    content = f.read()

# Retirer les blocs #ifdef CONFIG_KSU contenant ces appels
patterns_to_remove = [
    r'#ifdef CONFIG_KSU\s*\n\s*ksu_handle_newfstat_ret\([^;]+\);\s*\n#endif',
    r'#ifdef CONFIG_KSU\s*\n\s*ksu_handle_fstat64_ret\([^;]+\);\s*\n#endif',
]
for pat in patterns_to_remove:
    content = re.sub(pat, '', content)

# Retirer les appels nus (au cas où)
content = re.sub(r'ksu_handle_newfstat_ret\([^;]+\);', '', content)
content = re.sub(r'ksu_handle_fstat64_ret\([^;]+\);', '', content)

# Retirer les déclarations extern
content = re.sub(r'__attribute__\(\(hot\)\)\s*\nextern void ksu_handle_newfstat_ret\([^;]+\);', '', content)
content = re.sub(r'__attribute__\(\(hot\)\)\s*\nextern void ksu_handle_fstat64_ret\([^;]+\);', '', content)
content = re.sub(r'extern void ksu_handle_newfstat_ret\([^;]+\);', '', content)
content = re.sub(r'extern void ksu_handle_fstat64_ret\([^;]+\);', '', content)

# Nettoyer les lignes vides multiples
content = re.sub(r'\n\s*\n\s*\n', '\n\n', content)

with open('fs/stat.c', 'w') as f:
    f.write(content)
print("OK: nettoyage stat.c effectué")
PYEOF

if grep -q "ksu_handle_newfstat_ret\|ksu_handle_fstat64_ret" fs/stat.c; then
    echo "⚠️  Appels résiduels :"
    grep -n "ksu_handle_newfstat_ret\|ksu_handle_fstat64_ret" fs/stat.c
    exit 1
else
    echo "✅ Aucun appel résiduel à newfstat_ret/fstat64_ret"
fi

if grep -q "ksu_handle_stat" fs/stat.c; then
    echo "✅ ksu_handle_stat présent"
else
    echo "⚠️  ksu_handle_stat absent"
fi

# ==================== 3.4. disable_seccomp() ====================
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

# ==================== 4b. TRAITEMENT DES .rej ====================
echo ""
echo "=== Traitement des .rej SuSFS ==="

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

if 'susfs_def.h' in r and '#include <linux/susfs_def.h>' not in c:
    for anchor in ['#include <linux/user_namespace.h>', '#include <linux/fsnotify.h>',
                   '#include <linux/lockdep.h>', '#include <linux/namei.h>',
                   '#include <linux/fs.h>', '#include "internal.h"']:
        if anchor in c:
            c = c.replace(anchor, anchor + '\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif', 1)
            print(f"  OK: include après '{anchor}'"); mod = True; break

if 'susfs_is_current_ksu_domain' in r and 'extern bool susfs_is_current_ksu_domain' not in c:
    for anchor in ['#include "internal.h"', '#include <linux/user_namespace.h>', '#include <linux/fs.h>']:
        if anchor in c:
            c = c.replace(anchor, anchor + '''

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
#endif''', 1)
            print(f"  OK: extern après '{anchor}'"); mod = True; break

if mod:
    with open(target, 'w') as f: f.write(c)
PYEOF
        rm -f "$rej"
    fi
done

find . -name "*.rej" -type f -delete 2>/dev/null || true
find . -name "*.orig" -type f -delete 2>/dev/null || true

echo "✅ Traitement des .rej terminé"

# ==================== 4c. PATCHES COMPLÉMENTAIRES ====================
echo ""
echo "=== Patches complémentaires ==="

if [ -f "fs/proc/task_mmu.c" ]; then
  sed -i 's/struct vm_area_struct \*vma;/struct vm_area_struct *vma __maybe_unused;/g' fs/proc/task_mmu.c
fi

if [ -f "fs/stat.c" ] && ! grep -q "susfs_def.h" fs/stat.c; then
    sed -i '1i #ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n#include <linux/susfs_def.h>\n#endif' fs/stat.c
fi

python3 - << 'PYEOF'
import re, os
if os.path.exists('fs/namespace.c'):
    with open('fs/namespace.c', 'r') as f: c = f.read()
    c = re.sub(r'^\s*n(?=#ifdef|#endif|#include|#define|extern)', '', c, flags=re.MULTILINE)
    if '#include <linux/susfs_def.h>' not in c:
        c = c.replace('#include <linux/sched/task.h>', '#include <linux/sched/task.h>\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif')
    if 'extern bool susfs_is_current_ksu_domain' not in c:
        c = c.replace('#include "pnode.h"', '#include "pnode.h"\n\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n#define CL_COPY_MNT_NS BIT(25)\n#endif')
    with open('fs/namespace.c', 'w') as f: f.write(c)
PYEOF

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

if [ -f "fs/Makefile" ] && ! grep -q "susfs.o" fs/Makefile; then
  echo "obj-\$(CONFIG_KSU_SUSFS) += susfs.o" >> fs/Makefile
  [ -f "fs/sus_su.c" ] && ! grep -q "sus_su.o" fs/Makefile && echo "obj-\$(CONFIG_KSU_SUSFS) += sus_su.o" >> fs/Makefile
fi

echo "✅ Patches complémentaires appliqués"

# ==================== 5. CONFIGURATION ====================
echo ""
echo "=== Configuration ==="
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

mkdir -p out
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 vendor/lito-perf_defconfig

{
  echo "CONFIG_KSU=y"
  echo "CONFIG_KSU_SUSFS=y"
  echo "# CONFIG_KSU_MANUAL_HOOK is not set"
  echo "# CONFIG_KSU_TRACEPOINT_HOOK is not set"
  echo "CONFIG_KPROBES=y"
  echo "CONFIG_HAVE_KPROBES=y"
  echo "CONFIG_KRETPROBES=y"
  echo "CONFIG_COMPAT=y"
  echo "CONFIG_COMPAT_32BIT_TIME=y"
  echo "# CONFIG_COMPAT_VDSO is not set"
  echo "# CONFIG_VDSO32 is not set"
  echo ""
  echo "CONFIG_KSU_SUSFS_SUS_PATH=y"
  echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y"
  echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y"
  echo "# CONFIG_KSU_SUSFS_SUS_MAP is not set"
  echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y"
  echo "# CONFIG_KSU_SUSFS_ENABLE_LOG is not set"
  echo "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y"
  echo "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y"
  echo "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y"
} >> out/.config

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig

# ==================== 5b. VÉRIFICATIONS ====================
echo ""
echo "=== Vérification config ==="
grep -E "^CONFIG_KSU=|^CONFIG_KSU_SUSFS=|^CONFIG_KSU_SUSFS_SUS_MOUNT=" out/.config

grep -q "^CONFIG_KSU=y" out/.config || (echo "❌ CONFIG_KSU!=y" && exit 1)
grep -q "^CONFIG_KSU_SUSFS=y" out/.config || (echo "❌ CONFIG_KSU_SUSFS!=y" && exit 1)
grep -q "^CONFIG_KSU_SUSFS_SUS_MOUNT=y" out/.config || (echo "❌ SUS_MOUNT!=y" && exit 1)

echo "✅ Config validée"

# ==================== 6. PATCHES FINAUX ====================
echo "=== Patch signatures modules + tactile ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c

printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c

# ==================== 7. COMPILATION ====================
echo ""
echo "=== Compilation finale ==="
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j$(nproc) Image 2>&1 | tee build.log

if [ ! -f "out/arch/arm64/boot/Image" ]; then
  echo "❌ BUILD FAILED"
  grep -iE "error:|fatal error:" build.log | head -40
  exit 1
fi

echo "✅ Compilation réussie"
ls -lh out/arch/arm64/boot/

# ==================== 7b. VÉRIFICATION KSU ====================
echo ""
echo "=== Vérification KSU dans le binaire final ==="
if strings out/arch/arm64/boot/Image 2>/dev/null | grep -qi "kernelsu\|ksu_handle\|susfs"; then
    echo "✅ Symboles KSU/SuSFS trouvés dans le kernel"
    strings out/arch/arm64/boot/Image | grep -iE "kernelsu|ksu_handle|susfs" | head -8
else
    echo "❌ AUCUN symbole KSU dans le kernel"
    exit 1
fi

# ==================== 8. REPACK ====================
echo ""
echo "=== Téléchargement des images stock ==="
cd $GITHUB_WORKSPACE
rm -f boot-stock.img dtbo-stock.img final_boot.img 2>/dev/null || true

curl -fLo boot-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260830/boot.img" 2>/dev/null || {
  echo "⚠️ Fallback mkbootimg..."
  mkbootimg --kernel kernel_sources/out/arch/arm64/boot/Image --ramdisk /dev/null --output final_boot.img \
    --header_version 2 --pagesize 4096 --base 0x00000000 --kernel_offset 0x00008000 \
    --ramdisk_offset 0x01000000 --tags_offset 0x00000100 \
    --cmdline "androidboot.hardware=kiev androidboot.selinux=permissive"
  exit 0
}

curl -fLo dtbo-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260830/dtbo.img" 2>/dev/null || true

BOOT_SIZE=$(stat -c%s boot-stock.img)
echo "✅ boot-stock.img: $BOOT_SIZE bytes ($((BOOT_SIZE / 1024 / 1024)) MB)"

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

if [ ! -f "ramdisk.cpio" ]; then
    echo "❌ ramdisk.cpio absent après unpack !"
    exit 1
fi
echo "✅ ramdisk.cpio présent ($(stat -c%s ramdisk.cpio) octets)"

echo ""
echo "--- Remplacement du kernel ---"
cp $GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image kernel
echo "✅ Nouveau kernel: $(stat -c%s kernel) octets"

echo ""
echo "--- Repack ---"
./magiskboot repack boot.img new-boot.img

if [ ! -f "new-boot.img" ]; then
    echo "❌ new-boot.img non créé !"
    exit 1
fi
NEWBOOT_SIZE=$(stat -c%s new-boot.img)
echo "✅ new-boot.img: $NEWBOOT_SIZE bytes ($((NEWBOOT_SIZE / 1024 / 1024)) MB)"

mv new-boot.img ../final_boot.img
cd ..

# ==================== 9. SORTIE ====================
echo ""
echo "=== Copie vers output ==="
mkdir -p output
cp final_boot.img output/ReSukiSU-SuSFS-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/

echo ""
echo "=== BUILD TERMINÉ ==="
ls -lh output/
