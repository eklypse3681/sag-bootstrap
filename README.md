# sag-bootstrap

A single PowerShell script that turns a stock Windows machine into a remotely
manageable endpoint: named, reachable over Tailscale, and ready for the
fleet-management tool to take over.

It deliberately stops there. Account provisioning, policy, inventory, software
deployment and BitLocker escrow belong to the fleet tool, not to this script.

**There are no secrets in this repository, and the script never writes one to disk.**

## Quick start

On the target machine, open PowerShell **as Administrator**:

```powershell
irm https://raw.githubusercontent.com/eklypse3681/sag-bootstrap/main/bootstrap.ps1 | iex
```

That is the whole setup. The machine keeps the name it already has — the script
reads it off the machine, so nothing needs to be typed in.

If your execution policy blocks the pipe, download and run instead:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
irm https://raw.githubusercontent.com/eklypse3681/sag-bootstrap/main/bootstrap.ps1 -OutFile $env:TEMP\bootstrap.ps1
& $env:TEMP\bootstrap.ps1
```

### With Tailscale enrollment in one pass

Enroll the machines as **tagged** nodes, not as user-owned ones. A tagged node is
owned by the tailnet rather than by the person who ran the script, so:

- its node key **does not expire** (user-owned keys expire after 180 days by
  default, and the machine silently drops off the tailnet — on exactly the
  machines you have no other way to reach),
- it survives that person's account being suspended or deleted,
- you can write ACLs against the tag instead of per-machine.

**1. Define the tag** in the tailnet policy file — admin console → **Access
controls**. A tag that isn't declared here cannot be used, and enrollment fails:

Note `autogroup:member` rather than `autogroup:admin` in `src`: `autogroup:admin`
covers only the Admin role and **excludes the tailnet Owner**, so on a small
tailnet it can silently grant access to nobody.

```jsonc
{
  "tagOwners": {
    "tag:clinic-workstation": ["autogroup:admin"]
  },
  "acls": [
    { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:clinic-workstation:22,3389"] }
  ]
}
```

**2. Create a pre-authorized auth key** with that tag selected
([admin console → Keys](https://login.tailscale.com/admin/settings/keys)),
reusable, ephemeral **off**. The tag travels with the key, so the script needs
nothing else:

```powershell
$env:TAILSCALE_AUTH_KEY = "tskey-auth-..."
irm https://raw.githubusercontent.com/eklypse3681/sag-bootstrap/main/bootstrap.ps1 | iex
```

If your key is untagged, name the tags instead (`tag:` is added if you leave it off):

```powershell
$env:TAILSCALE_TAGS = "tag:clinic-workstation"
```

Don't do both with *different* tags — Tailscale rejects a key whose tags conflict
with `--advertise-tags`.

The key is passed to `tailscale up` and nothing else. It is never written to the
log or to disk. Without a key the script still installs Tailscale and leaves it
for you to enroll manually with `tailscale up --unattended`.

After enrollment the script reports the node's tags, and **warns** if the machine
came up user-owned. A node that is already enrolled is not re-tagged on a re-run;
change its tags in the admin console or re-run `tailscale up --advertise-tags=...`.

## Machine naming

The script does **not** rename anything. It reads the machine's **full** computer
name and uses it as the Tailscale hostname.

Note this is not `$env:COMPUTERNAME`, which is the NetBIOS name truncated to 15
characters. `SAG-AIR12-LITE-01` and `SAG-AIR12-LITE-02` both truncate to
`SAG-AIR12-LITE-`, so deriving the Tailscale hostname from the short name would
collide. The script reads `Win32_ComputerSystem.DNSHostName` instead and warns
when the two differ. Since your machines are
already named, the same command line works on all of them.

If you ever do need to rename a box (a fresh install still sitting on
`DESKTOP-XXXXXXX`, say), pass a name explicitly:

```powershell
.\bootstrap.ps1 -ComputerName HB-FRONT-01
```

That validates the hostname, renames, and flags that a reboot is needed. The
script finishes all remaining work first, then tells you; it never reboots on
its own unless you pass `-AutoReboot`. Without `-ComputerName` no rename can
happen, so in the normal case there is usually nothing to reboot for.

A machine still carrying a stock Windows name (`DESKTOP-*`, `LAPTOP-*`, `WIN-*`,
`MININT-*`) is flagged in the log as a heads-up. Nothing is changed.

## Parameters

| Parameter | Default | Purpose |
|---|---|---|
| `-ComputerName` | *(none)* | Rename the machine. Omit to keep the current name. |
| `-BreakGlassAdmin` | `SAGAdmin` | Account to verify (never modify) as break-glass. |
| `-TailscaleAuthKey` | `$env:TAILSCALE_AUTH_KEY` | Enroll non-interactively. |
| `-Tags` | `$env:TAILSCALE_TAGS` | ACL tags to enroll with. Unnecessary if the auth key is already tagged. |
| `-SkipTailscale` | off | Do not install or enroll Tailscale. |
| `-RestrictRdpToTailscale` | off | Scope RDP to `100.64.0.0/10`. **Will cut a LAN RDP session.** |
| `-AutoReboot` | off | Reboot at the end if required. |

## What it changes

| Area | Change |
|---|---|
| Name | **Nothing** unless you pass `-ComputerName`. The existing name is read and reported. |
| Accounts | **Nothing.** Existing admins are listed for the log and left untouched; `SAGAdmin` is verified only. |
| RDP | `fDenyTSConnections=0`, NLA required (`UserAuthentication=1`, `SecurityLayer=2`), built-in Remote Desktop firewall rules enabled. |
| SSH | Installs the `OpenSSH.Server` capability, `sshd` set to Automatic and started, default shell set to PowerShell. |
| SSH keys | Authorises the public keys listed in `$script:AdminPublicKeys` for administrator logins, in `C:\ProgramData\ssh\administrators_authorized_keys` with permissions locked to Administrators and SYSTEM. Adds only; never removes. |
| Firewall | Adds `ClinicFleet-SSH-Tailscale` (TCP 22, source `100.64.0.0/10`, program `sshd.exe`) and **disables** the default allow-from-anywhere `OpenSSH-Server-In-TCP`. Re-enables any firewall profile found switched off. Never disables the firewall. |
| Tailscale | Installs current stable MSI with `TS_UNATTENDEDMODE=always`, service set to Automatic, `tailscale set --unattended=true`. Enrolls with tags when given; reports tag ownership and warns if the node is user-owned. |
| Power | `standby-timeout-ac 0` and `hibernate-timeout-ac 0`. Battery settings and display sleep are untouched. |
| BitLocker | **Read only.** Reports protection status and whether a recovery protector exists. Never prints a recovery key. |

Everything is idempotent — running it twice changes nothing the second time.

### Reverting

```powershell
# power
powercfg /change standby-timeout-ac 30
powercfg /change hibernate-timeout-ac 180

# SSH exposure
Remove-NetFirewallRule -Name ClinicFleet-SSH-Tailscale
Enable-NetFirewallRule  -Name OpenSSH-Server-In-TCP     # allow SSH from any source again

# RDP
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 1
Disable-NetFirewallRule -Name RemoteDesktop-UserMode-In-TCP, RemoteDesktop-UserMode-In-UDP
```

## Security notes

- No auth key, password, or recovery key is in this repo or written to the log.
- SSH is reachable only from the Tailscale range; access control itself belongs
  in your Tailscale ACLs.
- The SSH **public** keys in the script are not secrets — the private keys never
  leave the operator's machine. To revoke, delete the line and remove the key
  from the machines; the script only ever adds keys, so it cannot silently strip
  your own access.
- Nothing is exposed to the internet. No port forwarding is configured, and none
  should be — reach these machines over Tailscale.
- RDP keeps Network Level Authentication on. Windows authentication is not weakened.

## After it runs

Verify from another machine on the tailnet:

```powershell
tailscale status                  # node is listed, online, and shows its tag
ssh SAGAdmin@100.x.y.z            # lands in PowerShell
mstsc /v:100.x.y.z                # RDP over Tailscale
```

Reboot the machine, log out, and confirm it is still
reachable — Tailscale runs as a system service, so it comes back before anyone
logs in.

Log: `C:\ProgramData\ClinicFleet\bootstrap.log`

## License

MIT — see [LICENSE](LICENSE).
