#!/bin/sh
# Metadata only: reject every covering nested mount before a library open.
set -u
CDPATH=; export CDPATH
[ "$#" -eq 3 ] || exit 1
SOURCE=$1; APP_ROOT=$2; MOUNTS=$3
[ ! -L "$SOURCE" ] && [ "$(stat -c '%F' "$SOURCE" 2>/dev/null)" = 'regular file' ] || exit 1
PARENT=$(cd -P "$(dirname "$SOURCE")" 2>/dev/null && pwd -P) || exit 1
CANONICAL="$PARENT/${SOURCE##*/}"
case "$CANONICAL" in "$APP_ROOT/"*) ;; *) exit 1 ;; esac
# The proc view is trusted kernel metadata, not capture-tree input.
[ -f "$MOUNTS" ] || exit 1
TABLE=$(dd if="$MOUNTS" bs=1 count=131073 2>/dev/null && printf x) || exit 1
TABLE=${TABLE%x}
[ "${#TABLE}" -le 131072 ] || exit 1
awk -v app="$APP_ROOT" -v source="$CANONICAL" '
    function covers(m, p) { return m == "/" || p == m || index(p, m "/") == 1 }
    NR > 1024 || length($0) > 4096 { bad=1; exit }
    NF == 0 { next }
    NF != 6 { bad=1; exit }
    {
        # Expected paths are unescaped. Reject ambiguous mount tables rather
        # than loosely decoding kernel octal escapes.
        if ($2 ~ /\\/ || substr($2,1,1) != "/") { bad=1; exit }
        if (covers($2,source)) {
            if (seen[$2]++) { bad=1; exit }
            if (length($2) > longest) { longest=length($2); effective=$2 }
        }
        if ($2 == app) {
            found++; fs=$3; n=split($4,opt,","); ro=0; rw=0
            for (i=1;i<=n;i++) { if (opt[i]=="ro") ro=1; if (opt[i]=="rw") rw=1 }
        }
    }
    END { if (bad || found != 1 || effective != app || fs != "squashfs" || !ro || rw) exit 1 }
' <<EOF || exit 1
$TABLE
EOF
APP_DEVICE=$(stat -c '%d' "$APP_ROOT" 2>/dev/null) || exit 1
SOURCE_DEVICE=$(stat -c '%d' "$CANONICAL" 2>/dev/null) || exit 1
case "$APP_DEVICE:$SOURCE_DEVICE" in *[!0-9:]*|:*) exit 1 ;; esac
[ "$APP_DEVICE" = "$SOURCE_DEVICE" ] || exit 1
printf '%s\n' "$CANONICAL"
