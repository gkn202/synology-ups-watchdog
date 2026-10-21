#!/bin/sh
# status.cgi - JSON status for the UPS-Watchdog app (runs as package user)
PKG=UPSWatchdog
V=/var/packages/$PKG/var
T=/var/packages/$PKG/target

USER_NAME="$(/usr/syno/synoman/webman/modules/authenticate.cgi 2>/dev/null)"
if [ -z "$USER_NAME" ]; then
    printf 'Status: 401 Unauthorized\r\nContent-Type: application/json\r\n\r\n{"error":"not logged in"}\n'
    exit 0
fi

json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r\n'; }
state_val() { [ -f "$V/root_state" ] && sed -n "s/^$1=//p" "$V/root_state" | tr -d '"' | head -1; }
set_val()   { [ -f "$V/settings" ] && sed -n "s/^$1=//p" "$V/settings" | tr -d '"' | head -1; }

printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
printf '{'
printf '"user":"%s",' "$(json_str "$USER_NAME")"
printf '"version":"%s",' "$(json_str "$(sed -n 's/^version="\(.*\)"/\1/p' /var/packages/$PKG/INFO 2>/dev/null)")"
printf '"driver":"%s",' "$(json_str "$("$T/bin/nutdrv_qx" -V 2>/dev/null | head -1)")"
NOW="$(date +%s)"; UP="$(cut -d. -f1 /proc/uptime 2>/dev/null)"
printf '"boot_epoch":%s,"root_epoch":%s,' "$(( NOW - ${UP:-0} ))" "$(state_val EPOCH | grep -E '^[0-9]+$' || echo 0)"
printf '"root":{"result":"%s","message":"%s","nas_ip":"%s","time":"%s"},' \
    "$(json_str "$(state_val RESULT)")" "$(json_str "$(state_val MESSAGE)")" \
    "$(json_str "$(state_val NAS_IP)")" "$(json_str "$(state_val TIME)")"
printf '"mac":"%s","wol":"%s","iface":"%s","shutdown_after":"%s",' "$(json_str "$(state_val MAC)")" "$(json_str "$(state_val WOL)")" "$(json_str "$(state_val IFACE)")" "$(json_str "$(state_val SHUTDOWN_AFTER)")"
printf '"settings":{"SHUTDOWN_AFTER":"%s","NAS_IP":"%s","VOLTAGE_DIVISOR":"%s","VOLT_HIGH":"%s","VOLT_LOW":"%s","SUBDRIVER":"%s","BATT_NOMINAL":"%s"},' \
    "$(json_str "$(set_val SHUTDOWN_AFTER)")" "$(json_str "$(set_val NAS_IP)")" "$(json_str "$(set_val VOLTAGE_DIVISOR)")" \
    "$(json_str "$(set_val VOLT_HIGH)")" "$(json_str "$(set_val VOLT_LOW)")" "$(json_str "$(set_val SUBDRIVER)")" "$(json_str "$(set_val BATT_NOMINAL)")"
printf '"dsm_monitor":"%s",' "$(json_str "$(grep -h '^MONITOR' /etc/ups/upsmon.conf /usr/syno/etc/ups/upsmon.conf 2>/dev/null | head -1)")"
printf '"upsmon_running":%s,' "$(pgrep -x upsmon >/dev/null 2>&1 && echo true || echo false)"
# --- USB detection (sysfs is world-readable) ---
RC=false; OTHER=""
for d in /sys/bus/usb/devices/*; do
    [ -f "$d/idVendor" ] || continue
    vid="$(cat "$d/idVendor")"; pid="$(cat "$d/idProduct")"
    name="$(cat "$d/manufacturer" 2>/dev/null) $(cat "$d/product" 2>/dev/null)"
    case "$vid:$pid" in
        0925:1234) RC=true ;;
        051d:*|0463:*|0764:*|09ae:*|06da:*|0665:5161)
            OTHER="$OTHER$vid:$pid $(printf '%s' "$name" | sed 's/^ *//') ; " ;;
    esac
done
printf '"usb":{"richcomm":%s,"other_ups":"%s"},' "$RC" "$(json_str "$OTHER")"
dsm_val() { [ -f "$V/dsm_ups" ] && sed -n "s/^$1=//p" "$V/dsm_ups" | head -1; }
OBS="$(cat "$V/ob_since" 2>/dev/null | grep -E '^[0-9]+$')"
printf '"now":%s,"ob_since":%s,"dsm":{"enabled":"%s","slave":"%s","mode":"%s"},' "$(date +%s)" "${OBS:-0}" \
    "$(json_str "$(dsm_val ENABLED)")" "$(json_str "$(dsm_val SLAVE)")" "$(json_str "$(dsm_val MODE)")"
WATCH=false; [ -f "$V/watch.pid" ] && [ -d "/proc/$(cat "$V/watch.pid")" ] && WATCH=true
printf '"watchdog":%s,"rescan_pending":%s,' "$WATCH" "$([ -f "$V/restart.request" ] && echo true || echo false)"
printf '"active_subdriver":"%s","active_nominal":"%s","active_divisor":"%s",' \
    "$(json_str "$(state_val SUBDRIVER)")" "$(json_str "$(state_val BATT_NOMINAL)")" "$(json_str "$(state_val DIVISOR)")"
printf '"task_command":"sleep 30\\n%s",' "$T/bin/ups-watchdog.sh start"
printf '"log":"%s",' "$(json_str "$(tail -n 15 "$V/root.log" 2>/dev/null | sed 's/$/\\n/' | tr -d '\n')")"

OUT="$(upsc ups@127.0.0.1 2>/dev/null)"
if [ -n "$OUT" ]; then
    printf '"online":true,"ups":{'
    printf '%s\n' "$OUT" | awk -F': ' 'NF>=2 {
        k=$1; v=substr($0, length($1)+3);
        gsub(/\\/,"\\\\",v); gsub(/"/,"\\\"",v);
        printf "%s\"%s\":\"%s\"", (n++?",":""), k, v }'
    printf '}'
else
    printf '"online":false,"ups":{}'
fi
printf '}\n'
