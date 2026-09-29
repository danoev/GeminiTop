#!/bin/sh
# Refuse a library/config copy unless its effective mount is the RO rootfs.
set -u
CDPATH=; export CDPATH
[ "$#" -eq 3 ] || exit 1
SOURCE=$1; ROOT=$2; MOUNTS=$3
[ -d "$ROOT" ] && [ ! -L "$ROOT" ] || exit 1
[ ! -L "$SOURCE" ] && [ "$(stat -c '%F' "$SOURCE" 2>/dev/null)" = 'regular file' ] || exit 1
PARENT=$(cd -P "$(dirname "$SOURCE")" 2>/dev/null && pwd -P) || exit 1
CANONICAL="$PARENT/${SOURCE##*/}"
case "$ROOT" in /) case "$CANONICAL" in /lib/*|/boot/config-4.9.217) ;; *) exit 1 ;; esac ;;
    *) case "$CANONICAL" in "$ROOT"/lib/*|"$ROOT"/boot/config-4.9.217) ;; *) exit 1 ;; esac ;;
esac
[ -f "$MOUNTS" ] && [ ! -L "$MOUNTS" ] || exit 1
TABLE=$(dd if="$MOUNTS" bs=1 count=131073 2>/dev/null && printf x) || exit 1
TABLE=${TABLE%x}
[ "${#TABLE}" -le 131072 ] || exit 1
awk -v root="$ROOT" -v source="$CANONICAL" '
    function covers(m,p) { return m=="/" || p==m || index(p,m"/")==1 }
    NF==0 { next }
    length($0)>4096 || ++records>1024 || NF!=6 { bad=1; exit }
    {
        if ($2 ~ /\\/ || substr($2,1,1)!="/") { bad=1; exit }
        if (covers($2,source)) {
            if (seen[$2]++) { bad=1; exit }
            if (length($2)>longest) { longest=length($2); effective=$2 }
        }
        if ($2==root) {
            found++; fs=$3; n=split($4,opt,","); ro=0; rw=0
            for (i=1;i<=n;i++) { if(opt[i]=="ro")ro=1; if(opt[i]=="rw")rw=1 }
        }
    }
    END { if(bad || found!=1 || effective!=root || fs!="squashfs" || !ro || rw)exit 1 }
' <<EOF || exit 1
$TABLE
EOF
[ "$(stat -c '%d' "$ROOT" 2>/dev/null)" = "$(stat -c '%d' "$CANONICAL" 2>/dev/null)" ] || exit 1
printf '%s\n' "$CANONICAL"
