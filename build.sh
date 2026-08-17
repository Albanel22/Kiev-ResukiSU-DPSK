#!/bin/bash
set -e
echo "=== Début du build ==="
df -h

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
sudo apt-get clean

sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache curl flex git gnupg gperf imagemagick lib32ncurses5-dev lib32readline-dev lib32z1-dev liblz4-tool libncurses5 libncurses5-dev libsdl1.2-dev libssl-dev libxml2 libxml2-utils lzop pngcrush rsync schedtool squashfs-tools xsltproc zip zlib1g-dev python3 python3-pip libelf-dev dwarves cpio automake autoconf gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi mkbootimg

mkdir -p /home/runner/gcc-64/bin /home/runner/gcc-32/bin
for tool in gcc ar nm objcopy objdump strip ld ld.bfd; do
  if [ -f "/usr/bin/aarch64-linux-gnu-$tool" ]; then
    ln -sf /usr/bin/aarch64-linux-gnu-$tool /home/runner/gcc-64/bin/aarch64-linux-android-$tool
  fi
  if [ -f "/usr/bin/arm-linux-gnueabi-$tool" ]; then
    ln -sf /usr/bin/arm-linux-gnueabi-$tool /home/runner/gcc-32/bin/arm-linux-androideabi-$tool
  fi
done

cd $GITHUB_WORKSPACE

echo "=== Clonage du kernel ==="
git clone --depth=1 --branch lineage-23.2 https://github.com/LineageOS/android_kernel_motorola_sm8250.git kernel_sources
cd kernel_sources

echo "=== Intégration de ReSukiSU ==="
curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash

if grep -q "ksu_handle_execveat" fs/exec.c && grep -q "ksu_input_hook" drivers/input/input.c; then
  echo "OK: Hooks déjà appliqués"
else
  echo "=== Application des hooks manuels ==="
  
  if ! grep -q "ksu_handle_execveat" fs/exec.c; then
    cat > /tmp/hook_exec.py << 'PYEOF'
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
    pattern = r'(static int do_execveat_common\(.*?\n\}\n)'
    replacement = r'\1' + extern_decl
    content = re.sub(pattern, replacement, content, count=1)
if 'ksu_handle_execveat((int *)AT_FDCWD' not in content:
    pattern = r'(int do_execve\(struct filename \*filename,.*?\{.*?struct user_arg_ptr envp = \{ \.ptr\.native = __envp \};\n)'
    replacement = r'\1#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);\n#endif\n'
    content = re.sub(pattern, replacement, content, count=1)
with open('fs/exec.c', 'w') as f:
    f.write(content)
print("OK: fs/exec.c")
PYEOF
    python3 /tmp/hook_exec.py
  fi

  if ! grep -q "ksu_handle_stat" fs/stat.c; then
    cat > /tmp/hook_stat.py << 'PYEOF'
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
#endif
'''
    pattern = r'(SYSCALL_DEFINE4\(newfstatat)'
    replacement = extern_decl + r'\n\1'
    content = re.sub(pattern, replacement, content, count=1)
if 'ksu_handle_stat(&dfd' not in content:
    pattern = r'(SYSCALL_DEFINE4\(newfstatat.*?struct kstat stat;\n\tint error;\n)'
    replacement = r'\1#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_stat(&dfd, &filename, &flag);\n#endif\n'
    content = re.sub(pattern, replacement, content, count=1)
if 'ksu_handle_newfstat_ret' not in content:
    pattern = r'(SYSCALL_DEFINE2\(newfstat.*?return error;\n)'
    replacement = r'\1#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_newfstat_ret(&fd, &statbuf);\n#endif\n'
    content = re.sub(pattern, replacement, content, count=1)
with open('fs/stat.c', 'w') as f:
    f.write(content)
print("OK: fs/stat.c")
PYEOF
    python3 /tmp/hook_stat.py
  fi

  if ! grep -q "ksu_handle_faccessat" fs/open.c; then
    cat > /tmp/hook_open.py << 'PYEOF'
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
    replacement = extern_decl + r'\n\1'
    content = re.sub(pattern, replacement, content, count=1)
    pattern = r'(SYSCALL_DEFINE3\(faccessat.*?\{)'
    replacement = r'\1\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n#endif\n'
    content = re.sub(pattern, replacement, content, count=1)
with open('fs/open.c', 'w') as f:
    f.write(content)
print("OK: fs/open.c")
PYEOF
    python3 /tmp/hook_open.py
  fi

  if [ -f "kernel/reboot.c" ] && ! grep -q "ksu_handle_sys_reboot" kernel/reboot.c; then
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
    replacement = extern_decl + r'\n\1'
    content = re.sub(pattern, replacement, content, count=1)
    pattern = r'(SYSCALL_DEFINE4\(reboot.*?int ret = 0;\n)'
    replacement = r'\1#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif\n'
    content = re.sub(pattern, replacement, content, count=1)
with open('kernel/reboot.c', 'w') as f:
    f.write(content)
print("OK: kernel/reboot.c")
PYEOF
    python3 /tmp/hook_reboot.py
  fi

  if ! grep -q "ksu_handle_sys_read" fs/read_write.c; then
    cat > /tmp/hook_read.py << 'PYEOF'
import re
with open('fs/read_write.c', 'r') as f:
    content = f.read()
if 'ksu_handle_sys_read' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
extern bool ksu_init_rc_hook __read_mostly;
extern __attribute__((cold)) int ksu_handle_sys_read(unsigned int fd,
				char __user **buf_ptr, size_t *count_ptr);
#endif
'''
    pattern = r'(SYSCALL_DEFINE3\(read)'
    replacement = extern_decl + r'\n\1'
    content = re.sub(pattern, replacement, content, count=1)
    pattern = r'(SYSCALL_DEFINE3\(read.*?\{)'
    replacement = r'\1\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tif (unlikely(ksu_init_rc_hook))\n\t\tksu_handle_sys_read(fd, &buf, &count);\n#endif\n'
    content = re.sub(pattern, replacement, content, count=1)
with open('fs/read_write.c', 'w') as f:
    f.write(content)
print("OK: fs/read_write.c")
PYEOF
    python3 /tmp/hook_read.py
  fi

  if ! grep -q "ksu_input_hook" drivers/input/input.c; then
    cat > /tmp/hook_input.py << 'PYEOF'
import re
with open('drivers/input/input.c', 'r') as f:
    content = f.read()
if 'ksu_input_hook' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
extern bool ksu_input_hook __read_mostly;
extern __attribute__((cold)) int ksu_handle_input_handle_event(
			unsigned int *type, unsigned int *code, int *value);
#endif
'''
    pattern = r'(void input_event\(struct input_dev \*dev,)'
    replacement = extern_decl + r'\n\1'
    content = re.sub(pattern, replacement, content, count=1)
    pattern = r'(void input_event\(struct input_dev \*dev,.*?\n\{)'
    replacement = r'\1\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tif (unlikely(ksu_input_hook))\n\t\tksu_handle_input_handle_event(&type, &code, &value);\n#endif\n'
    content = re.sub(pattern, replacement, content, count=1)
with open('drivers/input/input.c', 'w') as f:
    f.write(content)
print("OK: drivers/input/input.c")
PYEOF
    python3 /tmp/hook_input.py
  fi

  if ! grep -q "ksu_handle_setresuid" kernel/sys.c; then
    cat > /tmp/hook_setuid.py << 'PYEOF'
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
    replacement = extern_decl + r'\n\1'
    content = re.sub(pattern, replacement, content, count=1)
    pattern = r'(long __sys_setresuid.*?\n\{)'
    replacement = r'\1\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\t(void)ksu_handle_setresuid(ruid, euid, suid);\n#endif\n'
    content = re.sub(pattern, replacement, content, count=1)
with open('kernel/sys.c', 'w') as f:
    f.write(content)
print("OK: kernel/sys.c")
PYEOF
    python3 /tmp/hook_setuid.py
  fi

  echo "=== Hooks terminés ==="
fi

echo "=== Configuration ==="
make mrproper 2>/dev/null || true
rm -rf out

CONFIG=$(find arch/arm64/configs/ -name "*kiev*" -o -name "*sm8250*" | head -1)
cp "$CONFIG" .config
echo "Config: $CONFIG"

./scripts/config --enable KSU
./scripts/config --enable KSU_MANUAL_HOOK
./scripts/config --enable KPROBES
./scripts/config --enable HAVE_KPROBES
./scripts/config --enable KPROBE_EVENTS
./scripts/config --enable COMPAT
./scripts/config --enable COMPAT_32BIT_TIME

make ARCH=arm64 olddefconfig

echo "=== Compilation avec GCC ==="
export ARCH=arm64
export SUBARCH=arm64
export PATH="/home/runner/gcc-64/bin:/home/runner/gcc-32/bin:$PATH"
export CROSS_COMPILE=aarch64-linux-android-
export CROSS_COMPILE_ARM32=arm-linux-androideabi-

make -j$(nproc) ARCH=arm64 2>&1 | tee build.log

if [ -f "arch/arm64/boot/Image" ] || [ -f "arch/arm64/boot/Image.gz" ]; then
  echo "Compilation réussie"
  ls -lh arch/arm64/boot/
else
  echo "BUILD FAILED"
  grep -i "error:" build.log | tail -30
  exit 1
fi

echo "=== Création du boot.img ==="
mkdir -p /home/runner/output
KERNEL_IMAGE="arch/arm64/boot/Image.gz"
[ -f "$KERNEL_IMAGE" ] || KERNEL_IMAGE="arch/arm64/boot/Image"

mkbootimg --kernel "$KERNEL_IMAGE" --ramdisk /dev/null --output /home/runner/output/ReSukiSU-boot.img --header_version 2 --pagesize 4096 --base 0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 --tags_offset 0x00000100 --cmdline "androidboot.hardware=kiev androidboot.selinux=permissive"

echo "boot.img créé"

echo "=== Création du package ==="
cd /home/runner
git clone --depth=1 https://github.com/osm0sis/AnyKernel3.git
cd AnyKernel3
rm -f Image* *.zip
cp ../kernel_sources/$KERNEL_IMAGE .

cat > anykernel.sh << 'EOF'
properties() { '
kernel.string=ReSukiSU Kernel for kiev
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=kiev
device.name2=kiev
device.name3=kiev
device.name4=kiev
device.name5=kiev
supported.versions=14 - 16
'; }
block=/dev/block/bootdevice/by-name/boot;
is_slot_device=0;
ramdisk_compression=auto;
. /tmp/anykernel/tools/ak3-core.sh;
split_boot;
flash_boot;
EOF

zip -r9 /home/runner/output/ReSukiSU-kiev.zip *
cp ../kernel_sources/build.log /home/runner/output/

echo "=== BUILD TERMINÉ ==="
ls -lh /home/runner/output/
