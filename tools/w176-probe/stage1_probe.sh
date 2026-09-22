#!/bin/sh
# Read-only system inventory. All output paths remain below the USB root.

USB_ROOT="$1"
BASE="$USB_ROOT/stage1-probe"
OUT="$BASE"
INDEX=0
while [ -e "$OUT" ]; do
    INDEX=$((INDEX + 1))
    OUT="$BASE-$INDEX"
done

if ! mkdir "$OUT"; then
    echo "w176-probe: cannot create output directory on USB" >&2
    exit 1
fi

capture() {
    OUTPUT_FILE="$1"
    shift
    "$@" > "$OUT/$OUTPUT_FILE" 2>&1 || true
}

capture uname.txt uname -a
capture cpuinfo.txt cat /proc/cpuinfo
capture mtd.txt cat /proc/mtd
capture cmdline.txt cat /proc/cmdline
capture mounts.txt cat /proc/mounts
capture input-devices.txt cat /proc/bus/input/devices
capture input-nodes.txt ls -la /dev/input
capture applications.txt ls -la /application/bin /usr/local/bin
capture services.txt ps

{
    for ATTRIBUTE in virtual_size bits_per_pixel stride name; do
        VALUE="UNKNOWN"
        if [ -r "/sys/class/graphics/fb0/$ATTRIBUTE" ]; then
            VALUE="$(cat "/sys/class/graphics/fb0/$ATTRIBUTE" 2>/dev/null)"
        fi
        echo "$ATTRIBUTE=$VALUE"
    done
    if command -v fbset >/dev/null 2>&1; then
        fbset 2>&1 || true
    fi
} > "$OUT/framebuffer.txt"

APPINFO_SOURCE=""
for CANDIDATE in \
    /application/etc/appinfo.rc \
    /usr/local/etc/appinfo.rc \
    /system/etc/appinfo.rc \
    /etc/appinfo.rc
do
    if [ -r "$CANDIDATE" ]; then
        APPINFO_SOURCE="$CANDIDATE"
        cp "$CANDIDATE" "$OUT/appinfo.rc" 2>/dev/null || true
        break
    fi
done

HASH_TOOL=""
if command -v sha256sum >/dev/null 2>&1; then
    HASH_TOOL="sha256sum"
elif command -v busybox >/dev/null 2>&1 && busybox sha256sum --help >/dev/null 2>&1; then
    HASH_TOOL="busybox sha256sum"
fi

if [ -n "$HASH_TOOL" ]; then
    : > "$OUT/usb-handlers.sha256"
    for CANDIDATE in /usr/local/bin/*usb* /usr/local/bin/*Usb* /application/bin/*usb* /application/bin/*Usb*; do
        [ -f "$CANDIDATE" ] || continue
        $HASH_TOOL "$CANDIDATE" >> "$OUT/usb-handlers.sha256" 2>/dev/null || true
    done
    if [ -f "$OUT/appinfo.rc" ]; then
        $HASH_TOOL "$OUT/appinfo.rc" > "$OUT/appinfo.sha256" 2>/dev/null || true
    fi
fi

HARDWARE="$(awk -F: '/^Hardware[[:space:]]*:/ { sub(/^[[:space:]]+/, "", $2); print $2; exit }' /proc/cpuinfo 2>/dev/null)"
KERNEL_RELEASE="$(uname -r 2>/dev/null)"
NVM_BYTES="$(awk '/"nvm"/ { print $2; exit }' /proc/mtd 2>/dev/null)"
FB_SIZE="$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null)"
FB_BPP="$(cat /sys/class/graphics/fb0/bits_per_pixel 2>/dev/null)"

{
    echo "# GeminiTop W176 Stage-1 normalized hints"
    [ -n "$HARDWARE" ] && echo "identity.hardware=$HARDWARE"
    [ -n "$KERNEL_RELEASE" ] && echo "kernel.release=$KERNEL_RELEASE"
    if [ -n "$NVM_BYTES" ]; then
        case "$NVM_BYTES" in
            *[!0-9a-fA-F]*) ;;
            *) echo "mtd.nvm_hex=$NVM_BYTES" ;;
        esac
    fi
    [ -n "$FB_SIZE" ] && echo "framebuffer.virtual_size=$FB_SIZE"
    [ -n "$FB_BPP" ] && echo "framebuffer.bits_per_pixel=$FB_BPP"
    [ -n "$APPINFO_SOURCE" ] && echo "appinfo.source=$APPINFO_SOURCE"
} > "$OUT/stage1-summary.txt"

{
    echo "Stage-1 probe complete."
    echo "Output was written only to: $OUT"
    echo "No raw CAN, NVM/MTD payload, network, MCU, or Roadtop filesystem write was performed."
} > "$OUT/README.txt"

sync
echo "w176-probe: complete: $OUT"
