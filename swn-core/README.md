# sŵn – installation

`install.sh` rebuilds full sŵn functionality on a fresh Pi.

## Needs

- Raspberry Pi 5 (2 GB is enough), official 27 W supply;
- Apple SuperDrive and a USB audio device, both on USB ports of the Pi;
- A momentary push button between **GPIO17 (physical pin 11)** and **ground (physical pin 9)**. No resistor needed;
- Apple Siri Remote (Bluetooth);
- microSD card, a computer to flash it, network (cable is best);
- Optional: a picture for the idle screen (png, jpg, webp, gif or svg).

## Steps

1. **Flash** *Raspberry Pi OS Lite (64-bit)* (Debian 13 "trixie") with Raspberry Pi Imager. In the Imager settings set the host name, create the user (`swn`, or another name), enable SSH, and set Wi-Fi if you are not using a cable.
2. **Boot, log in over SSH**, and update: `sudo apt update && sudo apt full-upgrade -y && sudo reboot`
3. **Copy the whole `swn-core` folder to the Pi**. `install.sh` must stay next to its `files/` folder.
4. **Run it:**
   ```
   cd swn-core
   chmod +x install.sh
   sudo ./install.sh --idle ../idle.png
   ```
   Everything is installed and started. It ends with a self-check.
5. **Pair the remote** (once): `sudo cdpair` – when it asks, hold **Back (<) and Volume Up** together for about 5 seconds.
6. **Plug in** the SuperDrive and the USB audio device, push a disc in, open `http://<host name>.local/`.
7. **Check:** `sudo cdcheck`

The installer can be run again at any time; it only changes what differs and keeps copies of replaced files in `/var/backups/swn-core/`.

## Settings

Set by option or environment variable. The last used values are remembered in `/etc/swn-core.conf`.

| Setting | Option | Default | Meaning |
|---|---|---|---|
| `CD_USER` | `--user` | `swn` | User that runs the web page and may eject without a password. |
| `REMOTE_ADDR` | `--remote` | `60:BE:C4:18:43:90` | Bluetooth address of the Siri Remote (used by `cdpair` and `cdcheck`). |
| `AUDIO_CARD` | `--card` | `D20` | ALSA card name of the DAC (`aplay -l`, the word after `card N:`). |
| `BUTTON_GPIO` | `--gpio` | `17` | BCM number of the eject button. |
| `RAM_MB` | `--ram` | `900` | RAM disk size. 900 MB holds about 89 minutes of CD audio. |

The button and the remote are always installed. The remote address is not used by `cdremote` itself (it listens to any paired Siri Remote); it is used for pairing and checking.

## Services

| Item | Purpose |
|---|---|
| `cdplay` | On disc insert: reads the table of contents, loads track 1 head first, starts playing, then loads the rest into.RAM |
| `cdtag` | MusicBrainz lookup (title, artist, cover) and file tags. |
| `cdeject` | Stops everything, empties RAM, ejects. |
| `cdui` | Web page and API on port 80. |
| `cdbutton` | Eject button on the GPIO pin. |
| `cdremote` | Siri Remote: Click/Play-Pause toggle, Right next, Left previous, Back stop, Siri eject. |
| `cdpair`, `cdcheck` | Pairing helper and the checker. |
| `cdverify`, `cdcompare` .| Diagnostics for checking loaded audio against the disc |
| udev rules | **SuperDrive wake-up command** (`sg_raw ... EA 00 00 00 00 00 01`, without it the drive will not pull the disc in) and "start `cdplay` when a disc is read". |
| `/etc/mpd.conf` | Music directory = RAM disk, ALSA output to the audio device. |
| fstab line | The RAM disk `/run/cdmem.` |
| sudoers rule | Lets your user run `cdeject` without a password. |

## Rules

- Playback is from RAM only; MPD's music directory is the RAM disk.
- Keep `audio_buffer_size "4096"` in `/etc/mpd.conf`. Larger values crashed this MPD build or played the not yet written end of track 1 as silence.
- No `state_file` in MPD.
- Reads are unverified (`cdparanoia -q -Z`) for speed; a verified read is slower.

## Verification

1. `sudo cdcheck` shows no FAIL.
2. Insert a disc: the drive pulls it in, the page shows "Loading", playback starts after a few seconds.
3. `findmnt /run/cdmem` shows `tmpfs`.
4. A track change is gapless.
5. The button ejects, and `ls /run/cdmem` is empty afterwards.
6. Siri Remote: Click toggles, Right = next, Left = previous, Back = stop, Siri button = eject.
7. Reboot, then check 2–6 again.

## Troubleshooting

- **Disc is not pulled in:** the wake-up rule did not run. Unplug and replug the drive, or run `sudo sg_raw /dev/sr0 EA 00 00 00 00 00 01`. Check `lsusb` for `05ac:1500`.
- **Nothing plays / MPD error:** `journalctl -u mpd -b`, and make sure the buffer is still 4096.
- **No sound card:** `aplay -l`; if the card has a different name, reinstall with `--card NAME`.
- **No title or cover:** MusicBrainz may be down; it retries three times. The disc plays anyway as Track 01…
- **Slow load:** the drive speed varies from disc to disc; check `sudo systemctl status cdplay` and `journalctl -u cdplay -b`.
- **Button does nothing:** `systemctl status cdbutton`, check the GPIO number and wiring.
- **Pi under-voltage:** `vcgencmd get_throttled` should print `0x0`.
- **Remote silent:** `sudo systemctl restart cdremote`, then `journalctl -u cdremote -f` while pressing a button. If it was never paired, run `sudo cdpair`. cdremote reads the remote through `btmon`, because BlueZ cannot read this remote's HID reports.

### Remote Pairing

```
sudo bluetoothctl
power on
agent NoInputNoOutput
default-agent
scan on
```

Hold Back + Volume Up for about 5 seconds until the address shows up, then `pair <address>`, `trust <address>`, `connect <address>`, `quit`, and `sudo systemctl restart cdremote`. 
