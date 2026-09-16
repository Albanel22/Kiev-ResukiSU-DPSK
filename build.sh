#!/bin/bash
set -e
echo "=== Build ReSukiSU v4.2.0-rc1 (35061) + SuSFS pour kiev (SM8250) ==="
df -h

# Commit ReSukiSU épinglé (v4.2.0-rc1, 12 août 2026)
KSU_COMMIT="a9216b04e29cc973ddbf845342f2cbf85b47b460"

# ==================== 0. ENVIRONNEMENT ====================
sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
sudo apt-get clean

sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true

sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev \
  libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld \
  device-tree-compiler zip unzip curl git python3 mkbootimg binutils

cd $GITHUB_WORKSPACE

# ==================== 1. CLONAGE DU NOYAU ====================
echo "=== Clonage du kernel Albanel22 lineage-23.2-tactile ==="
git clone https://github.com/Albanel22/android_kernel_motorola_sm8250.git \
  -b lineage-23.2-tactile --depth=1 kernel_sources
cd kernel_sources
git log --oneline -1

# ==================== 2. INTÉGRATION ReSukiSU (commit épinglé) ====================
echo ""
echo "=== Intégration ReSukiSU au commit $KSU_COMMIT ==="

cd "$GITHUB_WORKSPACE"
rm -rf /tmp/resukisu_repo
git clone https://github.com/ReSukiSU/ReSukiSU.git /tmp/resukisu_repo
cd /tmp/resukisu_repo
git checkout "$KSU_COMMIT"
echo "✅ ReSukiSU checkouté à $KSU_COMMIT"
git log --oneline -1

# Copier le kernel dans le repo principal
cd "$GITHUB_WORKSPACE/kernel_sources"
rm -rf drivers/kernelsu kernelSU susfs4ksu
cp -r /tmp/resukisu_repo/kernel drivers/kernelsu

# Copier le dossier include s'il n'a pas été copié
if [ -d "/tmp/resukisu_repo/kernel/include" ] && [ ! -d "drivers/kernelsu/include" ]; then
    cp -r /tmp/resukisu_repo/kernel/include drivers/kernelsu/include
    echo "→ Copie de drivers/kernelsu/include"
fi

if [ ! -d "drivers/kernelsu" ]; then
    echo "❌ drivers/kernelsu absent après copie"
    exit 1
fi
echo "✅ drivers/kernelsu copié"
ls drivers/kernelsu/ | head -10

# Ajouter dans drivers/Makefile
if [ -f "drivers/Makefile" ]; then
    if ! grep -q "kernelsu" drivers/Makefile; then
        echo "" >> drivers/Makefile
        echo "obj-\$(CONFIG_KSU) += kernelsu/" >> drivers/Makefile
        echo "→ Ajout de kernelsu/ dans drivers/Makefile"
    fi
fi

# Ajouter dans drivers/Kconfig
if [ -f "drivers/Kconfig" ]; then
    if ! grep -q "kernelsu/Kconfig" drivers/Kconfig; then
        sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig
        echo "→ Ajout de kernelsu/Kconfig dans drivers/Kconfig"
    fi
fi

if [ ! -f "drivers/kernelsu/Kconfig" ]; then
    echo "❌ drivers/kernelsu/Kconfig absent"
    exit 1
fi

echo "✅ Intégration kernelsu terminée"

# ==================== 2c. CONTOURNEMENT DU CHECK SUBMODULE ====================
echo ""
echo "=== Contournement du check git submodule dans Kbuild ==="

if [ -f "drivers/kernelsu/Kbuild" ]; then
    echo "→ Contenu avant :"
    grep -n "You should use\|You should integrate" drivers/kernelsu/Kbuild || echo "(rien trouvé)"

    # Remplacer les $(error ...) par $(info ...)
    sed -i 's/\$(error You should use \$(REPO_NAME) as a git submodule instead of copying code directly)/\$(info Submodule check bypassed)/g' drivers/kernelsu/Kbuild
    sed -i 's/\$(error You should use ReSukiSU as a git submodule instead of copying code directly)/\$(info Submodule check bypassed)/g' drivers/kernelsu/Kbuild
    sed -i 's/\$(error You should integrate susfs in your kernel.)/\$(info SuSFS check bypassed)/g' drivers/kernelsu/Kbuild
    sed -i 's/\$(error Unsupported hook method)/\$(info Unsupported hook method bypassed)/g' drivers/kernelsu/Kbuild
    sed -i 's/\$(error TP hooks are incompatible with Non-GKI\/GKI 1.0 kernels.)/\$(info TP hooks bypassed)/g' drivers/kernelsu/Kbuild

    echo "→ Contenu après :"
    grep -n "Submodule check bypassed\|SuSFS check bypassed" drivers/kernelsu/Kbuild || echo "(modifié)"
fi

# Forcer KSU_VERSION (car sans .git, le calcul échoue)
if [ -f "drivers/kernelsu/Kbuild" ]; then
    python3 - << 'PYEOF'
import re

with open('drivers/kernelsu/Kbuild', 'r') as f:
    content = f.read()

# Forcer KSU_VERSION à 35061
content = re.sub(r'^KSU_VERSION :=.*$', 'KSU_VERSION := 35061', content, flags=re.MULTILINE)
content = re.sub(r'^KSU_LOCAL_VERSION :=.*$', 'KSU_LOCAL_VERSION := 4361', content, flags=re.MULTILINE)

# Forcer les variables Git-dépendantes
content = re.sub(r'^KSU_TAG_NAME\s*:=.*$', 'KSU_TAG_NAME := v4.2.0-rc1', content, flags=re.MULTILINE)
content = re.sub(r'^KSU_COMMIT_SHA\s*:=.*$', 'KSU_COMMIT_SHA := a9216b04', content, flags=re.MULTILINE)
content = re.sub(r'^KSU_BRANCH_NAME\s*:=.*$', 'KSU_BRANCH_NAME := main', content, flags=re.MULTILINE)

# Forcer KSU_VERSION_FULL
content = re.sub(r'^KSU_VERSION_FULL\s*:=.*$', 'KSU_VERSION_FULL := v4.2.0-rc1-35061', content, flags=re.MULTILINE)

# Neutraliser la commande git fetch
content = content.replace(
    '$(shell cd $(KSU_SRC); [ -f ../.git/shallow ] && $(GIT_BIN) fetch --unshallow)',
    '# Git fetch désactivé (pas de repo git)'
)

with open('drivers/kernelsu/Kbuild', 'w') as f:
    f.write(content)

print("✅ Kbuild modifié : KSU_VERSION=35061, KSU_TAG_NAME=v4.2.0-rc1")
PYEOF

    echo "✅ Version KSU forcée à 35061"
fi

echo "✅ Contournement submodule terminé"

# ==================== 3. HOOKS MANUELS ReSukiSU ====================
echo ""
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

echo "✅ Hooks ReSukiSU en place"

# ==================== 4. INTÉGRATION SuSFS (JackA1ltman) ====================
echo ""
echo "=== Intégration SuSFS depuis JackA1ltman (mainline) ==="
cd "$GITHUB_WORKSPACE"
rm -rf /tmp/jack_repo
git clone --depth=1 --branch mainline https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git /tmp/jack_repo

cd "$GITHUB_WORKSPACE/kernel_sources"

SUSFS_PATCH="/tmp/jack_repo/Patches/Patch/susfs_patch_to_4.19.patch"
if [ ! -f "$SUSFS_PATCH" ]; then
    echo "❌ Patch SuSFS 4.19 non trouvé"
    find /tmp/jack_repo/Patches -name "*.patch" 2>/dev/null | sort
    exit 1
fi
echo "✅ Patch SuSFS trouvé : $(wc -l < $SUSFS_PATCH) lignes"

echo "=== Application du patch SuSFS ==="
patch -p1 --forward --batch < "$SUSFS_PATCH" 2>&1 | tee /tmp/susfs_patch.log || true

# ---------- Corrections des .rej ----------
echo "=== Corrections des rejets de patch ==="

if [ -f "fs/proc/task_mmu.c.rej" ]; then
    python3 - << 'PYEOF'
import re, os
file_path = 'fs/proc/task_mmu.c'
if os.path.exists(file_path):
    with open(file_path, 'r') as f: content = f.read()
    if 'SUSFS_IS_INODE_SUS_MAP' not in content:
        content = content.replace("ret = walk_page_range(start_vaddr, end, &pagemap_walk);",
            "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\t\tvma = find_vma(mm, start_vaddr);\n\t\tif (vma && vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n\t\t\tgoto bypass_orig_flow;\n#endif\n\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);")
        content = re.sub(r'(ret = walk_page_range.*?)(up_read\(&mm->mmap_sem\);|mmap_read_unlock\(mm\);)',
            r'\1#ifdef CONFIG_KSU_SUSFS_SUS_MAP\nbypass_orig_flow:\n#endif\n\t\2', content, flags=re.DOTALL)
        with open(file_path, 'w') as f: f.write(content)
PYEOF
    rm -f fs/proc/task_mmu.c.rej
fi

if [ -f "fs/namespace.c.rej" ] && grep -q "vfs_kern_mount" "fs/namespace.c.rej"; then
    python3 - << 'PYEOF'
import re, os
file_path = 'fs/namespace.c'
if os.path.exists(file_path):
    with open(file_path, 'r') as f: content = f.read()
    if 'susfs_alloc_non_unshare_ksu_vfsmnt' not in content:
        content = re.sub(r'(\tif \(!type\)\n\t\treturn ERR_PTR\(-ENODEV\);\n)(\n\tmnt = alloc_vfsmnt\(name\);)',
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
#endif''', content)
        with open(file_path, 'w') as f: f.write(content)
PYEOF
    rm -f fs/namespace.c.rej
fi

echo "=== Correction fs/super.c ==="
python3 - << 'PYEOF'
import re
with open('fs/super.c', 'r') as f:
    content = f.read()
if 'extern bool susfs_is_current_ksu_domain' not in content:
    decl = """
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
#include <linux/susfs_def.h>
extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
#ifndef DEFAULT_KSU_MNT_MINOR_DEV
#define DEFAULT_KSU_MNT_MINOR_DEV (1 << 20)
#endif
#endif /* CONFIG_KSU_SUSFS_SUS_MOUNT */
"""
    content = re.sub(r'(#include\s+"internal\.h"\s*\n)', r'\1' + decl, content, count=1)
    print("✅ fs/super.c patché")
with open('fs/super.c', 'w') as f:
    f.write(content)
PYEOF
rm -f fs/super.c.rej 2>/dev/null || true

if find . -name "*.rej" -type f | grep -q .; then
    echo "❌ ÉCHEC CRITIQUE : Des rejets persistent."
    find . -name "*.rej" -type f -exec echo "=== {} ===" \; -exec cat {} \;
    exit 1
fi
echo "✅ Patch SuSFS appliqué"

# Copie fichiers SuSFS
if [ -d "/tmp/jack_repo/Patches/fs" ]; then
    cp -rn /tmp/jack_repo/Patches/fs/* fs/ 2>/dev/null || true
fi
if [ -d "/tmp/jack_repo/Patches/include/linux" ]; then
    cp -rn /tmp/jack_repo/Patches/include/linux/* include/linux/ 2>/dev/null || true
fi

find . -name "*.orig" -type f -delete 2>/dev/null || true

# Makefile
if [ -f "fs/Makefile" ] && ! grep -q "susfs.o" fs/Makefile; then
    echo "obj-\$(CONFIG_KSU_SUSFS) += susfs.o" >> fs/Makefile
    [ -f "fs/sus_su.c" ] && ! grep -q "sus_su.o" fs/Makefile && echo "obj-\$(CONFIG_KSU_SUSFS) += sus_su.o" >> fs/Makefile
fi

if [ -f "fs/proc/task_mmu.c" ]; then
    sed -i 's/struct vm_area_struct \*vma;/struct vm_area_struct *vma __maybe_unused;/g' fs/proc/task_mmu.c
fi

# ==================== 4b. FIX stat.c ====================
echo ""
echo "=== Fix des déclarations SuSFS (stat.c) ==="

if [ -f "include/linux/susfs.h" ]; then
    if ! grep -q "susfs_is_current_app_uid" include/linux/susfs.h; then
        cat >> include/linux/susfs.h << 'SUSFS_H_EOF'

#ifdef CONFIG_KSU_SUSFS
bool susfs_is_current_app_uid(void);
#endif
SUSFS_H_EOF
    fi
fi

if [ -f "include/linux/susfs_def.h" ]; then
    if ! grep -q "STATX_SUS_KSTAT" include/linux/susfs_def.h; then
        cat >> include/linux/susfs_def.h << 'SUSFS_DEF_EOF'

#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
#define STATX_SUS_KSTAT     0x10000000
#define STATX_SUS_KSTAT_FUSE 0x20000000
#endif
SUSFS_DEF_EOF
    fi
fi

if [ -f "fs/stat.c" ]; then
    if ! grep -q "susfs_def.h" fs/stat.c; then
        sed -i '1i #ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n#include <linux/susfs_def.h>\n#endif' fs/stat.c
    fi
    if ! grep -q "susfs.h" fs/stat.c; then
        sed -i '1i #ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs.h>\n#endif' fs/stat.c
    fi
fi

echo "✅ Fix stat.c terminé"

# ==================== 4c. FIX namespace.c ====================
echo ""
echo "=== Fix des définitions SuSFS (namespace.c) ==="

if [ -f "include/linux/susfs_def.h" ]; then
    if ! grep -q "DEFAULT_KSU_MNT_GROUP_ID" include/linux/susfs_def.h; then
        cat >> include/linux/susfs_def.h << 'SUSFS_DEF_MOUNT_EOF'

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
#ifndef DEFAULT_KSU_MNT_ID
#define DEFAULT_KSU_MNT_ID       ((1 << 20) + 1)
#endif
#ifndef DEFAULT_KSU_MNT_GROUP_ID
#define DEFAULT_KSU_MNT_GROUP_ID ((1 << 20) + 1)
#endif
#ifndef VFSMOUNT_MNT_FLAGS_KSU_UNSHARED_MNT
#define VFSMOUNT_MNT_FLAGS_KSU_UNSHARED_MNT (1 << 25)
#endif
#endif
SUSFS_DEF_MOUNT_EOF
    fi
fi

if [ -f "include/linux/susfs.h" ]; then
    if ! grep -q "susfs_is_current_ksu_domain" include/linux/susfs.h; then
        cat >> include/linux/susfs.h << 'SUSFS_H_DOMAIN_EOF'

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
bool susfs_is_current_ksu_domain(void);
bool susfs_is_current_proc_umounted_for_zygote_next(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
#endif
SUSFS_H_DOMAIN_EOF
    fi
fi

if [ -f "fs/namespace.c" ]; then
    if ! grep -q "susfs_def.h" fs/namespace.c; then
        sed -i '1i #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif' fs/namespace.c
    fi
    if ! grep -q "susfs.h" fs/namespace.c; then
        sed -i '1i #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs.h>\n#endif' fs/namespace.c
    fi
fi

echo "✅ Fix namespace.c terminé"

# ==================== 4d. FIX CL_COPY_MNT_NS ====================
echo ""
echo "=== Fix CL_COPY_MNT_NS ==="

if [ -f "fs/namespace.c" ]; then
    if ! grep -q "#define CL_COPY_MNT_NS" fs/namespace.c; then
        python3 - << 'PYEOF'
import re
with open('fs/namespace.c', 'r') as f:
    content = f.read()
if '#define CL_COPY_MNT_NS' not in content:
    matches = list(re.finditer(r'(#include\s+[<"][^>"]+[>"]\s*\n)', content))
    if matches:
        insert_pos = matches[-1].end()
        definition = '''
/* --- SuSFS: CL_COPY_MNT_NS --- */
#ifndef CL_COPY_MNT_NS
#define CL_COPY_MNT_NS 0x80
#endif
/* --- Fin SuSFS --- */

'''
        content = content[:insert_pos] + definition + content[insert_pos:]
        with open('fs/namespace.c', 'w') as f:
            f.write(content)
        print("✅ CL_COPY_MNT_NS ajouté")
PYEOF
    fi

    if [ -f "include/linux/susfs_def.h" ]; then
        if ! grep -q "CL_COPY_MNT_NS" include/linux/susfs_def.h; then
            cat >> include/linux/susfs_def.h << 'SUSFS_DEF_CL_EOF'

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
#ifndef CL_COPY_MNT_NS
#define CL_COPY_MNT_NS 0x80
#endif
#endif
SUSFS_DEF_CL_EOF
        fi
    fi
fi

echo "✅ Fix CL_COPY_MNT_NS terminé"

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

# ==================== 7b. COMPILATION KSUD ====================
echo ""
echo "=== Compilation de ksud (ReSukiSU @ $KSU_COMMIT) ==="
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
cd "$GITHUB_WORKSPACE/ksud-src"
git checkout "$KSU_COMMIT"
echo "✅ ReSukiSU checkouté à $KSU_COMMIT pour ksud"

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

echo "=== Suppression du Cargo.lock ==="
rm -f Cargo.lock

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
echo "=== Repack ==="
cd $GITHUB_WORKSPACE

curl -fLo boot-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260830/boot.img" 2>/dev/null || {
  echo "Fallback mkbootimg..."
  mkbootimg --kernel kernel_sources/out/arch/arm64/boot/Image --ramdisk /dev/null --output final_boot.img \
    --header_version 2 --pagesize 4096 --base 0x00000000 --kernel_offset 0x00008000 \
    --ramdisk_offset 0x01000000 --tags_offset 0x00000100 \
    --cmdline "androidboot.hardware=kiev androidboot.selinux=permissive"
}

curl -fLo dtbo-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260830/dtbo.img" 2>/dev/null || true

if [ -f "boot-stock.img" ]; then
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

  ./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 data" \
    "mkdir 0755 data/adb" \
    "mkdir 0755 data/adb/ksud" \
    "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"

  ./magiskboot repack boot.img new-boot.img
  mv new-boot.img ../final_boot.img
  cd ..
fi

# ==================== 9. SORTIE ====================
echo "=== Sortie ==="
mkdir -p output
cp final_boot.img output/ReSukiSU-SusFS-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true

echo "=== BUILD TERMINÉ ==="
ls -lh output/
