# UPS-Watchdog for Synology DSM

Driver, status app and power-failure handling for USB UPSes with the
**RICHCOMM "UPS USB Mon V2.0"** interface (USB ID `0925:1234`), e.g. the
**Vultech UPS1000VA-PURE**. DSM's built-in UPS drivers cannot talk to this chip.

Version 3.0.3 · Licence GPL-2.0-or-later · Source: <https://github.com/gkn202/synology-ups-watchdog>

A full technical description (system layout, components, power-failure sequence, app layout) is available on request: [gary.kneip@infinis.lu](mailto:gary.kneip@infinis.lu?subject=UPS-Watchdog%20%E2%80%93%20full%20description%20request).

---

## 1. How it works

- A statically linked **Network UPS Tools `nutdrv_qx`** driver (subdriver
  `richcomm-svc`, fallback `armac`) reads the UPS over USB. A small patch adds
  `battery_voltage_divisor`, because some models report a multiple of the real
  battery voltage.
- DSM's own `upsd` serves the data on `127.0.0.1` with a private configuration
  in `/run/ups-watchdog/nut`. `/etc/ups` is not touched.
- A **watchdog** (root, started by a boot task) checks the UPS every 5 seconds:
  - **On battery:** after the configured time (default **5 minutes**) the NAS
    is **powered off cleanly**. With "0 minutes" it powers off only when the
    UPS reports "battery low".
  - **Power returns in time:** the shutdown is cancelled.
  - **The UPS stops answering:** after 30 s the driver is restarted. If the USB
    chip has hung, the watchdog **resets the USB port automatically** (same as
    unplugging the cable).
- **DSM's own UPS support stays off.** DSM's "Standby" mode never wakes up by
  itself, and cutting the UPS output would also switch off the router, switch
  and smart-home devices on the same UPS.
- **Wake-up** after power returns: Wake-on-LAN from a smart plug on plain mains
  (see section 4). Backup: if the battery ran completely flat, DSM's
  "restart automatically when power supply issue is fixed" starts the NAS.

## 2. Requirements

| | |
|---|---|
| NAS | Synology with **x86_64** CPU and DSM 7 (tested: DS923+, DSM 7.3). Check with `uname -m`. ARM models are not supported. |
| UPS | USB chip `0925:1234` "RICHCOMM UPS USB Mon V2.0" (tested: Vultech UPS1000VA-PURE, 1 × 12 V / 9 Ah). Same chip in other Vultech, Armac, ExeGate, SVC and Accurat models. |
| Wake-up | A smart plug with ESPHome (e.g. NOUS A1T) in a wall socket **not** on the UPS, or any other device that can send Wake-on-LAN. |

## 3. Installation and setup

1. **Package Center → Manual Install** → select the `.spk`. Choose the battery
    voltage in the wizard (12 V for one battery).
2. **Control Panel → Task Scheduler → Create → Triggered Task → User-defined script**

    | Field | Value |
    |---|---|
    | Task | `UPS-Watchdog` |
    | User | **root** |
    | Event | **Boot-up** |
    | Run command | `sleep 30`<br>`/var/packages/UPSWatchdog/target/bin/ups-watchdog.sh start` |

3. Select the new task and click **Run** once (or restart the NAS).
4. **Control Panel → Hardware & Power → UPS:** leave UPS support **off**.
5. **Control Panel → Hardware & Power → General:** enable
   **"Restart automatically when power supply issue is fixed"** and
   **"Enable WOL on LAN 1"** (on the LAN port that is actually connected).
6. Set up the wake-up plug (section 4).
7. Open **UPS-Watchdog** from the DSM main menu. The setup steps show a ✓ when
   they are done.

**After every package update, run the boot task once** so the new watchdog
version is active.

## 4. Wake-up plug with ESPHome

The plug sits in a **wall socket that is not on the UPS**, on the same LAN/Wi-Fi
as the NAS. When mains returns it boots, waits 60 s for the network and sends a
Wake-on-LAN packet every 30 s for about 10 minutes.

> ### ⚠ Adapt the MAC address
>
> `target_mac_address` must be the MAC address of **your** NAS – of the LAN
> port on which WOL is enabled. The value below is only a placeholder.
>
> Where to find it:
>
> - in the **UPS-Watchdog app**, setup step 5: the block there already
>   contains the correct MAC of your NAS and can be copied as is;
> - or **Control Panel → Network → Network Interface → LAN 1** (the MAC
>   address is shown in the details);
> - or via SSH: `cat /sys/class/net/eth0/address`.
>
> With a wrong MAC the NAS **stays off** after a power failure until someone
> presses the power button.

Add to the plug's ESPHome configuration. Put `on_boot` **inside the existing
`esphome:` section** – do not create a second one:

```yaml
button:
  - platform: wake_on_lan
    id: wol_nas
    name: "WOL NAS"
    target_mac_address: AA:BB:CC:DD:EE:FF   # <-- MAC of YOUR NAS

esphome:
  # keep name, board etc. as they are
  on_boot:
    priority: -100
    then:
      - wait_until:
          condition: wifi.connected
          timeout: 120s
      - delay: 60s
      - repeat:
          count: 20
          then:
            - button.press: wol_nas
            - delay: 30s
```

Recommended: give the plug a fixed IP (`wifi: manual_ip:`), so it comes up
quickly after a power failure.

**Test without a power failure:** shut the NAS down, then press the button
"WOL NAS" in the ESPHome web page / Home Assistant – the NAS must start. Then
pull the plug out of the socket and put it back: after about 1–2 minutes the
NAS starts.

**Complete firmware for the NOUS A1T:** the package contains the full ESPHome
configuration `doc/wake-plug/ups-wake.yaml` (ESP8285, relay GPIO14, LED GPIO13,
Wi-Fi setup network "UPS-Wake-Setup"). Set `nas_mac`, compile with ESPHome, and
upload the gzipped `.bin` through the plug's Tasmota "Firmware Upgrade" page.

**Tasmota cannot do this:** the plug is sold with Tasmota, which has no
Wake-on-LAN command. It must be reflashed with the ESPHome firmware above.

## 5. The app

- **Status:** on line / on battery / battery low, charge, battery voltage,
  load, temperature, input/output voltage, frequency, beeper.
- **On mains:** the tile "Power off set to" shows the configured time.
- **On battery:** a live countdown "NAS powers off in …" and the estimated
  **battery time left** (from charge and load; 800 W, 12 V / 9 Ah).
- **Red warning "Watchdog not running":** the NAS would **not** power off on a
  power failure. Run the boot task.
- **Search USB port:** restarts the driver; if the UPS does not answer, the USB port is reset.

The UPS reports no charge percentage; it is estimated from the battery voltage.
Under load on battery the estimate is rough.

## 6. Settings (app → "Settings & log")

| Setting | Default | Meaning |
|---|---|---|
| Power off after | 5 min | Minutes on battery before the NAS powers off. 0 = only at "battery low". |
| NAS LAN IP | auto | Only needed with several network ports. |
| Battery nominal voltage | 12 V | 12 / 24 / 36 / 48 V. |
| Battery voltage divisor | auto | Corrects models that report a multiple of the real voltage. |
| Battery full / empty | 13.1 V / 10.4 V per 12 V | Used for the charge estimate. |
| Subdriver | auto | `richcomm-svc`, fallback `armac`. |

Run the boot task again after saving.

## 7. Troubleshooting

| Symptom | Cause / remedy |
|---|---|
| App still shows old content after an update | Browser cache. Open `http://<NAS>:5000/webman/3rdparty/UPSWatchdog/index.html`, press Cmd+Shift+R (Ctrl+F5), reopen the app. Check the version in the footer. |
| "Watchdog not running" | Boot task missing, disabled, not run as root, or not run after an update. Run it. |
| "No connection – chip found, but the UPS does not answer" | USB chip hung (e.g. after a long time on battery). From 3.0.2 the watchdog resets the USB port by itself; otherwise unplug the USB cable for 10 s or switch the UPS off and on. |
| "No Richcomm chip found" | USB cable, other UPS model (the app names other UPS chips it finds). |
| NAS does not start after power returns | Wrong MAC in the plug, WOL not enabled on the connected LAN port, plug on the UPS instead of the wall, or plug not on the same LAN. |
| DSM goes to standby and never wakes up | DSM's UPS support is switched on. Switch it off. |

Log: app → "Settings & log", or `/var/packages/UPSWatchdog/var/root.log`.

## 8. Uninstalling

1. Edit the boot task: replace `start` with `remove` at the end of the command,
   run it once.
2. Delete the task.
3. Uninstall the package in Package Center.

## 9. Credits and licence

- [Network UPS Tools](https://networkupstools.org) (GPL-2.0-or-later) –
  `nutdrv_qx`, `richcomm-svc` subdriver
  ([NUT #3667](https://github.com/networkupstools/nut/issues/3667)).
- Related reports: [NUT #2219](https://github.com/networkupstools/nut/issues/2219)
  (Vultech UPS1400VA-LFP), [NUT #2738](https://github.com/networkupstools/nut/issues/2738)
  (Vultech UPS2000VA-PRO),
  [lvl47's gist](https://gist.github.com/lvl47/a280c7d1a0a8a489c084c83b8f28f054) (Accurat Flux 850).
- [libusb](https://libusb.info) (LGPL-2.1).

**Source of the driver binary:** `nutdrv_qx` is built from NUT commit
`3b79a0fa8` with the patch `nut/0001-nutdrv_qx-battery_voltage_divisor.patch`
and libusb 1.0.27 (without udev) by `build/build-nutdrv_qx.sh` in the
project repository.

This package: GPL-2.0-or-later, © gkn202. No warranty – test the power-off
and wake-up with your own setup.
