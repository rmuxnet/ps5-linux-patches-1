#!/usr/bin/env bash
set -euo pipefail

die() { echo "==> ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
  exec sudo bash "$HERE/install.sh" "$@"
fi

EFI_DIR="${1:-auto}"
EFI_BACKUP_DIR=/boot/efi-backup
EFI_BACKUP_KEEP=3

k="$(ls "$HERE"/boot/vmlinuz-* 2>/dev/null | head -1 || true)"
[ -n "$k" ] || die "no kernel in $HERE/boot"
KVER="${k##*/vmlinuz-}"
[ -d "$HERE/lib/modules/$KVER" ] || die "no modules for $KVER in $HERE/lib/modules"
log "installing $KVER"

if command -v mkinitcpio >/dev/null; then
  INITRD_TOOL=mkinitcpio
elif command -v update-initramfs >/dev/null; then
  INITRD_TOOL=update-initramfs
elif command -v dracut >/dev/null; then
  INITRD_TOOL=dracut
else
  die "no mkinitcpio, update-initramfs or dracut found"
fi

if [ "$EFI_DIR" = auto ]; then
  found=()
  while read -r src mnt _; do
    [[ "$src" == /dev/* ]] || continue
    mnt="$(printf '%b' "$mnt")"
    [[ " ${found[*]} " == *" $mnt "* ]] && continue
    if [ -f "$mnt/bzImage" ]; then
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
  fi
fi
[ -d "$EFI_DIR" ] || die "$EFI_DIR is not a directory"
log "boot partition $EFI_DIR"

rm -rf "/lib/modules/$KVER"
cp -a "$HERE/lib/modules/$KVER" "/lib/modules/$KVER"
depmod -a "$KVER"
log "modules at /lib/modules/$KVER"

install -Dm644 "$HERE/boot/vmlinuz-$KVER" "/boot/vmlinuz-$KVER"
install -Dm644 "$HERE/boot/config-$KVER" "/boot/config-$KVER"
install -Dm644 "$HERE/boot/System.map-$KVER" "/boot/System.map-$KVER"
log "kernel at /boot/vmlinuz-$KVER"

if [ -d "/lib/modules/$KVER/kernel/drivers/net/wireless/nxp-wlan" ]; then
  MOAL_FW=nxp/pcieuartiw620_combo_v1.bin
  MOAL_OPTS="fw_name=$MOAL_FW pcie_int_mode=1 drv_mode=1 cfg80211_wext=4 sta_name=mlan ext_scan=1 wifi_reset_config=0 sched_scan=0 ps_mode=2 auto_ds=2 amsdu_disable=1 auto_fw_reload=0"
  install -d /etc/modprobe.d
  cat > /etc/modprobe.d/ps5-iw620.conf <<EOF
softdep moal pre: cfg80211 mlan
options moal $MOAL_OPTS
EOF
  log "modprobe config at /etc/modprobe.d/ps5-iw620.conf"
  if [ -f "$EFI_DIR/lib/$MOAL_FW" ]; then
    install -Dm644 "$EFI_DIR/lib/$MOAL_FW" "/lib/firmware/$MOAL_FW"
    log "firmware at /lib/firmware/$MOAL_FW"
  fi
fi

case "$INITRD_TOOL" in
  mkinitcpio) mkinitcpio -k "$KVER" -g "/boot/initrd.img-$KVER" ;;
  update-initramfs)
    if [ -e "/boot/initrd.img-$KVER" ]; then
      update-initramfs -u -k "$KVER"
    else
      update-initramfs -c -k "$KVER"
    fi ;;
  dracut) dracut --force "/boot/initrd.img-$KVER" "$KVER" ;;
esac
[ -f "/boot/initrd.img-$KVER" ] || die "initrd was not made"
log "initrd at /boot/initrd.img-$KVER"

new_k="/boot/vmlinuz-$KVER"
new_i="/boot/initrd.img-$KVER"
size_of() { stat -c %s "$1" 2>/dev/null || echo 0; }
grow=$(( $(size_of "$new_k") - $(size_of "$EFI_DIR/bzImage") + $(size_of "$new_i") - $(size_of "$EFI_DIR/initrd.img") ))
free=$(( $(df -B1 --output=avail "$EFI_DIR" | tail -1) ))
[ "$grow" -lt $(( free - 4 * 1024 * 1024 )) ] || die "not enough space in $EFI_DIR (need $grow more bytes, $free free)"

stamp="$(date +%Y%m%d-%H%M%S)"
bdir="$EFI_BACKUP_DIR/$stamp"
mkdir -p "$bdir"
for f in bzImage initrd.img; do
  if [ -f "$EFI_DIR/$f" ]; then
    cp "$EFI_DIR/$f" "$bdir/$f"
  fi
done
log "old boot files saved in $bdir"
ls -1d "$EFI_BACKUP_DIR"/*/ 2>/dev/null | sort | head -n -"$EFI_BACKUP_KEEP" | while read -r old; do
  rm -rf "$old"
  log "removed old backup $old"
done

cp "$new_k" "$EFI_DIR/bzImage"
cp "$new_i" "$EFI_DIR/initrd.img"
sync
cmp "$new_k" "$EFI_DIR/bzImage" || die "bzImage copy differs, restore from $bdir"
cmp "$new_i" "$EFI_DIR/initrd.img" || die "initrd.img copy differs, restore from $bdir"
log "installed $KVER to $EFI_DIR, cold boot the PS5 to run it"
log "to roll back: cp $bdir/{bzImage,initrd.img} $EFI_DIR/ && sync"
