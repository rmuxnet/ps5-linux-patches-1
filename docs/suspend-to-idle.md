# Suspend-to-idle on the PS5

## Overview

The PS5 kernel supports suspend-to-idle (s2idle).
The PS5 has no ACPI. Thus s2idle is the only sleep state.
In s2idle, the kernel stops all tasks and puts the devices to sleep.
The power button wakes the system.
When the system wakes, all tasks continue from the same point.
A game that runs before sleep continues after sleep.

## Kernel configuration

Set `CONFIG_SUSPEND=y`.
The kernel then also sets `CONFIG_PM_SLEEP=y`.

## How to use

1. Start the sleep: push the power button for a short time, or use `systemctl suspend`.
   In game mode, you can also use the Sleep button of Steam.
2. Make sure that the screen goes dark and that the indicator becomes orange.
3. To wake the system, push the power button for a short time.
   The system controller makes one short beep.

The power button is the only wake source.
The Bluetooth controller disconnects from the DualSense during sleep.
After sleep, push the PS button to connect the controller again.

## Parameters

| Parameter | Default | Effect |
|---|---|---|
| `spcie.wake_beep` | `Y` | One short beep when the system wakes. |
| `spcie.sleep_led` | `Y` | Orange indicator during sleep. The previous indicator setting comes back after sleep. |

## Driver changes

### spcie (Salina glue, `drivers/ps5/spcie.c`)

The system controller (ICC) sends the power button, fan, HDMI and thermal messages.
These messages go through the ICC mailbox of the spcie function.

Before this change, spcie had no PM callbacks.
Thus the PCI core cleared bus mastering before sleep.
The ICC interrupt then stopped, and the power button could not wake the system.

The changes are:

- In the `suspend_noirq` callback, the driver saves the PCI state.
  Thus the PCI core keeps the function in D0 with bus mastering on.
- The ICC interrupt uses `IRQF_NO_SUSPEND`.
  The interrupt stays on during sleep.
  A wake interrupt is not correct here, because thermal and HDMI messages also use this interrupt.
  These messages must not wake the system.
- During sleep, a power button push calls `pm_wakeup_dev_event()`.
  This wakes the system.
- During sleep, the driver does not send button messages to the input device.
  If user space gets `KEY_POWER`, it can start a new sleep immediately.
- A PM notifier does the work before and after sleep:
  - Before sleep, it sets the indicator to orange.
  - After sleep, it sends the last indicator setting again, and makes one beep.
  - After sleep, it sends `KEY_WAKEUP`. The ACPI button driver does the same.
- During sleep, the driver keeps ICC notifications in its queue.
  The driver processes them after sleep, when the GPU and the displays are on again.
  If the driver processes an HDMI message during sleep, the EDID read fails.
  The connector then has no modes, and the screen stays dark after sleep.

### led (`drivers/ps5/led/core.c`)

The LED class devices do not use `LED_CORE_SUSPENDRESUME`.
With this flag, the LED core turned the indicator off before sleep.
After sleep, the indicator stayed off.
Now spcie sets the indicator before and after sleep.

### mts (Ethernet, `drivers/net/phy/mts/mts_main.c`)

Before this change, mts had no PM callbacks.
The PCI core cleared bus mastering while RX DMA was active.
The MAC then reported `HW error 0x20000 rx-axi`.
After resume, RX did not work until reboot.

The changes are:

- At suspend, the driver stops the queue, the link poll, NAPI and DMA.
  This is the same sequence as `ndo_stop`.
- At resume, the driver does the full bringup again.
  This is the same sequence as `ndo_open`.
- At resume, the driver also writes the RX filter again.
  The MAC reset in `gbe_init_hw()` clears the RX filter.

### ahci_salina (SATA, `drivers/ata/ahci_salina.c`)

The PM code did not compile with `CONFIG_PM_SLEEP=y`.
`ata_host_suspend()` returns no value.
The change removes the return value check.

### amdgpu (display)

Without ACPI, amdgpu does not do a suspend for s2idle.
The GPU stays on, and the screen shows the last frame.

On the PS5, amdgpu now turns off the displays at suspend.
It uses the same state cache as the full suspend: `dm_cache_state()`.
At resume, it uses `dm_destroy_cached_state()` to turn on the displays again.
The modeset at resume also configures the HDMI bridge again.

### Salina xHCI (Bluetooth, `drivers/usb/host/xhci*.c`)

The IW620 Bluetooth controller is a USB device (1286:2059) on the Salina xHCI (104d:9108).

Interrupts:

- The Salina xHCI does not clear `IMAN.IP` after it sends an MSI.
  Thus the controller sent only one interrupt after boot.
- The driver now clears `IMAN.IP` itself (`ip_autoclear = false`).
  The controller now sends one interrupt for each event.

Sleep:

- The Bluetooth controller does not accept a USB suspend.
  When its port goes to U3, the port goes to the Resume state without a port change.
  After sleep, the device disconnects and comes back at full speed only.
  It then stays in this state until power off.
- Thus, during s2idle, the Salina xHCI stays on, and its ports stay in U0:
  - `xhci_pci_suspend()` and `xhci_pci_resume()` do not halt or restart the controller.
    The driver keeps one more `pci_enable_device()` reference during sleep.
    Thus `pci_disable_device()` in `suspend_common()` does not clear bus mastering.
  - `SetPortFeature(USB_PORT_FEAT_SUSPEND)` does nothing for the Salina ports.
  - `xhci_bus_suspend()` does not set U3 on the Salina ports.
  - The Salina xHCI interrupt is not a wake source.
- The Salina xHCI does not go to D3 (`PCI_DEV_FLAGS_NO_D3`).
  The PHY setup from `xhci_salina_init()` does not survive D3.
- The software poller stops during sleep and starts again after sleep.
  If the poller runs during sleep, the system can stop in sleep.
- The poller does not read the registers while the controller is not accessible.
  Before this change, the poller read `0xffffffff` during sleep and marked the controller dead.

## Limits

- The GPU and its memory stay on during sleep.
- The kernel command line has `idle=halt`. Thus the CPU cores stay in C1.
- Thus the power decrease is small. This is not the rest mode of the PS5 system software.
- The Bluetooth controller and the Salina xHCI stay on during sleep.
- A DualSense cannot wake the system.

## Test procedure

Use `CONFIG_PM_DEBUG=y` for steps 1 and 2.

1. Write `freezer` to `/sys/power/pm_test`, then write `freeze` to `/sys/power/state`.
   The system stops all tasks for 5 seconds, then continues.
2. Do step 1 again with `devices`, then with `platform`.
3. Write `none` to `/sys/power/pm_test`, then write `freeze` to `/sys/power/state`.
   Wake the system with the power button.
4. Start a sleep and wake the system five times, one after the other.
5. After each sleep, make sure that these items work: display, audio, Ethernet, Wi-Fi, Bluetooth.
6. After each step, examine `dmesg`.
   Make sure that there are no new warnings or errors.
