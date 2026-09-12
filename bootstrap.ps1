<#
.SYNOPSIS
    Turns a stock Windows machine into a remotely manageable endpoint
    (name + RDP + OpenSSH + Tailscale), ready for the fleet-management tool.

.DESCRIPTION
    Safe to host publicly: contains no secrets of any kind.
    Idempotent: re-running is a no-op on an already-configured machine.
    Non-destructive: never removes or modifies existing administrator accounts,
    never disables the firewall, never enables/alters BitLocker.

    The machine keeps whatever name it already has; the script reads it and
    reports it, so the one-liner below needs no arguments.

.PARAMETER ComputerName
    Only needed to RENAME the machine. Omit it to keep the current name.
    A rename requires a reboot.

.PARAMETER BreakGlassAdmin
    Name of the expected local break-glass administrator (default "SAGAdmin").
    Checked only: the script never creates, renames, disables or alters accounts.

.PARAMETER TailscaleAuthKey
    Tailscale auth key. Defaults to $env:TAILSCALE_AUTH_KEY. Never logged,
    never written to disk. Omit it to install Tailscale and enroll manually.

.PARAMETER Tags
    ACL tags to enroll with, e.g. "tag:clinic-workstation". Defaults to
    $env:TAILSCALE_TAGS. Tagged nodes are owned by the tailnet rather than by a
    person and their keys do not expire, which is what an unattended machine
    needs. Omit this if the auth key already carries its tags (the usual case).

.PARAMETER SkipTailscale
    Do not install or enroll Tailscale.

.PARAMETER RestrictRdpToTailscale
    Scope the Windows RDP firewall rules to the Tailscale range (100.64.0.0/10).
    Off by default: it will cut a LAN RDP session, including the one you may be
    running this from.

.PARAMETER AutoReboot
    Reboot automatically at the end if a reboot is required.

.EXAMPLE
    irm https://raw.githubusercontent.com/eklypse3681/sag-bootstrap/main/bootstrap.ps1 | iex

.EXAMPLE
    $env:TAILSCALE_AUTH_KEY = 'tskey-auth-xxxx'   # a TAGGED, pre-authorized key
    irm https://raw.githubusercontent.com/eklypse3681/sag-bootstrap/main/bootstrap.ps1 | iex

.EXAMPLE
    .\bootstrap.ps1 -ComputerName HB-FRONT-01 -AutoReboot   # only to rename
#>
[CmdletBinding()]
param(
    [string] $ComputerName,
    [string] $BreakGlassAdmin = 'SAGAdmin',
    [string] $TailscaleAuthKey = $env:TAILSCALE_AUTH_KEY,
    [string[]] $Tags = $env:TAILSCALE_TAGS,
    [switch] $SkipTailscale,
    [switch] $RestrictRdpToTailscale,
    [switch] $AutoReboot
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

$script:AppName        = 'ClinicFleet'
$script:LogDir         = Join-Path $env:ProgramData $script:AppName
$script:LogFile        = Join-Path $script:LogDir 'bootstrap.log'
$script:TailscaleCgnat = '100.64.0.0/10'
$script:TailscaleExe   = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
$script:Failures       = @()
$script:RebootRequired = $false
$script:TargetName     = $env:COMPUTERNAME
$script:S              = [ordered]@{      # summary fields, in display order
    'Machine'         = $env:COMPUTERNAME
    'Windows'         = 'unknown'
    'Break-glass'     = 'not checked'
    'RDP'             = 'not configured'
    'SSH'             = 'not configured'
    'Tailscale'       = 'not installed'
    'Tailscale IP'    = '-'
    'Tailscale name'  = '-'
    'Tailscale tags'  = '-'
    'BitLocker'       = 'unknown'
    'Firewall'        = 'unknown'
    'Power'           = 'unchanged'
    'Reboot required' = 'No'
    'Log'             = $null
}

#--------------------------------------------------------------------- logging

function Write-Log {
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'STEP')][string] $Level = 'INFO'
    )
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $color = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'STEP'  { 'Cyan' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
    try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
}

function Invoke-Step {
    param([Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][scriptblock] $Action)
    Write-Log "== $Name" 'STEP'
    try {
        & $Action
    } catch {
        Write-Log "$Name failed: $($_.Exception.Message)" 'ERROR'
        $script:Failures += $Name
    }
}

#------------------------------------------------------------------- utilities

function Test-HostNameValid {
    param([string] $Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name.Length -gt 63) { return $false }
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*$') { return $false }
    if ($Name.EndsWith('-')) { return $false }
    if ($Name -match '^[0-9]+$') { return $false }
    return $true
}

# $env:COMPUTERNAME is the NetBIOS name, truncated to 15 characters. The real
# name lives in the TCP/IP host name, which is what Tailscale should use.
function Get-FullComputerName {
    try {
        $dns = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).DNSHostName
        if ($dns) { return "$dns".Trim() }
    } catch { }
    return $env:COMPUTERNAME
}

function Test-PendingReboot {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($p in $paths) { if (Test-Path -LiteralPath $p) { return $true } }
    try {
        $sm = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        if ($sm -and $sm.PendingFileRenameOperations) { return $true }
    } catch { }
    try {
        $cn = 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName'
        $active  = (Get-ItemProperty -LiteralPath "$cn\ActiveComputerName" -Name ComputerName).ComputerName
        $pending = (Get-ItemProperty -LiteralPath "$cn\ComputerName"       -Name ComputerName).ComputerName
        if ($active -ne $pending) { return $true }
    } catch { }
    return $false
}

function Get-TailscaleStatus {
    if (-not (Test-Path -LiteralPath $script:TailscaleExe)) { return $null }
    try {
        $json = & $script:TailscaleExe status --json 2>$null | Out-String
        if ([string]::IsNullOrWhiteSpace($json)) { return $null }
        return ($json | ConvertFrom-Json)
    } catch { return $null }
}

#----------------------------------------------------------------- 1. validate

try { if (-not (Test-Path -LiteralPath $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null } } catch { }

Write-Log ('=' * 64)
Write-Log "$script:AppName bootstrap starting (user: $env:USERNAME, host: $env:COMPUTERNAME)"

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ''
    Write-Host 'ERROR: this script must run in an ELEVATED PowerShell window.' -ForegroundColor Red
    Write-Host '       Right-click PowerShell -> Run as administrator, then run it again.' -ForegroundColor Red
    Write-Host ''
    return
}
Write-Log 'Running elevated.' 'OK'

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Log "PowerShell $($PSVersionTable.PSVersion) is too old (need 5.1+)." 'ERROR'
    return
}
Write-Log "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))." 'OK'

$os    = Get-CimInstance -ClassName Win32_OperatingSystem
$build = [int]$os.BuildNumber
$script:S['Windows'] = "$($os.Caption) (build $build)"
if ($build -lt 17763) {
    Write-Log "$($os.Caption) build $build is not supported (need Windows 10 1809 / Server 2019 or newer)." 'ERROR'
    return
}
Write-Log "$($os.Caption) build $build." 'OK'

$online = $false
try { $online = Test-NetConnection -ComputerName 'pkgs.tailscale.com' -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue } catch { }
if ($online) {
    Write-Log 'Internet connectivity confirmed.' 'OK'
} else {
    Write-Log 'No internet connectivity (pkgs.tailscale.com:443 unreachable). Tailscale install will fail.' 'WARN'
}

#-------------------------------------------------------- 2. local admin audit

Invoke-Step 'Local administrators (read-only audit)' {
    $group = (Get-LocalGroup -SID 'S-1-5-32-544').Name
    $members = @()
    try {
        $members = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop)
    } catch {
        # Get-LocalGroupMember chokes on orphaned SIDs; fall back to net.exe
        Write-Log "Get-LocalGroupMember unavailable ($($_.Exception.Message)); using net localgroup." 'WARN'
        $members = @(net localgroup "$group" | Select-Object -Skip 4 |
                     Where-Object { $_.Trim() -and $_ -notmatch '^-+$' -and $_ -notmatch 'completed successfully' } |
                     ForEach-Object { [pscustomobject]@{ Name = $_.Trim(); ObjectClass = 'Unknown' } })
    }
    if ($members.Count -eq 0) { throw "No members found in local group '$group'." }
    foreach ($m in $members) { Write-Log "  admin: $($m.Name) [$($m.ObjectClass)]" }

    # Get-LocalGroupMember returns "MACHINE\User"; the net.exe fallback returns "User".
    $adminLeaves = @($members.Name | ForEach-Object { ("$_" -split '\\')[-1] })
    $enabledLocal = @(Get-LocalUser -ErrorAction SilentlyContinue | Where-Object {
        $_.Enabled -and ($adminLeaves -contains $_.Name)
    })
    if ($enabledLocal.Count -eq 0) {
        Write-Log 'No ENABLED local administrator account detected. Verify break-glass access before rebooting.' 'WARN'
    } else {
        Write-Log "$($enabledLocal.Count) enabled local administrator account(s) present; left untouched." 'OK'
    }

    # Break-glass account: verified, never modified.
    if ($BreakGlassAdmin) {
        $bg = Get-LocalUser -Name $BreakGlassAdmin -ErrorAction SilentlyContinue
        if (-not $bg) {
            Write-Log "Break-glass account '$BreakGlassAdmin' NOT FOUND on this machine. Confirm your recovery access before rebooting." 'WARN'
            $script:S['Break-glass'] = "$BreakGlassAdmin (missing!)"
        } elseif (-not $bg.Enabled) {
            Write-Log "Break-glass account '$BreakGlassAdmin' exists but is DISABLED. Not changed by this script." 'WARN'
            $script:S['Break-glass'] = "$BreakGlassAdmin (disabled!)"
        } elseif ($adminLeaves -notcontains $BreakGlassAdmin) {
            Write-Log "Break-glass account '$BreakGlassAdmin' is enabled but NOT in the Administrators group." 'WARN'
            $script:S['Break-glass'] = "$BreakGlassAdmin (not an admin!)"
        } else {
            Write-Log "Break-glass account '$BreakGlassAdmin': enabled, local administrator, untouched." 'OK'
            $script:S['Break-glass'] = "$BreakGlassAdmin (enabled, admin)"
        }
    }
}

#-------------------------------------------------------------- 3. machine name

Invoke-Step 'Computer name' {
    $current = $env:COMPUTERNAME              # NetBIOS, max 15 chars
    $full    = Get-FullComputerName           # full DNS host name
    $script:TargetName = $full

    if ($full -ne $current) {
        Write-Log "Full computer name: '$full'." 'OK'
        Write-Log "'$current' is the 15-character NetBIOS truncation of it. Machines whose names differ only after character 15 share that short name; the full name is used for Tailscale." 'WARN'
    }

    if (-not $ComputerName) {
        Write-Log "Using the machine's existing name: '$full'." 'OK'
        if ($full -match '^(DESKTOP|LAPTOP|WIN|MININT|MINWINPC)-') {
            Write-Log "That is still a stock Windows name. Pass -ComputerName <name> if this machine should be renamed." 'WARN'
        }
        $script:S['Machine'] = if ($full -ne $current) { "$full (NetBIOS: $current)" } else { $full }
        return
    }

    $target = $ComputerName.Trim()
    if ($target -eq $full -or $target -eq $current) {
        Write-Log "Already named '$full'; nothing to do." 'OK'
        $script:S['Machine'] = $full
        return
    }
    if (-not (Test-HostNameValid $target)) {
        throw "'$target' is not a valid Windows hostname (1-63 chars, letters/digits/hyphen, not all digits, no trailing hyphen)."
    }
    if ($target.Length -gt 15) {
        Write-Log "'$target' is longer than 15 characters; its NetBIOS name will be truncated to '$($target.Substring(0,15))'." 'WARN'
    }
    Rename-Computer -NewName $target -Force -ErrorAction Stop
    $script:RebootRequired = $true
    $script:TargetName = $target
    Write-Log "Renamed '$full' -> '$target' (takes effect after reboot)." 'OK'
    $script:S['Machine'] = "$target (pending reboot; currently $full)"
}

#--------------------------------------------------------------------- 4. RDP

Invoke-Step 'Remote Desktop' {
    $ts = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
    Set-ItemProperty -LiteralPath $ts -Name 'fDenyTSConnections' -Value 0 -Type DWord -Force

    $rdpTcp = "$ts\WinStations\RDP-Tcp"
    if (Test-Path -LiteralPath $rdpTcp) {
        Set-ItemProperty -LiteralPath $rdpTcp -Name 'UserAuthentication' -Value 1 -Type DWord -Force  # require NLA
        Set-ItemProperty -LiteralPath $rdpTcp -Name 'SecurityLayer'      -Value 2 -Type DWord -Force  # TLS
    }
    Write-Log 'RDP enabled; Network Level Authentication required.' 'OK'

    $rules = @()
    foreach ($n in @('RemoteDesktop-UserMode-In-TCP', 'RemoteDesktop-UserMode-In-UDP')) {
        $r = Get-NetFirewallRule -Name $n -ErrorAction SilentlyContinue
        if ($r) { $rules += $r }
    }
    if ($rules.Count -eq 0) { $rules = @(Get-NetFirewallRule -Group '@FirewallAPI.dll,-28752' -ErrorAction SilentlyContinue) }
    if ($rules.Count -eq 0) { throw 'Could not locate the built-in Remote Desktop firewall rules.' }

    foreach ($r in $rules) {
        if ($r.Enabled -ne 'True') { Enable-NetFirewallRule -Name $r.Name }
    }
    Write-Log "Firewall: $($rules.Count) Remote Desktop rule(s) enabled (all profiles)." 'OK'

    if ($RestrictRdpToTailscale) {
        $rules | Set-NetFirewallRule -RemoteAddress $script:TailscaleCgnat
        Write-Log "Firewall: RDP restricted to $script:TailscaleCgnat (Tailscale only)." 'OK'
        $script:S['RDP'] = "Enabled (NLA required, Tailscale-only)"
    } else {
        $script:S['RDP'] = 'Enabled (NLA required)'
    }
}

#--------------------------------------------------------------------- 5. SSH

Invoke-Step 'OpenSSH Server' {
    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cap) { throw 'OpenSSH.Server capability not offered by this Windows build.' }
    if ($cap.State -ne 'Installed') {
        Write-Log "Installing $($cap.Name) (this can take a minute)..."
        try {
            $r = Add-WindowsCapability -Online -Name $cap.Name
        } catch {
            if ("$($_.Exception.Message)" -match '0x800f0954|0x8024002e') {
                throw "Windows blocked the feature download (WSUS/Group Policy). Allow optional features from Windows Update, or install OpenSSH manually, then re-run. Original: $($_.Exception.Message)"
            }
            throw
        }
        if ($r.RestartNeeded) { $script:RebootRequired = $true }
        Write-Log 'OpenSSH Server installed.' 'OK'
    } else {
        Write-Log 'OpenSSH Server already installed.' 'OK'
    }

    if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) {
        $script:RebootRequired = $true
        throw 'The sshd service is not registered yet. Reboot and re-run this script to finish SSH setup.'
    }
    Set-Service -Name sshd -StartupType Automatic
    if ((Get-Service -Name sshd).Status -ne 'Running') { Start-Service -Name sshd }
    Write-Log 'sshd: running, startup=Automatic.' 'OK'

    # SSH sessions land in PowerShell rather than cmd.exe
    $oss = 'HKLM:\SOFTWARE\OpenSSH'
    if (-not (Test-Path -LiteralPath $oss)) { New-Item -Path $oss -Force | Out-Null }
    $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Set-ItemProperty -LiteralPath $oss -Name 'DefaultShell' -Value $shell -Type String -Force
    Write-Log 'sshd default shell set to Windows PowerShell.' 'OK'

    # Narrow inbound rule: TCP 22 from the Tailscale range only, sshd.exe only.
    $ruleName = "$script:AppName-SSH-Tailscale"
    $sshd     = Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe'
    $params   = @{
        Direction     = 'Inbound'
        Action        = 'Allow'
        Protocol      = 'TCP'
        LocalPort     = 22
        RemoteAddress = $script:TailscaleCgnat
        Profile       = 'Any'
        Enabled       = 'True'
    }
    if (Test-Path -LiteralPath $sshd) { $params['Program'] = $sshd }

    if (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue) {
        try {
            Set-NetFirewallRule -Name $ruleName @params | Out-Null
            Write-Log "Firewall: rule '$ruleName' reapplied." 'OK'
        } catch {
            Remove-NetFirewallRule -Name $ruleName
            New-NetFirewallRule -Name $ruleName -DisplayName "$script:AppName: SSH over Tailscale (TCP 22)" `
                -Description 'Inbound SSH limited to the Tailscale CGNAT range.' @params | Out-Null
            Write-Log "Firewall: rule '$ruleName' rebuilt." 'OK'
        }
    } else {
        New-NetFirewallRule -Name $ruleName -DisplayName "$script:AppName: SSH over Tailscale (TCP 22)" `
            -Description 'Inbound SSH limited to the Tailscale CGNAT range.' @params | Out-Null
        Write-Log "Firewall: rule '$ruleName' created (TCP 22 from $script:TailscaleCgnat)." 'OK'
    }

    # The capability's own rule allows SSH from anywhere; turn it off in favour of the scoped one.
    $broad = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    if ($broad -and $broad.Enabled -eq 'True') {
        Disable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP'
        Write-Log "Firewall: disabled the default allow-any rule 'OpenSSH-Server-In-TCP'." 'OK'
    }

    Write-Log 'No SSH keys installed - key deployment belongs to the fleet tool.' 'INFO'
    $script:S['SSH'] = "Enabled (TCP 22 from $script:TailscaleCgnat)"
}

#--------------------------------------------------------------- 6. Tailscale

if ($SkipTailscale) {
    $script:S['Tailscale'] = 'Skipped'
    Write-Log '== Tailscale (skipped by -SkipTailscale)' 'STEP'
} else {
    Invoke-Step 'Tailscale' {
        if (-not (Test-Path -LiteralPath $script:TailscaleExe)) {
            $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
            $url  = "https://pkgs.tailscale.com/stable/tailscale-setup-latest-$arch.msi"
            $msi  = Join-Path $env:TEMP 'tailscale-setup.msi'
            Write-Log "Downloading $url ..."
            Invoke-WebRequest -Uri $url -OutFile $msi -UseBasicParsing
            Write-Log 'Installing Tailscale (unattended mode enabled)...'
            $p = Start-Process -FilePath 'msiexec.exe' -Wait -PassThru -ArgumentList @(
                '/i', "`"$msi`"", '/quiet', '/norestart', 'TS_UNATTENDEDMODE=always')
            Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
            if ($p.ExitCode -eq 3010) { $script:RebootRequired = $true }
            elseif ($p.ExitCode -ne 0) { throw "msiexec exited with code $($p.ExitCode)." }
            Write-Log 'Tailscale installed.' 'OK'
        } else {
            Write-Log 'Tailscale already installed.' 'OK'
        }

        $svc = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
        if ($svc) {
            if ($svc.StartType -ne 'Automatic') { Set-Service -Name 'Tailscale' -StartupType Automatic }
            if ($svc.Status -ne 'Running') { Start-Service -Name 'Tailscale'; Start-Sleep -Seconds 3 }
            Write-Log 'Tailscale service: running, startup=Automatic.' 'OK'
        }

        $status    = Get-TailscaleStatus
        $state     = if ($status) { $status.BackendState } else { 'Unknown' }
        $attempted = $false

        if ($state -eq 'Running') {
            Write-Log 'Already enrolled in a tailnet; not re-authenticating.' 'OK'
        } elseif ($TailscaleAuthKey) {
            $attempted = $true
            $tsHost  = (("$script:TargetName".ToLower() -replace '[^a-z0-9-]', '-') -replace '-+', '-').Trim('-')
            if (-not $tsHost) { $tsHost = $env:COMPUTERNAME.ToLower() }
            $tagArgs = @()
            $tagList = @($Tags -split '[,\s]+' | Where-Object { $_ } |
                         ForEach-Object { if ($_ -like 'tag:*') { $_ } else { "tag:$_" } })
            if ($tagList.Count -gt 0) {
                $tagArgs = @("--advertise-tags=$($tagList -join ',')")
                Write-Log "Advertising tags: $($tagList -join ', ')"
            }
            Write-Log "Enrolling with auth key (hostname: $tsHost). The key is not logged or saved."
            # The key is passed as an argument only; it is never written to the log or disk.
            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'   # native stderr must not terminate the step
            try {
                $out = & $script:TailscaleExe up --unattended --authkey $TailscaleAuthKey --hostname $tsHost @tagArgs --timeout 60s 2>&1
            } finally {
                $ErrorActionPreference = $prev
            }
            foreach ($line in @($out)) { if ("$line".Trim()) { Write-Log "  tailscale: $line" } }
            if ($LASTEXITCODE -ne 0) { Write-Log "tailscale up exited with code $LASTEXITCODE." 'WARN' }
        } else {
            Write-Log 'No auth key supplied. Enroll later with: tailscale up --unattended' 'WARN'
        }

        # Make sure the node stays up before any user logs in.
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { & $script:TailscaleExe set --unattended=true 2>&1 | Out-Null } catch { } finally { $ErrorActionPreference = $prev }

        $status = Get-TailscaleStatus
        if ($attempted) {
            for ($i = 0; $i -lt 10; $i++) {
                if ($status -and $status.BackendState -eq 'Running' -and $status.Self.TailscaleIPs) { break }
                Start-Sleep -Seconds 2
                $status = Get-TailscaleStatus
            }
        }
        if ($status) {
            $ip  = @($status.Self.TailscaleIPs | Where-Object { $_ -notmatch ':' })[0]
            $dns = "$($status.Self.DNSName)".TrimEnd('.')
            $nodeTags = @()
            if ($status.Self.PSObject.Properties.Name -contains 'Tags') { $nodeTags = @($status.Self.Tags | Where-Object { $_ }) }
            $script:S['Tailscale']      = $status.BackendState
            $script:S['Tailscale IP']   = if ($ip)  { $ip }  else { '(none yet)' }
            $script:S['Tailscale name'] = if ($dns) { $dns } else { '(none yet)' }
            $script:S['Tailscale tags'] = if ($nodeTags.Count) { $nodeTags -join ', ' } else { 'NONE (user-owned)' }
            Write-Log "Tailscale state=$($status.BackendState) ip=$ip name=$dns" 'OK'
            if ($nodeTags.Count) {
                Write-Log "Node is tag-owned: $($nodeTags -join ', '). Key expiry does not apply." 'OK'
            } elseif ($status.BackendState -eq 'Running') {
                Write-Log 'Node is USER-owned, not tag-owned. Its key will expire (180 days by default) and the machine will drop off the tailnet; it also disappears if that user account is removed. Re-enroll with a tagged auth key.' 'WARN'
            }
        } else {
            $script:S['Tailscale'] = 'Installed, status unavailable'
            Write-Log 'Could not read Tailscale status.' 'WARN'
        }
    }
}
$TailscaleAuthKey = $null

#---------------------------------------------------------------- 7. firewall

Invoke-Step 'Windows Firewall' {
    $profiles = Get-NetFirewallProfile -Profile Domain, Private, Public
    foreach ($p in $profiles) {
        if (-not $p.Enabled) {
            Set-NetFirewallProfile -Profile $p.Name -Enabled True
            Write-Log "Firewall profile '$($p.Name)' was OFF; re-enabled." 'WARN'
        }
    }
    $state = (Get-NetFirewallProfile -Profile Domain, Private, Public |
              ForEach-Object { "$($_.Name)=$(if ($_.Enabled) { 'on' } else { 'off' })" }) -join ' '
    Write-Log "Firewall: $state" 'OK'
    $script:S['Firewall'] = $state
}

#------------------------------------------------------------------- 8. power

Invoke-Step 'Power settings (AC only)' {
    # Keep the machine reachable while plugged in. Monitor timeout is left alone.
    & powercfg.exe /change standby-timeout-ac 0   | Out-Null
    & powercfg.exe /change hibernate-timeout-ac 0 | Out-Null
    Write-Log 'On AC power: sleep and hibernate disabled; display timeout unchanged.' 'OK'
    Write-Log 'Revert with: powercfg /change standby-timeout-ac 30 (and hibernate-timeout-ac 180)' 'INFO'
    $script:S['Power'] = 'No sleep/hibernate on AC'
}

#--------------------------------------------------------------- 9. BitLocker

Invoke-Step 'BitLocker (report only)' {
    $vol = $null
    try { $vol = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop } catch { }
    if (-not $vol) {
        Write-Log 'BitLocker cmdlets unavailable (Windows Home or feature absent).' 'WARN'
        $script:S['BitLocker'] = 'Unknown'
        return
    }
    $types = @($vol.KeyProtector | ForEach-Object { $_.KeyProtectorType }) -join ', '
    $hasRecovery = @($vol.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' }).Count -gt 0
    Write-Log "Volume $($vol.MountPoint): protection=$($vol.ProtectionStatus) status=$($vol.VolumeStatus) encrypted=$($vol.EncryptionPercentage)%"
    Write-Log "Key protectors present: $(if ($types) { $types } else { 'none' })"   # types only, never key values
    Write-Log "Recovery password protector: $(if ($hasRecovery) { 'yes' } else { 'NO - no recovery escrow exists yet' })" $(if ($hasRecovery) { 'OK' } else { 'WARN' })
    Write-Log 'BitLocker not modified (out of scope for bootstrap).' 'INFO'
    $script:S['BitLocker'] = "$($vol.ProtectionStatus) ($($vol.VolumeStatus), recovery protector: $(if ($hasRecovery) { 'yes' } else { 'no' }))"
}

#------------------------------------------------------------------ 10. summary

if (Test-PendingReboot) { $script:RebootRequired = $true }
$script:S['Reboot required'] = if ($script:RebootRequired) { 'Yes' } else { 'No' }
$script:S['Log'] = $script:LogFile

Write-Host ''
Write-Log ('-' * 64)
Write-Log 'BOOTSTRAP SUMMARY' 'STEP'
foreach ($k in $script:S.Keys) { if ($script:S[$k]) { Write-Log ('{0,-17}{1}' -f "$k`:", $script:S[$k]) } }
Write-Log ('-' * 64)

if ($script:Failures.Count -gt 0) {
    Write-Log "Completed with errors in: $($script:Failures -join ', ')" 'ERROR'
} else {
    Write-Log 'Completed successfully.' 'OK'
}

if ("$($script:S['Tailscale'])" -ne 'Running' -and -not $SkipTailscale) {
    Write-Host ''
    Write-Log 'Next step: enroll this machine with  tailscale up --unattended' 'WARN'
}

#----------------------------------------------------------------- 11. reboot

if ($script:RebootRequired) {
    Write-Host ''
    Write-Log 'A reboot is required to finish (hostname and/or component install).' 'WARN'
    if ($AutoReboot) {
        Write-Log 'Rebooting in 15 seconds (-AutoReboot). Press Ctrl+C to cancel.' 'WARN'
        Start-Sleep -Seconds 15
        Restart-Computer -Force
    } else {
        $answer = ''
        try { $answer = Read-Host 'Reboot now? [y/N]' } catch { }
        if ($answer -match '^(y|yes)$') {
            Write-Log 'Rebooting at operator request.' 'WARN'
            Restart-Computer -Force
        } else {
            Write-Log 'Reboot deferred. Restart this machine when convenient.' 'WARN'
        }
    }
}
