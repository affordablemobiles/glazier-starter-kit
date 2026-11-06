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

    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    public static readonly IntPtr HWND_BOTTOM = new IntPtr(1);
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOACTIVATE = 0x0010;

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);

    public const uint ES_CONTINUOUS = 0x80000000;
    public const uint ES_SYSTEM_REQUIRED = 0x00000001;
    public const uint ES_DISPLAY_REQUIRED = 0x00000002;

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetStdHandle(int nStdHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);

    public const int STD_INPUT_HANDLE = -10;
    public const uint ENABLE_QUICK_EDIT_MODE = 0x0040;
    public const uint ENABLE_EXTENDED_FLAGS = 0x0080;

    public static void DisableQuickEdit() {
        try {
            IntPtr hStdin = GetStdHandle(STD_INPUT_HANDLE);
            uint mode;
            if (GetConsoleMode(hStdin, out mode)) {
                mode &= ~ENABLE_QUICK_EDIT_MODE;
                mode |= ENABLE_EXTENDED_FLAGS;
                SetConsoleMode(hStdin, mode);
            }
        } catch {}
    }
}
"@ -ErrorAction SilentlyContinue

# Ensure core fonts are loaded into the live GDI session
$fontsDir = "$env:SystemRoot\Fonts"
$fontFiles = @("segoeui.ttf", "segoeuib.ttf", "segoeuii.ttf", "seguisb.ttf", "consola.ttf", "consolab.ttf")
foreach ($ff in $fontFiles) {
    $fp = "$fontsDir\$ff"
    if (Test-Path $fp) {
        [void][Win32WindowHelper]::AddFontResource($fp)
    }
}

function Show-GlazierProfileGUI {
    param([hashtable]$MenuData)

    # Assert Wake Lock (ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED)
    try {
        [void][Win32WindowHelper]::SetThreadExecutionState(0x80000003)
    } catch {}

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
                [void][Win32WindowHelper]::ShowWindow($consoleHwnd, 6) # SW_MINIMIZE
            }
        } catch {
            # continue even if console helper fails
        }

        $form = New-Object System.Windows.Forms.Form
        $form.Text = "Glazier Deployment - Select Profile"
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
        $btnTerminal.Add_Click({
            & $stopCountdown
            $form.TopMost = $false
            Start-Process -FilePath "cmd.exe" -ArgumentList '/c start "Glazier Menu Debug Terminal" PowerShell.exe -NoProfile -NoLogo -NoExit'
        })

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
                    [void][Win32WindowHelper]::ShowWindow($consoleHwnd, 6) # SW_MINIMIZE
                }
            } catch {}
            $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
            $form.Activate()
            $form.BringToFront()
        })

        try {
            [void]$form.ShowDialog()
        } finally {
            # Keep console minimized so Start-GlazierDeploymentGUI displays with desktop background
            try {
                if ($consoleHwnd -ne [IntPtr]::Zero) {
                    [void][Win32WindowHelper]::ShowWindow($consoleHwnd, 6) # SW_MINIMIZE
                }
            } catch {
                # ignore error
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
    } catch {}
    return $null
}

function Get-GlazierLiveProgress {
    param(
        [string]$CurrentLogChunk = ""
    )

    $taskCandidates = @(
        "X:\task_list.yaml",
        "X:\glazier_cache\task_list.yaml",
        "C:\glazier_cache\task_list.yaml",
        "C:\task_list.yaml"
    )

    $taskFile = $null
    foreach ($tc in $taskCandidates) {
        if (Test-Path $tc) {
            $taskFile = $tc
            break
        }
    }

    if (-not $taskFile) {
        if ($script:totalPhaseTasks -gt 0) {
            return "Completing deployment phase..."
        }
        return "Compiling Glazier deployment tasks from server..."
    }

    $rawYaml = Get-Content -Path $taskFile -Raw -ErrorAction SilentlyContinue
    if (-not $rawYaml) {
        return "Processing deployment tasks..."
    }

    $blocks = [regex]::Split($rawYaml, '(?m)^-\s+data:\s*\r?$')
    $tasks = @()
    foreach ($b in $blocks) {
        $trimmed = $b.Trim()
        if (-not $trimmed) { continue }
        $lines = $trimmed -split "`r?`n"
        $firstLine = $lines[0].Trim()
        if ($firstLine -match '^([A-Za-z0-9_]+):') {
            $actName = $matches[1]
            $taskBody = ""
            if ($lines.Length -gt 1) {
                $contentLines = @()
                for ($li = 1; $li -lt $lines.Length; $li++) {
                    if ($lines[$li] -match '^\s*path:\s*') { break }
                    $contentLines += $lines[$li]
                }
                $taskBody = $contentLines -join "`n"
            }
            $tasks += [PSCustomObject]@{
                Action = $actName
                Body   = $taskBody
            }
        }
    }

    if ($tasks.Count -eq 0) {
        return "Completing deployment phase..."
    }

    # Identify tasks up to first Reboot or ExitWinPE
    $phaseTasks = @()
    foreach ($t in $tasks) {
        $phaseTasks += $t
        if ($t.Action -in @('Reboot', 'ExitWinPE')) {
            break
        }
    }

    $phaseCount = $phaseTasks.Count
    if ($script:totalPhaseTasks -eq 0 -or $phaseCount -gt $script:totalPhaseTasks) {
        $script:totalPhaseTasks = $phaseCount
    }

    $currentStepNum = [Math]::Max(1, $script:totalPhaseTasks - $phaseCount + 1)
    $activeTask = $phaseTasks[0]
    $act = $activeTask.Action
    $body = $activeTask.Body

    $taskSig = "$currentStepNum|$act|$body"
    if ($taskSig -ne $script:lastTaskSig) {
        $script:lastTaskSig = $taskSig
        $script:lastLogLine = ""
        $script:subTaskPct = 0
        $CurrentLogChunk = ""
    }

    # Check for sub-task percentage in CurrentLogChunk (e.g. "45%", "14.2%", "(40%)", "[=== 35.0% ===]")
    if ($CurrentLogChunk -match '(?<![0-9.])(\d{1,3}(?:\.\d+)?)\s*%') {
        try {
            $parsedSubPct = [double]$matches[1]
            if ($parsedSubPct -ge 0 -and $parsedSubPct -le 100) {
                $script:subTaskPct = [int]$parsedSubPct
            }
        } catch {}
    }

    # Calculate overall percentage across the phase
    $stepStartPct = if ($script:totalPhaseTasks -gt 0) { (($currentStepNum - 1) / [double]$script:totalPhaseTasks) * 100.0 } else { 0.0 }
    $stepSpanPct  = if ($script:totalPhaseTasks -gt 0) { (1.0 / [double]$script:totalPhaseTasks) * 100.0 } else { 100.0 }
    $script:currentOverallPct = [int][Math]::Min(98, [Math]::Max(6, [Math]::Round($stepStartPct + ($stepSpanPct * ($script:subTaskPct / 100.0)))))

    # Check friendly hints from body first
    $desc = $null
    if ($body -match 'Start-OSDCloud') {
        $desc = "Installing Windows OS image and hardware drivers (OSDCloud)..."
    } elseif ($body -match 'bcdboot') {
        $desc = "Configuring Windows UEFI Boot Manager..."
    } elseif ($body -match 'install_latest_cu\.py|UpdateMSU') {
        $desc = "Downloading and installing latest Windows Cumulative Updates..."
    } elseif ($body -match 'Invoke-OSDSpecialize|unattend\.xml') {
        $desc = "Applying Windows unattend specialization config..."
    } elseif ($body -match 'odt_installer|setup\.exe\s+/configure|Office365') {
        $desc = "Installing Microsoft Office 365..."
    } elseif ($body -match 'GoogleChromeStandaloneEnterprise') {
        $desc = "Installing Google Chrome Enterprise..."
    } elseif ($body -match 'EndpointVerification') {
        $desc = "Installing Google Endpoint Verification..."
    } elseif ($body -match 'gcpwstandaloneenterprise') {
        $desc = "Installing Google Credential Provider for Windows (GCPW)..."
    } elseif ($body -match 'mgmt-installer') {
        $desc = "Installing Enterprise Management Agent..."
    } elseif ($body -match 'stage_wifi_profiles|Stage-GlazierWifiProfiles') {
        $desc = "Staging Wi-Fi profiles into target Windows OS..."
    } elseif ($body -match 'Install-WindowsUpdate') {
        $desc = "Checking and installing Windows and driver updates..."
    }

    # If body did not match a friendly hint, check CurrentLogChunk
    if (-not $desc -and $CurrentLogChunk) {
        if ($CurrentLogChunk -match 'GoogleChromeStandaloneEnterprise') {
            $desc = "Installing Google Chrome Enterprise..."
        } elseif ($CurrentLogChunk -match 'EndpointVerification') {
            $desc = "Installing Google Endpoint Verification..."
        } elseif ($CurrentLogChunk -match 'gcpwstandaloneenterprise') {
            $desc = "Installing Google Credential Provider for Windows (GCPW)..."
        } elseif ($CurrentLogChunk -match 'odt_installer|setup\.exe\s+/configure|Office365') {
            $desc = "Installing Microsoft Office 365..."
        } elseif ($CurrentLogChunk -match 'mgmt-installer') {
            $desc = "Installing Enterprise Management Agent..."
        } elseif ($CurrentLogChunk -match 'stage_wifi_profiles|Stage-GlazierWifiProfiles') {
            $desc = "Staging Wi-Fi profiles into target Windows OS..."
        } elseif ($CurrentLogChunk -match 'KB\d+') {
            $desc = "Downloading and installing Windows Cumulative Updates..."
        }
    }

    # Generate dynamic description if not in hint map
    if (-not $desc) {
        switch ($act) {
            'pull' {
                $leaf = "files"
                if ($body -match 'https?://[^\s''",\]]+/([^\s''",\]]+)') {
                    $leaf = $matches[1]
                } elseif ($body -match '-\s*[''"]?([^''"#\s,\]]+)') {
                    $leaf = Split-Path -Leaf $matches[1]
                }
                $desc = "Downloading $leaf..."
            }
            { $_ -in @('CopyDir', 'CopyFile') } {
                $p1 = "source"
                $p2 = "destination"
                if ($body -match '-\s*[''"]?([^''"\r\n]+)[''"]?\s*\r?\n\s*-\s*[''"]?([^''"\r\n]+)[''"]?') {
                    $p1 = Split-Path -Leaf $matches[1]
                    $p2 = Split-Path -Leaf $matches[2]
                }
                $desc = "Copying $p1 to $p2..."
            }
            'MkDir' {
                $dir = "directory"
                if ($body -match '-\s*[''"]?([^''"\r\n]+)') {
                    $dir = Split-Path -Leaf $matches[1].Trim()
                }
                $desc = "Creating directory $dir..."
            }
            'RmDir' {
                $dir = "directory"
                if ($body -match '-\s*[''"]?([^''"\r\n]+)') {
                    $dir = Split-Path -Leaf $matches[1].Trim()
                }
                $desc = "Cleaning up temporary directory $dir..."
            }
            'Sleep' {
                $reason = ""
                $sec = "10"
                if ($body -match '-\s*(\d+)') { $sec = $matches[1] }
                if ($body -match '-\s*[''"]([^''"\r\n]+)[''"]') { $reason = $matches[1] }
                if ($reason) {
                    $desc = "Waiting: $reason..."
                } else {
                    $desc = "Waiting ($sec s)..."
                }
            }
            'SetTimer' {
                $tName = "phase"
                if ($body -match '-\s*[''"]?([^''"\r\n]+)') { $tName = $matches[1].Trim() }
                $desc = "Recording deployment timer ($tName)..."
            }
            { $_ -in @('Reboot', 'ExitWinPE') } {
                $rReason = "to continue deployment"
                if ($body -match '-\s*[''"]([^''"\r\n]+)[''"]') { $rReason = $matches[1] }
                $desc = "Rebooting system ($rReason)..."
            }
            { $_ -in @('Execute', 'PSCommand', 'MultiPSCommand') } {
                $cmdShort = ""
                if ($body -match '-\s*[''"]?([^''"\r\n]+)') {
                    $cmdShort = $matches[1].Trim()
                    if ($cmdShort.Length -gt 45) {
                        $cmdShort = $cmdShort.Substring(0, 42) + "..."
                    }
                }
                if ($cmdShort) {
                    $desc = "Running $act ($cmdShort)..."
                } else {
                    $desc = "Running $act..."
                }
            }
            default {
                $desc = "Running $act..."
            }
        }
    }

    if ($script:totalPhaseTasks -gt 0) {
        $stepPrefix = if ($script:subTaskPct -gt 0) {
            "Step $currentStepNum of $($script:totalPhaseTasks) ($($script:subTaskPct)%): "
        } else {
            "Step $currentStepNum of $($script:totalPhaseTasks): "
        }
        return "$stepPrefix$desc"
    }
    return $desc
}

function Start-GlazierDeploymentGUI {
    param(
        [string]$ConfigServer = "http://glazier",
        [string]$GlazierSpecOS = "windows-stable",
        [string]$ResourcePath = "",
        [string]$PythonExe = "",
        [string]$GlazierScript = "",
        [string]$ConfigRootPath = ""
    )

    $isWinPE = Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT'
    $rootDrive = if ($isWinPE) { "X:" } else { "C:" }

    $createdNew = $false
    $script:glazierMutex = New-Object System.Threading.Mutex($true, "Global\GlazierDeploymentGUIMutex", [ref]$createdNew)
    if (-not $createdNew) {
        Write-Host "Another instance of Glazier Deployment GUI is already running. Exiting duplicate instance."
        [Environment]::Exit(0)
    }

    if ([string]::IsNullOrWhiteSpace($ResourcePath)) {
        $ResourcePath = "$rootDrive\glazier-resources"
    }
    if ([string]::IsNullOrWhiteSpace($PythonExe)) {
        $PythonExe = "$rootDrive\Python\python.exe"
    }
    if ([string]::IsNullOrWhiteSpace($GlazierScript)) {
        $GlazierScript = "$rootDrive\glazier\glazier\autobuild.py"
    }

    $env:LOCALAPPDATA = "$rootDrive\"
    $env:PYTHONPATH = "$rootDrive\glazier\"
    $env:SSL_CERT_FILE = "$ResourcePath\ca-certs.crt"

    $consoleHwnd = [IntPtr]::Zero
    try {
        $consoleHwnd = [Win32WindowHelper]::GetConsoleWindow()
        if ($consoleHwnd -ne [IntPtr]::Zero) {
            [void][Win32WindowHelper]::ShowWindow($consoleHwnd, 6) # SW_MINIMIZE
        }
    } catch {}

    # If in Windows (Phase 2), apply wallpaper and resolution cascade if available
    if (-not $isWinPE) {
        $wallScript = "C:\glazier-resources\Set-WinPEWallpaper.ps1"
        if (Test-Path $wallScript) {
            try { & $wallScript } catch {}
        }
    }

    # Assert Wake Lock (ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED)
    try {
        [void][Win32WindowHelper]::SetThreadExecutionState(0x80000003)
    } catch {}

    # In Phase 2 Windows, disable AC/DC standby, hibernate, and monitor timeouts
    if (-not $isWinPE) {
        foreach ($setting in @('standby-timeout-ac', 'standby-timeout-dc', 'hibernate-timeout-ac', 'hibernate-timeout-dc', 'monitor-timeout-ac', 'monitor-timeout-dc')) {
            & powercfg.exe /change $setting 0 2>$null | Out-Null
        }
    }

    # Ensure core fonts are loaded into live GDI session
    $fontsDir = "$env:SystemRoot\Fonts"
    $fontFiles = @("segoeui.ttf", "segoeuib.ttf", "segoeuii.ttf", "seguisb.ttf", "consola.ttf", "consolab.ttf")
    foreach ($ff in $fontFiles) {
        $fp = "$fontsDir\$ff"
        if (Test-Path $fp) {
            [void][Win32WindowHelper]::AddFontResource($fp)
        }
    }

    $bgForm = $null
    $form = $null

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        [System.Windows.Forms.Application]::EnableVisualStyles()

        # Compute window dimensions and position relative to AO logo on bottom-left
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $marginX = [Math]::Max(32, [int]($screen.Width * 0.03125)) # 60px on 1920
        $topY    = [Math]::Max(16, [int]($screen.Height * 0.022))   # 24px on 1080
        $bottomClearance = [Math]::Max(140, [int]($screen.Height * 0.182)) # ~196px on 1080 (leaves clean gap above logo at Y=912)
        $formW = [Math]::Max(860, $screen.Width - ($marginX * 2))
        $formH = [Math]::Max(520, $screen.Height - $topY - $bottomClearance)

        $form = New-Object System.Windows.Forms.Form
        $phaseTitle = if ($isWinPE) { "Phase 1: WinPE Deployment" } else { "Phase 2: Windows Setup" }
        $form.Text = "Glazier Deployment - $phaseTitle"
        $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
        $form.Location = New-Object System.Drawing.Point($marginX, $topY)
        $form.ClientSize = New-Object System.Drawing.Size($formW, $formH)
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false
        $form.TopMost = $isWinPE
        $form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
        $form.KeyPreview = $true

        # Keyboard shortcut (F12 or Ctrl+T) to open debug shell at any point
        $openShellAction = {
            $form.TopMost = $false
            Start-Process -FilePath "cmd.exe" -ArgumentList '/c start "Glazier Debug Shell" PowerShell.exe -NoProfile -NoLogo -NoExit'
        }

        $saveLogsAction = {
            $form.TopMost = $false
            try {
                Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

                $usbDrive = [System.IO.DriveInfo]::GetDrives() |
                    Where-Object { $_.DriveType -eq [System.IO.DriveType]::Removable -and $_.IsReady } |
                    Select-Object -First 1

                $initDir = if ($usbDrive) { $usbDrive.RootDirectory.FullName } else { $rootDrive + "\" }

                $serial = "UNKNOWN"
                try {
                    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
                    if ($bios -and $bios.SerialNumber) { $serial = $bios.SerialNumber.Trim() }
                } catch {}

                $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                $defaultName = "Glazier-Logs-$serial-$timestamp.zip"

                $sfd = New-Object System.Windows.Forms.SaveFileDialog
                $sfd.Title = "Save Glazier Deployment Logs"
                $sfd.Filter = "ZIP Archive (*.zip)|*.zip|Combined Log File (*.log)|*.log|All Files (*.*)|*.*"
                $sfd.FileName = $defaultName
                $sfd.InitialDirectory = $initDir

                if ($sfd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                    $savePath = $sfd.FileName
                    $discoveredLogs = @()

                    $logCandidates = @(
                        "X:\glazier_cache\glazier.log",
                        "C:\glazier_cache\glazier.log",
                        "C:\Windows\Logs\Glazier\glazier.log",
                        "$env:TEMP\glazier_gui_error.log",
                        "$env:TEMP\glazier_stdout.log",
                        "$env:TEMP\glazier_stderr.log",
                        "$env:TEMP\update_modules.log",
                        "$env:TEMP\update_modules_err.log",
                        "X:\Windows\Logs\DISM\dism.log",
                        "C:\Windows\Logs\DISM\dism.log"
                    )
                    foreach ($lc in $logCandidates) {
                        if (Test-Path $lc) { $discoveredLogs += $lc }
                    }

                    $osdDirs = @("X:\OSDCloud\Logs", "C:\OSDCloud\Logs")
                    foreach ($od in $osdDirs) {
                        if (Test-Path $od) {
                            $discoveredLogs += (Get-ChildItem -Path $od -Filter "*.log" -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
                        }
                    }

                    if ($savePath.ToLower().EndsWith(".zip")) {
                        $tempStaging = "$env:TEMP\glazier_log_bundle_$timestamp"
                        if (Test-Path $tempStaging) { Remove-Item $tempStaging -Recurse -Force -ErrorAction SilentlyContinue }
                        New-Item -ItemType Directory -Path $tempStaging -Force | Out-Null

                        Set-Content -Path "$tempStaging\console_transcript.log" -Value $txtOutput.Text -Encoding UTF8 -Force

                        foreach ($lf in $discoveredLogs) {
                            if (Test-Path $lf) {
                                $fname = Split-Path -Leaf $lf
                                $destLog = "$tempStaging\$fname"
                                if (Test-Path $destLog) {
                                    $parentDir = Split-Path -Parent $lf | Split-Path -Leaf
                                    $destLog = "$tempStaging\${parentDir}_$fname"
                                }
                                Copy-Item -Path $lf -Destination $destLog -Force -ErrorAction SilentlyContinue
                            }
                        }

                        if (Test-Path $savePath) { Remove-Item -Path $savePath -Force -ErrorAction SilentlyContinue }
                        [System.IO.Compression.ZipFile]::CreateFromDirectory($tempStaging, $savePath)
                        Remove-Item -Path $tempStaging -Recurse -Force -ErrorAction SilentlyContinue
                    } else {
                        $combined = @()
                        $combined += "================================================================================"
                        $combined += "GLAZIER DEPLOYMENT CONSOLE TRANSCRIPT - $timestamp"
                        $combined += "================================================================================"
                        $combined += $txtOutput.Text
                        $combined += ""
                        foreach ($lf in $discoveredLogs) {
                            if (Test-Path $lf) {
                                $combined += "================================================================================"
                                $combined += "LOG FILE: $lf"
                                $combined += "================================================================================"
                                $combined += (Get-Content -Path $lf -Raw -ErrorAction SilentlyContinue)
                                $combined += ""
                            }
                        }
                        Set-Content -Path $savePath -Value ($combined -join "`r`n") -Encoding UTF8 -Force
                    }

                    [System.Windows.Forms.MessageBox]::Show(
                        "Logs saved successfully to:`r`n$savePath",
                        "Logs Saved",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Information
                    )
                }
            } catch {
                [System.Windows.Forms.MessageBox]::Show(
                    "Failed to save logs: $_",
                    "Error",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error
                )
            } finally {
                $form.TopMost = $true
            }
        }

        $form.Add_KeyDown({
            if ($_.KeyCode -eq [System.Windows.Forms.Keys]::F12 -or ($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::T)) {
                & $openShellAction
            }
        })

        # Header Panel
        $panelHeader = New-Object System.Windows.Forms.Panel
        $panelHeader.Location = New-Object System.Drawing.Point(20, 16)
        $panelHeader.Size = New-Object System.Drawing.Size(($formW - 40), 108)
        $panelHeader.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
        $panelHeader.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        $form.Controls.Add($panelHeader)

        # Status Badge
        $lblBadge = New-Object System.Windows.Forms.Label
        $lblBadge.Location = New-Object System.Drawing.Point(16, 16)
        $lblBadge.Size = New-Object System.Drawing.Size(52, 52)
        $lblBadge.Text = "[..]"
        $lblBadge.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $lblBadge.Font = New-Object System.Drawing.Font("Segoe UI", 20, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $lblBadge.BackColor = [System.Drawing.Color]::FromArgb(219, 234, 254)
        $lblBadge.ForeColor = [System.Drawing.Color]::FromArgb(29, 78, 216)
        $panelHeader.Controls.Add($lblBadge)

        # Header Title
        $lblTitle = New-Object System.Windows.Forms.Label
        $lblTitle.Location = New-Object System.Drawing.Point(82, 12)
        $lblTitle.Size = New-Object System.Drawing.Size(($formW - 140), 28)
        $phaseHeader = if ($isWinPE) { "Installing Windows ($GlazierSpecOS) - Phase 1: WinPE Deployment" } else { "Finalizing Installation ($GlazierSpecOS) - Phase 2: Windows Setup" }
        $lblTitle.Text = $phaseHeader
        $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 20, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
        $panelHeader.Controls.Add($lblTitle)

        # Dynamic Stage Subtitle
        $lblStage = New-Object System.Windows.Forms.Label
        $lblStage.Location = New-Object System.Drawing.Point(82, 42)
        $lblStage.Size = New-Object System.Drawing.Size(($formW - 140), 24)
        $lblStage.Text = "Starting Glazier provisioning engine..."
        $lblStage.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $lblStage.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
        $panelHeader.Controls.Add($lblStage)

        # 3-Panel Percentage Fill Bar with Aero Shimmer Pulse
        $trackW = $formW - 140
        $trackH = 22

        $progressTrack = New-Object System.Windows.Forms.Panel
        $progressTrack.Location = New-Object System.Drawing.Point(82, 72)
        $progressTrack.Size = New-Object System.Drawing.Size($trackW, $trackH)
        $progressTrack.BackColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
        $progressTrack.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        $panelHeader.Controls.Add($progressTrack)

        # Middle Completed-Percentage Panel (grows left-to-right)
        $progressFill = New-Object System.Windows.Forms.Panel
        $progressFill.Location = New-Object System.Drawing.Point(0, 0)
        $progressFill.Size = New-Object System.Drawing.Size([Math]::Max(36, [int]($trackW * 0.08)), $trackH)
        $progressFill.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
        $progressTrack.Controls.Add($progressFill)

        # Inner Aero Shimmer Highlight Panel (child of $progressFill so Windows GDI clips it automatically!)
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

        # Terminal Header Panel
        $panelTermHeader = New-Object System.Windows.Forms.Panel
        $panelTermHeader.Location = New-Object System.Drawing.Point(20, 136)
        $panelTermHeader.Size = New-Object System.Drawing.Size(($formW - 40), 36)
        $panelTermHeader.BackColor = [System.Drawing.Color]::FromArgb(22, 30, 46)
        $form.Controls.Add($panelTermHeader)

        $lblTermTitle = New-Object System.Windows.Forms.Label
        $lblTermTitle.Location = New-Object System.Drawing.Point(12, 8)
        $lblTermTitle.Size = New-Object System.Drawing.Size(360, 20)
        $lblTermTitle.Text = ">_ glazier-autobuild -- live console output"
        $lblTermTitle.Font = New-Object System.Drawing.Font("Consolas", 13, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $lblTermTitle.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
        $panelTermHeader.Controls.Add($lblTermTitle)

        # Auto-scroll Checkbox
        $chkAutoScroll = New-Object System.Windows.Forms.CheckBox
        $chkAutoScroll.Text = "Auto-scroll"
        $chkAutoScroll.Checked = $true
        $chkAutoScroll.Location = New-Object System.Drawing.Point(($panelTermHeader.Width - 445), 6)
        $chkAutoScroll.Size = New-Object System.Drawing.Size(100, 24)
        $chkAutoScroll.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
        $chkAutoScroll.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $panelTermHeader.Controls.Add($chkAutoScroll)

        # Open Shell / Terminal button (always present and clickable)
        $btnTerminal = New-Object System.Windows.Forms.Button
        $btnTerminal.Text = "Open Shell"
        $btnTerminal.Location = New-Object System.Drawing.Point(($panelTermHeader.Width - 335), 4)
        $btnTerminal.Size = New-Object System.Drawing.Size(105, 28)
        $btnTerminal.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnTerminal.BackColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
        $btnTerminal.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
        $btnTerminal.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $btnTerminal.Add_Click($openShellAction)
        $panelTermHeader.Controls.Add($btnTerminal)

        # Save Logs button (always present, highlighted on failure)
        $btnSaveLogs = New-Object System.Windows.Forms.Button
        $btnSaveLogs.Text = "Save Logs..."
        $btnSaveLogs.Location = New-Object System.Drawing.Point(($panelTermHeader.Width - 220), 4)
        $btnSaveLogs.Size = New-Object System.Drawing.Size(105, 28)
        $btnSaveLogs.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnSaveLogs.BackColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
        $btnSaveLogs.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
        $btnSaveLogs.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $btnSaveLogs.Add_Click($saveLogsAction)
        $panelTermHeader.Controls.Add($btnSaveLogs)

        # Reboot PC button (hidden initially, shown on failure)
        $btnReboot = New-Object System.Windows.Forms.Button
        $btnReboot.Text = "Reboot PC"
        $btnReboot.Location = New-Object System.Drawing.Point(($panelTermHeader.Width - 105), 4)
        $btnReboot.Size = New-Object System.Drawing.Size(95, 28)
        $btnReboot.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnReboot.BackColor = [System.Drawing.Color]::FromArgb(185, 28, 28)
        $btnReboot.ForeColor = [System.Drawing.Color]::White
        $btnReboot.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $btnReboot.Visible = $false
        $btnReboot.Add_Click({
            if ($bgForm -and -not $bgForm.IsDisposed) {
                try { $bgForm.Close(); $bgForm.Dispose() } catch {}
            }
            $bgForm = $null
            try { [void][Win32WindowHelper]::SetThreadExecutionState(0x80000000) } catch {}
            if ($isWinPE) {
                & "$env:SystemRoot\System32\wpeutil.exe" reboot
            } else {
                & shutdown.exe /r /t 0
            }
            $form.Close()
        })
        $panelTermHeader.Controls.Add($btnReboot)

        # Terminal Body Container Panel
        $panelTermBody = New-Object System.Windows.Forms.Panel
        $panelTermBody.Location = New-Object System.Drawing.Point(20, 172)
        $panelTermBody.Size = New-Object System.Drawing.Size(($formW - 40), ($formH - 192))
        $panelTermBody.BackColor = [System.Drawing.Color]::FromArgb(12, 18, 30)
        $form.Controls.Add($panelTermBody)

        # Inner Terminal TextBox
        $txtOutput = New-Object System.Windows.Forms.TextBox
        $txtOutput.Location = New-Object System.Drawing.Point(10, 8)
        $txtOutput.Size = New-Object System.Drawing.Size(($panelTermBody.Width - 20), ($panelTermBody.Height - 16))
        $txtOutput.BorderStyle = [System.Windows.Forms.BorderStyle]::None
        $txtOutput.BackColor = [System.Drawing.Color]::FromArgb(12, 18, 30)
        $txtOutput.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
        $txtOutput.Font = New-Object System.Drawing.Font("Consolas", 13, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $txtOutput.Multiline = $true
        $txtOutput.ReadOnly = $true
        $txtOutput.HideSelection = $true
        $txtOutput.WordWrap = $false
        $txtOutput.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
        $panelTermBody.Controls.Add($txtOutput)

        $form.Add_Shown({
            try {
                if ($consoleHwnd -ne [IntPtr]::Zero) {
                    [void][Win32WindowHelper]::ShowWindow($consoleHwnd, 6) # SW_MINIMIZE
                }
            } catch {}
            $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
            $form.Activate()
            $form.BringToFront()
        })

        if (-not $isWinPE) {
            $bgImgPath = if (Test-Path "$env:TEMP\winpe_cropped.jpg") { "$env:TEMP\winpe_cropped.jpg" } else { "C:\glazier-resources\winpe.jpg" }
            if (Test-Path $bgImgPath) {
                $bgForm = New-Object System.Windows.Forms.Form
                $bgForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
                $bgForm.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
                $bgForm.Bounds = $screen
                $bgForm.BackColor = [System.Drawing.Color]::FromArgb(2, 66, 43)
                $bgForm.ShowInTaskbar = $false
                $bgForm.TopMost = $false
                try {
                    $bgForm.BackgroundImage = [System.Drawing.Image]::FromFile($bgImgPath)
                    $bgForm.BackgroundImageLayout = [System.Windows.Forms.ImageLayout]::Stretch
                } catch {}

                $pinBottomAction = {
                    if ($bgForm -and -not $bgForm.IsDisposed) {
                        [void][Win32WindowHelper]::SetWindowPos($bgForm.Handle, [Win32WindowHelper]::HWND_BOTTOM, 0, 0, 0, 0, 0x0013)
                    }
                }
                $bgForm.Add_Shown($pinBottomAction)
                $bgForm.Add_Activated($pinBottomAction)
                $bgForm.Add_MouseDown($pinBottomAction)
                $bgForm.Add_Click($pinBottomAction)

                $bgForm.Show()
                if ($bgForm -and -not $bgForm.IsDisposed) {
                    [void][Win32WindowHelper]::SetWindowPos($bgForm.Handle, [Win32WindowHelper]::HWND_BOTTOM, 0, 0, 0, 0, 0x0013)
                }
            }
        }

        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()

        # Phase 1 vs Phase 2 Wi-Fi profile handling and network readiness
        if ($isWinPE) {
            $wifiExportDir = "X:\glazier-resources\wifi_profiles"
            if (-not (Test-Path $wifiExportDir)) {
                New-Item -ItemType Directory -Path $wifiExportDir -Force | Out-Null
            }
            # Scan candidate drives for staged profiles if none present in RAM
            $existingProfiles = Get-ChildItem -Path $wifiExportDir -Filter "*.xml" -ErrorAction SilentlyContinue
            if (-not $existingProfiles -or $existingProfiles.Count -eq 0) {
                try {
                    $candidateDrives = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.Name -ne 'X:\' }
                    foreach ($cDrive in $candidateDrives) {
                        $stagedSourcesDir = Join-Path $cDrive.RootDirectory.FullName "sources\wifi_profiles"
                        if (Test-Path $stagedSourcesDir) {
                            $stagedXmls = Get-ChildItem -Path $stagedSourcesDir -Filter "*.xml" -ErrorAction SilentlyContinue
                            foreach ($sXml in $stagedXmls) {
                                Copy-Item -Path $sXml.FullName -Destination $wifiExportDir -Force -ErrorAction SilentlyContinue
                            }
                        }
                    }
                } catch {}
            }
            if ((Get-Service -Name WlanSvc -ErrorAction SilentlyContinue).Status -eq 'Running') {
                try {
                    & netsh.exe wlan export profile key=clear folder="$wifiExportDir" | Out-Null
                } catch {}
            }
        } else {
            $wifiDir = "C:\glazier-resources\wifi_profiles"
            if (Test-Path $wifiDir) {
                try {
                    Start-Service -Name WlanSvc -ErrorAction SilentlyContinue
                    # Wait up to 10 seconds for WlanSvc to initialize and enumerate wireless interface
                    for ($wInit = 1; $wInit -le 10; $wInit++) {
                        $wlanIfaces = (& netsh.exe wlan show interfaces 2>$null) -join "`n"
                        if ($wlanIfaces -match 'Name\s*:') { break }
                        $script:shimmerPos = ($script:shimmerPos + 16)
                        if ($script:shimmerPos -gt ($progressFill.Width + 70)) { $script:shimmerPos = -70 }
                        $progressPulse.Left = $script:shimmerPos
                        [System.Windows.Forms.Application]::DoEvents()
                        Start-Sleep -Milliseconds 1000
                    }

                    $pFiles = Get-ChildItem -Path $wifiDir -Filter "*.xml" -ErrorAction SilentlyContinue
                    foreach ($pf in $pFiles) {
                        & netsh.exe wlan add profile filename="$($pf.FullName)" user=all | Out-Null
                        if ($LASTEXITCODE -eq 0) {
                            try {
                                [xml]$px = Get-Content -Path $pf.FullName -ErrorAction SilentlyContinue
                                $pn = if ($px -and $px.WLANProfile) { $px.WLANProfile.name } else { $pf.BaseName }
                                if ($pn) {
                                    & netsh.exe wlan connect name="$pn" | Out-Null
                                }
                            } catch {}
                            Remove-Item -Path $pf.FullName -Force -ErrorAction SilentlyContinue
                        }
                    }
                    $remainingXml = Get-ChildItem -Path $wifiDir -Filter "*.xml" -ErrorAction SilentlyContinue
                    if (-not $remainingXml -or $remainingXml.Count -eq 0) {
                        Remove-Item -Path $wifiDir -Recurse -Force -ErrorAction SilentlyContinue
                    }
                } catch {}
            }

            $netOk = Test-WinPENetwork
            if (-not $netOk) {
                $lblStage.Text = "Waiting for network connection in Windows..."
                for ($nSec = 1; $nSec -le 15; $nSec++) {
                    $netOk = Test-WinPENetwork
                    if ($netOk) { break }
                    $script:shimmerPos = ($script:shimmerPos + 16)
                    if ($script:shimmerPos -gt ($progressFill.Width + 70)) { $script:shimmerPos = -70 }
                    $progressPulse.Left = $script:shimmerPos
                    [System.Windows.Forms.Application]::DoEvents()
                    Start-Sleep -Milliseconds 1000
                }
                if (-not $netOk) {
                    $wcCands = @(
                        "C:\glazier-resources\WirelessConnect.exe",
                        "C:\Windows\System32\WirelessConnect.exe",
                        "C:\Windows\WirelessConnect.exe"
                    )
                    $wcExe = $wcCands | Where-Object { Test-Path $_ } | Select-Object -First 1
                    if ($wcExe) {
                        $form.TopMost = $false
                        [System.Windows.Forms.Application]::DoEvents()
                        Start-Process -FilePath $wcExe -Wait
                        $form.TopMost = $true
                        [System.Windows.Forms.Application]::DoEvents()
                        for ($wSec = 1; $wSec -le 10; $wSec++) {
                            $netOk = Test-WinPENetwork
                            if ($netOk) { break }
                            $script:shimmerPos = ($script:shimmerPos + 16)
                            if ($script:shimmerPos -gt ($progressFill.Width + 70)) { $script:shimmerPos = -70 }
                            $progressPulse.Left = $script:shimmerPos
                            [System.Windows.Forms.Application]::DoEvents()
                            Start-Sleep -Milliseconds 1000
                        }
                    }
                }
            }
        }

        # Set up streaming output paths in $env:TEMP
        $stdoutLog = "$env:TEMP\glazier_stdout.log"
        $stderrLog = "$env:TEMP\glazier_stderr.log"
        if (Test-Path $stdoutLog) { Remove-Item $stdoutLog -Force -ErrorAction SilentlyContinue }
        if (Test-Path $stderrLog) { Remove-Item $stderrLog -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType File -Path $stdoutLog -Force | Out-Null
        New-Item -ItemType File -Path $stderrLog -Force | Out-Null

        # Self-heal X:\glazier-resources\GlazierDeploymentGUI.ps1 in RAM before launching Python
        if ($isWinPE) {
            try {
                if (-not (Test-Path "X:\glazier-resources")) {
                    New-Item -ItemType Directory -Path "X:\glazier-resources" -Force | Out-Null
                }
                $targetGuiPath = "X:\glazier-resources\GlazierDeploymentGUI.ps1"
                $downloaded = $false
                $remoteGuiUrl = "$($ConfigServer.TrimEnd('/'))/glazier-resources/GlazierDeploymentGUI.ps1"
                try {
                    $wc = New-Object System.Net.WebClient
                    $wc.DownloadFile($remoteGuiUrl, $targetGuiPath)
                    if ((Test-Path $targetGuiPath) -and (Get-Item $targetGuiPath).Length -gt 0) {
                        $dlContent = Get-Content -Path $targetGuiPath -Raw -ErrorAction SilentlyContinue
                        if ($dlContent -and $dlContent -match 'Start-GlazierDeploymentGUI') {
                            $downloaded = $true
                        }
                    }
                } catch {
                    $downloaded = $false
                }

                if (-not $downloaded) {
                    $win32TypeDefCode = @'
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

$win32HelperTypeDef = @"
using System;
using System.Runtime.InteropServices;

public class Win32WindowHelper {
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();

    [DllImport("gdi32.dll", CharSet = CharSet.Auto)]
    public static extern int AddFontResource(string lpFileName);

    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    public static readonly IntPtr HWND_BOTTOM = new IntPtr(1);
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOACTIVATE = 0x0010;

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);

    public const uint ES_CONTINUOUS = 0x80000000;
    public const uint ES_SYSTEM_REQUIRED = 0x00000001;
    public const uint ES_DISPLAY_REQUIRED = 0x00000002;

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetStdHandle(int nStdHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);

    public const int STD_INPUT_HANDLE = -10;
    public const uint ENABLE_QUICK_EDIT_MODE = 0x0040;
    public const uint ENABLE_EXTENDED_FLAGS = 0x0080;

    public static void DisableQuickEdit() {
        try {
            IntPtr hStdin = GetStdHandle(STD_INPUT_HANDLE);
            uint mode;
            if (GetConsoleMode(hStdin, out mode)) {
                mode &= ~ENABLE_QUICK_EDIT_MODE;
                mode |= ENABLE_EXTENDED_FLAGS;
                SetConsoleMode(hStdin, mode);
            }
        } catch {}
    }
}
"@

if (-not ('Win32WindowHelper' -as [type])) {
    Add-Type -TypeDefinition $win32HelperTypeDef -ErrorAction SilentlyContinue
}
'@
                    $guiContent = @(
                        "# GlazierDeploymentGUI.ps1 - Runtime Self-Healed Deployment GUI",
                        $win32TypeDefCode,
                        "",
                        "function Test-WinPENetwork {",
                        ${function:Test-WinPENetwork},
                        "}",
                        "",
                        "function Get-GlazierLiveProgress {",
                        ${function:Get-GlazierLiveProgress},
                        "}",
                        "",
                        "function Start-GlazierDeploymentGUI {",
                        ${function:Start-GlazierDeploymentGUI},
                        "}"
                    ) -join "`r`n"
                    Set-Content -Path $targetGuiPath -Value $guiContent -Encoding UTF8 -Force
                }
            } catch {
                Write-Host "Warning: Could not self-heal X:\glazier-resources\GlazierDeploymentGUI.ps1: $_" -ForegroundColor Yellow
            }
        }

        $env:PYTHONUNBUFFERED = "1"
        $pyArgs = @("-u", $GlazierScript, "--config_server=$ConfigServer", "--resource_path=$ResourcePath", "--glazier_spec_os=$GlazierSpecOS", "--preserve_tasks=true")
        if (-not [string]::IsNullOrWhiteSpace($ConfigRootPath)) {
            $pyArgs += "--config_root_path=$ConfigRootPath"
        }

        $proc = Start-Process -FilePath $PythonExe `
            -ArgumentList $pyArgs `
            -RedirectStandardOutput $stdoutLog `
            -RedirectStandardError $stderrLog `
            -NoNewWindow -PassThru

        $outStream = [System.IO.File]::Open($stdoutLog, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $outReader = New-Object System.IO.StreamReader($outStream, [System.Text.Encoding]::UTF8)

        $errStream = [System.IO.File]::Open($stderrLog, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $errReader = New-Object System.IO.StreamReader($errStream, [System.Text.Encoding]::UTF8)

        $script:totalPhaseTasks = 0
        $script:lastGlazierError = ""
        $script:lastLogLine = ""
        $script:lastTaskSig = ""
        $script:subTaskPct = 0
        $script:currentOverallPct = 6
        $script:shimmerPos = -70
        $pulseFrames = @("[.  ]", "[.. ]", "[...]", "[ ..]", "[  .]", "[   ]")
        $pulseIdx = 0

        try {
            while (-not $proc.HasExited) {
                try { [void][Win32WindowHelper]::SetThreadExecutionState(0x80000003) } catch {}
                if ($bgForm -and -not $bgForm.IsDisposed) {
                    [void][Win32WindowHelper]::SetWindowPos($bgForm.Handle, [Win32WindowHelper]::HWND_BOTTOM, 0, 0, 0, 0, 0x0013)
                }
                $hasNewText = $false

                $pulseIdx = ($pulseIdx + 1) % $pulseFrames.Length
                $lblBadge.Text = $pulseFrames[$pulseIdx]

                # Update progress bar width based on overall percentage
                $fillPct = [Math]::Min(98, [Math]::Max(6, $script:currentOverallPct))
                $targetFillW = [Math]::Max(36, [int]($trackW * ($fillPct / 100.0)))
                $progressFill.Width = [Math]::Min($trackW, $targetFillW)

                # Sweep shimmer pulse across completed portion
                $script:shimmerPos = ($script:shimmerPos + 16)
                if ($script:shimmerPos -gt ($progressFill.Width + 70)) {
                    $script:shimmerPos = -70
                }
                $progressPulse.Left = $script:shimmerPos

                $chunk = $outReader.ReadToEnd()
                if ($chunk) {
                    $cleanChunk = [regex]::Replace($chunk, "\x1b\[[0-9;]*[a-zA-Z]", "")
                    $cleanChunk = [regex]::Replace($cleanChunk, "\r\n|\r|\n", "`r`n")
                    $txtOutput.AppendText($cleanChunk)
                    $hasNewText = $true
                    foreach ($line in ($cleanChunk -split "`r?`n")) {
                        $tLine = $line.Trim()
                        if ($tLine) {
                            $script:lastLogLine = $tLine
                        }
                        if ($line -match 'CRITICAL|Error Code|Exception|Error encountered|FAILED') {
                            $script:lastGlazierError = $line.Trim()
                        }
                    }
                }

                $errChunk = $errReader.ReadToEnd()
                if ($errChunk) {
                    $cleanErr = [regex]::Replace($errChunk, "\x1b\[[0-9;]*[a-zA-Z]", "")
                    $cleanErr = [regex]::Replace($cleanErr, "\r\n|\r|\n", "`r`n")
                    $txtOutput.AppendText($cleanErr)
                    $hasNewText = $true
                    foreach ($line in ($cleanErr -split "`r?`n")) {
                        $tLine = $line.Trim()
                        if ($tLine) {
                            $script:lastLogLine = $tLine
                        }
                        if ($line -match 'CRITICAL|Error Code|Exception|Error encountered|FAILED') {
                            $script:lastGlazierError = $line.Trim()
                        }
                    }
                }

                if ($hasNewText -and $chkAutoScroll.Checked) {
                    [void][Win32WindowHelper]::SendMessage($txtOutput.Handle, 0x0115, [IntPtr]7, [IntPtr]::Zero)
                }

                # Dynamically update progress from task list and latest log
                $prog = Get-GlazierLiveProgress -CurrentLogChunk $script:lastLogLine
                if ($prog) {
                    $lblStage.Text = $prog
                }

                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 100
            }

            # Drain any remaining bytes after exit
            $finalOut = $outReader.ReadToEnd()
            if ($finalOut) {
                $cleanFinalOut = [regex]::Replace($finalOut, "\x1b\[[0-9;]*[a-zA-Z]", "")
                $cleanFinalOut = [regex]::Replace($cleanFinalOut, "\r\n|\r|\n", "`r`n")
                $txtOutput.AppendText($cleanFinalOut)
                foreach ($line in ($cleanFinalOut -split "`r?`n")) {
                    if ($line -match 'CRITICAL|Error Code|Exception|Error encountered|FAILED') {
                        $script:lastGlazierError = $line.Trim()
                    }
                }
            }
            $finalErr = $errReader.ReadToEnd()
            if ($finalErr) {
                $cleanFinalErr = [regex]::Replace($finalErr, "\x1b\[[0-9;]*[a-zA-Z]", "")
                $cleanFinalErr = [regex]::Replace($cleanFinalErr, "\r\n|\r|\n", "`r`n")
                $txtOutput.AppendText($cleanFinalErr)
                foreach ($line in ($cleanFinalErr -split "`r?`n")) {
                    if ($line -match 'CRITICAL|Error Code|Exception|Error encountered|FAILED') {
                        $script:lastGlazierError = $line.Trim()
                    }
                }
            }
            if ($chkAutoScroll.Checked) {
                [void][Win32WindowHelper]::SendMessage($txtOutput.Handle, 0x0115, [IntPtr]7, [IntPtr]::Zero)
            }
        } finally {
            $outReader.Dispose()
            $outStream.Dispose()
            $errReader.Dispose()
            $errStream.Dispose()
        }

        if ($proc.ExitCode -eq 0) {
            $panelHeader.BackColor = [System.Drawing.Color]::FromArgb(220, 252, 231)
            $lblBadge.Text = "[OK]"
            $lblBadge.BackColor = [System.Drawing.Color]::FromArgb(22, 163, 74)
            $lblBadge.ForeColor = [System.Drawing.Color]::White
            $lblTitle.Text = "Stage Complete - Rebooting..."
            $lblStage.Text = "Glazier tasks completed successfully. Rebooting system..."
            $progressPulse.Visible = $false
            $progressFill.Location = New-Object System.Drawing.Point(0, 0)
            $progressFill.Size = New-Object System.Drawing.Size($trackW, $trackH)
            $progressFill.BackColor = [System.Drawing.Color]::FromArgb(22, 163, 74)

            for ($sec = 0; $sec -lt 30; $sec++) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 100
            }
            if ($bgForm -and -not $bgForm.IsDisposed) {
                try { $bgForm.Close(); $bgForm.Dispose() } catch {}
            }
            $bgForm = $null
            if ($form -and -not $form.IsDisposed) {
                try { $form.Close(); $form.Dispose() } catch {}
            }
            $form = $null
            try { $script:glazierMutex.ReleaseMutex() } catch {}
            try { [void][Win32WindowHelper]::SetThreadExecutionState(0x80000000) } catch {}
            [Environment]::Exit(0)
        } else {
            $panelHeader.BackColor = [System.Drawing.Color]::FromArgb(254, 226, 226)
            $lblBadge.Text = "[!]"
            $lblBadge.BackColor = [System.Drawing.Color]::FromArgb(220, 38, 38)
            $lblBadge.ForeColor = [System.Drawing.Color]::White
            $lblTitle.Text = "DEPLOYMENT FAILED (Exit Code: $($proc.ExitCode)) - Please Photograph This Screen"
            if ($script:lastGlazierError) {
                $lblStage.Text = "$($script:lastGlazierError) | Take a photo of this screen and send to IT Support."
            } else {
                $lblStage.Text = "An error occurred during deployment. Take a photo of this screen and send to IT Support."
            }
            $progressPulse.Visible = $false
            $progressFill.Location = New-Object System.Drawing.Point(0, 0)
            $progressFill.Size = New-Object System.Drawing.Size($trackW, $trackH)
            $progressFill.BackColor = [System.Drawing.Color]::FromArgb(220, 38, 38)
            $btnSaveLogs.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
            $btnReboot.Visible = $true
            [void][Win32WindowHelper]::SendMessage($txtOutput.Handle, 0x0115, [IntPtr]7, [IntPtr]::Zero)

            # Keep window open until technician closes or reboots
            while (-not $form.IsDisposed) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 100
            }
            if ($bgForm -and -not $bgForm.IsDisposed) {
                try { $bgForm.Close(); $bgForm.Dispose() } catch {}
            }
            $bgForm = $null
            try { $script:glazierMutex.ReleaseMutex() } catch {}
            try { [void][Win32WindowHelper]::SetThreadExecutionState(0x80000000) } catch {}
        }
    } catch {
        if ($bgForm -and -not $bgForm.IsDisposed) {
            try { $bgForm.Close(); $bgForm.Dispose() } catch {}
        }
        $bgForm = $null
        if ($form -and -not $form.IsDisposed) {
            try { $form.Close(); $form.Dispose() } catch {}
        }
        $form = $null

        try {
            $errDetails = @(
                "================================================================================",
                "GLAZIER DEPLOYMENT GUI RUNTIME EXCEPTION - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
                "================================================================================",
                ($_ | Out-String),
                $_.InvocationInfo.PositionMessage
            ) -join "`r`n"
            Set-Content -Path "$env:TEMP\glazier_gui_error.log" -Value $errDetails -Encoding UTF8 -Force
        } catch {}

        try {
            if ($script:glazierMutex) {
                $script:glazierMutex.ReleaseMutex()
            }
        } catch {}

        try {
            if ($consoleHwnd -ne [IntPtr]::Zero) {
                [void][Win32WindowHelper]::ShowWindow($consoleHwnd, 9) # SW_RESTORE
                Start-Sleep -Milliseconds 50
                [void][Win32WindowHelper]::ShowWindow($consoleHwnd, 3) # SW_MAXIMIZE
            }
            [Win32WindowHelper]::DisableQuickEdit()
        } catch {}

        # Ensure wake lock is active during fallback CLI execution
        try {
            [void][Win32WindowHelper]::SetThreadExecutionState(0x80000003)
        } catch {}

        Write-Host "Warning: Glazier Deployment GUI error: $_" -ForegroundColor Yellow
        # Fallback to direct CLI execution if GUI threw
        $env:PYTHONUNBUFFERED = "1"
        $pyArgs = @($GlazierScript, "--config_server=$ConfigServer", "--resource_path=$ResourcePath", "--glazier_spec_os=$GlazierSpecOS", "--preserve_tasks=true")
        if (-not [string]::IsNullOrWhiteSpace($ConfigRootPath)) {
            $pyArgs += "--config_root_path=$ConfigRootPath"
        }
        & $PythonExe $pyArgs
        try { [void][Win32WindowHelper]::SetThreadExecutionState(0x80000000) } catch {}
    }
    }
}

# Only show GUI if $glazier_spec_os wasn't explicitly passed via CLI and no active task list exists
$hasPendingTasks = (Test-Path "C:\glazier_cache\task_list.yaml") -or (Test-Path "C:\task_list.yaml") -or (Test-Path "X:\task_list.yaml")
if ([string]::IsNullOrWhiteSpace($glazier_spec_os) -and -not $hasPendingTasks) {
    try {
        $initConsoleHwnd = [Win32WindowHelper]::GetConsoleWindow()
        if ($initConsoleHwnd -ne [IntPtr]::Zero) {
            [void][Win32WindowHelper]::ShowWindow($initConsoleHwnd, 6) # SW_MINIMIZE
        }
    } catch {}
    $menuData = Get-GlazierProfiles -BaseUrl $config_server
    $rawSelection = @(Show-GlazierProfileGUI -MenuData $menuData)
    $glazier_spec_os = ($rawSelection | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1).Trim()
}
if ([string]::IsNullOrWhiteSpace($glazier_spec_os)) {
    $glazier_spec_os = "windows-stable"
}

Write-Output "Starting Glazier imaging process with profile: $glazier_spec_os..."

Start-GlazierDeploymentGUI -ConfigServer $config_server -GlazierSpecOS $glazier_spec_os
