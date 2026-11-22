#!/bin/sh
# Mudi 7 (GL-E5800) post-firmware-update setup
#
# Restores:
#   1. glbattlimit  - battery charge limit at 80% (with GUI toggle)
#   2. LPM timers   - WiFi sleep, Ethernet sleep and auto-shutdown all 60 s
#   3. Repeater watchdog - stop repeater after 60 min disconnected
#                          (so auto-shutdown can happen)
#   4. Speedify     - last, because its installer reboots the router
#
# Usage on the Mudi 7 (as root, via SSH):
#   wget -O /tmp/install.sh https://raw.githubusercontent.com/cdhutzler/mudi7-setup/main/install.sh && sh /tmp/install.sh
#
# Options (environment variables):
#   BATT_LIMIT=80      charge limit percentage
#   LPM_SECONDS=60     WiFi/Ethernet sleep and auto-shutdown time
#
# Safe to run more than once.

BATT_LIMIT="${BATT_LIMIT:-80}"
LPM_SECONDS="${LPM_SECONDS:-60}"
FAILED=""

step() { echo; echo "==> $*"; }
ok()   { echo "    OK: $*"; }
fail() { echo "    FAILED: $*"; FAILED="${FAILED}  - $*
"; }

if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root." >&2
  exit 1
fi

echo "Mudi 7 setup starting: $(date)"

# ---------------------------------------------------------------------------
# 1. Battery charge limit
# ---------------------------------------------------------------------------
step "1/4 Installing glbattlimit (charge limit ${BATT_LIMIT}%)"
if wget -O /usr/bin/glbattlimit \
     https://raw.githubusercontent.com/ChiliApple/mudi7-battery-limit/main/glbattlimit \
   && chmod +x /usr/bin/glbattlimit; then
  glbattlimit status
  if glbattlimit on "$BATT_LIMIT" gui; then
    ok "battery limit set to ${BATT_LIMIT}%"
  else
    fail "glbattlimit on ${BATT_LIMIT} gui"
  fi

  # The limit only applies while a charger is connected and is lost when it
  # is unplugged, so re-apply it every minute via cron.
  CRON=/etc/crontabs/root
  mkdir -p /etc/crontabs
  touch "$CRON"
  sed -i '/# mudi7-battlimit$/d' "$CRON"
  echo "* * * * * /usr/bin/glbattlimit on ${BATT_LIMIT} gui >/dev/null 2>&1 # mudi7-battlimit" >> "$CRON"
  # Quiet cron's per-run syslog entries so the log isn't flooded every minute
  uci set system.@system[0].cronloglevel='9' && uci commit system
  if /etc/init.d/cron enable && /etc/init.d/cron restart; then
    ok "cron job added: re-applies ${BATT_LIMIT}% limit every minute"
  else
    fail "cron setup for glbattlimit"
  fi
else
  fail "download of glbattlimit"
fi

# ---------------------------------------------------------------------------
# 2. Low-power-mode timers
# ---------------------------------------------------------------------------
step "2/4 Setting WiFi/Ethernet sleep and auto-shutdown to ${LPM_SECONDS}s"
if uci set lpm.global.wifi_sleep_time="$LPM_SECONDS" \
   && uci set lpm.global.phy_sleep_time="$LPM_SECONDS" \
   && uci set lpm.global.auto_shutdown_time="$LPM_SECONDS" \
   && uci commit lpm \
   && /etc/init.d/lpm_monitor restart; then
  ok "lpm: wifi_sleep_time=$(uci -q get lpm.global.wifi_sleep_time)" \
     "phy_sleep_time=$(uci -q get lpm.global.phy_sleep_time)" \
     "auto_shutdown_time=$(uci -q get lpm.global.auto_shutdown_time)"
else
  fail "LPM timer settings"
fi

# ---------------------------------------------------------------------------
# 3. Repeater watchdog (runs every minute from cron)
# ---------------------------------------------------------------------------
step "3/4 Installing repeater watchdog"
cat > /root/repeater-watchdog.sh << 'EOF'
#!/bin/sh
STA=wlan4
LIMIT=60                        # minutes disconnected before stopping
CNT=/tmp/repeater-miss         # RAM file, resets on reboot

if iw dev "$STA" link 2>/dev/null | grep -q "Connected to"; then
  rm -f "$CNT"
  exit 0
fi

N=$(( $(cat "$CNT" 2>/dev/null || echo 0) + 1 ))
echo "$N" > "$CNT"

if [ "$N" -ge "$LIMIT" ]; then
  logger "repeater: disconnected ${N} min, stopping"
  /etc/init.d/repeater stop
  rm -f "$CNT"
fi
EOF
chmod +x /root/repeater-watchdog.sh

# Remove the older rc.local version of this, if an earlier run added it
if [ -f /etc/rc.local ]; then
  sed -i '/# BEGIN mudi7-repeater-timeout/,/# END mudi7-repeater-timeout/d' /etc/rc.local
fi

CRON=/etc/crontabs/root
mkdir -p /etc/crontabs
touch "$CRON"
sed -i '/# mudi7-repeater-watchdog$/d' "$CRON"
echo "* * * * * /root/repeater-watchdog.sh # mudi7-repeater-watchdog" >> "$CRON"
if /etc/init.d/cron enable && /etc/init.d/cron restart; then
  ok "repeater watchdog installed and scheduled every minute"
else
  fail "cron setup for repeater watchdog"
fi

# ---------------------------------------------------------------------------
# Report results before Speedify, since its installer reboots the router
# and this output would be lost.
# ---------------------------------------------------------------------------
if [ -n "$FAILED" ]; then
  echo
  echo "Some steps failed:"
  printf '%s' "$FAILED"
  echo
  echo "Stopping before Speedify. Fix the issue and re-run this script (it is safe to repeat)."
  exit 1
fi
echo
echo "Steps 1-3 completed successfully."

# ---------------------------------------------------------------------------
# 4. Speedify (last - its installer reboots the router)
# ---------------------------------------------------------------------------
step "4/4 Installing Speedify (the router will reboot when it finishes)"
# Download first rather than piping, so a failed download is caught and the
# installer doesn't compete with this script for stdin.
if wget -q https://get.speedify.com -O /tmp/speedify-install.sh \
   && sh /tmp/speedify-install.sh; then
  echo "    OK: Speedify installed"
else
  echo "    FAILED: Speedify install. Re-run this script to try again."
  exit 1
fi
