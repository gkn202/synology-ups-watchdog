#!/bin/sh
# settings.cgi - store optional overrides for ups-watchdog.sh (admins only)
PKG=UPSWatchdog
V=/var/packages/$PKG/var

USER_NAME="$(/usr/syno/synoman/webman/modules/authenticate.cgi 2>/dev/null)"
reply() { printf 'Status: %s\r\nContent-Type: application/json\r\n\r\n%s\n' "$1" "$2"; exit 0; }
[ -n "$USER_NAME" ] || reply "401 Unauthorized" '{"ok":false,"error":"not logged in"}'
id -Gn "$USER_NAME" 2>/dev/null | tr ' ' '\n' | grep -qx administrators \
    || reply "403 Forbidden" '{"ok":false,"error":"administrators only"}'
[ "$REQUEST_METHOD" = "POST" ] || reply "405 Method Not Allowed" '{"ok":false,"error":"POST only"}'

LEN="${CONTENT_LENGTH:-0}"; [ "$LEN" -gt 2048 ] 2>/dev/null && LEN=2048
BODY="$(head -c "$LEN")"
get() { printf '%s' "$BODY" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1 | sed 's/%2[Ee]/./g'; }

NAS_IP="$(get NAS_IP)"; DIV="$(get VOLTAGE_DIVISOR)"; HI="$(get VOLT_HIGH)"; LO="$(get VOLT_LOW)"; SUB="$(get SUBDRIVER)"; NOM="$(get BATT_NOMINAL)"; SDA="$(get SHUTDOWN_AFTER)"
case "$NOM" in ""|12|24|36|48) ;; *) reply "400 Bad Request" '{"ok":false,"error":"invalid nominal voltage"}' ;; esac
[ "$DIV" = auto ] && DIV=""
case "$SUB" in ""|auto|richcomm-svc|armac) ;; *) reply "400 Bad Request" '{"ok":false,"error":"invalid subdriver"}' ;; esac
num() { [ -z "$1" ] || printf '%s' "$1" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; }
[ -z "$NAS_IP" ] || printf '%s' "$NAS_IP" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || reply "400 Bad Request" '{"ok":false,"error":"invalid NAS IP"}'
[ -z "$SDA" ] || printf '%s' "$SDA" | grep -Eq '^[0-9]{1,3}$' || reply "400 Bad Request" '{"ok":false,"error":"invalid shutdown time"}'
num "$DIV" && num "$HI" && num "$LO" || reply "400 Bad Request" '{"ok":false,"error":"invalid number"}'

{
    [ -n "$NAS_IP" ] && echo "NAS_IP=$NAS_IP"
    [ -n "$DIV" ]    && echo "VOLTAGE_DIVISOR=$DIV"
    [ -n "$HI" ]     && echo "VOLT_HIGH=$HI"
    [ -n "$LO" ]     && echo "VOLT_LOW=$LO"
    [ -n "$SUB" ]    && echo "SUBDRIVER=$SUB"
    [ -n "$NOM" ]    && echo "BATT_NOMINAL=$NOM"
    [ -n "$SDA" ]    && echo "SHUTDOWN_AFTER=$SDA"
} > "$V/settings.tmp" && mv "$V/settings.tmp" "$V/settings"
reply "200 OK" '{"ok":true}'
