#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo ./uninstall.sh"; exit 1; }

echo "This removes the CD Memory Player services, scripts, udev rules and sudoers entry."
echo "It does not remove MPD or shared system packages, and it leaves /etc/mpd.conf and /etc/fstab in place."
read -r -p "Continue? [y/N] " answer
[[ "$answer" =~ ^[Yy]$ ]] || exit 0

systemctl disable --now cdui.service cdbutton.service 2>/dev/null || true
systemctl stop cdplay.service 2>/dev/null || true
rm -f /etc/systemd/system/cdui.service /etc/systemd/system/cdbutton.service
rm -rf /etc/systemd/system/cdui.service.d
rm -f /etc/udev/rules.d/98-cdplay.rules /etc/udev/rules.d/99-superdrive.rules
rm -f /etc/sudoers.d/cdeject
for name in cdplay cdtag cdeject cdbutton cdui cdverify cdcompare; do
    rm -f "/usr/local/bin/$name"
done
rm -rf /usr/local/share/cdui
systemctl daemon-reload
udevadm control --reload-rules
echo "Player services and files removed. MPD, its configuration, packages, and /run/cdmem fstab entry were retained."
echo "To restore earlier configuration, inspect /var/backups/cd-memory-player/."
