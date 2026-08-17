#!/bin/bash
set -e
echo "=== Début du build ==="
df -h

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
sudo apt-get clean

sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache curl flex git gnupg gperf imagemagick lib32ncurses5-dev lib32readline-dev lib32z1-dev liblz4-tool libncurses5 libncurses5-dev libsdl1.2-dev libssl-dev libxml2 libxml2-utils lzop pngcrush rsync schedtool squashfs-tools xsltproc zip zlib1g-dev python3 python3-pip libelf-dev dwarves cpio automake autoconf lld llvm gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi mkbootimg

if [ ! -d "/home/runner/clang" ]; then
  mkdir -p /home/runner/clang
  cd /home/runner/clang
  wget -q https://github.com/llvm/llvm-project/releases/download/llvmorg-17.0.6/clang+llvm-17.0.6-x86_64-linux-gnu-ubuntu-22.04.tar.xz
  tar -xf clang+llvm-17.0.6-x86_64-linux-gnu-ubuntu-22.04.tar.xz
  mv clang+llvm-17.0.6-x86_64-linux-gnu-ubuntu-22.04/* .
  rm -rf clang+llvm-17.0.6-x86_64-linux-gnu-ubuntu-22.04*
fi

mkdir -p /home/runner/gcc-64/bin /home/runner/gcc-32/bin
for tool in gcc ar nm objcopy objdump strip; do
  ln -sf /usr/bin/aarch64-linux-gnu-$tool /home/runner/gcc-64/bin/aarch64-linux-android-$tool
  ln -sf /usr/bin/arm-linux-gnueabi-$tool /home/runner/gcc-32/bin/arm-linux-androideabi-$tool
done

cd /home/runner/work/*/*/

# === NOUVELLE MÉTHODE : Utiliser git submodule ===

# 1. Cloner le kernel
git clone --depth=1 --branch lineage-23.2 https://github.com/LineageOS/android_kernel_motorola_sm8250.git kernel_sources
cd kernel_sources

# 2. Ajouter ReSukiSU comme submodule dans drivers/kernelsu
echo "=== Ajout de ReSukiSU comme submodule ==="

# Initialiser git si nécessaire
git init 2>/dev/null || true

# Ajouter le submodule ReSukiSU
git submodule add https://github.com/ReSukiSU/ReSukiSU.git drivers/kernelsu 2>/dev/null || {
  echo "Submodule add échoué, essai alternatif..."
  # Alternative : cloner directement dans le bon dossier avec .git
  rm -rf drivers/kernelsu
  git clone --depth=1 https://github.com/ReSukiSU/ReSukiSU.git drivers/kernelsu
}

# Initialiser et mettre à jour les submodules
git submodule update --init --recursive 2>/dev/null || true

# Vérifier que le submodule est en place
echo "=== Vérification du submodule ==="
ls -la drivers/kernelsu/
if [ -d "drivers/kernelsu/.git" ] || [ -f "drivers/kernelsu/.git" ]; then
  echo "✅ ReSukiSU est un submodule git valide"
else
  echo "⚠️ Le dossier .git n'existe pas, création artificielle..."
  # Créer un faux .git pour satisfaire le Kbuild
  if [ ! -d "drivers/kernelsu/.git" ]; then
    mkdir -p drivers/kernelsu/.git
    echo "gitdir: ../../.git/modules/drivers/kernelsu" > drivers/kernelsu/.git
  fi
fi

# 3. Modifier le Makefile du kernel
if ! grep -q "kernelsu" drivers/Makefile; then
  echo "obj-y += kernelsu/" >> drivers/Makefile
  echo "✅ Makefile modifié"
fi

# 4. Modifier le Kconfig du kernel
if ! grep -q "kernelsu" drivers/Kconfig; then
  echo 'source "drivers/kernelsu/Kconfig"' >> drivers/Kconfig
  echo "✅ Kconfig modifié"
fi

# 5. Modifier fs/exec.c
if ! grep -q "handle_kernelsu" fs/exec.c; then
  sed -i '/#include <linux\/fs.h>/a extern int handle_kernelsu(int argc, char *argv[]);' fs/exec.c
  cat > /tmp/patch_exec.py << 'PYEOF'
import re
with open('fs/exec.c', 'r') as f:
    content = f.read()
pattern = r'(static int do_execveat_common\(.*?\{)'
replacement = r'\1\n\tif (unlikely(handle_kernelsu(argc, argv))) {\n\t\treturn 0;\n\t}'
content = re.sub(pattern, replacement, content, count=1)
with open('fs/exec.c', 'w') as f:
    f.write(content)
PYEOF
  python3 /tmp/patch_exec.py
  echo "✅ fs/exec.c modifié"
fi

# 6. Configuration
echo "=== Configuration du kernel ==="
make mrproper

CONFIG=$(find arch/arm64/configs/ -name "*kiev*" -o -name "*sm8250*" | head -1)
if [ -z "$CONFIG" ]; then
  echo "❌ Aucune config trouvée"
  exit 1
fi

cp "$CONFIG" .config
echo "Config: $CONFIG"

./scripts/config --enable KSU
./scripts/config --enable KPROBES
./scripts/config --enable HAVE_KPROBES
./scripts/config --enable KPROBE_EVENTS

make ARCH=arm64 olddefconfig

# 7. Compilation
echo "=== Compilation ==="
export ARCH=arm64
export SUBARCH=arm64
export PATH="/home/runner/clang/bin:/home/runner/gcc-64/bin:/home/runner/gcc-32/bin:$PATH"
export CLANG_TRIPLE=aarch64-linux-gnu-
export CROSS_COMPILE=aarch64-linux-android-
export CROSS_COMPILE_ARM32=arm-linux-androideabi-
export CC=clang
export LD=ld.lld
export AR=llvm-ar
export NM=llvm-nm
export OBJCOPY=llvm-objcopy
export OBJDUMP=llvm-objdump
export STRIP=llvm-strip

make -j$(nproc) O=out ARCH=arm64 CC=clang 2>&1 | tee build.log

if [ ! -f "out/arch/arm64/boot/Image" ] && [ ! -f "out/arch/arm64/boot/Image.gz" ]; then
  echo "❌ BUILD FAILED"
  grep -i "error:" build.log | tail -30
  exit 1
fi

echo "✅ Compilation réussie"

# 8. Créer boot.img
echo "=== Création du boot.img ==="
mkdir -p /home/runner/output
KERNEL_IMAGE="out/arch/arm64/boot/Image.gz"
[ -f "$KERNEL_IMAGE" ] || KERNEL_IMAGE="out/arch/arm64/boot/Image"

mkbootimg --kernel "$KERNEL_IMAGE" --ramdisk /dev/null --output /home/runner/output/ReSukiSU-boot.img --header_version 2 --pagesize 4096 --base 0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 --tags_offset 0x00000100 --cmdline "androidboot.hardware=kiev androidboot.selinux=permissive"

echo "✅ boot.img créé"

# 9. Créer package AnyKernel3
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
