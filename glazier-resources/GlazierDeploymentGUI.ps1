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

    # Check friendly hints from task body or current log chunk
    $desc = $null
    $targetText = if ($CurrentLogChunk) { "$body`n$CurrentLogChunk" } else { $body }

    if ($targetText -match 'Start-OSDCloud') {
        $desc = "Installing Windows OS image and hardware drivers (OSDCloud)..."
    } elseif ($targetText -match 'bcdboot') {
        $desc = "Configuring Windows UEFI Boot Manager..."
    } elseif ($targetText -match 'install_latest_cu\.py|UpdateMSU|KB\d+') {
        $desc = "Downloading and installing latest Windows Cumulative Updates..."
    } elseif ($targetText -match 'Invoke-OSDSpecialize|unattend\.xml') {
        $desc = "Applying Windows unattend specialization config..."
    } elseif ($targetText -match 'odt_installer|setup\.exe\s+/configure|Office365') {
        $desc = "Installing Microsoft Office 365..."
    } elseif ($targetText -match 'GoogleChromeStandaloneEnterprise') {
        $desc = "Installing Google Chrome Enterprise..."
    } elseif ($targetText -match 'EndpointVerification') {
        $desc = "Installing Google Endpoint Verification..."
    } elseif ($targetText -match 'gcpwstandaloneenterprise') {
        $desc = "Installing Google Credential Provider for Windows (GCPW)..."
    } elseif ($targetText -match 'mgmt-installer') {
        $desc = "Installing Enterprise Management Agent..."
    } elseif ($targetText -match 'Install-WindowsUpdate') {
        $desc = "Checking and installing Windows and driver updates..."
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
        return "Step $currentStepNum of $($script:totalPhaseTasks): $desc"
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

    # Ensure core fonts are loaded into live GDI session
    $fontsDir = "$env:SystemRoot\Fonts"
    $fontFiles = @("segoeui.ttf", "segoeuib.ttf", "segoeuii.ttf", "seguisb.ttf", "consola.ttf", "consolab.ttf")
    foreach ($ff in $fontFiles) {
        $fp = "$fontsDir\$ff"
        if (Test-Path $fp) {
            [void][Win32WindowHelper]::AddFontResource($fp)
        }
    }

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
        $form.TopMost = $true
        $form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
        $form.KeyPreview = $true

        # Keyboard shortcut (F12 or Ctrl+T) to open debug shell at any point
        $openShellAction = {
            $form.TopMost = $false
            Start-Process -FilePath "cmd.exe" -ArgumentList '/c start "Glazier Debug Shell" PowerShell.exe -NoProfile -NoLogo -NoExit'
        }

        $form.Add_KeyDown({
            if ($_.KeyCode -eq [System.Windows.Forms.Keys]::F12 -or ($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::T)) {
                & $openShellAction
            }
        })

        # Header Panel
        $panelHeader = New-Object System.Windows.Forms.Panel
        $panelHeader.Location = New-Object System.Drawing.Point(20, 16)
        $panelHeader.Size = New-Object System.Drawing.Size($formW - 40, 108)
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
        $lblTitle.Size = New-Object System.Drawing.Size($formW - 140, 28)
        $phaseHeader = if ($isWinPE) { "Installing Windows ($GlazierSpecOS) - Phase 1: WinPE Deployment" } else { "Finalizing Installation ($GlazierSpecOS) - Phase 2: Windows Setup" }
        $lblTitle.Text = $phaseHeader
        $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 20, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
        $panelHeader.Controls.Add($lblTitle)

        # Dynamic Stage Subtitle
        $lblStage = New-Object System.Windows.Forms.Label
        $lblStage.Location = New-Object System.Drawing.Point(82, 42)
        $lblStage.Size = New-Object System.Drawing.Size($formW - 140, 24)
        $lblStage.Text = "Starting Glazier provisioning engine..."
        $lblStage.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $lblStage.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
        $panelHeader.Controls.Add($lblStage)

        # Progress Bar
        $progressBar = New-Object System.Windows.Forms.ProgressBar
        $progressBar.Location = New-Object System.Drawing.Point(82, 72)
        $progressBar.Size = New-Object System.Drawing.Size($formW - 140, 22)
        $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        $progressBar.MarqueeAnimationSpeed = 25
        $panelHeader.Controls.Add($progressBar)

        # Terminal Header Panel
        $panelTermHeader = New-Object System.Windows.Forms.Panel
        $panelTermHeader.Location = New-Object System.Drawing.Point(20, 136)
        $panelTermHeader.Size = New-Object System.Drawing.Size($formW - 40, 36)
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
        $chkAutoScroll.Location = New-Object System.Drawing.Point($panelTermHeader.Width - 340, 6)
        $chkAutoScroll.Size = New-Object System.Drawing.Size(105, 24)
        $chkAutoScroll.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
        $chkAutoScroll.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $panelTermHeader.Controls.Add($chkAutoScroll)

        # Open Shell / Terminal button (always present and clickable)
        $btnTerminal = New-Object System.Windows.Forms.Button
        $btnTerminal.Text = "Open Shell"
        $btnTerminal.Location = New-Object System.Drawing.Point($panelTermHeader.Width - 225, 4)
        $btnTerminal.Size = New-Object System.Drawing.Size(105, 28)
        $btnTerminal.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnTerminal.BackColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
        $btnTerminal.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
        $btnTerminal.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $btnTerminal.Add_Click($openShellAction)
        $panelTermHeader.Controls.Add($btnTerminal)

        # Reboot PC button (hidden initially, shown on failure)
        $btnReboot = New-Object System.Windows.Forms.Button
        $btnReboot.Text = "Reboot PC"
        $btnReboot.Location = New-Object System.Drawing.Point($panelTermHeader.Width - 110, 4)
        $btnReboot.Size = New-Object System.Drawing.Size(100, 28)
        $btnReboot.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnReboot.BackColor = [System.Drawing.Color]::FromArgb(185, 28, 28)
        $btnReboot.ForeColor = [System.Drawing.Color]::White
        $btnReboot.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $btnReboot.Visible = $false
        $btnReboot.Add_Click({
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
        $panelTermBody.Size = New-Object System.Drawing.Size($formW - 40, $formH - 192)
        $panelTermBody.BackColor = [System.Drawing.Color]::FromArgb(12, 18, 30)
        $form.Controls.Add($panelTermBody)

        # Inner Terminal TextBox
        $txtOutput = New-Object System.Windows.Forms.TextBox
        $txtOutput.Location = New-Object System.Drawing.Point(10, 8)
        $txtOutput.Size = New-Object System.Drawing.Size($panelTermBody.Width - 20, $panelTermBody.Height - 16)
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
            $form.Activate()
            $form.BringToFront()
        })

        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()

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

        try {
            while (-not $proc.HasExited) {
                $hasNewText = $false

                $chunk = $outReader.ReadToEnd()
                if ($chunk) {
                    $txtOutput.AppendText($chunk)
                    $hasNewText = $true
                    foreach ($line in ($chunk -split "`r?`n")) {
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
                    $txtOutput.AppendText($errChunk)
                    $hasNewText = $true
                    foreach ($line in ($errChunk -split "`r?`n")) {
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
                $txtOutput.AppendText($finalOut)
                foreach ($line in ($finalOut -split "`r?`n")) {
                    if ($line -match 'CRITICAL|Error Code|Exception|Error encountered|FAILED') {
                        $script:lastGlazierError = $line.Trim()
                    }
                }
            }
            $finalErr = $errReader.ReadToEnd()
            if ($finalErr) {
                $txtOutput.AppendText($finalErr)
                foreach ($line in ($finalErr -split "`r?`n")) {
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
            $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
            $progressBar.Value = 100

            for ($sec = 0; $sec -lt 30; $sec++) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 100
            }
            $form.Close()
            $form.Dispose()
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
            $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
            $progressBar.Value = 100
            $btnReboot.Visible = $true
            [void][Win32WindowHelper]::SendMessage($txtOutput.Handle, 0x0115, [IntPtr]7, [IntPtr]::Zero)

            # Keep window open until technician closes or reboots
            while (-not $form.IsDisposed) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 100
            }
        }
    } catch {
        Write-Host "Warning: Glazier Deployment GUI error: $_" -ForegroundColor Yellow
        # Fallback to direct CLI execution if GUI threw
        $env:PYTHONUNBUFFERED = "1"
        $pyArgs = @($GlazierScript, "--config_server=$ConfigServer", "--resource_path=$ResourcePath", "--glazier_spec_os=$GlazierSpecOS", "--preserve_tasks=true")
        if (-not [string]::IsNullOrWhiteSpace($ConfigRootPath)) {
            $pyArgs += "--config_root_path=$ConfigRootPath"
        }
        & $PythonExe $pyArgs
    }
}
