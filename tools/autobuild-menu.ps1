Param(
    [string]$config_server = "http://glazier",
    [string]$glazier_spec_os = "",
    [int]$timeout = 600
)

if ($config_server -eq "") {
    $config_server = "http://glazier"
}
$config_server = $config_server.TrimEnd('/')

$Host.UI.RawUI.WindowTitle = 'Glazier'
$env:LOCALAPPDATA = 'X:\'
$env:PYTHONPATH = 'X:\glazier\'
$env:SSL_CERT_FILE = 'X:\glazier-resources\ca-certs.crt'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
} catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

function Get-GlazierProfiles {
    param([string]$BaseUrl)

    $menuConfig = @{
        timeout_seconds = $timeout
        default_profile = "windows-stable"
        profiles        = @()
    }

    # 1. Try fetching rich profiles.json from the GCS bucket first
    try {
        Write-Host "Fetching dynamic profile menu from $BaseUrl/profiles.json..." -ForegroundColor Cyan
        $rawJson = $null
        try {
            $rawJson = (Invoke-WebRequest -Uri "$BaseUrl/profiles.json" -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop).Content
        } catch {
            if (Test-Path "$env:SystemRoot\System32\curl.exe") {
                $rawJson = & curl.exe -fsSL --connect-timeout 10 "$BaseUrl/profiles.json" 2>$null
            }
        }
        if ($rawJson) {
            $jsonResp = $rawJson | ConvertFrom-Json
            if ($jsonResp -and $jsonResp.profiles) {
                if ($null -ne $jsonResp.timeout_seconds) { $menuConfig.timeout_seconds = [int]$jsonResp.timeout_seconds }
                if ($jsonResp.default_profile) { $menuConfig.default_profile = [string]$jsonResp.default_profile }
                $menuConfig.profiles = @($jsonResp.profiles)
                Write-Host "Loaded $($menuConfig.profiles.Count) profiles from profiles.json." -ForegroundColor Green
                return $menuConfig
            }
        }
    } catch {
        Write-Host "profiles.json not found or unreachable, falling back to version-info.yaml..." -ForegroundColor Yellow
    }

    # 2. Fallback: Parse existing version-info.yaml dynamically from the GCS bucket
    try {
        Write-Host "Fetching $BaseUrl/version-info.yaml..." -ForegroundColor Cyan
        $yamlContent = $null
        try {
            $yamlContent = (Invoke-WebRequest -Uri "$BaseUrl/version-info.yaml" -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop).Content
        } catch {
            if (Test-Path "$env:SystemRoot\System32\curl.exe") {
                $yamlContent = & curl.exe -fsSL --connect-timeout 10 "$BaseUrl/version-info.yaml" 2>$null
            }
        }
        if ($yamlContent) {
            $lines = $yamlContent -split "`r?`n"
            $parsedProfiles = @()
            foreach ($line in $lines) {
                if ($line -match '^\s+([a-zA-Z0-9_-]+)\s*:\s*[''"]?([^''"#\s]+)[''"]?') {
                    $profileKey = $matches[1]
                    $profileFolder = $matches[2]
                    $parsedProfiles += [PSCustomObject]@{
                        id          = $profileKey
                        name        = "$profileKey ($profileFolder)"
                        description = "Glazier build profile: $profileKey (path: /$profileFolder)"
                    }
                }
            }
            if ($parsedProfiles.Count -gt 0) {
                $menuConfig.profiles = $parsedProfiles
                Write-Host "Loaded $($parsedProfiles.Count) profiles from version-info.yaml." -ForegroundColor Green
                return $menuConfig
            }
        }
    } catch {
        Write-Host "Warning: Failed to fetch version-info.yaml: $_" -ForegroundColor Yellow
    }

    # 3. Last-resort hardcoded fallback if bucket is temporarily slow/unreachable
    $menuConfig.profiles = @(
        [PSCustomObject]@{ id = "windows-stable"; name = "Windows 11 Stable"; description = "Windows 11 with Office 365 & Management Agent" },
        [PSCustomObject]@{ id = "windows-blank";  name = "Windows 11 Blank";  description = "Clean Windows 11 installation with no additional software" },
        [PSCustomObject]@{ id = "win10-stable";   name = "Windows 10 Stable"; description = "Windows 10 22H2 with Office 365 & Management Agent" },
        [PSCustomObject]@{ id = "win10-blank";    name = "Windows 10 Blank";  description = "Clean Windows 10 22H2 installation" }
    )
    return $menuConfig
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class Win32WindowHelper {
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();

    [DllImport("gdi32.dll", CharSet = CharSet.Auto)]
    public static extern int AddFontResource(string lpFileName);
}
"@ -ErrorAction SilentlyContinue

# Ensure core fonts are loaded into the live GDI session
$fontsDir = "$env:SystemRoot\Fonts"
$fontFiles = @("segoeui.ttf", "segoeuib.ttf", "segoeuii.ttf", "seguisb.ttf", "consola.ttf", "consolab.ttf")
foreach ($ff in $fontFiles) {
    $fp = "$fontsDir\$ff"
    if (Test-Path $fp) {
        [Win32WindowHelper]::AddFontResource($fp) | Out-Null
    }
}

function Show-GlazierProfileGUI {
    param([hashtable]$MenuData)

    $profiles = $MenuData.profiles
    $defaultId = $MenuData.default_profile
    $script:remainingSeconds = [int]$MenuData.timeout_seconds
    $script:timerActive = ($script:remainingSeconds -gt 0)
    $script:selectedProfile = $defaultId
    $consoleHwnd = [IntPtr]::Zero

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        [System.Windows.Forms.Application]::EnableVisualStyles()

        # Minimize console before creating and displaying the GUI
        try {
            $consoleHwnd = [Win32WindowHelper]::GetConsoleWindow()
            if ($consoleHwnd -ne [IntPtr]::Zero) {
                [Win32WindowHelper]::ShowWindow($consoleHwnd, 6) # SW_MINIMIZE
            }
        } catch {
            # continue even if console helper fails
        }

        $form = New-Object System.Windows.Forms.Form
        $form.Text = "Glazier Deployment — Select Profile"
        $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
        $form.ClientSize = New-Object System.Drawing.Size(640, 390)
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false
        $form.TopMost = $true
        $form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
        $form.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)

        # Header Title
        $lblTitle = New-Object System.Windows.Forms.Label
        $lblTitle.Text = "Select Glazier Imaging Profile"
        $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 20, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
        $lblTitle.Location = New-Object System.Drawing.Point(28, 22)
        $lblTitle.Size = New-Object System.Drawing.Size(584, 36)
        $form.Controls.Add($lblTitle)

        # Subheader / Server info
        $lblServer = New-Object System.Windows.Forms.Label
        $lblServer.Text = "Config Server: $config_server"
        $lblServer.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $lblServer.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
        $lblServer.Location = New-Object System.Drawing.Point(28, 60)
        $lblServer.Size = New-Object System.Drawing.Size(584, 26)
        $lblServer.AutoEllipsis = $true
        $form.Controls.Add($lblServer)

        # Profile Dropdown Label
        $lblCombo = New-Object System.Windows.Forms.Label
        $lblCombo.Text = "Deployment Profile:"
        $lblCombo.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $lblCombo.ForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
        $lblCombo.Location = New-Object System.Drawing.Point(28, 96)
        $lblCombo.Size = New-Object System.Drawing.Size(584, 26)
        $form.Controls.Add($lblCombo)

        # ComboBox
        $combo = New-Object System.Windows.Forms.ComboBox
        $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
        $combo.Font = New-Object System.Drawing.Font("Segoe UI", 15, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $combo.Location = New-Object System.Drawing.Point(28, 126)
        $combo.Size = New-Object System.Drawing.Size(584, 34)

        $defaultIndex = 0
        for ($i = 0; $i -lt $profiles.Count; $i++) {
            [void]$combo.Items.Add($profiles[$i].name)
            if ($profiles[$i].id -eq $defaultId) {
                $defaultIndex = $i
            }
        }
        $form.Controls.Add($combo)

        # Profile Details Card
        $panelDesc = New-Object System.Windows.Forms.Panel
        $panelDesc.Location = New-Object System.Drawing.Point(28, 172)
        $panelDesc.Size = New-Object System.Drawing.Size(584, 100)
        $panelDesc.BackColor = [System.Drawing.Color]::FromArgb(235, 240, 245)
        $panelDesc.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        $form.Controls.Add($panelDesc)

        $lblDesc = New-Object System.Windows.Forms.Label
        $lblDesc.Location = New-Object System.Drawing.Point(12, 10)
        $lblDesc.Size = New-Object System.Drawing.Size(558, 78)
        $lblDesc.ForeColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
        $lblDesc.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $panelDesc.Controls.Add($lblDesc)

        # Countdown / Status Label
        $lblTimer = New-Object System.Windows.Forms.Label
        $lblTimer.Location = New-Object System.Drawing.Point(28, 286)
        $lblTimer.Size = New-Object System.Drawing.Size(584, 28)
        $lblTimer.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $lblTimer.ForeColor = [System.Drawing.Color]::FromArgb(180, 83, 9)
        $form.Controls.Add($lblTimer)

        # Bottom Action Buttons (Y = 328, Height = 40):
        # Pause / Resume Timer Button
        $btnPause = New-Object System.Windows.Forms.Button
        $btnPause.Text = "Pause Timer"
        $btnPause.Location = New-Object System.Drawing.Point(28, 328)
        $btnPause.Size = New-Object System.Drawing.Size(140, 40)
        $btnPause.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $btnPause.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnPause.BackColor = [System.Drawing.Color]::FromArgb(240, 242, 245)
        $btnPause.ForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
        $btnPause.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
        $form.Controls.Add($btnPause)

        # Open Terminal Button
        $btnTerminal = New-Object System.Windows.Forms.Button
        $btnTerminal.Text = "Open Terminal"
        $btnTerminal.Location = New-Object System.Drawing.Point(180, 328)
        $btnTerminal.Size = New-Object System.Drawing.Size(140, 40)
        $btnTerminal.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $btnTerminal.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnTerminal.BackColor = [System.Drawing.Color]::FromArgb(240, 242, 245)
        $btnTerminal.ForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
        $btnTerminal.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
        $btnTerminal.Add_Click({
            Start-Process "PowerShell.exe" -ArgumentList "-NoLogo"
        })
        $form.Controls.Add($btnTerminal)

        # Start Imaging Primary Button
        $btnStart = New-Object System.Windows.Forms.Button
        $btnStart.Location = New-Object System.Drawing.Point(442, 328)
        $btnStart.Size = New-Object System.Drawing.Size(170, 40)
        $btnStart.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
        $btnStart.ForeColor = [System.Drawing.Color]::White
        $btnStart.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnStart.FlatAppearance.BorderSize = 0
        $btnStart.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $btnStart.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Controls.Add($btnStart)
        $form.AcceptButton = $btnStart

        # Timer object
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 1000

        $stopCountdown = {
            if ($script:timerActive) {
                $script:timerActive = $false
                $timer.Stop()
                $lblTimer.Text = "Auto-start timer paused. Click 'Start Imaging' when ready."
                $lblTimer.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
                $btnStart.Text = "Start Imaging"
                $btnPause.Text = "Resume Timer"
            }
        }

        $toggleCountdown = {
            if ($script:timerActive) {
                & $stopCountdown
            } else {
                if ($script:remainingSeconds -gt 0) {
                    $script:timerActive = $true
                    $timer.Start()
                    $lblTimer.Text = "Auto-starting '$($script:selectedProfile)' in $($script:remainingSeconds) seconds..."
                    $lblTimer.ForeColor = [System.Drawing.Color]::FromArgb(180, 83, 9)
                    $btnStart.Text = "Start Imaging ($($script:remainingSeconds)s)"
                    $btnPause.Text = "Pause Timer"
                }
            }
        }

        $combo.Add_SelectedIndexChanged({
            $idx = $combo.SelectedIndex
            if ($idx -ge 0 -and $idx -lt $profiles.Count) {
                $script:selectedProfile = $profiles[$idx].id
                $lblDesc.Text = "Profile ID: $($profiles[$idx].id)`r`n$($profiles[$idx].description)"
            }
        })

        # Pause countdown if the user interacts with the dropdown or clicks pause/resume
        $combo.Add_DropDown($stopCountdown)
        $combo.Add_KeyDown($stopCountdown)
        $btnPause.Add_Click($toggleCountdown)

        # Set initial selection before starting timer so SelectedIndexChanged sets description
        if ($combo.Items.Count -gt 0) {
            $combo.SelectedIndex = $defaultIndex
        }

        if ($script:timerActive) {
            $lblTimer.Text = "Auto-starting '$($script:selectedProfile)' in $($script:remainingSeconds) seconds..."
            $btnStart.Text = "Start Imaging ($($script:remainingSeconds)s)"
            $timer.Add_Tick({
                $script:remainingSeconds--
                if ($script:remainingSeconds -le 0) {
                    $timer.Stop()
                    $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
                    $form.Close()
                } else {
                    $lblTimer.Text = "Auto-starting '$($script:selectedProfile)' in $($script:remainingSeconds) seconds..."
                    $btnStart.Text = "Start Imaging ($($script:remainingSeconds)s)"
                }
            })
            $timer.Start()
        } else {
            $lblTimer.Text = "Select a profile and click 'Start Imaging'."
            $btnStart.Text = "Start Imaging"
            $btnPause.Enabled = $false
        }

        $form.Add_Shown({
            try {
                if ($consoleHwnd -ne [IntPtr]::Zero) {
                    [Win32WindowHelper]::ShowWindow($consoleHwnd, 6) # SW_MINIMIZE
                }
            } catch {}
            $form.Activate()
            $form.BringToFront()
        })

        try {
            [void]$form.ShowDialog()
        } finally {
            # Restore console to Maximized so Glazier imaging logs are visible full-screen
            try {
                if ($consoleHwnd -ne [IntPtr]::Zero) {
                    [Win32WindowHelper]::ShowWindow($consoleHwnd, 3) # SW_MAXIMIZE
                }
            } catch {
                # ignore restore error
            }
            $timer.Dispose()
            $form.Dispose()
        }
    } catch {
        Write-Host "Warning: GUI failed to display ($_); falling back to default profile: $defaultId" -ForegroundColor Yellow
        $script:selectedProfile = $defaultId
    }

    return $script:selectedProfile
}

# Only show GUI if $glazier_spec_os wasn't explicitly passed via CLI
if ([string]::IsNullOrWhiteSpace($glazier_spec_os)) {
    try {
        $initConsoleHwnd = [Win32WindowHelper]::GetConsoleWindow()
        if ($initConsoleHwnd -ne [IntPtr]::Zero) {
            [Win32WindowHelper]::ShowWindow($initConsoleHwnd, 6) # SW_MINIMIZE
        }
    } catch {}
    $menuData = Get-GlazierProfiles -BaseUrl $config_server
    $glazier_spec_os = Show-GlazierProfileGUI -MenuData $menuData
}

Write-Output "Starting Glazier imaging process with profile: $glazier_spec_os..."

# For a full list of Glazier flags, execute `python autobuild.py --helpfull`
$py_args = @(
    "X:\glazier\glazier\autobuild.py",
    "--config_server=$config_server",
    '--resource_path=X:\glazier-resources',
    "--glazier_spec_os=$glazier_spec_os",
    '--preserve_tasks=true'
)

& X:\Python\python.exe $py_args
