# mudi7-setup
Mudi7 Setup with power management, Speedify, and 80% battery charge limit

One-command restore of my custom software and settings on a GL.iNet Mudi 7 (GL-E5800) after a firmware update.

## What it does

1. Installs [glbattlimit](https://github.com/ChiliApple/mudi7-battery-limit) and sets the charge limit to 80% (with GUI toggle). A cron job re-applies it every minute, because the limit only takes effect while a charger is connected and is lost when it's unplugged
2. Installs Speedify
3. Sets WiFi sleep, Ethernet sleep and auto-shutdown timers to 60 seconds
4. Installs `/root/repeater-watchdog.sh`, run every minute by cron, which stops repeater mode after 2 minutes disconnected so auto-shutdown can kick in
5. Reboots

## Usage

SSH into the Mudi 7 as root, then:

```sh
wget -O /tmp/install.sh https://raw.githubusercontent.com/cdhutzler/mudi7-setup/main/install.sh && sh /tmp/install.sh
```

The router needs internet access (for glbattlimit and Speedify downloads).

If any step fails, the script prints what failed and **does not reboot**. It is safe to re-run.

### Options

Set before `sh`, e.g. `NO_REBOOT=1 sh /tmp/install.sh`

| Variable | Default | Meaning |
|---|---|---|
| `NO_REBOOT` | `0` | `1` skips the final reboot |
| `BATT_LIMIT` | `80` | Charge limit % |
| `LPM_SECONDS` | `60` | WiFi/Ethernet sleep and auto-shutdown time |

## Notes

- The repeater check assumes the station interface is `wlan4`. If a future firmware renames it, check with `iw dev` and edit `STA=` in the watchdog section of `install.sh`.
- Check the battery cron job with: `cat /etc/crontabs/root`
- Check the repeater log after a boot with: `logread | grep repeater`
