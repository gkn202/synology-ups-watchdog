#!/bin/sh
#
# ups-watchdog.sh - privileged part of the "UPS-Watchdog" DSM package.
#
# DSM 7 packages run as an unprivileged package user, so they can neither
# open the USB device nor start DSM's upsd. This script does that and must
# be run as root, normally from a DSM Task Scheduler task:
#
#   Control Panel -> Task Scheduler -> Create -> Triggered Task ->
#   User-defined script, User: root, Event: Boot-up, command:
#       /var/packages/UPSWatchdog/target/bin/ups-watchdog.sh start
#
# Actions:  start (default) | stop | status | remove | watch (internal)
#
# After a successful start a small watchdog ("watch") runs in the background:
# - "Search USB port" in the app drops $V/restart.request -> full restart
# - chip present but upsd has no data for 30 s (cable moved to another
#   port, UPS power-cycled) -> full restart, which finds the UPS on any port
#
# Power failure policy (2.0): DSM's own UPS support stays OFF. DSM's
# "Standby" never ends by itself, and cutting the UPS output would also cut
# router/switch/smart-home devices on the same UPS. Instead the watchdog
# powers the NAS off cleanly after SHUTDOWN_AFTER minutes on battery (or on
# "battery low"). It comes back by Wake-on-LAN from a device on plain mains
# (e.g. an ESPHome smart plug), or - if the battery ran flat - by DSM's
# "restart automatically after a power failure".
#
# Licence: GPL-2.0-or-later

PKG=UPSWatchdog
T=/var/packages/$PKG/target
V=/var/packages/$PKG/var
# Runtime copy on the system disk (tmpfs): DSM's Standby Mode unmounts the
# data volume that holds the package, but the driver, upsd and the watchdog
# must keep running so DSM learns when mains power is back.
R=/run/ups-watchdog
C=$R/nut
SYNOUPS=/usr/syno/etc/ups/synoups.conf
STATE=$V/root_state
LOG=$V/root.log
ACTION="${1:-start}"

log() {
    line="$(date '+%Y-%m-%d %H:%M:%S') $*"
    # $V lives on the data volume; in Standby it is gone -> system disk
    echo "$line" >> "$LOG" 2>/dev/null || echo "$line" >> /var/log/ups-watchdog.log
    echo "$*"
}

[ "$(id -u)" = 0 ] || { echo "ups-watchdog.sh must run as root"; exit 1; }
if [ "$ACTION" != watch ]; then
    mkdir -p "$R"
    if [ -x "$T/bin/nutdrv_qx" ]; then
        cmp -s "$T/bin/nutdrv_qx" "$R/nutdrv_qx" || cp -f "$T/bin/nutdrv_qx" "$R/nutdrv_qx"
        cp -f "$T/bin/ups-watchdog.sh" "$R/ups-watchdog.sh"
        chmod 755 "$R/nutdrv_qx" "$R/ups-watchdog.sh"
    elif [ ! -x "$R/nutdrv_qx" ]; then
        echo "package not installed ($T/bin/nutdrv_qx missing)"; exit 1
    fi
fi
mkdir -p "$C" /run/ups_state

# ---------------------------------------------------------------- hardware --

chip_present() {
    for d in /sys/bus/usb/devices/*; do
        [ -f "$d/idVendor" ] || continue
        [ "$(cat "$d/idVendor")" = "0925" ] && [ "$(cat "$d/idProduct")" = "1234" ] && return 0
    done
    return 1
}

usb_reset() {   # re-enumerate the Richcomm chip (same as unplugging the cable)
    done_any=1
    for d in /sys/bus/usb/devices/*; do
        [ -f "$d/idVendor" ] || continue
        [ "$(cat "$d/idVendor")" = "0925" ] && [ "$(cat "$d/idProduct")" = "1234" ] || continue
        [ -w "$d/authorized" ] || continue
        log "USB reset of $(basename "$d")"
        echo 0 > "$d/authorized"; sleep 3; echo 1 > "$d/authorized"
        done_any=0
    done
    [ $done_any = 0 ] && sleep 8      # give the chip time to come back
    return $done_any
}

# ---------------------------------------------------------------- settings --
# Optional overrides (written by the package UI or by hand):
#   NAS_IP=192.168.1.10
#   BATT_NOMINAL=12          nominal battery voltage (asked at install)
#   VOLTAGE_DIVISOR=auto     or a number; auto = derived from BATT_NOMINAL
#   VOLT_HIGH= / VOLT_LOW=   empty = 13.1 V / 10.4 V per 12 V block
#   SUBDRIVER=auto|richcomm-svc|armac
#   SHUTDOWN_AFTER=5         minutes on battery before power-off, 0 = only on "battery low"
NAS_IP=""; BATT_NOMINAL=12; VOLTAGE_DIVISOR=auto; VOLT_HIGH=""; VOLT_LOW=""; SUBDRIVER=auto; SHUTDOWN_AFTER=5
# Parsed, never sourced: the file is writable by the package user, this
# script runs as root. Only plain numbers / IPv4 addresses are accepted.
if [ -f "$V/settings" ]; then
    while IFS='=' read -r k v; do
        v="$(printf '%s' "$v" | tr -d '"'"'"' \r')"
        case "$k" in
            NAS_IP)          printf '%s' "$v" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' && NAS_IP="$v" ;;
            BATT_NOMINAL)    case "$v" in 12|24|36|48|72|96) BATT_NOMINAL="$v" ;; esac ;;
            VOLTAGE_DIVISOR) { [ "$v" = auto ] || printf '%s' "$v" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; } && VOLTAGE_DIVISOR="$v" ;;
            VOLT_HIGH)       printf '%s' "$v" | grep -Eq '^[0-9]+(\.[0-9]+)?$' && VOLT_HIGH="$v" ;;
            VOLT_LOW)        printf '%s' "$v" | grep -Eq '^[0-9]+(\.[0-9]+)?$' && VOLT_LOW="$v" ;;
            SUBDRIVER)       case "$v" in auto|richcomm-svc|armac) SUBDRIVER="$v" ;; esac ;;
            SHUTDOWN_AFTER)  printf '%s' "$v" | grep -Eq '^[0-9]{1,3}$' && SHUTDOWN_AFTER="$v" ;;
        esac
    done < "$V/settings"
fi

detect_ip() {
    python3 - <<'PY' 2>/dev/null
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    s.connect(("1.1.1.1", 53)); print(s.getsockname()[0])
finally:
    s.close()
PY
}
[ -n "$NAS_IP" ] || NAS_IP="$(detect_ip)"
[ -n "$NAS_IP" ] || NAS_IP="$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')"

ACTIVE_SUB=""; DIV=1
[ -n "$VOLT_HIGH" ] || VOLT_HIGH="$(awk -v n="$BATT_NOMINAL" 'BEGIN{printf "%.1f", 13.1*n/12}')"
[ -n "$VOLT_LOW" ]  || VOLT_LOW="$(awk -v n="$BATT_NOMINAL" 'BEGIN{printf "%.1f", 10.4*n/12}')"
[ "$VOLTAGE_DIVISOR" = auto ] || DIV="$VOLTAGE_DIVISOR"
IFACE="$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p')"; [ -n "$IFACE" ] || IFACE=eth0
MAC="$(cat "/sys/class/net/$IFACE/address" 2>/dev/null)"
WOL="$(ethtool "$IFACE" 2>/dev/null | sed -n 's/^[[:space:]]*Wake-on: //p' | head -1)"
write_state() {   # $1 = ok|error, $2 = message
    printf 'RESULT=%s\nMESSAGE="%s"\nNAS_IP=%s\nSUBDRIVER=%s\nBATT_NOMINAL=%s\nDIVISOR=%s\nSHUTDOWN_AFTER=%s\nIFACE=%s\nMAC=%s\nWOL=%s\nTIME=%s\nEPOCH=%s\n' "$1" "$2" "$NAS_IP" "$ACTIVE_SUB" "$BATT_NOMINAL" "$DIV" "$SHUTDOWN_AFTER" "$IFACE" "$MAC" "$WOL" "$(date '+%Y-%m-%d %H:%M:%S')" "$(date +%s)" > "$STATE"
    chmod 644 "$STATE"
}

stop_watch() {
    if [ -f "$V/watch.pid" ]; then
        wp="$(cat "$V/watch.pid")"
        [ "$wp" != "$$" ] && kill "$wp" >/dev/null 2>&1
        rm -f "$V/watch.pid"
    fi
}

start_watch() {
    stop_watch
    nohup sh "$R/ups-watchdog.sh" watch >/dev/null 2>&1 &
    echo $! > "$V/watch.pid"
}

notify() {   # best effort DSM notification to administrators
    /usr/syno/bin/synodsmnotify @administrators "UPS-Watchdog" "$1" >/dev/null 2>&1
}

power_off() {
    sync
    if [ -x /usr/syno/sbin/synopoweroff ]; then /usr/syno/sbin/synopoweroff
    else /sbin/poweroff || poweroff; fi
}

upsd_alive() {
    pgrep -f '/usr/sbin/upsd' >/dev/null 2>&1
}

driver_alive() {
    pgrep -f "nutdrv_qx -a ups" >/dev/null 2>&1
}

stop_all() {
    NUT_CONFPATH="$C" /usr/sbin/upsd -c stop >/dev/null 2>&1
    NUT_CONFPATH=/usr/local/nut/etc /usr/sbin/upsd -c stop >/dev/null 2>&1   # earlier manual install
    pkill -f "$T/bin/nutdrv_qx" >/dev/null 2>&1
    pkill -f "$R/nutdrv_qx" >/dev/null 2>&1
    pkill -f "/usr/local/nut/nutdrv_qx" >/dev/null 2>&1
    sleep 2
}

write_config() {   # $1 = subdriver
    cat > "$C/ups.conf" <<EOF
# generated by ups-watchdog.sh - edit $V/settings instead
[ups]
	driver = nutdrv_qx
	port = auto
	vendorid = 0925
	productid = 1234
	subdriver = $1
	protocol = megatec
	novendor
	norating
	pollinterval = 5
	desc = "Richcomm 0925:1234 UPS"
	battery_voltage_divisor = $DIV
	default.battery.voltage.high = $VOLT_HIGH
	default.battery.voltage.low = $VOLT_LOW
EOF
    {
        echo "LISTEN 127.0.0.1 3493"
    } > "$C/upsd.conf"
    cat > "$C/upsd.users" <<'EOF'
# DSM's upsmon always logs in as monuser/secret
[monuser]
	password = secret
	upsmon master
EOF
    chmod 600 "$C/ups.conf" "$C/upsd.conf" "$C/upsd.users"
}

cleanup_legacy() {
    # 1.x added these to synoups.conf for DSM's network UPS client; not used any more
    if grep -q '^ups_acl=' "$SYNOUPS" 2>/dev/null; then
        sed -i '/^ups_acl=/d' "$SYNOUPS"; log "removed ups_acl from synoups.conf (no longer needed)"
    fi
    rm -f "$V/dsm_wanted"
}

case "$ACTION" in
start|restart)
    log "start (NAS_IP=$NAS_IP, SUBDRIVER=$SUBDRIVER)"
    stop_watch
    stop_all
    if ! chip_present; then
        log "no USB device 0925:1234 found"
        write_state error "No Richcomm USB chip (0925:1234) found - check the USB cable or UPS model"
        start_watch      # restarts automatically once the cable is plugged in
        exit 1
    fi
    if [ "$SUBDRIVER" = auto ]; then CANDIDATES="richcomm-svc armac"; else CANDIDATES="$SUBDRIVER"; fi
    # The Richcomm chip sometimes hangs (e.g. after a long time on battery);
    # if no subdriver gets an answer, reset the USB port once and try again.
    for attempt in 1 2; do
        for sub in $CANDIDATES; do
            write_config "$sub"
            # one-shot probe: read data once and exit
            if NUT_CONFPATH="$C" "$R/nutdrv_qx" -a ups -u root -d 1 >"$R/probe.out" 2>&1 \
               && grep -q '^ups.status:' "$R/probe.out"; then
                ACTIVE_SUB="$sub"; break
            fi
            log "subdriver $sub: no data"
        done
        [ -n "$ACTIVE_SUB" ] && break
        [ $attempt = 1 ] || break
        log "UPS does not answer - resetting the USB port"
        usb_reset || { log "USB reset not possible"; break; }
        chip_present || break
    done
    if [ -z "$ACTIVE_SUB" ]; then
        tail -n 5 "$R/probe.out" >> "$LOG"
        write_state error "Chip found, but the UPS does not answer with: $CANDIDATES"
        start_watch      # retries automatically
        exit 1
    fi
    log "using subdriver $ACTIVE_SUB"
    if [ "$VOLTAGE_DIVISOR" = auto ]; then
        # probe ran with divisor $DIV; derive the factor between the reported
        # voltage and a healthy battery of BATT_NOMINAL volts (13.6 V float per 12 V)
        RAW="$(sed -n 's/^battery.voltage: //p' "$R/probe.out" | head -1)"
        if [ -n "$RAW" ]; then
            DIV="$(awk -v r="$RAW" -v d="$DIV" -v n="$BATT_NOMINAL" 'BEGIN{
                x = (r*d) / (n*13.6/12); k = int(x + 0.5); if (k < 1) k = 1; print k }')"
            log "battery: reported ${RAW} V (divisor 1), nominal ${BATT_NOMINAL} V -> divisor $DIV"
        fi
    fi
    write_config "$ACTIVE_SUB"
    if ! NUT_CONFPATH="$C" "$R/nutdrv_qx" -a ups -u root >>"$LOG" 2>&1; then
        log "driver failed to start"
        write_state error "Driver could not start (see log)"
        exit 1
    fi
    sleep 3
    cleanup_legacy
    # DSM's own UPS hotplug script may stop "the" upsd shortly after boot,
    # so start it, then verify for up to 30 s and start it again if needed.
    ok=0
    for try in 1 2 3; do
        upsd_alive || NUT_CONFPATH="$C" /usr/sbin/upsd -u root >>"$LOG" 2>&1
        for i in 1 2 3 4 5; do
            sleep 2
            if upsc ups@127.0.0.1 ups.status >/dev/null 2>&1; then ok=1; break 2; fi
        done
        log "upsd not answering (try $try)"
    done
    start_watch      # keeps watching and repairing in every case
    if [ $ok = 1 ]; then
        log "running: $(upsc ups@127.0.0.1 ups.status 2>/dev/null)"
        write_state ok "Driver ($ACTIVE_SUB) and upsd running"
    else
        write_state error "upsd does not answer - the watchdog keeps retrying (see log)"
        exit 1
    fi
    ;;
watch)
    echo $$ > "$V/watch.pid"
    fails=0; ob_start=0; lbn=0; gone=0
    # keep the on-battery start time across a driver restart
    [ -f "$R/ob_start" ] && { ob_start="$(cat "$R/ob_start")"; rm -f "$R/ob_start"; }
    while :; do
        sleep 5
        # package uninstalled? A package update removes the folder only for a
        # moment, so require it to be missing for 2 minutes before giving up.
        if [ -d "/var/packages/$PKG" ]; then gone=0
        else gone=$((gone + 1)); [ $gone -ge 24 ] && { log "watch: package removed - exiting"; exit 0; }; continue; fi
        # --- publish DSM's UPS settings (synoups.conf is root-only) for the app
        {
            sed -n 's/^ups_enabled=/ENABLED=/p; s/^upsslave_enabled=/SLAVE=/p; s/^ups_mode=/MODE=/p' "$SYNOUPS" 2>/dev/null | tr -d '"'
        } > "$V/dsm_ups.tmp" && chmod 644 "$V/dsm_ups.tmp" && mv "$V/dsm_ups.tmp" "$V/dsm_ups"
        ST="$(upsc ups@127.0.0.1 ups.status 2>/dev/null)"
        case " $ST " in
            *" OB "*)
                if [ $ob_start = 0 ]; then
                    ob_start=$(date +%s); echo $ob_start > "$V/ob_since"; chmod 644 "$V/ob_since"
                    log "watch: on battery"
                    if [ "$SHUTDOWN_AFTER" -gt 0 ]; then notify "Power failure - NAS shuts down in $SHUTDOWN_AFTER min unless power returns"
                    else notify "Power failure - NAS shuts down when the battery is low"; fi
                fi
                el=$(( $(date +%s) - ob_start ))
                case " $ST " in *" LB "*) lbn=$((lbn + 1)) ;; *) lbn=0 ;; esac
                if { [ "$SHUTDOWN_AFTER" -gt 0 ] && [ $el -ge $((SHUTDOWN_AFTER * 60)) ]; } || [ $lbn -ge 2 ]; then
                    # confirm once more - never power off on a single bad reading
                    sleep 5
                    case " $(upsc ups@127.0.0.1 ups.status 2>/dev/null) " in
                        *" OB "*)
                            log "watch: on battery for ${el}s (status $ST) - powering the NAS off"
                            notify "On battery for $((el / 60)) min - NAS powers off now"
                            date +%s > "$V/last_poweroff" 2>/dev/null
                            power_off
                            sleep 600; exit 0 ;;
                    esac
                fi ;;
            *" OL "*)
                if [ $ob_start != 0 ]; then
                    log "watch: power restored after $(( $(date +%s) - ob_start ))s"
                    notify "Power restored - shutdown cancelled"
                fi
                ob_start=0; lbn=0; rm -f "$V/ob_since" ;;
        esac
        if [ -f "$V/restart.request" ]; then
            rm -f "$V/restart.request"
            log "watch: USB search / restart requested from the app"
            sh "$R/ups-watchdog.sh" start >/dev/null 2>&1 &
            exit 0
        fi
        if upsc ups@127.0.0.1 ups.status >/dev/null 2>&1; then
            fails=0
        elif chip_present && driver_alive && ! upsd_alive; then
            log "watch: upsd was stopped - starting it again"
            NUT_CONFPATH="$C" /usr/sbin/upsd -u root >>"$LOG" 2>&1
            fails=0
        elif chip_present; then
            fails=$((fails + 1))
            if [ $fails -ge 6 ]; then
                log "watch: UPS present but no data for 30 s - restarting"
                [ $ob_start != 0 ] && echo $ob_start > "$R/ob_start"
                sh "$R/ups-watchdog.sh" start >/dev/null 2>&1 &
                exit 0
            fi
        else
            fails=0                                  # cable unplugged: wait
        fi
    done
    ;;
stop)
    log "stop"
    stop_watch
    stop_all
    write_state stopped "Stopped by administrator"
    ;;
remove)
    log "remove"
    stop_watch
    stop_all
    sed -i '/^ups_acl=/d' "$SYNOUPS" 2>/dev/null
    rm -rf "$R" "$V/dsm_wanted"
    write_state stopped "Removed - you can uninstall the package now"
    ;;
status)
    upsc ups@127.0.0.1 2>&1
    ;;
*)
    echo "usage: $0 start|stop|status|remove"; exit 2 ;;
esac
exit 0
