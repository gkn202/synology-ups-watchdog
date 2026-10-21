#!/bin/sh
# rescan.cgi - ask the root watchdog to search the USB ports again (admins only)
PKG=UPSWatchdog
V=/var/packages/$PKG/var
USER_NAME="$(/usr/syno/synoman/webman/modules/authenticate.cgi 2>/dev/null)"
reply() { printf 'Status: %s\r\nContent-Type: application/json\r\n\r\n%s\n' "$1" "$2"; exit 0; }
[ -n "$USER_NAME" ] || reply "401 Unauthorized" '{"ok":false,"error":"not logged in"}'
id -Gn "$USER_NAME" 2>/dev/null | tr ' ' '\n' | grep -qx administrators \
    || reply "403 Forbidden" '{"ok":false,"error":"administrators only"}'
[ "$REQUEST_METHOD" = "POST" ] || reply "405 Method Not Allowed" '{"ok":false,"error":"POST only"}'
touch "$V/restart.request" && reply "200 OK" '{"ok":true}'
reply "500 Internal Server Error" '{"ok":false,"error":"cannot write request"}'
