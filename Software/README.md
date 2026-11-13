# sŵn Memory Player Installation (UNTESTED)

Target: Raspberry Pi OS / Debian 13 on Raspberry Pi, ARM64 or ARMHF.

**NB - keep in mind that this script is not fully tested, and no guarantees are or will be given as to its success.**

## What this installs

- The supplied CD extraction/playback scripts (`cdplay`, `cdtag`, `cdeject`);
- The GPIO eject-button daemon (`cdbutton`, GPIO17);
- The web interface (`cdui`) on TCP port 80;
- MPD and its configuration from the supplied system;
- Audio-CD udev detection and Apple SuperDrive initialization rules;
- The 900 MB `/run/cdmem` tmpfs mount;
- A narrowly scoped passwordless sudo rule for `cdeject`;
- Diagnostic utilities `cdverify` and `cdcompare`.

The supplied alternate `cdplay.v2` is retained under `optional/` for reference and is not installed or activated.

## Audio output behavior

MPD's ALSA output is configured with `device "default"`. It does not hardcode an ALSA card number. The actual target is whatever ALSA resolves as the system default for the MPD service.

If a user-specific `~/.asoundrc` is used, note that the system MPD daemon normally runs as user `mpd` and will not automatically use the login user's ALSA configuration. Prefer a system-wide `/etc/asound.conf` for a device selection intended for MPD, or configure ALSA's global default appropriately.

## Install

Extract the archive, enter the directory, and run:

```bash
sudo ./install.sh
```

The installer:
- Checks Debian/Raspberry Pi OS and ARM architecture;
- Installs the required Debian packages;
- Adds the invoking login user to `cdrom`, `audio`, and `gpio` groups when those groups exist;
- Backs up files it replaces under `/var/backups/cd-memory-player/<timestamp>/`;
- Enables MPD, cdbutton and cdui;
- Reloads systemd and udev.

A reboot is recommended after installation so new group memberships and udev rules are fully applied.

## Uninstall

```bash
sudo ./uninstall.sh
```

The uninstaller removes player-specific scripts, units, udev rules, artwork and sudoers rule. It deliberately retains MPD, `/etc/mpd.conf`, `/etc/fstab`, installed packages and backups to avoid destroying unrelated configuration.

## Important notes

1. The installer preserves the supplied MPD configuration while setting ALSA `default`.
2. `cdplay` is started by the supplied udev rule as a transient systemd unit named `cdplay`; there is intentionally no permanent `cdplay.service`.
3. The project expects the optical drive at `/dev/sr0`. The Apple SuperDrive initialization rule is specific to USB vendor/product `05ac:1500`.
4. The web UI is an unauthenticated HTTP interface bound to all network interfaces on port 80. Use it only on a trusted local network.
5. The original MPD configuration includes `include_optional "mpd_local.conf"`; this installer does not create or overwrite that optional file.
