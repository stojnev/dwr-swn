#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="CD Memory Player"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TARGET_USER="${SUDO_USER:-${USER:-}}"
BACKUP_ROOT="/var/backups/cd-memory-player"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/${STAMP}"
INSTALL_LOG="/var/log/cd-memory-player-install.log"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$INSTALL_LOG"; }
die() { log "ERROR: $*"; exit 1; }
backup_file() {
    local f="$1"
    if [[ -e "$f" || -L "$f" ]]; then
        mkdir -p "${BACKUP_DIR}$(dirname "$f")"
        cp -a "$f" "${BACKUP_DIR}${f}"
        log "Backed up $f to ${BACKUP_DIR}${f}"
    fi
}
install_file() {
    local src="$1" dst="$2" mode="${3:-0644}"
    backup_file "$dst"
    install -D -m "$mode" "$SCRIPT_DIR/$src" "$dst"
}
trap 'rc=$?; if [[ $rc -ne 0 ]]; then log "Installation failed (exit $rc). Backups, if any, are in $BACKUP_DIR"; fi' EXIT

[[ $EUID -eq 0 ]] || die "Run with sudo: sudo ./install.sh"
[[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]] || die "Could not determine the login user. Run with sudo from the intended user account."
id "$TARGET_USER" >/dev/null 2>&1 || die "User $TARGET_USER does not exist."
[[ -f "$SCRIPT_DIR/bin/cdui" && -f "$SCRIPT_DIR/config/mpd.conf" ]] || die "Run this installer from the extracted package directory."

. /etc/os-release
case "${ID:-}" in
    debian|raspbian) ;;
    *) die "This installer targets Debian/Raspberry Pi OS. Detected ID=${ID:-unknown}." ;;
esac

ARCH="$(dpkg --print-architecture)"
[[ "$ARCH" == "arm64" || "$ARCH" == "armhf" ]] || die "Expected Raspberry Pi ARM architecture; detected $ARCH."

mkdir -p "$BACKUP_DIR"
touch "$INSTALL_LOG"
log "Installing $APP_NAME for user $TARGET_USER on ${PRETTY_NAME:-Debian}."

PACKAGES=(
    mpd mpc cdparanoia eject sg3-utils alsa-utils
    python3 python3-gpiozero python3-rpi-lgpio sudo
)
log "Installing dependencies: ${PACKAGES[*]}"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y "${PACKAGES[@]}"

# Runtime user permissions.
for group in cdrom audio gpio; do
    getent group "$group" >/dev/null && usermod -aG "$group" "$TARGET_USER" || true
done

# Install scripts. Diagnostic tools are included; the alternate cdplay.v2 is not activated.
for name in cdplay cdtag cdeject cdbutton cdui cdverify cdcompare; do
    install_file "bin/$name" "/usr/local/bin/$name" 0755
done
install -d -o root -g root -m 0755 /usr/local/share/cdui
install_file "share/cdui/idle.png" "/usr/local/share/cdui/idle.png" 0644

# MPD configuration from the supplied working system, with ALSA device set to "default".
install_file "config/mpd.conf" "/etc/mpd.conf" 0644
install -d -o mpd -g audio -m 0750 /var/lib/mpd /var/lib/mpd/playlists
chown -R mpd:audio /var/lib/mpd 2>/dev/null || true

# RAM-backed CD audio directory. Add only if no existing mount entry targets /run/cdmem.
if ! awk '$2=="/run/cdmem" {found=1} END {exit !found}' /etc/fstab; then
    backup_file /etc/fstab
    printf '\n# CD Memory Player: audio tracks are staged in RAM\ntmpfs /run/cdmem tmpfs defaults,noatime,size=900m,mode=1777,x-systemd.mkdir 0 0\n' \
        >> /etc/fstab
    log "Added /run/cdmem tmpfs entry to /etc/fstab."
else
    log "/run/cdmem already has an /etc/fstab entry; leaving it unchanged."
fi
mkdir -p /run/cdplay-work
chmod 1777 /run/cdplay-work

# sudo permission is narrowly scoped to the eject helper.
SUDOERS_FILE="/etc/sudoers.d/cdeject"
backup_file "$SUDOERS_FILE"
printf '%s ALL=(root) NOPASSWD: /usr/local/bin/cdeject\n' "$TARGET_USER" > "$SUDOERS_FILE"
chmod 0440 "$SUDOERS_FILE"
visudo -cf "$SUDOERS_FILE" >/dev/null || die "Invalid sudoers configuration."

# systemd units and port-80 capability override.
install_file "systemd/cdbutton.service" "/etc/systemd/system/cdbutton.service" 0644
install_file "systemd/cdui.service" "/etc/systemd/system/cdui.service" 0644
install_file "systemd/cdui.service.d/port80.conf" "/etc/systemd/system/cdui.service.d/port80.conf" 0644

# udev rules for audio-CD detection and Apple SuperDrive initialization.
install_file "udev/98-cdplay.rules" "/etc/udev/rules.d/98-cdplay.rules" 0644
install_file "udev/99-superdrive.rules" "/etc/udev/rules.d/99-superdrive.rules" 0644

systemctl daemon-reload
systemctl enable mpd.service cdbutton.service cdui.service
systemctl restart mpd.service
udevadm control --reload-rules

# Mount RAM disk now if not already mounted.
if ! mountpoint -q /run/cdmem; then
    mount /run/cdmem || log "WARNING: /run/cdmem did not mount immediately; it should mount on reboot."
fi
mkdir -p /run/cdplay-work
chmod 1777 /run/cdplay-work

systemctl restart cdbutton.service
systemctl restart cdui.service

log "Installation completed."
log "Web interface: http://$(hostname -I | awk '{print $1}')/"
log "A reboot is recommended so the new group memberships and udev rules take effect."
log "Backup directory: $BACKUP_DIR"
log "NOTE: MPD uses ALSA device 'default'; ensure the desired USB audio interface is selected as the system ALSA default."
