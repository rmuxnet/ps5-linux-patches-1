#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="${1:-$SCRIPT_DIR/build.cfg}"

die() { echo "==> ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

[ -f "$CFG" ] || die "config not found: $CFG"
cd "$SCRIPT_DIR"
source "$CFG"

case "$LTO" in
  full) TARGET_LTO=FullLTO; LOCALVERSION=-PinkSoup ;;
  thin) TARGET_LTO=ThinLTO; LOCALVERSION=-Clang-ThinLTO ;;
  none) TARGET_LTO=NoLTO; LOCALVERSION=-Clang-NoLTO ;;
  *) die "LTO must be full, thin or none (got '$LTO')" ;;
esac
case "$OPTIMIZE" in performance|size) ;; *) die "OPTIMIZE must be performance or size" ;; esac
for v in CONFIG_ONLY CCACHE STRIP DEPLOY_EFI ZSWAP ZSWAP_SHRINKER ZRAM LZ4 NTSYNC; do
  case "${!v}" in y|n) ;; *) die "$v must be y or n" ;; esac
done

declare -A COMP_SYM=(
  [zstd]=ZSTD [lz4]=LZ4 [lz4hc]=LZ4HC [lzo]=LZO [lzo-rle]=LZORLE [deflate]=DEFLATE [842]=842
)
declare -A BACKEND_SYM=(
  [zstd]=ZSTD [lz4]=LZ4 [lz4hc]=LZ4HC [lzo]=LZO [lzo-rle]=LZO [deflate]=DEFLATE [842]=842
)
declare -A CRYPTO_SYM=(
  [zstd]=CRYPTO_ZSTD [lz4]=CRYPTO_LZ4 [lz4hc]=CRYPTO_LZ4HC [lzo]=CRYPTO_LZO [deflate]=CRYPTO_DEFLATE [842]=CRYPTO_842
)
[ -n "${CRYPTO_SYM[$ZSWAP_COMPRESSOR]:-}" ] || die "ZSWAP_COMPRESSOR not supported: $ZSWAP_COMPRESSOR"
[ -n "${COMP_SYM[$ZRAM_COMPRESSOR]:-}" ] || die "ZRAM_COMPRESSOR not supported: $ZRAM_COMPRESSOR"

if [ "$SWAP_GB" = auto ]; then
  case "$LTO" in full) SWAP_GB=10 ;; thin) SWAP_GB=6 ;; none) SWAP_GB=0 ;; esac
fi
[[ "$SWAP_GB" =~ ^[0-9]+$ ]] || die "SWAP_GB must be auto or a number"
[[ "$EFI_BACKUP_KEEP" =~ ^[1-9][0-9]*$ ]] || die "EFI_BACKUP_KEEP must be 1 or more"
[ "$JOBS" = auto ] && JOBS="$(nproc)"

if command -v dracut >/dev/null; then
  INITRD_TOOL=dracut
elif command -v mkinitcpio >/dev/null; then
  INITRD_TOOL=mkinitcpio
elif command -v update-initramfs >/dev/null; then
  INITRD_TOOL=update-initramfs
else
  die "no dracut, mkinitcpio or update-initramfs found"
fi

if [ "$DEPLOY_EFI" = y ] && [ "$EFI_DIR" = auto ]; then
  found=()
  while read -r src mnt _; do
    [[ "$src" == /dev/* ]] || continue
    mnt="$(printf '%b' "$mnt")"
    [[ " ${found[*]} " == *" $mnt "* ]] && continue
    if sudo test -f "$mnt/bzImage"; then
      found+=("$mnt")
    fi
  done < /proc/mounts
  EFI_DIR=""
  if [ "${#found[@]}" -eq 1 ]; then
    while :; do
      read -r -p "==> boot partition is ${found[0]}, is this right? [Y/n] " ans || die "no answer"
      case "$ans" in
        ""|y|Y) EFI_DIR="${found[0]}"; break ;;
        n|N) break ;;
      esac
    done
  elif [ "${#found[@]}" -gt 1 ]; then
    log "more than one partition with bzImage: ${found[*]}"
  else
    log "no mounted partition with bzImage found"
  fi
  if [ -z "$EFI_DIR" ]; then
    read -r -p "==> path to the boot partition: " EFI_DIR || die "no answer"
    [ -d "$EFI_DIR" ] || die "$EFI_DIR is not a directory"
  fi
  log "boot partition $EFI_DIR"
fi

[ -f "$PATCHES_DIR/linux.patch" ] || die "no linux.patch in $PATCHES_DIR"
[ -f "$PATCHES_DIR/.config" ] || die "no .config in $PATCHES_DIR"

SWAP_ADDED=n
cleanup() {
  if [ "$SWAP_ADDED" = y ]; then
    sudo swapoff "$SWAP_FILE" || true
    sudo rm -f "$SWAP_FILE"
    log "removed build swap $SWAP_FILE"
  fi
}
trap cleanup EXIT

swap_have_kb="$(awk 'NR>1 {s+=$3} END {print s+0}' /proc/swaps)"
swap_want_kb=$(( SWAP_GB * 1024 * 1024 ))
if [ "$swap_want_kb" -gt "$swap_have_kb" ]; then
  add_mb=$(( (swap_want_kb - swap_have_kb) / 1024 ))
  log "swap ${swap_have_kb} kB, want ${SWAP_GB} GB, adding ${add_mb} MB at $SWAP_FILE"
  sudo rm -f "$SWAP_FILE"
  sudo fallocate -l "${add_mb}M" "$SWAP_FILE" 2>/dev/null \
    || sudo dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$add_mb" status=none
  sudo chmod 600 "$SWAP_FILE"
  sudo mkswap -q "$SWAP_FILE"
  sudo swapon "$SWAP_FILE"
  SWAP_ADDED=y
else
  log "swap ${swap_have_kb} kB is enough for ${SWAP_GB} GB"
fi

if [ "$KERNEL_REF" = latest ]; then
  KERNEL_REF="$(git ls-remote --tags --refs "$KERNEL_REPO_MAINLINE" 'v[0-9]*' \
    | sed -n 's|.*refs/tags/||p' | grep -E '^v[0-9]+\.[0-9]+(-rc[0-9]+)?$' \
    | sed -E 's/^(v[0-9]+\.[0-9]+)$/\1-rc999/' | sort -V | tail -1 | sed 's/-rc999$//')" \
    || die "cannot list tags of $KERNEL_REPO_MAINLINE"
  [ -n "$KERNEL_REF" ] || die "no mainline tag found"
elif [ "$KERNEL_REF" = auto ]; then
  raw="$(head -n 5 "$PATCHES_DIR/.config" | grep -m1 -oP '^# Linux/\S+ \K[0-9]+\.[0-9]+(\.[0-9]+)?(-rc[0-9]+)?')" \
    || die "cannot read kernel version from $PATCHES_DIR/.config"
  base="${raw%%-*}"
  rc=""
  [[ "$raw" == *-rc* ]] && rc="-${raw#*-}"
  [[ "$base" =~ ^[0-9]+\.[0-9]+\.0$ ]] && base="${base%.0}"
  KERNEL_REF="v${base}${rc}"
fi
if [[ "$KERNEL_REF" =~ ^v[0-9]+\.[0-9]+(-rc[0-9]+)?$ ]]; then
  KERNEL_REPO="$KERNEL_REPO_MAINLINE"
else
  KERNEL_REPO="$KERNEL_REPO_STABLE"
fi
log "kernel $KERNEL_REF from $KERNEL_REPO, $TARGET_LTO"

PATCH_SUM="$(sha256sum "$PATCHES_DIR/linux.patch" | cut -d' ' -f1)"
if [ -d "$SRC_DIR/.git" ]; then
  [ -f "$SRC_DIR/.ci-kernel-ref" ] || die "$SRC_DIR exists and was not made by this script, not touching it"
  have_ref="$(cat "$SRC_DIR/.ci-kernel-ref")"
  have_sum="$(cat "$SRC_DIR/.ci-patch-sum" 2>/dev/null || true)"
  if [ "$have_ref" = "$KERNEL_REF" ] && [ "$have_sum" = "$PATCH_SUM" ]; then
    log "reusing $SRC_DIR as is ($KERNEL_REF, same linux.patch)"
  else
    if [ "$have_ref" != "$KERNEL_REF" ]; then
      log "moving $SRC_DIR from $have_ref to $KERNEL_REF, build objects are kept"
      git -C "$SRC_DIR" remote set-url origin "$KERNEL_REPO"
      git -C "$SRC_DIR" fetch --depth 1 origin "refs/tags/$KERNEL_REF:refs/tags/$KERNEL_REF"
      git -C "$SRC_DIR" checkout -q -f "$KERNEL_REF"
    else
      log "linux.patch changed, re-applying it on $KERNEL_REF"
      git -C "$SRC_DIR" checkout -q -f -- .
    fi
    git -C "$SRC_DIR" clean -q -fd -e .ci-kernel-ref -e .ci-patch-sum
    rm -f "$SRC_DIR/.ci-patch-sum"
    echo "$KERNEL_REF" > "$SRC_DIR/.ci-kernel-ref"
  fi
else
  [ -e "$SRC_DIR" ] && die "$SRC_DIR exists and is not a git tree, not touching it"
  git clone --depth 1 --branch "$KERNEL_REF" "$KERNEL_REPO" "$SRC_DIR"
  echo "$KERNEL_REF" > "$SRC_DIR/.ci-kernel-ref"
fi

if [ ! -f "$SRC_DIR/.ci-patch-sum" ]; then
  git -C "$SRC_DIR" apply --exclude=Makefile "$PATCHES_DIR/linux.patch" \
    || die "linux.patch does not apply on $KERNEL_REF, fix the patch first"
  if [ -f /etc/gentoo-release ]; then
    for gp in "$PATCHES_DIR"/*.patch; do
      [ -f "$gp" ] || continue
      [ "$(basename "$gp")" = "linux.patch" ] && continue
      log "applying $(basename "$gp")"
      git -C "$SRC_DIR" apply "$gp" \
        || log "WARN: $(basename "$gp") did not apply cleanly, skipping"
    done
  fi
  echo "$PATCH_SUM" > "$SRC_DIR/.ci-patch-sum"
fi
cp "$PATCHES_DIR/.config" "$SRC_DIR/.config"

FW_LIST="$(grep -m1 '^CONFIG_EXTRA_FIRMWARE=' "$SRC_DIR/.config" | cut -d'"' -f2 || true)"
for fw in $FW_LIST; do
  [ -f "$PATCHES_DIR/firmware/$fw" ] || die "firmware $fw not found in $PATCHES_DIR/firmware"
done

cd "$SRC_DIR"
kcfg() { ./scripts/config --file .config "$@"; }

if [ -n "$FW_LIST" ]; then
  kcfg --set-str EXTRA_FIRMWARE_DIR "$PATCHES_DIR/firmware"
fi

case "$LTO" in
  full) kcfg --disable LTO_NONE --disable LTO_CLANG_THIN --enable LTO_CLANG --enable LTO_CLANG_FULL ;;
  thin) kcfg --disable LTO_NONE --disable LTO_CLANG_FULL --enable LTO_CLANG --enable LTO_CLANG_THIN ;;
  none) kcfg --disable LTO_CLANG_FULL --disable LTO_CLANG_THIN --disable LTO_CLANG --enable LTO_NONE ;;
esac

if [ "$OPTIMIZE" = performance ]; then
  kcfg --enable CC_OPTIMIZE_FOR_PERFORMANCE --disable CC_OPTIMIZE_FOR_SIZE
else
  kcfg --disable CC_OPTIMIZE_FOR_PERFORMANCE --enable CC_OPTIMIZE_FOR_SIZE
fi

if [ "$STRIP" = y ]; then
  kcfg --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT --disable DEBUG_INFO_DWARF4 \
       --disable DEBUG_INFO_DWARF5 --enable DEBUG_INFO_NONE
fi

if [ "$LZ4" = y ]; then
  kcfg --enable CRYPTO_LZ4 --enable CRYPTO_LZ4HC --enable LZ4_COMPRESS --enable LZ4HC_COMPRESS \
       --enable ZRAM_BACKEND_LZ4 --enable ZRAM_BACKEND_LZ4HC
fi

if [ "$ZSWAP" = y ]; then
  kcfg --enable ZSWAP --enable ZSWAP_DEFAULT_ON --enable ZSMALLOC --enable "${CRYPTO_SYM[$ZSWAP_COMPRESSOR]}"
  for c in DEFLATE LZO 842 LZ4 LZ4HC ZSTD; do kcfg --disable "ZSWAP_COMPRESSOR_DEFAULT_$c"; done
  kcfg --enable "ZSWAP_COMPRESSOR_DEFAULT_${COMP_SYM[$ZSWAP_COMPRESSOR]}" \
       --set-str ZSWAP_COMPRESSOR_DEFAULT "$ZSWAP_COMPRESSOR"
  if [ "$ZSWAP_SHRINKER" = y ]; then
    kcfg --enable ZSWAP_SHRINKER_DEFAULT_ON
  else
    kcfg --disable ZSWAP_SHRINKER_DEFAULT_ON
  fi
else
  kcfg --disable ZSWAP_DEFAULT_ON
fi

if [ "$ZRAM" = y ]; then
  kcfg --enable ZRAM --enable ZSMALLOC --enable "ZRAM_BACKEND_${BACKEND_SYM[$ZRAM_COMPRESSOR]}"
  for c in LZORLE LZO LZ4 LZ4HC ZSTD DEFLATE 842; do kcfg --disable "ZRAM_DEF_COMP_$c"; done
  kcfg --enable "ZRAM_DEF_COMP_${COMP_SYM[$ZRAM_COMPRESSOR]}" --set-str ZRAM_DEF_COMP "$ZRAM_COMPRESSOR"
fi

if [ "$NTSYNC" = y ]; then
  kcfg --enable NTSYNC
fi

for op in "${CONFIG_OPS[@]}"; do
  read -r -a args <<< "$op"
  kcfg "${args[@]}"
done

make olddefconfig LLVM=1

fail=0
want() {
  local sym="$1" val="$2" got
  got="$(grep -m1 -E "^CONFIG_${sym}=" .config | cut -d= -f2- || true)"
  [ -z "$got" ] && got=n
  if [ "$got" = "$val" ]; then
    printf '    ok    %-36s %s\n' "$sym" "$got"
  else
    printf '    FAIL  %-36s want %s got %s\n' "$sym" "$val" "$got"
    fail=1
  fi
}
log "config check"
case "$LTO" in
  full) want LTO_CLANG_FULL y ;;
  thin) want LTO_CLANG_THIN y ;;
  none) want LTO_NONE y ;;
esac
[ "$OPTIMIZE" = performance ] && want CC_OPTIMIZE_FOR_PERFORMANCE y || want CC_OPTIMIZE_FOR_SIZE y
[ "$STRIP" = y ] && want DEBUG_INFO_NONE y
if [ "$LZ4" = y ]; then
  want CRYPTO_LZ4 y
  want CRYPTO_LZ4HC y
fi
if [ "$ZSWAP" = y ]; then
  want ZSWAP_DEFAULT_ON y
  want ZSWAP_COMPRESSOR_DEFAULT "\"$ZSWAP_COMPRESSOR\""
  want "${CRYPTO_SYM[$ZSWAP_COMPRESSOR]}" y
  [ "$ZSWAP_SHRINKER" = y ] && want ZSWAP_SHRINKER_DEFAULT_ON y
fi
if [ "$ZRAM" = y ]; then
  want ZRAM y
  want ZRAM_DEF_COMP "\"$ZRAM_COMPRESSOR\""
fi
[ "$NTSYNC" = y ] && want NTSYNC y
if [ -n "$FW_LIST" ]; then
  want EXTRA_FIRMWARE "\"$FW_LIST\""
  want EXTRA_FIRMWARE_DIR "\"$PATCHES_DIR/firmware\""
fi
[ "$fail" = 0 ] || die "config check failed, see FAIL lines above"

if [ "$CONFIG_ONLY" = y ]; then
  cp .config "$SCRIPT_DIR/config-$TARGET_LTO"
  log "CONFIG_ONLY=y, stopping before the build"
  exit 0
fi

KVER="$(make -s kernelrelease LLVM=1 LOCALVERSION="$LOCALVERSION")"
log "building $KVER with $JOBS jobs"

if [ "$CCACHE" = y ]; then
  export CCACHE_DIR
  mkdir -p "$CCACHE_DIR"
  CC_BIN="ccache clang"
  HOSTCC_BIN="ccache clang"
  HOSTCXX_BIN="ccache clang++"
else
  CC_BIN=clang
  HOSTCC_BIN=clang
  HOSTCXX_BIN=clang++
fi

MAKE_FLAGS=(
  LLVM=1
  CC="$CC_BIN"
  LD=ld.lld
  AR=llvm-ar
  NM=llvm-nm
  STRIP=llvm-strip
  OBJCOPY=llvm-objcopy
  OBJDUMP=llvm-objdump
  READELF=llvm-readelf
  HOSTCC="$HOSTCC_BIN"
  HOSTCXX="$HOSTCXX_BIN"
  KCFLAGS="-march=${MARCH} -mtune=${MTUNE} ${KCFLAGS_EXTRA}"
  LOCALVERSION="${LOCALVERSION}"
  KBUILD_BUILD_VERSION="1~ps5-${TARGET_LTO}"
)

make -j"$JOBS" "${MAKE_FLAGS[@]}"

for fw in $FW_LIST; do
  [ -f "drivers/base/firmware_loader/builtin/$fw.gen.o" ] || die "firmware $fw was not built into the kernel"
  log "firmware $fw built into the kernel"
done

if [ "$STRIP" = y ]; then
  sudo make "${MAKE_FLAGS[@]}" INSTALL_MOD_STRIP=1 modules_install
else
  sudo make "${MAKE_FLAGS[@]}" modules_install
fi
sudo install -Dm644 arch/x86/boot/bzImage "/boot/vmlinuz-$KVER"
sudo install -Dm644 .config "/boot/config-$KVER"
sudo install -Dm644 System.map "/boot/System.map-$KVER"
log "kernel at /boot/vmlinuz-$KVER"

if [ -n "$WIFI_SRC" ]; then
  [ -f "$WIFI_SRC/Makefile" ] || die "no Makefile in WIFI_SRC $WIFI_SRC"
  WIFI_BUILD="$(dirname "$SRC_DIR")/mwifiex-build"
  rm -rf "$WIFI_BUILD"
  cp -a "$WIFI_SRC" "$WIFI_BUILD"
  make -C "$WIFI_BUILD" clean >/dev/null 2>&1 || true
  make -C "$WIFI_BUILD" -j"$JOBS" CONFIG_OBJTOOL= KERNELDIR="$SRC_DIR" ARCH=x86 LLVM=1 \
    KCFLAGS="-march=${MARCH} -mtune=${MTUNE} -Wno-unknown-warning-option"
  for ko in mlan.ko moal.ko; do
    [ -f "$WIFI_BUILD/$ko" ] || die "Wi-Fi module $ko was not built"
    [ "$STRIP" = y ] && llvm-strip --strip-debug "$WIFI_BUILD/$ko"
    sudo install -Dm644 "$WIFI_BUILD/$ko" "/usr/lib/modules/$KVER/extra/ps5-iw620/$ko"
  done
  sudo depmod "$KVER"
  log "Wi-Fi modules in /usr/lib/modules/$KVER/extra/ps5-iw620"
fi

if [ "$INITRD_TOOL" = dracut ]; then
  sudo dracut --force --no-hostonly --kver "$KVER" "/boot/initrd.img-$KVER"
elif [ "$INITRD_TOOL" = mkinitcpio ]; then
  sudo mkinitcpio -k "$KVER" -g "/boot/initrd.img-$KVER"
elif [ -e "/boot/initrd.img-$KVER" ]; then
  sudo update-initramfs -u -k "$KVER"
else
  sudo update-initramfs -c -k "$KVER"
fi
log "initrd at /boot/initrd.img-$KVER"

if [ "$DEPLOY_EFI" = y ]; then
  [ -d "$EFI_DIR" ] || die "EFI_DIR $EFI_DIR not found"
  new_k="/boot/vmlinuz-$KVER"
  new_i="/boot/initrd.img-$KVER"
  size_of() { sudo stat -c %s "$1" 2>/dev/null || echo 0; }
  grow=$(( $(size_of "$new_k") - $(size_of "$EFI_DIR/bzImage") + $(size_of "$new_i") - $(size_of "$EFI_DIR/initrd.img") ))
  free=$(( $(df -B1 --output=avail "$EFI_DIR" | tail -1) ))
  [ "$grow" -lt $(( free - 4 * 1024 * 1024 )) ] || die "not enough space in $EFI_DIR (need $grow more bytes, $free free)"

  stamp="$(date +%Y%m%d-%H%M%S)"
  bdir="$EFI_BACKUP_DIR/$stamp"
  sudo mkdir -p "$bdir"
  for f in bzImage initrd.img; do
    if [ -f "$EFI_DIR/$f" ]; then
      sudo cp "$EFI_DIR/$f" "$bdir/$f"
    fi
  done
  log "old EFI files saved in $bdir"
  ls -1d "$EFI_BACKUP_DIR"/*/ 2>/dev/null | sort | head -n -"$EFI_BACKUP_KEEP" | while read -r old; do
    sudo rm -rf "$old"
    log "removed old backup $old"
  done

  sudo cp "$new_k" "$EFI_DIR/bzImage"
  sudo cp "$new_i" "$EFI_DIR/initrd.img"
  sync
  sudo cmp "$new_k" "$EFI_DIR/bzImage" || die "bzImage copy differs, restore from $bdir"
  sudo cmp "$new_i" "$EFI_DIR/initrd.img" || die "initrd.img copy differs, restore from $bdir"
  log "deployed $KVER to $EFI_DIR, cold boot the PS5 to run it"
fi

log "installed $KVER"
if [ "$CCACHE" = y ]; then
  ccache -s | grep -E "cache hit|cache miss|^Hits|^Misses" || true
fi
