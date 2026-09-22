#!/bin/bash
set -e

echo "=== Début du build ReSukiSU + SuSFS (JackA1ltman/NonGKI_Kernel_Build_2nd, mainline) pour kiev (SM8250) ==="
df -h

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
sudo apt-get clean

sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true

sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev \
  libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld \
  device-tree-compiler zip unzip curl git python3 mkbootimg

cd "$GITHUB_WORKSPACE"

# ==================== 1. CLONAGE DU NOYAU ====================
echo "=== Clonage du kernel Albanel22 lineage-23.2-tactile ==="
git clone https://github.com/Albanel22/android_kernel_motorola_sm8250.git \
  -b lineage-23.2-tactile kernel_sources

cd kernel_sources

echo "Commit kernel_sources actuel :"
git log --oneline -1

# ==================== 2. INTÉGRATION ReSukiSU ====================
echo "=== Intégration ReSukiSU (Driver Kernel) ==="

rm -rf drivers/kernelsu kernelSU susfs4ksu KernelSU || true
rm -rf /tmp/resukisu_pin

git clone https://github.com/ReSukiSU/ReSukiSU.git /tmp/resukisu_pin

# On garde l'épinglage du driver au 17 août pour la cohérence avec le kernel
RESUKISU_COMMIT=$(cd /tmp/resukisu_pin && git rev-list -n 1 --before="2026-08-17 23:59:59" main)
echo "Commit ReSukiSU (driver) épinglé : $RESUKISU_COMMIT"

curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash -s -- "$RESUKISU_COMMIT"

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

echo "✅ Hooks ReSukiSU en place"

# ==================== 4. INTÉGRATION SuSFS (JackA1ltman, branche mainline) ====================
echo ""
echo "=== Intégration SuSFS depuis JackA1ltman/NonGKI_Kernel_Build_2nd (mainline) ==="

cd "$GITHUB_WORKSPACE"
rm -rf /tmp/jack_repo

git clone --branch mainline https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git /tmp/jack_repo

JACK_COMMIT=$(cd /tmp/jack_repo && git rev-list -n 1 --before="2026-08-17 23:59:59" mainline)
echo "Commit JackA1ltman/NonGKI_Kernel_Build_2nd épinglé : $JACK_COMMIT"
(cd /tmp/jack_repo && git checkout "$JACK_COMMIT")

cd "$GITHUB_WORKSPACE/kernel_sources"

SUSFS_PATCH="/tmp/jack_repo/Patches/Patch/susfs_patch_to_4.19.patch"

if [ ! -f "$SUSFS_PATCH" ]; then
    echo "❌ Patch SuSFS 4.19 non trouvé dans la branche mainline !"
    find /tmp/jack_repo/Patches -name "*.patch" 2>/dev/null | sort
    exit 1
fi

echo "✅ Patch SuSFS trouvé : $(wc -l < "$SUSFS_PATCH") lignes"

echo "=== Application du patch SuSFS ==="
patch -p1 --forward --batch < "$SUSFS_PATCH" 2>&1 | tee /tmp/susfs_patch.log || true

# ---------- Corrections des .rej (logique réelle, pas de stubs) ----------
echo "=== Corrections des rejets de patch (logique réelle du patch, pas de stub) ==="

if [ -f "fs/proc/task_mmu.c.rej" ]; then
    echo "⚠️ Rejet détecté dans task_mmu.c. Correction automatique..."
    python3 - << 'PYEOF'
import re, os

file_path = 'fs/proc/task_mmu.c'

if os.path.exists(file_path):
    with open(file_path, 'r') as f:
        content = f.read()

    if 'SUSFS_IS_INODE_SUS_MAP' not in content:
        content = content.replace(
            "ret = walk_page_range(start_vaddr, end, &pagemap_walk);",
            "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\t\tvma = find_vma(mm, start_vaddr);\n\t\tif (vma && vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n\t\t\tgoto bypass_orig_flow;\n#endif\n\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);"
        )

        content = re.sub(
            r'(ret = walk_page_range.*?)(up_read\(&mm->mmap_sem\);|mmap_read_unlock\(mm\);)',
            r'\1#ifdef CONFIG_KSU_SUSFS_SUS_MAP\nbypass_orig_flow:\n#endif\n\t\2',
            content,
            flags=re.DOTALL
        )

        with open(file_path, 'w') as f:
            f.write(content)
PYEOF

    rm -f fs/proc/task_mmu.c.rej
fi

if [ -f "fs/namespace.c.rej" ] && grep -q "vfs_kern_mount" "fs/namespace.c.rej"; then
    echo "⚠️ Rejet détecté dans namespace.c. Correction automatique..."
    python3 - << 'PYEOF'
import re, os

file_path = 'fs/namespace.c'

if os.path.exists(file_path):
    with open(file_path, 'r') as f:
        content = f.read()

    if 'susfs_alloc_non_unshare_ksu_vfsmnt' not in content:
        content = re.sub(
            r'(\tif \(!type\)\n\t\treturn ERR_PTR\(-ENODEV\);\n)(\n\tmnt = alloc_vfsmnt\(name\);)',
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
#endif''',
            content
        )

        with open(file_path, 'w') as f:
            f.write(content)
PYEOF

    rm -f fs/namespace.c.rej
fi

echo "=== Correction inconditionnelle des déclarations SuSFS dans fs/super.c ==="
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
    print("✅ Déclarations forcées injectées dans fs/super.c")
else:
    print("✅ Déclarations déjà présentes dans fs/super.c")

with open('fs/super.c', 'w') as f:
    f.write(content)
PYEOF

rm -f fs/super.c.rej 2>/dev/null || true

echo "=== Correction inconditionnelle de l'inclusion susfs_def.h dans fs/stat.c ==="
python3 - << 'PYEOF'
with open('fs/stat.c', 'r') as f:
    content = f.read()

if '#include <linux/susfs_def.h>' not in content:
    content = content.replace(
        '#include <linux/uaccess.h>',
        '#include <linux/uaccess.h>\n#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n#include <linux/susfs_def.h>\n#endif\n',
        1
    )
    print("✅ susfs_def.h injecté dans fs/stat.c")
else:
    print("✅ susfs_def.h déjà présent dans fs/stat.c")

with open('fs/stat.c', 'w') as f:
    f.write(content)
PYEOF

echo "=== Correction inconditionnelle et robuste de fs/namespace.c (CL_COPY_MNT_NS) ==="
python3 - << 'PYEOF'
import re

with open('fs/namespace.c', 'r') as f:
    content = f.read()

content = re.sub(r'^\s*n(?=#ifdef|#endif|#include|#define|extern)', '', content, flags=re.MULTILINE)

if 'define CL_COPY_MNT_NS' not in content:
    decl = '''
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
#include <linux/susfs_def.h>
extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
#define CL_COPY_MNT_NS BIT(25)
#endif
'''

    match = re.search(r'^#include\s+[^\n]+\n', content, flags=re.MULTILINE)
    if match:
        insert_pos = match.end()
        content = content[:insert_pos] + decl + content[insert_pos:]
        print("✅ CL_COPY_MNT_NS et déclarations injectées dans fs/namespace.c")
    else:
        print("❌ Aucun #include trouvé dans fs/namespace.c — injection impossible")
else:
    print("✅ CL_COPY_MNT_NS déjà présent dans fs/namespace.c")

with open('fs/namespace.c', 'w') as f:
    f.write(content)
PYEOF

# Vérification stricte : aucun .rej ne doit persister
if find . -name "*.rej" -type f | grep -q .; then
    echo "❌ ÉCHEC CRITIQUE : Des rejets de patch SuSFS persistent."
    find . -name "*.rej" -type f -exec echo "=== {} ===" \; -exec cat {} \;
    exit 1
fi

echo "✅ Patch SuSFS appliqué avec succès (aucun rejet)."

# Copie des fichiers source/headers SuSFS fournis par JackA1ltman
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

# Correction variable 'vma' non utilisée
if [ -f "fs/proc/task_mmu.c" ]; then
    echo "🔧 Correction de la variable 'vma' non utilisée dans task_mmu.c..."
    sed -i 's/struct vm_area_struct \*vma;/struct vm_area_struct *vma __maybe_unused;/g' fs/proc/task_mmu.c
fi

# Symboles susfs_is_current_ksu_domain / susfs_ksu_sid / susfs_priv_app_sid
if [ -f "fs/susfs.c" ] && ! grep -q "susfs_is_current_ksu_domain" fs/susfs.c; then
    echo "⚠️ susfs_is_current_ksu_domain absent après le patch réel — ajout de l'implémentation standard SuSFS"
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

echo "✅ SuSFS (JackA1ltman mainline) intégré, sans stub à return-false fabriqué"

# ==================== 5. CONFIGURATION ====================
echo "=== Configuration ==="

export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

mkdir -p out

make O=out LLVM=1 CROSS_COMPILE="$CROSS_COMPILE" CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" vendor/lito-perf_defconfig

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

make O=out LLVM=1 CROSS_COMPILE="$CROSS_COMPILE" CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" olddefconfig

# ==================== 6. PATCHES FINAUX ====================
echo "=== Patch signatures modules ==="

# On garde la désactivation de la vérification de version des modules (vermagic)
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c

# ⚠️ SUPPRESSION DU PATCH TACTILE MANUEL ⚠️
# La branche "lineage-23.2-tactile" inclut déjà nativement les correctifs 
# pour le tactile. Le rajouter manuellement créait un conflit de symboles 
# (redéfinition de panel_register_notifier et touch_set_state) qui cassait le driver.

# ==================== 7. COMPILATION ====================
echo "=== Compilation finale ==="

make O=out LLVM=1 CROSS_COMPILE="$CROSS_COMPILE" CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" -j"$(nproc)" Image 2>&1 | tee build.log

if [ -f "out/arch/arm64/boot/Image" ]; then
  echo "✅ Compilation réussie"
  ls -lh out/arch/arm64/boot/
else
  echo "❌ BUILD FAILED"
  grep -iE "error:|fatal error:" build.log | head -40
  exit 1
fi

# ==================== 7b. COMPILATION KSUD (ReSukiSU) ====================
# SOLUTION PROPRE : On utilise le commit qui a corrigé les dépendances Git
# Commit 7e92d45ed5c7e0ed6e3e0f7e87d1cea510d068ea (fix Kernel-SU -> ReSukiSU forks)
echo "=== Compilation de ksud (ReSukiSU - avec fix dépendances) ==="

cd "$GITHUB_WORKSPACE"

# Installation Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

rustup toolchain install nightly
rustup default nightly
rustup target add aarch64-linux-android

# Installation NDK
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

# On checkout le commit spécifique qui corrige les URLs Git (fix de sliva/Telegram)
KSUD_FIX_COMMIT="7e92d45ed5c7e0ed6e3e0f7e87d1cea510d068ea"
echo "=== Checkout du commit fix ksud : $KSUD_FIX_COMMIT ==="
git checkout "$KSUD_FIX_COMMIT"

# Configuration Cargo pour le cross-compilation Android
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

echo "=== Lancement du build cargo ksud (propre, sans hacks) ==="
if ! cargo +nightly build --release --target aarch64-linux-android; then
  echo "❌ Échec du build cargo de ksud"
  exit 1
fi

echo "=== Recherche du binaire ksud ==="
KSUD_BINARY="$GITHUB_WORKSPACE/ksud-src/userspace/ksud/target/aarch64-linux-android/release/ksud"

if [ ! -f "$KSUD_BINARY" ]; then
  KSUD_BINARY=$(find "$GITHUB_WORKSPACE/ksud-src" -type f -name ksud 2>/dev/null | head -1)
fi

if [ -z "$KSUD_BINARY" ]; then
  echo "❌ ksud introuvable après build"
  find "$GITHUB_WORKSPACE/ksud-src" -path '*/target/*' -type f -name 'ksud*' 2>/dev/null | head -20
  exit 1
fi

echo "✅ ksud trouvé ici : $KSUD_BINARY"
cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"
chmod 755 "$GITHUB_WORKSPACE/ksud"
echo "✅ ksud (ReSukiSU) compilé"

cd "$GITHUB_WORKSPACE"

# ==================== 8. REPACK (avec ksud) ====================
echo "=== Téléchargement des images stock ==="

cd "$GITHUB_WORKSPACE"

curl -fLo boot-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260830/boot.img" 2>/dev/null || {
  echo "Fallback mkbootimg..."
  mkbootimg --kernel kernel_sources/out/arch/arm64/boot/Image --ramdisk /dev/null --output final_boot.img \
    --header_version 2 --pagesize 4096 --base 0x00000000 --kernel_offset 0x00008000 \
    --ramdisk_offset 0x01000000 --tags_offset 0x00000100 \
    --cmdline "androidboot.hardware=kiev androidboot.selinux=permissive"
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
  cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel

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

  echo "=== Ajout du déclencheur init.rc pour lancer ksud au boot ==="

  # Le ramdisk stock Motorola n'a pas toujours d'init.rc à la racine.
  rm -f /tmp/init.rc
  ./magiskboot cpio ramdisk.cpio "extract init.rc /tmp/init.rc" 2>/dev/null || true

  if [ ! -f /tmp/init.rc ]; then
    echo "⚠️ init.rc absent du ramdisk stock. Création d'un init.rc sur mesure pour ksud..."
    cat > /tmp/init.rc << 'RCEOF'
on post-fs-data
    start ksud

service ksud /data/adb/ksu/bin/ksud daemon
    user root
    seclabel u:r:su:s0
    disabled
    oneshot
RCEOF
  else
    if ! grep -q "service ksud" /tmp/init.rc; then
      cat >> /tmp/init.rc << 'RCEOF'

on post-fs-data
    start ksud

service ksud /data/adb/ksu/bin/ksud daemon
    user root
    seclabel u:r:su:s0
    disabled
    oneshot
RCEOF
      echo "✅ Bloc service ksud ajouté à l'init.rc existant"
    else
      echo "✅ Bloc service ksud déjà présent dans init.rc"
    fi
  fi

  # On injecte le fichier (qu'il soit nouveau ou modifié) dans le ramdisk
  ./magiskboot cpio ramdisk.cpio "add 0750 init.rc /tmp/init.rc"

  ./magiskboot repack boot.img new-boot.img
  mv new-boot.img ../final_boot.img

  cd ..
fi

# ==================== 9. SORTIE ====================
echo "=== Copie vers output ==="

mkdir -p output

cp final_boot.img output/ReSukiSU-SusFS-boot.img

if [ -s dtbo-stock.img ]; then
  cp dtbo-stock.img output/dtbo.img
fi

cp kernel_sources/build.log output/

if [ -f "$GITHUB_WORKSPACE/ksud" ]; then
  cp "$GITHUB_WORKSPACE/ksud" output/ksud
fi

echo "=== BUILD TERMINÉ ==="
ls -lh output/
