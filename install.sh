#!/bin/sh
# Mudi 7 (GL-E5800) post-firmware-update setup
#
# Restores:
#   1. glbattlimit  - battery charge limit at 80% (with GUI toggle)
#   2. LPM timers   - WiFi sleep, Ethernet sleep and auto-shutdown all 60 s
#   3. mudi-sms     - send SMS directly through the modem AT port
#                     (the GL web UI outbox stalls)
#   4. Repeater watchdog - stop repeater after 60 min disconnected
#                          (so auto-shutdown can happen) and text a warning
#   5. Speedify     - last, because its installer reboots the router
#
# Usage on the Mudi 7 (as root, via SSH):
#   wget -O /tmp/install.sh https://raw.githubusercontent.com/cdhutzler/mudi7-setup/main/install.sh && sh /tmp/install.sh
#
# Options (environment variables):
#   BATT_LIMIT=80      charge limit percentage
#   LPM_SECONDS=60     WiFi/Ethernet sleep and auto-shutdown time
#   SMS_TO=+1...       phone number for alerts (otherwise asked for once,
#                      then kept in /etc/mudi-sms.conf, never in this repo)
#
# Safe to run more than once.

BATT_LIMIT="${BATT_LIMIT:-80}"
LPM_SECONDS="${LPM_SECONDS:-60}"
SMS_TO="${SMS_TO:-}"
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
step "1/5 Installing glbattlimit (charge limit ${BATT_LIMIT}%)"
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
step "2/5 Setting WiFi/Ethernet sleep and auto-shutdown to ${LPM_SECONDS}s"
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
# 3. mudi-sms (SMS straight through the modem AT port)
# ---------------------------------------------------------------------------
step "3/5 Installing mudi-sms"
cat > /usr/bin/mudi-sms << 'EOF'
#!/bin/sh
# mudi-sms: send an SMS straight through the Mudi 7 modem AT port,
# bypassing the GL web UI outbox.
#
# Usage:  mudi-sms "message text"            (number from /etc/mudi-sms.conf)
#         mudi-sms "+17035551234" "message"  (explicit number)
#
# Exit code 0 = modem confirmed send (+CMGS), 1 = failed. Result goes to logread.

PORT=/dev/at_mdm0
CONF=/etc/mudi-sms.conf
OUT=/tmp/mudi-sms.$$

if [ $# -ge 2 ]; then
  NUM="$1"; MSG="$2"
else
  [ -f "$CONF" ] && . "$CONF"
  NUM="$SMS_TO"; MSG="$1"
fi

if [ -z "$NUM" ] || [ -z "$MSG" ]; then
  echo "usage: $0 [number] \"message\"" >&2
  exit 1
fi

if [ ! -c "$PORT" ]; then
  logger -t mudi-sms "AT port $PORT not found"
  exit 1
fi

cat "$PORT" > "$OUT" &
CATPID=$!
sleep 1

printf 'AT+CMGF=1\r' > "$PORT"; sleep 1
printf 'AT+CMGS="%s"\r' "$NUM" > "$PORT"; sleep 2
printf '%s\032' "$MSG" > "$PORT"     # \032 = Ctrl-Z, ends the message

i=0
while [ $i -lt 30 ]; do
  grep -qE '\+CMGS:|ERROR' "$OUT" && break
  sleep 1
  i=$((i + 1))
done
kill $CATPID 2>/dev/null

if grep -q '+CMGS:' "$OUT"; then
  logger -t mudi-sms "sent to $NUM: $MSG"
  rm -f "$OUT"
  exit 0
else
  logger -t mudi-sms "send to $NUM failed: $(tr '\r\n' '  ' < "$OUT")"
  rm -f "$OUT"
  exit 1
fi
EOF
chmod +x /usr/bin/mudi-sms

# Phone number lives only on the device, never in the public repo.
if [ -n "$SMS_TO" ]; then
  echo "SMS_TO=\"$SMS_TO\"" > /etc/mudi-sms.conf
elif [ ! -f /etc/mudi-sms.conf ]; then
  printf "    Phone number for SMS alerts (e.g. +17035551234), blank to skip: "
  read -r SMS_NUM < /dev/tty
  [ -n "$SMS_NUM" ] && echo "SMS_TO=\"$SMS_NUM\"" > /etc/mudi-sms.conf
fi
# Keep the number across firmware updates that preserve settings
grep -qx '/etc/mudi-sms.conf' /etc/sysupgrade.conf 2>/dev/null \
  || echo '/etc/mudi-sms.conf' >> /etc/sysupgrade.conf

if [ -f /etc/mudi-sms.conf ]; then
  ok "mudi-sms installed, alerts go to $(. /etc/mudi-sms.conf; echo "$SMS_TO")"
else
  ok "mudi-sms installed (no number set, alerts disabled)"
fi

# ---------------------------------------------------------------------------
# 4. Repeater watchdog (runs every minute from cron)
# ---------------------------------------------------------------------------
step "4/5 Installing repeater watchdog"
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
  # Text a warning before stopping (skipped if no number is configured)
  if [ -x /usr/bin/mudi-sms ] && [ -f /etc/mudi-sms.conf ]; then
    SECS=$(uci -q get lpm.global.auto_shutdown_time)
    /usr/bin/mudi-sms "Mudi: repeater offline ${N} min. Shutting down due to inactivity in about ${SECS:-60}s."
  fi
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
echo "Steps 1-4 completed successfully."

# ---------------------------------------------------------------------------
# 5. Speedify (last - its installer reboots the router)
# ---------------------------------------------------------------------------
step "5/5 Installing Speedify (the router will reboot when it finishes)"
# Download first rather than piping, so a failed download is caught and the
# installer doesn't compete with this script for stdin.
if wget -q https://get.speedify.com -O /tmp/speedify-install.sh \
   && sh /tmp/speedify-install.sh; then
  echo "    OK: Speedify installed"
else
  echo "    FAILED: Speedify install. Re-run this script to try again."
  exit 1
fi
