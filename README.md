# ps5-linux-patches

## Compilation

```bash
git clone https://github.com/ps5-linux/ps5-linux-patches
git clone https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
cd linux
git checkout "tags/v$(grep -m1 "^# Linux/" ../ps5-linux-patches/.config | awk '{print $3}')"
git apply ../ps5-linux-patches/linux.patch
cp ../ps5-linux-patches/.config .config
make -j$(nproc)
```

## Installation

In the same `linux` folder after compilation, do:

```bash
sudo make modules_install && sudo make install
```

On a PS5 Pro, also install the Viola firmware service, see [firmware/README.md](firmware/README.md#viola-firmware-ps5-pro).

## TODO

- amdgpu smu driver to show correct gpu frequency and temperature on the base ps5

## Bugs

- screen save does not work properly
- hdmi audio output does not work on some monitors
- hdmi 1440p and 2160p video output does not work on some monitors

## Off by default

These work in testing but have only been tried on a few displays and
consoles, so they stay off until more people have tested them. Add to
`cmdline.txt` to turn on:

- `hdmi.frl_4k120=1`: native FRL on FLAVA3, including 4K100/120
- `hdmi.frl_recovery=1`: retry with a lower format or depth when FRL fails
- `hdmi.frl_yuv420=1`: use 4:2:0 over FRL when RGB doesn't fit, `2` to prefer it
- `hdmi.allm=1`: ALLM while the content type is Game, `2` for always
- `usbc_dp.enable=1`: USB-C DP output, only for USB-C DP devices such as PSVR2;
  it resets any USB device on the front USB-C port, so leave it off when booting from it
