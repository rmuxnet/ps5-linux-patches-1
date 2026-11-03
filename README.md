# ps5-linux-patches

Linux patches and kernel config for the PS5.
This is a fork of [ps5-linux/ps5-linux-patches](https://github.com/ps5-linux/ps5-linux-patches).
The patch targets stable 7.3.1.

## Disclaimer

**This fork is for experimental work. Things can break.**

Do not rename this kernel and ship it as your own fork.
Renamed forks are not allowed right now.
We do not need millions of renamed kernels that are the same code and claim to be optimized or faster.

If you use anything from this repo, credit it.
This work will be merged into [ps5-linux/ps5-linux-patches](https://github.com/ps5-linux/ps5-linux-patches) over time.

To contribute, fork this repo and open a pull request.
Changes do not get in any other way.
AI generated slop will not be merged.

## Build with build.sh

Run this on the PS5.

### What you need

Arch:

```bash
sudo pacman -S --needed base-devel git bc cpio libelf clang lld llvm ccache mkinitcpio
```

Ubuntu:

```bash
sudo apt install build-essential bc bison flex libssl-dev libelf-dev libncurses-dev dwarves git clang lld llvm ccache
```

`ccache` is only needed with `CCACHE=y` (the default).

### Steps

```bash
git clone https://github.com/rmuxnet/ps5-linux-patches-1 ps5-linux-patches
cd ps5-linux-patches
./build.sh
```

The script clones the tag set in `KERNEL_REF` in `build.cfg` (now `v7.3.1`) into `../linux`, applies the patch and builds with clang.
Release tags like `v7.3` come from mainline. Point releases like `v7.3.1` come from the stable tree.
It installs the modules, backs up the boot partition to `/boot/efi-backup/<date>` and copies the new kernel and initrd there.
The script looks for a mounted partition with `bzImage` on it and asks if it is the right one.
Press Enter or `y` to use it. Press `n` to type the path yourself.
To skip the question, set `EFI_DIR` in `build.cfg`.
Cold boot the PS5 after that.

The tree in `../linux` stays between runs, so the next build is faster.

### Options

All options are in `build.cfg`. To use your own file:

```bash
cp build.cfg my.cfg
./build.sh my.cfg
```

### Wi-Fi

The Wi-Fi driver (NXP mwifiex) is in `oot/mwifiex`, already patched for 7.3.
`build.sh` copies it to `drivers/net/wireless/nxp-wlan` and builds it with the kernel.
Nothing else is needed.

MT7921 PCIe Wi-Fi (`CONFIG_MT7921E`) is testing and off by default.
To turn it on, set `CONFIG_MT7921E=m` in `.config`.

### Roll back

The script prints the backup folder. Copy the old files back:

```bash
sudo cp /boot/efi-backup/<date>/{bzImage,initrd.img} <boot partition>/
sync
```

Then cold boot.

## Build by hand

```bash
git clone https://github.com/rmuxnet/ps5-linux-patches-1 ps5-linux-patches
git clone --depth 1 --branch v7.3.1 https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
cd linux
git apply ../ps5-linux-patches/linux.patch
cp ../ps5-linux-patches/.config .config
make LLVM=1 olddefconfig
make LLVM=1 -j$(nproc)
sudo make LLVM=1 INSTALL_MOD_STRIP=1 modules_install
```

Use the tag from the first lines of `.config`.
Keep the folder name `ps5-linux-patches`. The `.config` loads the VCN firmware from `../ps5-linux-patches/firmware`.
The `.config` is made with clang, so always pass `LLVM=1`.

For Wi-Fi, copy the driver into the tree before you build:

```bash
cp -a ../ps5-linux-patches/oot/mwifiex drivers/net/wireless/nxp-wlan
sed -i 's/\$(CONFIG_NXP_WLAN_DRIVER)/m/g' drivers/net/wireless/nxp-wlan/Makefile
echo 'obj-m += nxp-wlan/' >> drivers/net/wireless/Makefile
```

`make install` does not copy the kernel on the PS5. Copy it to the boot partition and make an initrd.
This example uses `/boot/efi`:

```bash
KVER=$(make -s kernelrelease LLVM=1)
sudo cp arch/x86/boot/bzImage /boot/efi/bzImage
sudo mkinitcpio -k $KVER -g /boot/efi/initrd.img
```

Back up the old `bzImage` and `initrd.img` before you do this.

## Clock scaling

- `ps5-cpufreq`: CPU P-states through the SMU. The boost states (3.3 to 3.5 GHz) are off until you turn boost on.
- `ps5-gpufreq`: GPU clock through the SMU with devfreq, at `/sys/class/devfreq/`.
  Base, slim and fat: 400 to 2230 MHz. PS5 Pro: 500 to 2350 MHz.

## Off by default

Add to `cmdline.txt` to turn on:

- `usbc_dp.enable=1`: USB-C DP output, only for USB-C DP devices such as PSVR2.
  It resets any USB device on the front USB-C port, so leave it off when booting from it.

## TODO

- amdgpu smu driver to show correct gpu frequency and temperature on the base ps5

## Bugs

- screen save does not work properly
- hdmi audio output does not work on some monitors
- hdmi 1440p and 2160p video output does not work on some monitors
