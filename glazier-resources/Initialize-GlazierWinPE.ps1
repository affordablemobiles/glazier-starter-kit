if (-not $env:GLAZIER_INIT_OVERRIDE) {
    try {
        $drvList = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.Name -ne 'X:\' }
        foreach ($d in $drvList) {
            $ovrDir = Join-Path $d.RootDirectory.FullName "sources\override"
            if (Test-Path $ovrDir) {
                New-Item -ItemType Directory -Path "X:\glazier-resources" -Force | Out-Null
                Get-ChildItem -Path $ovrDir -Filter "*.ps1" -ErrorAction SilentlyContinue | ForEach-Object {
                    Copy-Item -Path $_.FullName -Destination "X:\Windows\System32\$($_.Name)" -Force -ErrorAction SilentlyContinue
                    Copy-Item -Path $_.FullName -Destination "X:\glazier-resources\$($_.Name)" -Force -ErrorAction SilentlyContinue
                }
                if (Test-Path "$ovrDir\Initialize-GlazierWinPE.ps1") {
                    $env:GLAZIER_INIT_OVERRIDE = "1"
                    & "X:\Windows\System32\Initialize-GlazierWinPE.ps1"
                    exit $LASTEXITCODE
                }
            }
        }
    } catch {}
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$win32TypeDef = @"
using System;
using System.Runtime.InteropServices;

public class Win32Window {
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();

    [DllImport("gdi32.dll", CharSet = CharSet.Auto)]
    public static extern int AddFontResource(string lpFileName);

    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);

    public const uint ES_CONTINUOUS = 0x80000000;
    public const uint ES_SYSTEM_REQUIRED = 0x00000001;
    public const uint ES_DISPLAY_REQUIRED = 0x00000002;
}
"@
if (-not ('Win32Window' -as [type])) {
    Add-Type -TypeDefinition $win32TypeDef -ErrorAction SilentlyContinue
}

# Assert Wake Lock (ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED)
try {
    [void][Win32Window]::SetThreadExecutionState(0x80000003)
} catch {}

# Hide Parent Console immediately so Startnet.cmd disappears completely (no gray titlebar stubs)
$consoleHwnd = [Win32Window]::GetConsoleWindow()
if ($consoleHwnd -ne [IntPtr]::Zero) {
    [void][Win32Window]::ShowWindow($consoleHwnd, 0) # SW_HIDE
}
Get-Process -Name cmd -ErrorAction SilentlyContinue | ForEach-Object {
    $h = $_.MainWindowHandle
    if ($h -ne [IntPtr]::Zero -and ($null -eq $form -or $h -ne $form.Handle)) {
        [void][Win32Window]::ShowWindow($h, 0) # SW_HIDE
    }
}

# Ensure core fonts are loaded into the live GDI session
$fontsDir = "$env:SystemRoot\Fonts"
$fontFiles = @("segoeui.ttf", "segoeuib.ttf", "segoeuii.ttf", "seguisb.ttf", "consola.ttf", "consolab.ttf")
foreach ($ff in $fontFiles) {
    $fp = "$fontsDir\$ff"
    if (Test-Path $fp) {
        [void][Win32Window]::AddFontResource($fp)
    }
}

# Display & Wallpaper: Call Set-WinPEWallpaper.ps1 FIRST so screen resolution is configured before the form centers itself on screen
$wallpaperScript = "$env:SystemRoot\System32\Set-WinPEWallpaper.ps1"
if (-not (Test-Path $wallpaperScript)) {
    $wallpaperScript = "X:\Windows\System32\Set-WinPEWallpaper.ps1"
}
if (Test-Path $wallpaperScript) {
    try {
        & $wallpaperScript
    } catch {
        # continue even if wallpaper script fails
    }
}

function Test-WinPENetwork {
    try {
        $interfaces = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()
        foreach ($iface in $interfaces) {
            if ($iface.OperationalStatus.ToString() -eq "Up" -and
                $iface.NetworkInterfaceType.ToString() -ne "Loopback") {
                $ipProps = $iface.GetIPProperties()
                if ($ipProps -and $ipProps.UnicastAddresses) {
                    foreach ($uni in $ipProps.UnicastAddresses) {
                        if ($uni.Address.AddressFamily.ToString() -eq "InterNetwork") {
                            $ipStr = $uni.Address.ToString()
                            if ($ipStr -notlike "169.254.*" -and $ipStr -notlike "127.*" -and $ipStr -ne "0.0.0.0") {
                                return [PSCustomObject]@{
                                    Connected = $true
                                    Interface = $iface.Description
                                    Name      = $iface.Name
                                    IPAddress = $ipStr
                                }
                            }
                        }
                    }
                }
            }
        }
    } catch {
        # ignore error and return $null
    }
    return $null
}

# Construct Boot Progress GUI
$form = New-Object System.Windows.Forms.Form
$form.Text = "Glazier WinPE Initialization"
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.ClientSize = New-Object System.Drawing.Size(620, 250)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.ControlBox = $false
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.TopMost = $true
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)

# Title Label: Location = (28, 22), Size = (564, 36)
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "Preparing Glazier Environment"
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 20, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
$lblTitle.Location = New-Object System.Drawing.Point(28, 22)
$lblTitle.Size = New-Object System.Drawing.Size(564, 36)
$form.Controls.Add($lblTitle)

# Step Status Label: Location = (28, 64), Size = (564, 28)
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Step 1 of 4: Initializing environment..."
$lblStatus.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
$lblStatus.Location = New-Object System.Drawing.Point(28, 64)
$lblStatus.Size = New-Object System.Drawing.Size(564, 28)
$form.Controls.Add($lblStatus)

# 3-Panel Percentage Fill Bar with Aero Shimmer Pulse (100% theme-independent & color-coded)
$trackW = 564
$trackH = 26

$progressTrack = New-Object System.Windows.Forms.Panel
$progressTrack.Location = New-Object System.Drawing.Point(28, 100)
$progressTrack.Size = New-Object System.Drawing.Size($trackW, $trackH)
$progressTrack.BackColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
$progressTrack.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$form.Controls.Add($progressTrack)

$progressFill = New-Object System.Windows.Forms.Panel
$progressFill.Location = New-Object System.Drawing.Point(0, 0)
$progressFill.Size = New-Object System.Drawing.Size([Math]::Max(40, [int]($trackW * 0.25)), $trackH)
$progressFill.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
$progressTrack.Controls.Add($progressFill)

$progressPulse = New-Object System.Windows.Forms.Panel
$progressPulse.Location = New-Object System.Drawing.Point(-70, 0)
$progressPulse.Size = New-Object System.Drawing.Size(70, $trackH)
$progressPulse.BackColor = [System.Drawing.Color]::FromArgb(96, 165, 250)
$progressFill.Controls.Add($progressPulse)

$progressPulseCore = New-Object System.Windows.Forms.Panel
$progressPulseCore.Location = New-Object System.Drawing.Point(20, 0)
$progressPulseCore.Size = New-Object System.Drawing.Size(30, $trackH)
$progressPulseCore.BackColor = [System.Drawing.Color]::FromArgb(147, 197, 253)
$progressPulse.Controls.Add($progressPulseCore)

# Detail / Sub-status Label: Location = (28, 134), Size = (564, 24)
$lblDetail = New-Object System.Windows.Forms.Label
$lblDetail.Text = "Configuring system settings..."
$lblDetail.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$lblDetail.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
$lblDetail.Location = New-Object System.Drawing.Point(28, 134)
$lblDetail.Size = New-Object System.Drawing.Size(564, 24)
$form.Controls.Add($lblDetail)

# Bottom Buttons (Y = 178, Height = 38):
$btnLogToggle = New-Object System.Windows.Forms.Button
$btnLogToggle.Text = "Show Debug Log [v]"
$btnLogToggle.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$btnLogToggle.Location = New-Object System.Drawing.Point(28, 178)
$btnLogToggle.Size = New-Object System.Drawing.Size(160, 38)
$btnLogToggle.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnLogToggle.BackColor = [System.Drawing.Color]::FromArgb(240, 242, 245)
$btnLogToggle.ForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
$btnLogToggle.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
$form.Controls.Add($btnLogToggle)

$btnTerminal = New-Object System.Windows.Forms.Button
$btnTerminal.Text = "Open Terminal"
$btnTerminal.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$btnTerminal.Location = New-Object System.Drawing.Point(200, 178)
$btnTerminal.Size = New-Object System.Drawing.Size(150, 38)
$btnTerminal.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnTerminal.BackColor = [System.Drawing.Color]::FromArgb(240, 242, 245)
$btnTerminal.ForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
$btnTerminal.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
$form.Controls.Add($btnTerminal)

# Debug Log TextBox: Location = (28, 232), Size = (564, 184)
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(28, 232)
$txtLog.Size = New-Object System.Drawing.Size(564, 184)
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 12, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$txtLog.ForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
$txtLog.Visible = $false
$form.Controls.Add($txtLog)

$btnLogToggle.Add_Click({
    if ($txtLog.Visible) {
        $txtLog.Visible = $false
        $form.ClientSize = New-Object System.Drawing.Size(620, 250)
        $btnLogToggle.Text = "Show Debug Log [v]"
    } else {
        $form.ClientSize = New-Object System.Drawing.Size(620, 440)
        $txtLog.Visible = $true
        $btnLogToggle.Text = "Hide Debug Log [^]"
    }
})

$btnTerminal.Add_Click({
    $form.TopMost = $false
    Add-Log -Message "Opening interactive PowerShell debug terminal..." -Detail "Terminal launched."
    Start-Process -FilePath "cmd.exe" -ArgumentList '/c start "Glazier WinPE Debug Terminal" PowerShell.exe -NoProfile -NoLogo -NoExit'
})

function Add-Log {
    param([string]$Message, [string]$Detail = "")
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $txtLog.AppendText("[$ts] $Message`r`n")
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.ScrollToCaret()
    if ($Detail) {
        $lblDetail.Text = $Detail
    } else {
        $lblDetail.Text = $Message
    }
    Write-Host "[$ts] $Message"
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-Step {
    param([string]$Status, [string]$Detail = "")
    $lblStatus.Text = $Status
    Add-Log -Message $Status -Detail $Detail
}

try {
    if ($consoleHwnd -ne [IntPtr]::Zero) {
        [void][Win32Window]::ShowWindow($consoleHwnd, 0) # SW_HIDE
    }
    Get-Process -Name cmd -ErrorAction SilentlyContinue | ForEach-Object {
        $h = $_.MainWindowHandle
        if ($h -ne [IntPtr]::Zero -and ($null -eq $form -or $h -ne $form.Handle)) {
            [void][Win32Window]::ShowWindow($h, 0) # SW_HIDE
        }
    }
    [void][Win32Window]::ShowWindow($form.Handle, 5) # SW_SHOW
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()

    $script:shimmerPos = -70
    function Pulse-Progress {
        try { [void][Win32Window]::SetThreadExecutionState(0x80000003) } catch {}
        $script:shimmerPos = ($script:shimmerPos + 16)
        if ($script:shimmerPos -gt ($progressFill.Width + 70)) {
            $script:shimmerPos = -70
        }
        $progressPulse.Left = $script:shimmerPos
        [System.Windows.Forms.Application]::DoEvents()
    }

    Add-Log -Message "Glazier WinPE initialization started." -Detail "Display configured."

    # Step 1 of 4: Initializing WinPE hardware and drivers (wpeinit)
    $progressFill.Width = [int]($trackW * 0.25)
    Set-Step -Status "Step 1 of 4: Initializing WinPE hardware and drivers (wpeinit)..." -Detail "Running wpeinit.exe..."
    $wpeProc = Start-Process -FilePath "$env:SystemRoot\System32\wpeinit.exe" -NoNewWindow -PassThru
    while (-not $wpeProc.HasExited) {
        Pulse-Progress
        Start-Sleep -Milliseconds 100
    }
    Add-Log -Message "wpeinit.exe completed." -Detail "Hardware and network drivers initialized."
    # Re-run Set-WinPEWallpaper.ps1 quickly in case wpeinit loaded a new GOP/display driver
    if (Test-Path $wallpaperScript) {
        try { & $wallpaperScript } catch {}
    }

    # Step 2: Native WLAN & Network Telemetry Auto-Connect / GUI
    $progressFill.Width = [int]($trackW * 0.50)
    Set-Step -Status "Step 2 of 4: Checking network connectivity..." -Detail "Checking network interfaces..."

    $wifiScriptCandidates = @(
        "$env:SystemRoot\System32\GlazierWiFi.ps1",
        "X:\Windows\System32\GlazierWiFi.ps1",
        "X:\glazier-resources\GlazierWiFi.ps1",
        "$PSScriptRoot\GlazierWiFi.ps1"
    )
    $wifiScript = $wifiScriptCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($wifiScript) {
        . $wifiScript
    }

    $connected = $false
    if (Get-Command Invoke-GlazierWiFiAutoConnect -ErrorAction SilentlyContinue) {
        Add-Log -Message "Running Glazier Wi-Fi & Wired auto-connect pre-check..." -Detail "Checking network..."
        $connected = Invoke-GlazierWiFiAutoConnect `
            -ProfileDirs @("X:\glazier-resources\wifi_profiles", "C:\glazier-resources\wifi_profiles") `
            -OnStatus { param($msg) Add-Log -Message $msg -Detail $msg } `
            -OnPulse { Pulse-Progress } `
            -TimeoutSeconds 20
    } else {
        $activeNet = Test-WinPENetwork
        if ($activeNet) { $connected = $true }
    }

    if (-not $connected) {
        Add-Log -Message "Network connection not yet established. Opening Network & Wi-Fi configuration dialog..." -Detail "Opening Network GUI..."
        $form.TopMost = $false
        [System.Windows.Forms.Application]::DoEvents()
        if (Get-Command Show-GlazierNetworkGUI -ErrorAction SilentlyContinue) {
            $guiResult = Show-GlazierNetworkGUI
            if ($guiResult) {
                $connected = $true
            }
        }
        $form.TopMost = $true
        [System.Windows.Forms.Application]::DoEvents()
    }

    if ($connected) {
        Add-Log -Message "Network connectivity established." -Detail "Network ready."
    } else {
        Add-Log -Message "Warning: Continuing without verified network connection." -Detail "Continuing..."
    }

    # Export active Wi-Fi profile(s) with cleartext keys to X:\glazier-resources\wifi_profiles for carry-over to Windows
    if ((Get-Service -Name WlanSvc -ErrorAction SilentlyContinue).Status -eq 'Running') {
        try {
            $wifiExportDir = "X:\glazier-resources\wifi_profiles"
            if (-not (Test-Path $wifiExportDir)) {
                New-Item -ItemType Directory -Path $wifiExportDir -Force | Out-Null
            }
            if (Get-Command Export-GlazierHostWiFiProfiles -ErrorAction SilentlyContinue) {
                Export-GlazierHostWiFiProfiles -OutputDir $wifiExportDir
            }
            $expProfiles = Get-ChildItem -Path $wifiExportDir -Filter "*.xml" -ErrorAction SilentlyContinue
            if ($expProfiles) {
                Add-Log -Message "Exported $($expProfiles.Count) Wi-Fi profile(s) for carry-over to installed Windows OS."
            }
        } catch {
            Add-Log -Message "Warning: Failed to export Wi-Fi profiles: $_"
        }
    }

    # Step 3: Keep OSD & MSCatalog Module Updates with Visible GUI Feedback
    $progressFill.Width = [int]($trackW * 0.75)
    Set-Step -Status "Step 3 of 4: Updating OSD & MSCatalog PowerShell modules (this may take a minute)..." -Detail "Checking for module updates..."

    $updateScriptContent = @(
        "`$ConfirmPreference = 'None'",
        "`$ProgressPreference = 'SilentlyContinue'",
        "try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 } catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }",
        "Import-Module OSD -ErrorAction SilentlyContinue",
        "Write-Output 'Testing web connection...'",
        "`$canConnect = `$false",
        "if (Get-Command Test-WebConnection -ErrorAction SilentlyContinue) { `$canConnect = Test-WebConnection } else { try { `$resp = Invoke-WebRequest -Uri 'https://www.powershellgallery.com' -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop; `$canConnect = (`$resp.StatusCode -eq 200) } catch { `$canConnect = `$false } }",
        "if (`$canConnect) {",
        "    Write-Output 'Web connection verified. Checking NuGet package provider...'",
        "    if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {",
        "        Write-Output 'Installing NuGet package provider...'",
        "        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null",
        "    }",
        "    Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction SilentlyContinue",
        "    Write-Output 'Updating OSD module from PSGallery...'",
        "    Install-Module OSD -Force -AllowClobber -SkipPublisherCheck -Confirm:`$false -ErrorAction SilentlyContinue",
        "    Write-Output 'Updating MSCatalog module from PSGallery...'",
        "    Install-Module MSCatalog -Force -AllowClobber -SkipPublisherCheck -Confirm:`$false -ErrorAction SilentlyContinue",
        "    Write-Output 'OSD and MSCatalog module updates completed.'",
        "} else {",
        "    Write-Output 'Web connection unavailable; skipping module updates.'",
        "}"
    ) -join "`r`n"

    $updateScriptFile = "$env:TEMP\Update-WinPEModules.ps1"
    Set-Content -Path $updateScriptFile -Value $updateScriptContent -Encoding UTF8 -Force

    $updateLog = "$env:TEMP\update_modules.log"
    $updateErrLog = "$env:TEMP\update_modules_err.log"
    if (Test-Path $updateLog) { Remove-Item $updateLog -Force -ErrorAction SilentlyContinue }
    if (Test-Path $updateErrLog) { Remove-Item $updateErrLog -Force -ErrorAction SilentlyContinue }

    $updateProc = Start-Process -FilePath "PowerShell.exe" `
        -ArgumentList "-NoProfile -NoLogo -ExecutionPolicy Bypass -File `"$updateScriptFile`"" `
        -RedirectStandardOutput $updateLog `
        -RedirectStandardError $updateErrLog `
        -NoNewWindow -PassThru

    $lastLineCount = 0
    while (-not $updateProc.HasExited) {
        if (Test-Path $updateLog) {
            $lines = @(Get-Content -Path $updateLog -ErrorAction SilentlyContinue)
            if ($lines -and $lines.Count -gt $lastLineCount) {
                for ($i = $lastLineCount; $i -lt $lines.Count; $i++) {
                    if ($lines[$i]) {
                        Add-Log -Message $lines[$i] -Detail $lines[$i]
                    }
                }
                $lastLineCount = $lines.Count
            }
        }
        Pulse-Progress
        Start-Sleep -Milliseconds 100
    }

    if (Test-Path $updateLog) {
        $lines = @(Get-Content -Path $updateLog -ErrorAction SilentlyContinue)
        if ($lines -and $lines.Count -gt $lastLineCount) {
            for ($i = $lastLineCount; $i -lt $lines.Count; $i++) {
                if ($lines[$i]) {
                    Add-Log -Message $lines[$i] -Detail $lines[$i]
                }
            }
        }
    }

    # Step 4: Hand-off
    Set-Step -Status "Step 4 of 4: Launching Glazier Profile Menu..." -Detail "Starting Glazier autobuild..."
    Add-Log -Message "Initialization complete. Handing off to autobuild.ps1..."
    $progressPulse.Visible = $false
    $progressFill.Location = New-Object System.Drawing.Point(0, 0)
    $progressFill.Size = New-Object System.Drawing.Size($trackW, $trackH)
    $progressFill.BackColor = [System.Drawing.Color]::FromArgb(22, 163, 74)

    for ($t = 0; $t -lt 5; $t++) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
} catch {
    Write-Host "Warning: Glazier WinPE initialization encountered an error: $_" -ForegroundColor Yellow
    try {
        if ($consoleHwnd -ne [IntPtr]::Zero) {
            [void][Win32Window]::ShowWindow($consoleHwnd, 5) # SW_SHOW
            [void][Win32Window]::ShowWindow($consoleHwnd, 9) # SW_RESTORE
            Start-Sleep -Milliseconds 50
            [void][Win32Window]::ShowWindow($consoleHwnd, 3) # SW_MAXIMIZE
        }
        Get-Process -Name cmd -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.MainWindowHandle -ne [IntPtr]::Zero) {
                [void][Win32Window]::ShowWindow($_.MainWindowHandle, 5) # SW_SHOW
                [void][Win32Window]::ShowWindow($_.MainWindowHandle, 9) # SW_RESTORE
            }
        }
    } catch {}
} finally {
    if ($form -and -not $form.IsDisposed) {
        $form.Close()
        $form.Dispose()
    }
}
