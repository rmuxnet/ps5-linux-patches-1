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
