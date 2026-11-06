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
"@

if (-not ('Win32WindowHelper' -as [type])) {
    Add-Type -TypeDefinition $win32HelperTypeDef -ErrorAction SilentlyContinue
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
        $script:lastGlazierError = ""
        $script:subTaskPct = 0
        $CurrentLogChunk = ""
    }

    # Check for sub-task percentage in CurrentLogChunk (e.g. "45%", "14.2%", "(40%)", "[=== 35.0% ===]")
    $curlDesc = $null
    if ($CurrentLogChunk -match '(?:execute\.py:\d+\]|\s)\s*(\d{1,3})\s+([0-9.]+[kKMGT]i?B?)\s+\d+\s+([0-9.]+[kKMGT]i?B?|0)\s+.*?\s+([0-9.]+[kKMGT]i?B?(?:/s)?|0)\s*$') {
        try {
            $parsedCurlPct = [int]$matches[1]
            if ($parsedCurlPct -ge 0 -and $parsedCurlPct -le 100) {
                $script:subTaskPct = $parsedCurlPct
            }
            $tot = $matches[2]
            $rec = $matches[3]
            $spdRaw = $matches[4]
            $spd = if ($spdRaw -eq '0') { '0 KB/s' } elseif ($spdRaw -match '/s$') { $spdRaw } else { "$spdRaw/s" }
            $curlDesc = "Downloading Windows OS image ($($script:subTaskPct)% - $rec / $tot @ $spd)..."
        } catch {}
    } elseif ($CurrentLogChunk -match '(?<![0-9.])(\d{1,3}(?:\.\d+)?)\s*%') {
        try {
            $parsedSubPct = [double]$matches[1]
            if ($parsedSubPct -ge 0 -and $parsedSubPct -le 100) {
                $script:subTaskPct = [int]$parsedSubPct
            }
        } catch {}
    } elseif ($script:subTaskPct -ge 100 -and $CurrentLogChunk.Trim()) {
        # Reset sub-task percentage when previous sub-task completed and non-progress log arrives
        $script:subTaskPct = 0
    }

    # Calculate overall percentage across the phase strictly from main step
    $script:currentOverallPct = if ($script:totalPhaseTasks -gt 0) {
        [int][Math]::Min(98, [Math]::Max(6, [Math]::Round(($currentStepNum / [double]$script:totalPhaseTasks) * 100.0)))
    } else { 6 }

    # Check friendly hints from body first
    $desc = $null
    if ($curlDesc) {
        $desc = $curlDesc
    } elseif ($body -match 'Start-OSDCloud') {
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
            [void][Win32WindowHelper]::ShowWindow($consoleHwnd, 0) # SW_HIDE
        }
        Get-Process -Name cmd -ErrorAction SilentlyContinue | ForEach-Object {
            $h = $_.MainWindowHandle
            if ($h -ne [IntPtr]::Zero -and ($null -eq $form -or $h -ne $form.Handle) -and ($null -eq $bgForm -or $h -ne $bgForm.Handle)) {
                [void][Win32WindowHelper]::ShowWindow($h, 0) # SW_HIDE
            }
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
        $bottomClearance = [Math]::Max(220, [int]($screen.Height * 0.245)) # ~265px on 1080 (clears AO logo completely)
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
        $form.ControlBox = $false
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

                $fallbackSaveDir = if ($usbDrive) {
                    $usbDrive.RootDirectory.FullName
                } elseif (Test-Path "C:\glazier_cache") {
                    "C:\glazier_cache"
                } else {
                    "$rootDrive\"
                }
                $fallbackPath = Join-Path $fallbackSaveDir $defaultName

                $sfd = New-Object System.Windows.Forms.SaveFileDialog
                $sfd.Title = "Save Glazier Deployment Logs"
                $sfd.Filter = "ZIP Archive (*.zip)|*.zip|Combined Log File (*.log)|*.log|All Files (*.*)|*.*"
                $sfd.FileName = $defaultName
                $sfd.InitialDirectory = $initDir
                $sfd.AutoUpgradeEnabled = $false

                $savePath = $null
                try {
                    if ($sfd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                        $savePath = $sfd.FileName
                    }
                } catch {
                    $savePath = $fallbackPath
                }

                if ($savePath) {
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
                $form.TopMost = $isWinPE
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

        # Main Step Percentage Fill Bar with Aero Shimmer Pulse (14px)
        $trackW = $formW - 140
        $trackH = 14

        $progressTrack = New-Object System.Windows.Forms.Panel
        $progressTrack.Location = New-Object System.Drawing.Point(82, 68)
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

        # Sub-Task Progress Bar (6px, cyan/teal)
        $subProgressTrack = New-Object System.Windows.Forms.Panel
        $subProgressTrack.Location = New-Object System.Drawing.Point(82, 86)
        $subProgressTrack.Size = New-Object System.Drawing.Size($trackW, 6)
        $subProgressTrack.BackColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
        $subProgressTrack.BorderStyle = [System.Windows.Forms.BorderStyle]::None
        $panelHeader.Controls.Add($subProgressTrack)

        $subProgressFill = New-Object System.Windows.Forms.Panel
        $subProgressFill.Location = New-Object System.Drawing.Point(0, 0)
        $subProgressFill.Size = New-Object System.Drawing.Size(0, 6)
        $subProgressFill.BackColor = [System.Drawing.Color]::FromArgb(14, 165, 233)
        $subProgressTrack.Controls.Add($subProgressFill)

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
        $chkAutoScroll.Location = New-Object System.Drawing.Point(($panelTermHeader.Width - 340), 6)
        $chkAutoScroll.Size = New-Object System.Drawing.Size(100, 24)
        $chkAutoScroll.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
        $chkAutoScroll.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $panelTermHeader.Controls.Add($chkAutoScroll)

        # Open Shell / Terminal button (always present and clickable)
        $btnTerminal = New-Object System.Windows.Forms.Button
        $btnTerminal.Text = "Open Shell"
        $btnTerminal.Location = New-Object System.Drawing.Point(($panelTermHeader.Width - 230), 4)
        $btnTerminal.Size = New-Object System.Drawing.Size(105, 28)
        $btnTerminal.UseVisualStyleBackColor = $false
        $btnTerminal.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnTerminal.FlatAppearance.BorderSize = 1
        $btnTerminal.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
        $btnTerminal.BackColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
        $btnTerminal.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
        $btnTerminal.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $btnTerminal.Add_Click($openShellAction)
        $panelTermHeader.Controls.Add($btnTerminal)

        # Save Logs button (always present, highlighted on failure)
        $btnSaveLogs = New-Object System.Windows.Forms.Button
        $btnSaveLogs.Text = "Save Logs..."
        $btnSaveLogs.Location = New-Object System.Drawing.Point(($panelTermHeader.Width - 115), 4)
        $btnSaveLogs.Size = New-Object System.Drawing.Size(105, 28)
        $btnSaveLogs.UseVisualStyleBackColor = $false
        $btnSaveLogs.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnSaveLogs.FlatAppearance.BorderSize = 1
        $btnSaveLogs.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
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
        $btnReboot.UseVisualStyleBackColor = $false
        $btnReboot.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnReboot.FlatAppearance.BorderSize = 1
        $btnReboot.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
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
        $txtOutput.Size = New-Object System.Drawing.Size(($panelTermBody.Width - 12), ($panelTermBody.Height - 16))
        $txtOutput.BorderStyle = [System.Windows.Forms.BorderStyle]::None
        $txtOutput.BackColor = [System.Drawing.Color]::FromArgb(12, 18, 30)
        $txtOutput.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
        $txtOutput.Font = New-Object System.Drawing.Font("Consolas", 13, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $txtOutput.Multiline = $true
        $txtOutput.ReadOnly = $true
        $txtOutput.HideSelection = $true
        $txtOutput.WordWrap = $true
        $txtOutput.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
        $panelTermBody.Controls.Add($txtOutput)

        $form.Add_Shown({
            try {
                if ($consoleHwnd -ne [IntPtr]::Zero) {
                    [void][Win32WindowHelper]::ShowWindow($consoleHwnd, 0) # SW_HIDE
                }
                Get-Process -Name cmd -ErrorAction SilentlyContinue | ForEach-Object {
                    $h = $_.MainWindowHandle
                    if ($h -ne [IntPtr]::Zero -and ($null -eq $form -or $h -ne $form.Handle) -and ($null -eq $bgForm -or $h -ne $bgForm.Handle)) {
                        [void][Win32WindowHelper]::ShowWindow($h, 0) # SW_HIDE
                    }
                }
            } catch {}
            [void][Win32WindowHelper]::ShowWindow($form.Handle, 5) # SW_SHOW
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
                        $form.TopMost = $isWinPE
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
        $script:rebootTriggered = $false
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

                # Update sub-task progress bar width
                if ($script:subTaskPct -gt 0) {
                    $subProgressFill.Width = [Math]::Min($trackW, [Math]::Max(4, [int][Math]::Round($trackW * ($script:subTaskPct / 100.0))))
                } else {
                    $subProgressFill.Width = 0
                }

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
                        if ($line -match 'Leaving WinPE|Rebooting with a timeout of|Shutting down with a timeout of|shutdown\.exe -r') {
                            $script:rebootTriggered = $true
                        }
                        if ($line -match 'CRITICAL|IMAGING PROCESS FAILED|Error Code|GlazierError|ActionError|ConfigRunnerError|ConfigBuilderError|Unhandled exception|Traceback') {
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
                        if ($line -match 'Leaving WinPE|Rebooting with a timeout of|Shutting down with a timeout of|shutdown\.exe -r') {
                            $script:rebootTriggered = $true
                        }
                        if ($line -match 'CRITICAL|IMAGING PROCESS FAILED|Error Code|GlazierError|ActionError|ConfigRunnerError|ConfigBuilderError|Unhandled exception|Traceback') {
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
                    if ($line -match 'Leaving WinPE|Rebooting with a timeout of|Shutting down with a timeout of|shutdown\.exe -r') {
                        $script:rebootTriggered = $true
                    }
                    if ($line -match 'CRITICAL|IMAGING PROCESS FAILED|Error Code|GlazierError|ActionError|ConfigRunnerError|ConfigBuilderError|Unhandled exception|Traceback') {
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
                    if ($line -match 'Leaving WinPE|Rebooting with a timeout of|Shutting down with a timeout of|shutdown\.exe -r') {
                        $script:rebootTriggered = $true
                    }
                    if ($line -match 'CRITICAL|IMAGING PROCESS FAILED|Error Code|GlazierError|ActionError|ConfigRunnerError|ConfigBuilderError|Unhandled exception|Traceback') {
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

        $isSuccess = ($proc.ExitCode -eq 0) -or ($script:rebootTriggered -and ($txtOutput.Text -notmatch 'IMAGING PROCESS FAILED'))
        if ($isSuccess) {
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
            $subProgressFill.Width = 0

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
            if ($isWinPE -and (Test-Path "C:\glazier_cache\task_list.yaml")) {
                try { & "$env:SystemRoot\System32\wpeutil.exe" reboot } catch {}
            }
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
            $subProgressFill.Width = 0
            $btnSaveLogs.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)

            # Shift toolbar buttons left to accommodate $btnReboot on far right
            $chkAutoScroll.Location = New-Object System.Drawing.Point(($panelTermHeader.Width - 445), 6)
            $btnTerminal.Location = New-Object System.Drawing.Point(($panelTermHeader.Width - 335), 4)
            $btnSaveLogs.Location = New-Object System.Drawing.Point(($panelTermHeader.Width - 220), 4)
            $btnReboot.Location = New-Object System.Drawing.Point(($panelTermHeader.Width - 105), 4)
            $btnReboot.Visible = $true
            [void][Win32WindowHelper]::SendMessage($txtOutput.Handle, 0x0115, [IntPtr]7, [IntPtr]::Zero)

            # Keep window open until technician closes or reboots
            while (-not $form.IsDisposed) {
                try { [void][Win32WindowHelper]::SetThreadExecutionState(0x80000003) } catch {}
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
                [void][Win32WindowHelper]::ShowWindow($consoleHwnd, 5) # SW_SHOW
                [void][Win32WindowHelper]::ShowWindow($consoleHwnd, 9) # SW_RESTORE
                Start-Sleep -Milliseconds 50
                [void][Win32WindowHelper]::ShowWindow($consoleHwnd, 3) # SW_MAXIMIZE
            }
            Get-Process -Name cmd -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.MainWindowHandle -ne [IntPtr]::Zero) {
                    [void][Win32WindowHelper]::ShowWindow($_.MainWindowHandle, 5) # SW_SHOW
                    [void][Win32WindowHelper]::ShowWindow($_.MainWindowHandle, 9) # SW_RESTORE
                }
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
