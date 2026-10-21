#!/bin/bash
# Build a statically linked nutdrv_qx for Synology DSM 7 (x86_64)
# from Network UPS Tools + the UPS-Watchdog battery_voltage_divisor patch.
# Tested on Debian/Ubuntu x86_64. Output: out/nutdrv_qx
set -euo pipefail
NUT_COMMIT=3b79a0fa87a6757a6794d807197b84a6c4fe42ed   # NUT master, 2026-10-15 (includes richcomm-svc)
HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$HERE/.build}"
mkdir -p "$WORK" "$HERE/out"

if command -v apt-get >/dev/null; then
  sudo apt-get update -q >/dev/null || true
  sudo apt-get install -y build-essential autoconf automake libtool pkg-config \
       libusb-1.0-0-dev python3 git >/dev/null || true
fi

# libusb without udev (DSM has no libudev; a static udev cannot be linked)
LIBUSB_TAG=v1.0.27
cd "$WORK"
if [ ! -f "$WORK/libusb-prefix/lib/libusb-1.0.a" ]; then
  [ -d libusb ] || git clone -q https://github.com/libusb/libusb.git libusb
  ( cd libusb && git checkout -q -f "$LIBUSB_TAG" && ./autogen.sh >/dev/null 2>&1 || true
    ./configure --prefix="$WORK/libusb-prefix" --disable-udev --enable-static --disable-shared >/dev/null
    make -j"$(nproc)" >/dev/null && make install >/dev/null )
fi
export PKG_CONFIG_PATH="$WORK/libusb-prefix/lib/pkgconfig"

[ -d nut ] || git clone https://github.com/networkupstools/nut.git nut
cd nut
git fetch -q origin
git checkout -q -f "$NUT_COMMIT"
git apply "$HERE/nut/0001-nutdrv_qx-battery_voltage_divisor.patch"

./autogen.sh >/dev/null
./configure --with-usb=libusb-1.0 --without-snmp --without-neon --without-powerman \
            --without-modbus --without-ipmi --without-avahi --without-ssl \
            --without-wrap --without-libltdl --without-dev --without-docs \
            --with-drivers=nutdrv_qx --disable-shared --enable-static \
            LDFLAGS="-static" LIBUSB_CFLAGS="-I$WORK/libusb-prefix/include/libusb-1.0" \
            LIBUSB_LIBS="$WORK/libusb-prefix/lib/libusb-1.0.a -lpthread" >/dev/null
make -j"$(nproc)" -C common >/dev/null
rm -f drivers/nutdrv_qx
make -j"$(nproc)" -C drivers nutdrv_qx LDFLAGS="-all-static" >/dev/null
cp drivers/nutdrv_qx "$HERE/out/nutdrv_qx"
strip "$HERE/out/nutdrv_qx"
( cd "$HERE/out" && sha256sum nutdrv_qx > nutdrv_qx.sha256 )
file "$HERE/out/nutdrv_qx"
"$HERE/out/nutdrv_qx" -V 2>&1 | head -2 || true
git checkout -q -- .
