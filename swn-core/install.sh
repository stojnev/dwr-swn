#!/bin/bash
# =============================================================================
#  CD memory player - installer
#
#  Rebuilds the player on a fresh Raspberry Pi OS Lite (64-bit, Debian 13
#  "trixie") exactly as it was running on the original Pi. The scripts below
#  were copied from that Pi; the only changes are the settings listed here.
#
#  Usage:   sudo ./install.sh [options]
#
#  Settings (environment variable, or option; the option wins):
#     CD_USER        --user NAME       Linux user that runs the web page and is
#                                      allowed to eject.            [swn]
#     REMOTE_ADDR    --remote AA:BB:.. Bluetooth address of the Siri Remote.
#                                                         [60:BE:C4:18:43:90]
#     AUDIO_CARD  --card NAME       ALSA card name of the DAC (see
#                                      "aplay -l", the word after "card N:") [D20]
#     BUTTON_GPIO    --gpio N          BCM GPIO number of the eject button.
#                                      17 = physical pin 11.        [17]
#     RAM_MB         --ram N           Size of the RAM disk in MB.   [900]
#     IDLE_IMAGE     --idle FILE       Optional picture shown while no disc is
#                                      loaded (png, jpg, webp, gif or svg). Without
#                                      this option, a file files/usr/local/share/cdui/idle.*
#                                      next to this script is used.
#
#  Other options:
#     --stage DIR    only write the files under DIR (for checking; changes
#                    nothing on the running system)
#     --no-apt       do not run apt (packages already installed)
#     --only NAME    install just one program from files/usr/local/bin (cdplay,
#                    cdtag, cdeject, cdbutton, cdremote, cdui, cdcheck, ...) and
#                    restart its service; nothing else is touched
#     -h, --help     show this text
#
#  Settings used in an earlier run are remembered in /etc/swn-core.conf, so a
#  re-run without options keeps them. The script can be run again at any time.
# =============================================================================
set -euo pipefail

SAVED_CONF=/etc/swn-core.conf
SRC=$(dirname "$(readlink -f "$0")")
ONLY=""
STAGE=""
DO_APT=1

# ---- remembered settings (lowest priority) ----------------------------------
if [ -r "$SAVED_CONF" ]; then
    while IFS='=' read -r k v; do
        case "$k" in
            CD_USER|REMOTE_ADDR|AUDIO_CARD|BUTTON_GPIO|RAM_MB)
                [ -n "${!k:-}" ] || printf -v "$k" '%s' "$v" ;;
        esac
    done < "$SAVED_CONF"
fi

# ---- defaults ---------------------------------------------------------------
: "${CD_USER:=swn}"
: "${REMOTE_ADDR:=60:BE:C4:18:43:90}"
: "${AUDIO_CARD:=D20}"
: "${BUTTON_GPIO:=17}"
: "${RAM_MB:=900}"
: "${IDLE_IMAGE:=}"

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }
die()   { echo "ERROR: $*" >&2; exit 1; }
say()   { printf '\n== %s\n' "$*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --user)   CD_USER=${2:?}; shift 2 ;;
        --remote) REMOTE_ADDR=${2:?}; shift 2 ;;
        --card)   AUDIO_CARD=${2:?}; shift 2 ;;
        --gpio)   BUTTON_GPIO=${2:?}; shift 2 ;;
        --ram)    RAM_MB=${2:?}; shift 2 ;;
        --idle)   IDLE_IMAGE=${2:?}; shift 2 ;;
        --stage)  STAGE=${2:?}; shift 2 ;;
        --no-apt) DO_APT=0; shift ;;
        --only)   ONLY=${2:?}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

# ---- validate the settings (they end up inside scripts) ---------------------
REMOTE_ADDR=$(printf '%s' "$REMOTE_ADDR" | tr 'a-f' 'A-F')
[[ "$CD_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]            || die "CD_USER '$CD_USER' is not a valid Linux user name"
[[ "$REMOTE_ADDR" =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]] || die "REMOTE_ADDR '$REMOTE_ADDR' is not a Bluetooth address like 60:BE:C4:18:43:90"
[[ "$AUDIO_CARD" =~ ^[A-Za-z0-9_.-]+$ ]]        || die "AUDIO_CARD '$AUDIO_CARD' has unexpected characters"
[[ "$BUTTON_GPIO" =~ ^[0-9]{1,2}$ ]] && [ "$BUTTON_GPIO" -le 27 ] || die "BUTTON_GPIO must be a BCM number from 0 to 27"
[[ "$RAM_MB" =~ ^[0-9]{3,4}$ ]] && [ "$RAM_MB" -ge 300 ]          || die "RAM_MB must be a number of at least 300"
# no --idle given: use a picture placed in files/usr/local/share/cdui/idle.<ext>
if [ -z "$IDLE_IMAGE" ]; then
    for f in "$SRC"/files/usr/local/share/cdui/idle.*; do
        [ -f "$f" ] && { IDLE_IMAGE=$f; break; }
    done
fi
if [ -n "$IDLE_IMAGE" ]; then
    [ -f "$IDLE_IMAGE" ] || die "idle image not found: $IDLE_IMAGE"
    case "${IDLE_IMAGE##*.}" in png|jpg|jpeg|webp|gif|svg) ;; *) die "idle image must be png, jpg, jpeg, webp, gif or svg" ;; esac
    IDLE_IMAGE=$(readlink -f "$IDLE_IMAGE")
fi

if [ -z "$STAGE" ]; then
    [ "$(id -u)" -eq 0 ] || die "run as root:  sudo ./install.sh"
    id "$CD_USER" >/dev/null 2>&1 || die "user '$CD_USER' does not exist (create it in Raspberry Pi Imager, or pass --user)"
    grep -qi 'raspberry pi 5' /proc/device-tree/model 2>/dev/null || echo "NOTE: this does not look like a Raspberry Pi 5 - continuing anyway."
    command -v apt-get >/dev/null || die "apt-get not found - this installer is for Raspberry Pi OS / Debian"
else
    mkdir -p "$STAGE"
fi

ROOT=${STAGE:-}
BACKUP_DIR=/var/backups/swn-core/$(date +%Y%m%d-%H%M%S)
CHANGED=0

cat <<EOF
CD memory player installer
  user ............ $CD_USER
  remote address .. $REMOTE_ADDR
  DAC card ........ $AUDIO_CARD
  button GPIO ..... $BUTTON_GPIO
  RAM disk ........ ${RAM_MB} MB
  idle image ...... ${IDLE_IMAGE:-(none)}
EOF
[ -z "$STAGE" ] || echo "  STAGE MODE ..... writing under $STAGE only"

# ---- put MODE PATH < content : write a file, fill in the settings -----------
put() {
    local mode=$1 path=$2 tmp dest
    dest="$ROOT$path"
    tmp=$(mktemp)
    sed -e "s|@CD_USER@|$CD_USER|g" \
        -e "s|@REMOTE_ADDR@|$REMOTE_ADDR|g" \
        -e "s|@AUDIO_CARD@|$AUDIO_CARD|g" \
        -e "s|@BUTTON_GPIO@|$BUTTON_GPIO|g" \
        -e "s|@RAM_MB@|$RAM_MB|g" > "$tmp"
    if grep -qE '@(CD_USER|REMOTE_ADDR|AUDIO_CARD|BUTTON_GPIO|RAM_MB)@' "$tmp"; then
        rm -f "$tmp"; die "unfilled setting in $path (installer bug)"
    fi
    mkdir -p "$(dirname "$dest")"
    if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
        chmod "$mode" "$dest"
        echo "  unchanged  $path"
    else
        if [ -f "$dest" ]; then
            mkdir -p "$ROOT$BACKUP_DIR"
            cp --parents -p "$dest" "$ROOT$BACKUP_DIR/" 2>/dev/null || true
            echo "  updated    $path   (old copy in $BACKUP_DIR)"
        else
            echo "  created    $path"
        fi
        install -m "$mode" "$tmp" "$dest"
        CHANGED=1
    fi
    rm -f "$tmp"
}


[ -d "$SRC/files" ] || die "folder '$SRC/files' not found - keep install.sh next to its files/ folder"

# ---- --only NAME : update a single program and restart its service -----------
if [ -n "$ONLY" ]; then
    [[ "$ONLY" =~ ^[a-z]+$ ]] || die "bad name: $ONLY"
    [ -f "$SRC/files/usr/local/bin/$ONLY" ] || die "no such program in files/usr/local/bin: $ONLY"
    say "Updating $ONLY only"
    put 755 "/usr/local/bin/$ONLY" < "$SRC/files/usr/local/bin/$ONLY"
    if [ -z "$STAGE" ]; then
        case "$ONLY" in
            cdui|cdbutton|cdremote) systemctl restart "$ONLY" && echo "  restarted $ONLY" ;;
            cdplay) echo "  cdplay takes effect at the next disc insert (not restarted: it may be loading now)" ;;
            *) echo "  no service to restart" ;;
        esac
    fi
    exit 0
fi

# =============================================================================
say "1/9  Packages"
if [ -z "$STAGE" ] && [ "$DO_APT" -eq 1 ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y mpd mpc cdparanoia sg3-utils eject alsa-utils bluez \
        python3-gpiozero python3-lgpio usbutils curl sudo
else
    echo "  skipped"
fi

# =============================================================================
say "2/9  Settings file"
put 644 /etc/swn-core.conf < "$SRC/files/etc/swn-core.conf"

# =============================================================================
say "3/9  Programs in /usr/local/bin"
put 755 /usr/local/bin/cdplay < "$SRC/files/usr/local/bin/cdplay"
put 755 /usr/local/bin/cdtag < "$SRC/files/usr/local/bin/cdtag"
put 755 /usr/local/bin/cdeject < "$SRC/files/usr/local/bin/cdeject"
put 755 /usr/local/bin/cdbutton < "$SRC/files/usr/local/bin/cdbutton"
put 755 /usr/local/bin/cdremote < "$SRC/files/usr/local/bin/cdremote"
put 755 /usr/local/bin/cdui < "$SRC/files/usr/local/bin/cdui"
put 755 /usr/local/bin/cdverify < "$SRC/files/usr/local/bin/cdverify"
put 755 /usr/local/bin/cdcompare < "$SRC/files/usr/local/bin/cdcompare"

put 755 /usr/local/bin/cdpair < "$SRC/files/usr/local/bin/cdpair"

put 755 /usr/local/bin/cdcheck < "$SRC/files/usr/local/bin/cdcheck"

# =============================================================================
say "4/9  udev rules"
put 644 /etc/udev/rules.d/98-cdplay.rules < "$SRC/files/etc/udev/rules.d/98-cdplay.rules"
put 644 /etc/udev/rules.d/99-superdrive.rules < "$SRC/files/etc/udev/rules.d/99-superdrive.rules"

# =============================================================================
say "5/9  Permission to eject without a password (for $CD_USER)"
put 440 /etc/sudoers.d/cdeject < "$SRC/files/etc/sudoers.d/cdeject"
if [ -z "$STAGE" ]; then
    if ! visudo -cf /etc/sudoers.d/cdeject >/dev/null; then
        rm -f /etc/sudoers.d/cdeject
        die "generated sudoers file was invalid and has been removed"
    fi
fi

# =============================================================================
say "6/9  RAM disk (fstab)"
FSTAB_LINE="tmpfs /run/cdmem tmpfs defaults,noatime,size=${RAM_MB}m,mode=1777,x-systemd.mkdir 0 0"
FSTAB="$ROOT/etc/fstab"
mkdir -p "$(dirname "$FSTAB")"; touch "$FSTAB"
if grep -qxF "$FSTAB_LINE" "$FSTAB"; then
    echo "  unchanged  /etc/fstab"
else
    mkdir -p "$ROOT$BACKUP_DIR"; cp -p "$FSTAB" "$ROOT$BACKUP_DIR/fstab"
    grep -v '[[:space:]]/run/cdmem[[:space:]]' "$FSTAB" > "$FSTAB.new" || true
    echo "$FSTAB_LINE" >> "$FSTAB.new"
    cat "$FSTAB.new" > "$FSTAB"; rm -f "$FSTAB.new"
    echo "  updated    /etc/fstab   (old copy in $BACKUP_DIR)"
    CHANGED=1
fi

# =============================================================================
say "7/9  MPD configuration"
put 644 /etc/mpd.conf < "$SRC/files/etc/mpd.conf"

# =============================================================================
say "8/9  Services"
put 644 /etc/systemd/system/cdbutton.service < "$SRC/files/etc/systemd/system/cdbutton.service"
put 644 /etc/systemd/system/cdremote.service < "$SRC/files/etc/systemd/system/cdremote.service"
put 644 /etc/systemd/system/cdui.service < "$SRC/files/etc/systemd/system/cdui.service"
put 644 /etc/systemd/system/cdui.service.d/port80.conf < "$SRC/files/etc/systemd/system/cdui.service.d/port80.conf"

# idle image
IDLE_DIR="$ROOT/usr/local/share/cdui"
mkdir -p "$IDLE_DIR"
if [ -n "$IDLE_IMAGE" ]; then
    rm -f "$IDLE_DIR"/idle.*
    cp "$IDLE_IMAGE" "$IDLE_DIR/idle.${IDLE_IMAGE##*.}"
    chmod 644 "$IDLE_DIR"/idle.*
    echo "  idle image installed"
elif ls "$IDLE_DIR"/idle.* >/dev/null 2>&1; then
    echo "  idle image kept"
else
    echo "  no idle image given (the page shows just the title; put a picture in files/usr/local/share/cdui/idle.png or use --idle FILE)"
fi

if [ -z "$STAGE" ]; then
    usermod -aG cdrom,audio "$CD_USER" || true
    # lets the page read the remote's battery from BlueZ even if D-Bus policy requires it
    getent group bluetooth >/dev/null && usermod -aG bluetooth "$CD_USER" || true
fi

# =============================================================================
say "9/9  Starting everything"
if [ -n "$STAGE" ]; then
    echo "  stage mode: nothing started"
else
    udevadm control --reload
    systemctl daemon-reload
    # mount (or resize) the RAM disk
    if mountpoint -q /run/cdmem; then mount -o remount /run/cdmem; else mount /run/cdmem; fi
    # wake the drive now if it is already plugged in
    if [ -e /dev/sr0 ]; then sg_raw /dev/sr0 EA 00 00 00 00 00 01 >/dev/null 2>&1 || true; fi
    systemctl enable bluetooth >/dev/null 2>&1 || true
    systemctl restart bluetooth
    systemctl enable mpd >/dev/null 2>&1 || true
    systemctl restart mpd
    for u in cdui cdbutton cdremote; do
        systemctl enable "$u" >/dev/null 2>&1
        systemctl restart "$u" || echo "  WARNING: $u did not start - see: journalctl -u $u"
    done
    sleep 3
    echo
    echo "== Self-check =="
    /usr/local/bin/cdcheck || true
fi

cat <<EOF

Done.

Next:
  1. Pair the remote (once):        sudo cdpair
  2. Open the page:                  http://$(hostname).local/   (or the Pi's IP address)
  3. Plug in the SuperDrive and the Audio device, push an audio CD in.
  4. Check everything any time:     sudo cdcheck

Not tested from scratch on a clean Pi: if anything above fails, send me the
output of 'sudo cdcheck' and 'journalctl -u cdplay -u cdui -u cdremote -b'.
EOF
