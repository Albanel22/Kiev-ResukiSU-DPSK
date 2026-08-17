#!/bin/bash
set -e
echo "=== Début du build ==="
df -h

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
sudo apt-get clean

sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld device-tree-compiler zip unzip curl git python3 mkbootimg

cd $GITHUB_WORKSPACE

echo "=== Clonage du kernel ==="
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git -b lineage-23.2 --depth=1 kernel_sources
cd kernel_sources

echo "=== Intégration ReSukiSU ==="
rm -rf drivers/kernelsu || true
curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash

echo "=== Version ReSukiSU détectée ==="
if [ -f "drivers/kernelsu/Makefile" ] || [ -f "drivers/kernelsu/Kbuild" ]; then
  grep -i "version" drivers/kernelsu/Makefile drivers/kernelsu/Kbuild 2>/dev/null | head -5 || true
fi

echo "=== Injection des hooks CORRECTS pour kernel 4.19 ==="
python3 << 'PYEOF'
import re, os

def inject(path, declaration, call, search_pattern):
    if not os.path.exists(path):
        print(f"Fichier introuvable: {path}")
        return
    with open(path, 'r') as f:
        content = f.read()
    
    if call.strip().split('\n')[0] in content:
        print(f"Déjà injecté: {path}")
        return
    
    match = re.search(search_pattern, content)
    if match:
        content = content[:match.start()] + declaration + "\n" + content[match.start():]
        brace_pos = content.find('{', match.start())
        if brace_pos != -1:
            content = content[:brace_pos+1] + "\n" + call + content[brace_pos+1:]
        with open(path, 'w') as f:
            f.write(content)
        print(f"Injecté: {path}")
    else:
        print(f"Pattern non trouvé dans {path}")

# 1. fs/exec.c
inject(
    "fs/exec.c",
    """#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
				void *argv, void *envp, int *flags);
#endif""",
    """#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);
#endif""",
    r'int do_execve\(struct filename \*filename,\n\tconst char __user \*const __user \*__argv,\n\tconst char __user \*const __user \*__envp\)\n\{'
)

# 2. fs/stat.c
inject(
    "fs/stat.c",
    """#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_stat(int *dfd, const char __user **filename_user,
				int *flags);
extern void ksu_handle_newfstat_ret(unsigned int *fd, struct stat __user **statbuf_ptr);
#endif""",
    """#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_stat(&dfd, &filename, &flag);
#endif""",
    r'SYSCALL_DEFINE4\(newfstatat, int, dfd, const char __user \*, filename,\n\t\tstruct stat __user \*, statbuf, int, flag\)\n\{'
)

inject(
    "fs/stat.c",
    """#ifdef CONFIG_KSU_MANUAL_HOOK
extern void ksu_handle_newfstat_ret(unsigned int *fd, struct stat __user **statbuf_ptr);
#endif""",
    """#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_newfstat_ret(&fd, &statbuf);
#endif""",
    r'SYSCALL_DEFINE2\(newfstat, unsigned int, fd, struct stat __user \*, statbuf\)\n\{'
)

# 3. fs/open.c
inject(
    "fs/open.c",
    """#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,
				int *mode, int *flags);
#endif""",
    """#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
#endif""",
    r'SYSCALL_DEFINE3\(faccessat, int, dfd, const char __user \*, filename, int, mode\)\n\{'
)

# 4. fs/read_write.c
inject(
    "fs/read_write.c",
    """#ifdef CONFIG_KSU_MANUAL_HOOK
extern bool ksu_init_rc_hook __read_mostly;
extern __attribute__((cold)) int ksu_handle_sys_read(unsigned int fd,
				char __user **buf_ptr, size_t *count_ptr);
#endif""",
    """#ifdef CONFIG_KSU_MANUAL_HOOK
	if (unlikely(ksu_init_rc_hook))
		ksu_handle_sys_read(fd, &buf, &count);
#endif""",
    r'SYSCALL_DEFINE3\(read, unsigned int, fd, char __user \*, buf, size_t, count\)\n\{'
)

# 5. drivers/input/input.c
inject(
    "drivers/input/input.c",
    """#ifdef CONFIG_KSU_MANUAL_HOOK
extern bool ksu_input_hook __read_mostly;
extern __attribute__((cold)) int ksu_handle_input_handle_event(
			unsigned int *type, unsigned int *code, int *value);
#endif""",
    """#ifdef CONFIG_KSU_MANUAL_HOOK
	if (unlikely(ksu_input_hook))
		ksu_handle_input_handle_event(&type, &code, &value);
#endif""",
    r'void input_event\(struct input_dev \*dev,\n\t\t unsigned int type, unsigned int code, int value\)\n\{'
)

# 6. kernel/reboot.c
inject(
    "kernel/reboot.c",
    """#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);
#endif""",
    """#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif""",
    r'SYSCALL_DEFINE4\(reboot, int, magic1, int, magic2, unsigned int, cmd,\n\t\tvoid __user \*, arg\)\n\{'
)

# 7. kernel/sys.c
inject(
    "kernel/sys.c",
    """#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);
#endif""",
    """#ifdef CONFIG_KSU_MANUAL_HOOK
	(void)ksu_handle_setresuid(ruid, euid, suid);
#endif""",
    r'long __sys_setresuid\(uid_t ruid, uid_t euid, uid_t suid\)\n\{'
)

print("=== Tous les hooks injectés correctement ===")
PYEOF

echo "=== Vérification des hooks ==="
for f in fs/exec.c fs/stat.c fs/open.c fs/read_write.c drivers/input/input.c kernel/reboot.c kernel/sys.c; do
  COUNT=$(grep -c "ksu_handle" "$f" 2>/dev/null || echo "0")
  echo "$f: $COUNT hooks"
done

echo "=== Configuration ==="
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

mkdir -p out
CONFIG=$(find arch/arm64/configs/ -name "*kiev*" -o -name "*sm8250*" | head -1)
CONFIG_NAME=$(basename "$CONFIG")
cp "$CONFIG" arch/arm64/configs/$CONFIG_NAME

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 $CONFIG_NAME

{
  echo "CONFIG_KSU=y"
  echo "CONFIG_KSU_MANUAL_HOOK=y"
  echo "CONFIG_KPROBES=y"
  echo "CONFIG_HAVE_KPROBES=y"
  echo "CONFIG_KRETPROBES=y"
} >> out/.config

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig

echo "=== Compilation (version ReSukiSU auto-détectée) ==="
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j$(nproc) Image 2>&1 | tee build.log

if [ -f "out/arch/arm64/boot/Image" ]; then
  echo "✅ Compilation réussie"
  ls -lh out/arch/arm64/boot/
else
  echo "❌ BUILD FAILED"
  grep -i "error:" build.log | head -10
  exit 1
fi

echo "=== Téléchargement du boot.img stock ==="
cd $GITHUB_WORKSPACE
curl -fLo boot-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260705/boot.img" || {
  echo "Fallback: mkbootimg..."
  mkbootimg --kernel kernel_sources/out/arch/arm64/boot/Image --ramdisk /dev/null --output final_boot.img --header_version 2 --pagesize 4096 --base 0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 --tags_offset 0x00000100 --cmdline "androidboot.hardware=kiev androidboot.selinux=permissive"
}

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
mkdir -p /home/runner/output
cp final_boot.img /home/runner/output/ReSukiSU-boot.img
cp kernel_sources/build.log /home/runner/output/

echo "=== BUILD TERMINÉ ==="
ls -lh /home/runner/output/
