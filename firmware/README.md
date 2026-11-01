# VCN firmware

ps5_vcn.bin is just amd's navi10 vcn firmware with 2 patches.
it gets built into the kernel (CONFIG_EXTRA_FIRMWARE), so no need to copy it anywhere.

stock firmware waits for the smu to answer, ps5 smu never does, so vcn never comes up. the patches skip that.

## Stock firmware

you need navi10_vcn.bin rev 9 (ENC 1.24 DEC 8).
linux-firmware tags 20251125 to 20260622 have it.
newer ones wont work, the script will just say `Unexpected instruction at 0xfd2d`.

```bash
curl -LO https://gitlab.com/kernel-firmware/linux-firmware/-/raw/20260622/amdgpu/navi10_vcn.bin
sha256sum navi10_vcn.bin
```

sha256 should be `ac5f2182b0ddee7a2886bf1239a47b4027becd0c37a1b0b6cac1f335393302c9`.

dont grab the one from your distro, its probably newer and compressed anyway.

## Usage

```bash
python3 firmware/amdgpu/patch_vcn_navi10fw.py navi10_vcn.bin ps5_vcn.bin
```

output should be the same as ps5_vcn.bin in this repo (sha256 `bbd15ab65e76178c2918e8224b6ab4ab1711f1b59d935ee131ab188a9712e596`).

## What it patches

- `0xfd2d`: `16 fe 0e` -> `f0 20 00`, skips the smu wait on boot
- `0x10977`: `8c 28` -> `3d f0`, runtime smu helper returns without sending anything

then it fixes the payload crc32 at `0x1c`.

# Viola firmware (PS5 Pro)

ps5-linux-loader dumps the PS5 Pro gpu firmware to the boot partition, `/boot/efi/lib/firmware/amdgpu/`.
amdgpu uses it instead of the cyan skillfish firmware (`cyan_skillfish2_*.bin`) only if all 8 files load and have a valid header:

```
viola_ce.bin  viola_me.bin  viola_mec.bin  viola_mec2.bin
viola_pfp.bin viola_rlc.bin viola_sdma.bin viola_sdma1.bin
```

they get the same sony header handling as the cyan skillfish files, so they need the same format.

every ps5 pro change only turns on with the viola firmware:

- amdgpu: golden settings, 64 cus (`max_cu_per_sh = 16`, pro mask for `amdgpu.ps5_cu_unlock`) and the smu backend (gpu clock, temperature and `gpu_busy_percent`)
- mp1: bapm set 3 and 30 active wgps requested from the smu, the extra `/dev/mp1` queries
- `ps5-gpufreq` gpu clock scaling, 500-2350 mhz, holding the soc at `ps5_gpufreq.temp_limit` (85 c by default)

without it a ps5 pro (gpu `1002:13da` or `1002:13dc`) runs like before them, and gets no `ps5-gpufreq`: its smu mailbox stops answering under the cyan skillfish firmware.
a base ps5 gets `ps5-gpufreq` only (500-2230 mhz), the bc-250 is not affected, and the staging service does nothing on either.
`amdgpu.ps5_viola_fw=0` keeps the cyan skillfish firmware.

## Staging

amdgpu loads from the initramfs, before `/boot/efi` is mounted, so the files have to be in the initrd.
`ps5-stage-gpu-firmware` does that at boot:

- if all 8 files are in `/boot/efi/lib/firmware/amdgpu/`, copies them to `/usr/lib/firmware/amdgpu/` (all or nothing)
- rebuilds `/boot/initrd.img-$(uname -r)` (update-initramfs, mkinitcpio or dracut)
- copies it to `/boot/efi/initrd.img` if it has all 8 files, the old one is kept as `initrd.img.old`

nothing happens if a file is missing or nothing changed.
amdgpu uses the firmware from the next boot on, so run the loader again after it.

```bash
sudo install -Dm755 firmware/amdgpu/ps5-stage-gpu-firmware /usr/local/sbin/ps5-stage-gpu-firmware
sudo install -Dm644 firmware/amdgpu/ps5-stage-gpu-firmware.service /etc/systemd/system/ps5-stage-gpu-firmware.service
sudo systemctl enable ps5-stage-gpu-firmware.service
```

check with `journalctl -u ps5-stage-gpu-firmware` and `sudo dmesg | grep "PS5 Pro"`.
