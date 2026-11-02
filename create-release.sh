#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$SCRIPT_DIR/build.cfg"
REPO=rmuxnet/ps5-linux-patches-1
SRC_ARG=""
OUT_DIR="$(dirname "$SCRIPT_DIR")/release-out"
PREVIEW=n

while [ $# -gt 0 ]; do
  case "$1" in
    --preview) PREVIEW=y ;;
    --repo) REPO="$2"; shift ;;
    --src) SRC_ARG="$2"; shift ;;
    --out) OUT_DIR="$2"; shift ;;
    *) CFG="$1" ;;
  esac
  shift
done

die() { echo "==> ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

[ -f "$CFG" ] || die "config not found: $CFG"
source "$CFG"
SRC_DIR="${SRC_ARG:-$(dirname "$SCRIPT_DIR")/linux-release}"

case "$LTO" in
  full) TARGET_LTO=FullLTO; LOCALVERSION=-PinkSoup ;;
  thin) TARGET_LTO=ThinLTO; LOCALVERSION=-Clang-ThinLTO ;;
  none) TARGET_LTO=NoLTO; LOCALVERSION=-Clang-NoLTO ;;
  *) die "LTO must be full, thin or none (got '$LTO')" ;;
esac
[ "$JOBS" = auto ] && JOBS="$(nproc)"

cd "$SCRIPT_DIR"
HEAD_SHA="$(git rev-parse HEAD)"
SHORT="$(git rev-parse --short=7 HEAD)"
SUBJECT="$(git log -1 --format=%s)"
AUTHOR="$(git log -1 --format='%an <%ae>')"
CDATE="$(git log -1 --date='format:%Y-%m-%d %H:%M %z' --format=%cd)"
BODY="$(git log -1 --format=%b | grep -viE '^(signed-off-by|co-authored-by):' || true)"
COAUTHORS="$(git log -1 --format=%b | sed -n 's/^[Cc]o-authored-by: *//p')"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
KBASE="$(head -n 5 .config | grep -m1 -oP '^# Linux/\S+ \K[0-9.]+(-rc[0-9]+)?' || echo unknown)"
CLANG="$(clang --version | head -1)"
HOST="$(hostname)"

notes() {
  local kver="$1" started="$2"
  echo "## Kernel"
  echo
  echo "\`$kver\`"
  echo
  echo "## Commit"
  echo
  echo "[\`$SHORT\`](https://github.com/$REPO/commit/$HEAD_SHA) $SUBJECT"
  echo
  echo "- Branch: \`$BRANCH\`"
  echo "- Author: $AUTHOR"
  if [ -n "$COAUTHORS" ]; then
    while read -r c; do echo "- Co-author: $c"; done <<< "$COAUTHORS"
  fi
  echo "- Date: $CDATE"
  if [ -n "$(printf '%s' "$BODY" | tr -d '[:space:]')" ]; then
    echo
    printf '%s\n' "$BODY" | awk 'NF {p=1} p' | tac | awk 'NF {p=1} p' | tac | sed 's/.$/&  /'
  fi
  echo
  echo "## Build"
  echo
  echo "- Started: $started"
  echo "- Host: $HOST"
  echo "- Compiler: $CLANG"
  echo "- LTO: $LTO ($TARGET_LTO)"
  echo "- CPU flags: -march=$MARCH -mtune=$MTUNE"
  echo "- Optimize: $OPTIMIZE"
  echo
  echo "## Install"
  echo
  echo "On the PS5:"
  echo
  echo '```bash'
  echo "unzip ps5-linux-$kver.zip"
  echo "cd ps5-linux-$kver"
  echo "./install.sh"
  echo '```'
  echo
  echo "It installs the modules, makes the initrd, backs up the boot partition to \`/boot/efi-backup/<date>\` and copies the new kernel there."
  echo "Cold boot the PS5 after that."
}

if [ "$PREVIEW" = y ]; then
  notes "$KBASE$LOCALVERSION" "$(date '+%Y-%m-%d %H:%M %Z')"
  exit 0
fi

[ -z "$(git status --porcelain --untracked-files=no)" ] || die "working tree has changes, commit them first"
git fetch -q origin "$BRANCH" 2>/dev/null || git fetch -q fork "$BRANCH" 2>/dev/null || true
command -v gh >/dev/null || die "gh not found"
gh api "repos/$REPO/commits/$HEAD_SHA" >/dev/null 2>&1 || die "$SHORT is not on $REPO yet, push it first"

TMP_CFG="$(mktemp)"
SWAP_FILE="$OUT_DIR/build.swap"
SWAP_ADDED=n
cleanup() {
  rm -f "$TMP_CFG" "$SCRIPT_DIR/config-$TARGET_LTO"
  if [ "$SWAP_ADDED" = y ]; then
    sudo swapoff "$SWAP_FILE" || true
    sudo rm -f "$SWAP_FILE"
    log "removed build swap $SWAP_FILE"
  fi
}
trap cleanup EXIT

sed -e "s|^PATCHES_DIR=.*|PATCHES_DIR=\"$SCRIPT_DIR\"|" \
    -e "s|^SRC_DIR=.*|SRC_DIR=\"$SRC_DIR\"|" \
    -e 's|^CONFIG_ONLY=.*|CONFIG_ONLY=y|' \
    -e 's|^DEPLOY_EFI=.*|DEPLOY_EFI=n|' \
    -e 's|^SWAP_GB=.*|SWAP_GB=0|' "$CFG" > "$TMP_CFG"
"$SCRIPT_DIR/build.sh" "$TMP_CFG"

mkdir -p "$OUT_DIR"
if [ "$LTO" = full ]; then
  mem_kb="$(awk '/MemTotal/ {m=$2} END {print m}' /proc/meminfo)"
  swap_kb="$(awk 'NR>1 {s+=$3} END {print s+0}' /proc/swaps)"
  if [ $(( mem_kb + swap_kb )) -lt $(( 24 * 1024 * 1024 )) ]; then
    log "adding a 10 GB build swap at $SWAP_FILE for full LTO"
    sudo rm -f "$SWAP_FILE"
    sudo fallocate -l 10G "$SWAP_FILE"
    sudo chmod 600 "$SWAP_FILE"
    sudo mkswap -q "$SWAP_FILE"
    sudo swapon "$SWAP_FILE"
    SWAP_ADDED=y
  fi
fi

if [ "$CCACHE" = y ]; then
  export CCACHE_DIR
  mkdir -p "$CCACHE_DIR"
  CC_BIN="ccache clang"; HOSTCC_BIN="ccache clang"; HOSTCXX_BIN="ccache clang++"
else
  CC_BIN=clang; HOSTCC_BIN=clang; HOSTCXX_BIN=clang++
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

cd "$SRC_DIR"
KVER="$(make -s kernelrelease "${MAKE_FLAGS[@]}")"
STARTED="$(date '+%Y-%m-%d %H:%M %Z')"
log "building $KVER with $JOBS jobs"
make -j"$JOBS" "${MAKE_FLAGS[@]}"

FW_LIST="$(grep -m1 '^CONFIG_EXTRA_FIRMWARE=' .config | cut -d'"' -f2 || true)"
for fw in $FW_LIST; do
  [ -f "drivers/base/firmware_loader/builtin/$fw.gen.o" ] || die "firmware $fw was not built into the kernel"
done

NAME="ps5-linux-$KVER"
STAGE="$OUT_DIR/$NAME"
rm -rf "$STAGE" "$OUT_DIR/$NAME.zip"
mkdir -p "$STAGE/boot"
make "${MAKE_FLAGS[@]}" INSTALL_MOD_PATH="$STAGE" INSTALL_MOD_STRIP=1 modules_install
rm -f "$STAGE/lib/modules/$KVER/build" "$STAGE/lib/modules/$KVER/source"
install -Dm644 arch/x86/boot/bzImage "$STAGE/boot/vmlinuz-$KVER"
install -Dm644 .config "$STAGE/boot/config-$KVER"
install -Dm644 System.map "$STAGE/boot/System.map-$KVER"
install -Dm755 "$SCRIPT_DIR/release/install.sh" "$STAGE/install.sh"
(cd "$OUT_DIR" && bsdtar -a -cf "$NAME.zip" "$NAME")
log "zip at $OUT_DIR/$NAME.zip ($(du -h "$OUT_DIR/$NAME.zip" | cut -f1))"

TAG="$KVER-$SHORT"
notes "$KVER" "$STARTED" > "$OUT_DIR/$NAME.md"
cd "$SCRIPT_DIR"
gh release create "$TAG" "$OUT_DIR/$NAME.zip" \
  --repo "$REPO" \
  --target "$HEAD_SHA" \
  --title "$KVER ($SHORT)" \
  --notes-file "$OUT_DIR/$NAME.md" \
  --draft --prerelease
log "draft pre-release $TAG on $REPO"
