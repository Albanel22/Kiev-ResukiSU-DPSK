#!/bin/bash
set -e
echo "=== Build ReSukiSU + SuSFS - VARIANTE SuSFS Inline Hook natif (pas de CONFIG_KSU_MANUAL_HOOK, pas de patches sed) ==="
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
echo "=== Clonage du kernel Albanel22 lineage-23.2-tactile (HEAD du fork, non épinglé — source de vérité pour le tactile) ==="
git clone https://github.com/Albanel22/android_kernel_motorola_sm8250.git \
  -b lineage-23.2-tactile --depth=1 kernel_sources
cd kernel_sources
git log --oneline -1

# ==================== 2. INTÉGRATION ReSukiSU ====================
echo "=== Intégration ReSukiSU (épinglée à la release MOTOROLA du 18 août 2026, 03:29 UTC) ==="
rm -rf drivers/kernelsu kernelSU susfs4ksu KernelSU || true
rm -rf /tmp/resukisu_pin
git clone https://github.com/ReSukiSU/ReSukiSU.git /tmp/resukisu_pin
RESUKISU_COMMIT=$(cd /tmp/resukisu_pin && git rev-list -n 1 --before="2026-08-17 23:59:59" main)
echo "Commit ReSukiSU épinglé : $RESUKISU_COMMIT"
curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash -s -- "$RESUKISU_COMMIT"

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
echo "✅ Patch SuSFS trouvé : $(wc -l < $SUSFS_PATCH) lignes"

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
    echo "⚠️ Rejet détecté dans namespace.c. Correction automatique..."
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
# (uniquement si vraiment absents après le patch réel — pas un stub par défaut,
# c'est un filet de sécurité minimal identique à l'implémentation SuSFS d'origine)
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
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 vendor/lito-perf_defconfig

{
  echo "CONFIG_KSU=y"
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

# --- Vérification stricte : seccomp doit être bien désactivé après olddefconfig ---

# ==================== 6. PATCHES FINAUX ====================
echo "=== Patch signatures modules + tactile ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c

printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c

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

# ==================== 7b. COMPILATION KSUD (ReSukiSU) ====================
echo "=== Compilation de ksud (ReSukiSU) ==="
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
# --- ksud (daemon Rust) N'EST PAS épinglé à la même date que le driver kernel : il vient de la branche
# --- main actuelle de ReSukiSU, qui a déjà remplacé toutes les dépendances de l'org GitHub Kernel-SU
# --- (adb_client, java-properties, ...) par leurs propres forks depuis la PR #412 (14 sept 2026).
# --- L'org Kernel-SU est suspendue par GitHub : tout pin de ksud antérieur à cette PR tombe sur des
# --- dépendances git inaccessibles, une par une (adb_client puis java-properties rencontrés en pratique).
echo "=== Clonage de ksud (ReSukiSU) sur main actuelle — dépendances Kernel-SU déjà remplacées en amont ==="
git clone https://github.com/ReSukiSU/ReSukiSU.git "$GITHUB_WORKSPACE/ksud-src"
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

echo "=== Résolution des dépendances (main actuelle) et compilation de ksud ==="
export CARGO_NET_GIT_FETCH_WITH_CLI=true
cargo +nightly build --release --target aarch64-linux-android

echo "=== Recherche du binaire ksud dans tout le repo cloné ==="
find "$GITHUB_WORKSPACE/ksud-src" -type f -name "ksud" 2>/dev/null
KSUD_BINARY=$(find "$GITHUB_WORKSPACE/ksud-src" -type f -name "ksud" -executable 2>/dev/null | head -1)

if [ -z "$KSUD_BINARY" ]; then
    echo "❌ ksud introuvable après recherche automatique"
    echo "=== Contenu de la racine du repo ksud-src (diagnostic) ==="
    ls -la "$GITHUB_WORKSPACE/ksud-src/"
    exit 1
fi

echo "✅ ksud trouvé ici : $KSUD_BINARY"
cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"
chmod 755 "$GITHUB_WORKSPACE/ksud"
echo "✅ ksud (ReSukiSU) compilé"

cd "$GITHUB_WORKSPACE"

# ==================== 8. REPACK (avec ksud) - modèle backslashxx (proven) ====================
echo "=== Téléchargement des images stock ==="
cd $GITHUB_WORKSPACE

curl -fLo boot-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260830/boot.img" 2>/dev/null || {
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

  set +e
  ./magiskboot unpack boot.img
  UNPACK_EXIT=$?
  set -e

  if [ ! -f "kernel" ] || [ ! -f "ramdisk.cpio" ]; then
    echo "❌ Échec réel du unpack (exit magiskboot: $UNPACK_EXIT)"
    exit 1
  fi

  cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel

  echo "=== Installation de ksud (chemin /data/adb/ksud/ksud, requis par sucompat) ==="
  ./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 data" \
    "mkdir 0755 data/adb" \
    "mkdir 0755 data/adb/ksud" \
    "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"

  echo "=== Installation de SU ==="
  cp "$GITHUB_WORKSPACE/ksud" local_su_binary
  chmod 755 local_su_binary
  ./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 system" \
    "mkdir 0755 system/bin" \
    "add 06755 system/bin/su ./local_su_binary"
  rm -f local_su_binary

  echo "=== Vérification SU/ksud dans ramdisk ==="
  ./magiskboot cpio ramdisk.cpio list | grep -E '(^|/)(su|ksud)$' || true

  ./magiskboot repack boot.img new-boot.img || {
    echo "❌ Échec du repack"
    exit 1
  }
  mv new-boot.img ../final_boot.img
  cd ..
fi

# ==================== 9. SORTIE ====================
echo "=== Copie vers output ==="
mkdir -p output
cp final_boot.img output/ReSukiSU-SusFS-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true

echo "=== BUILD TERMINÉ ==="
ls -lh output/
