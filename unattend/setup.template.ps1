<#
    Runs once, at first logon, from the USB stick. Placeholders are filled by
    make-usb.sh; the generated copy contains secrets and must never be committed.

    Order matters: the purge runs in a finally block so credentials are destroyed
    even when the bootstrap fails.
#>
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$UsbRoot   = Split-Path -Parent $PSScriptRoot          # the stick
$LogDir    = 'C:\ProgramData\ClinicFleet'
$Log       = Join-Path $LogDir 'unattend.log'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

function Say($m) {
    $line = "{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Host $line
    Add-Content -LiteralPath $Log -Value $line -Encoding UTF8
}

try {
    Say "unattended setup starting on $env:COMPUTERNAME (usb: $UsbRoot)"

    # Belt and braces: some OEM images are sysprepped /oobe without /generalize,
    # in which case the specialize pass never runs and the policy set there is
    # never applied. Setting it again here is harmless and idempotent.
    reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v NoLocalPasswordResetQuestions /t REG_DWORD /d 1 /f | Out-Null
    Say "local-account security questions disabled"

    # --- network ---------------------------------------------------------------
    # Every profile on the stick is imported, so a machine can be moved between
    # sites without another visit. user=all so each profile belongs to the machine
    # and connects at the login screen; a per-user profile would leave the machine
    # offline and unreachable until somebody signed in.
    $wifiDir = Join-Path $PSScriptRoot 'wifi'
    $profiles = @(Get-ChildItem -Path $wifiDir -Filter *.xml -ErrorAction SilentlyContinue)
    if ($profiles.Count -gt 0) {
        foreach ($p in $profiles) {
            $out = (netsh wlan add profile filename="$($p.FullName)" user=all 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -eq 0) { Say "wifi profile added: $($p.BaseName)" }
            else { Say "WIFI FAILED for $($p.BaseName): $out" }
        }
    } else {
        Say "no wifi profiles on the stick - assuming wired"
    }

    Say "waiting for internet..."
    $online = $false
    foreach ($i in 1..60) {
        if (Test-NetConnection -ComputerName 'pkgs.tailscale.com' -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue) {
            $online = $true; break
        }
        Start-Sleep -Seconds 5
    }
    if (-not $online) { Say "NO INTERNET after 5 minutes - bootstrap will fail"; }
    else { Say "online" }

    # --- bootstrap -------------------------------------------------------------
    # Passed explicitly because some OEM images never run the specialize pass, so
    # the ComputerName in the answer file may not have been applied.
    $env:TAILSCALE_AUTH_KEY = '{{TAILSCALE_AUTH_KEY}}'
    $env:TAILSCALE_TAGS     = '{{TAILSCALE_TAGS}}'

    Say "running bootstrap for {{COMPUTER_NAME}}"
    $script = "$env:TEMP\bootstrap.ps1"
    Invoke-WebRequest -Uri '{{BOOTSTRAP_URL}}' -OutFile $script -UseBasicParsing
    & $script -ComputerName '{{COMPUTER_NAME}}'
    Say "bootstrap finished"
}
catch {
    Say "ERROR: $($_.Exception.Message)"
}
finally {
    # --- purge -----------------------------------------------------------------
    # Windows caches the answer file to %WINDIR%\Panther and it survives reboots.
    # Setup scrubs recognised <Password> fields there, but NOT arbitrary text in
    # FirstLogonCommands - so the auth key and wifi key would otherwise persist in
    # plaintext on the disk. Both the stick and the cached copies must go.
    $env:TAILSCALE_AUTH_KEY = $null
    $targets = @(
        (Join-Path $UsbRoot 'Autounattend.xml'),
        (Join-Path $UsbRoot 'autounattend.xml'),
        (Join-Path $PSScriptRoot 'setup.ps1'),
        "$env:WINDIR\Panther\unattend.xml",
        "$env:WINDIR\Panther\Unattend\unattend.xml",
        "$env:WINDIR\System32\Sysprep\unattend.xml"
    )
    # Wifi profiles carry network keys, so the whole directory goes too.
    $targets += @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'wifi') -Filter *.xml -ErrorAction SilentlyContinue |
                  ForEach-Object { $_.FullName })

    foreach ($t in $targets) {
        if (Test-Path -LiteralPath $t) {
            try {
                # Overwrite before unlinking; a plain delete leaves the bytes on the
                # stick recoverable.
                $len = (Get-Item -LiteralPath $t).Length
                [IO.File]::WriteAllBytes($t, (New-Object byte[] $len))
                Remove-Item -LiteralPath $t -Force
                Say "purged $t"
            } catch { Say "COULD NOT PURGE $t : $($_.Exception.Message)" }
        }
    }
    Say "done. remaining answer files: " + ((Get-ChildItem "$env:WINDIR\Panther" -Filter *.xml -ErrorAction SilentlyContinue).Name -join ', ')
}
