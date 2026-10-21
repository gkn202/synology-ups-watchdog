#!/bin/bash
# Assemble the DSM package UPS-Watchdog-x86_64-<version>.spk
# Needs out/nutdrv_qx (build/build-nutdrv_qx.sh) and package/ from this repo.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
P="$HERE/package"; OUT="$HERE/out"; T="$(mktemp -d)"
[ -x "$OUT/nutdrv_qx" ] || { echo "out/nutdrv_qx missing - run build/build-nutdrv_qx.sh first"; exit 1; }
cp -r "$P/pkg" "$T/pkg"
install -m 755 "$OUT/nutdrv_qx" "$T/pkg/bin/nutdrv_qx"
chmod 755 "$T/pkg/bin/ups-watchdog.sh" "$T"/pkg/ui/*.cgi
( cd "$T/pkg" && tar czf "$T/package.tgz" --owner=0 --group=0 * )
VER="$(sed -n 's/^version="\(.*\)"/\1/p' "$P/INFO")"
{ cat "$P/INFO"; echo "checksum=\"$(md5sum "$T/package.tgz" | cut -d' ' -f1)\""; } > "$T/INFO"
cp -r "$P/scripts" "$P/conf" "$P/WIZARD_UIFILES" "$P/PACKAGE_ICON.PNG" "$P/PACKAGE_ICON_256.PNG" "$T/"
cp "$HERE/LICENSE" "$T/LICENSE"
chmod 755 "$T"/scripts/*
SPK="$OUT/UPS-Watchdog-x86_64-${VER%-*}-$(date +%F).spk"   # public name: version + build date, no DSM build number
( cd "$T" && tar cf "$SPK" --owner=0 --group=0 INFO package.tgz scripts conf WIZARD_UIFILES PACKAGE_ICON.PNG PACKAGE_ICON_256.PNG LICENSE )
rm -rf "$T"
echo "$SPK"
