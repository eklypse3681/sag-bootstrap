# Unattended provisioning from a USB stick

Turns first boot of a factory machine into: plug in stick, power on, walk away.
The machine comes up named, on the network, in the tailnet, and bootstrapped —
ready for `fleet sync --apply`.

## Why this works on an OEM machine

You do **not** need to reinstall Windows. Microsoft's [implicit answer file search
order](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-setup-automation-overview)
says Setup searches for answer files *"at the beginning of each configuration
pass, including the initial installation and after applying and booting an
image"*, and removable media is position 4 in that order. A factory machine that
has never completed OOBE runs the `oobeSystem` pass on first boot, finds
`Autounattend.xml` at the root of the stick, and uses it.

**The known risk:** `%WINDIR%\Panther` is precedence 3 — higher than removable
media. If the OEM left an unprocessed answer file there, theirs wins and this is
ignored. If that happens, see *When it doesn't work* below.

## Build a stick

```bash
export COMPUTER_NAME=SAG-AIR12-LITE-101
export ADMIN_PASSWORD='...'                 # local break-glass account
export TAILSCALE_AUTH_KEY='tskey-auth-...'  # tagged, reusable, pre-approved
export WIFI_PROFILE=~/wifi-fireflood.xml    # optional; omit if wired

./unattend/make-usb.sh /Volumes/YOUR_USB
```

Any FAT32/exFAT stick works — it does not need to be Windows install media, and
nothing else on the stick is touched.

### Getting the wifi profile

Export it from a machine already on the network. It must be `key=clear`: an
encrypted export is bound to the exporting machine's DPAPI and will not import
anywhere else.

```powershell
netsh wlan export profile name="FireFlood" key=clear folder=C:\Temp
```

## What happens on first boot

1. OOBE is skipped entirely — no region, keyboard, EULA or Microsoft account
2. The local admin account is created
3. One automatic logon runs `fleet\setup.ps1`, which:
   - imports the wifi profile with `user=all`, so the machine is online at the
     login screen rather than only after someone signs in
   - waits up to 5 minutes for internet
   - downloads and runs `bootstrap.ps1` with the computer name and auth key
   - **purges every copy of the secrets** (see below)
4. Autologon reverts; the machine sits at the login screen, in the tailnet

Then, from your Mac: `fleet sync --apply`.

## The purge

The stick holds the admin password, the Tailscale key and the wifi key in
plaintext — it is a credential, so keep it with you and rotate the Tailscale key
when you have finished provisioning.

More importantly, **Windows copies the answer file to `%WINDIR%\Panther` and it
survives reboots**. Setup scrubs fields it recognises as `<Password>`, but it does
**not** scrub arbitrary text inside `FirstLogonCommands` — so the auth key would
otherwise sit in plaintext on the disk permanently. `setup.ps1` therefore
overwrites-then-deletes all of:

- `Autounattend.xml` on the stick
- `fleet\setup.ps1` and `fleet\wifi.xml` on the stick
- `%WINDIR%\Panther\unattend.xml`
- `%WINDIR%\Panther\Unattend\unattend.xml`
- `%WINDIR%\System32\Sysprep\unattend.xml`

This runs in a `finally` block, so it happens even when the bootstrap fails.

## When it doesn't work

**This has not been tested end to end** — it cannot be validated without running
it on real hardware. Check `C:\ProgramData\ClinicFleet\unattend.log` first; it
records every step.

| Symptom | Likely cause |
|---|---|
| Normal OOBE appears, stick ignored | OEM answer file in `%WINDIR%\Panther` outranked it |
| OOBE skipped but nothing else ran | `FirstLogonCommands` failed — check the log |
| Stalls asking for a Microsoft account | `HideOnlineAccountScreens` behaviour changes between builds |
| No network | wifi profile not imported as `user=all`, or wrong SSID |

Fallback if the OEM file wins: at the first OOBE screen press **Shift+F10** and run
`powershell -ExecutionPolicy Bypass -File D:\fleet\setup.ps1` (adjust the drive
letter). That skips the answer-file mechanism entirely and still beats doing it
by hand.
