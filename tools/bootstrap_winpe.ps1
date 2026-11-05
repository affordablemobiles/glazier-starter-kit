Param(
    [string]$config_server = "",
    [string]$storage_upload_path = "",
    [string]$storage_boot_upload_path = "",
    [string]$use_winre = "true",
    [string]$refresh_winre = "true",
    [string]$winre_os_name = "Windows 11 24H2 amd64"
)

# Real-time console flushed logger
function Write-Log {
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [string]$Color = "Cyan"
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$ts] $Message" -ForegroundColor $Color
    [Console]::Out.Flush()
}

function Invoke-DownloadWithRetry {
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [Parameter(Mandatory = $true)]
        [string]$OutFile,
        [int]$MaxAttempts = 5,
        [string]$ExpectedMD5 = "",
        [switch]$VerifyArchive
    )

    $attempt = 1
    while ($attempt -le $MaxAttempts) {
        Write-Log "Downloading $Url -> $OutFile (Attempt $attempt of $MaxAttempts)..." -Color Cyan
        
        if (Test-Path $OutFile) {
            Remove-Item -Path $OutFile -Force -ErrorAction SilentlyContinue
        }

        # Use curl with built-in retries, connection timeouts, and resume support
        & curl.exe -fL --retry 5 --retry-delay 5 --retry-all-errors --connect-timeout 30 -o "$OutFile" "$Url"
        $curlExit = $LASTEXITCODE

        if ($curlExit -ne 0 -or -not (Test-Path $OutFile) -or ((Get-Item $OutFile).Length -eq 0)) {
            Write-Log "Warning: curl.exe failed with exit code $curlExit on attempt $attempt." -Color Yellow
            $attempt++
            Start-Sleep -Seconds (5 * $attempt)
            continue
        }

        # Optional MD5 Hash Check
        if ($ExpectedMD5 -ne "") {
            $actualHash = (Get-FileHash -Path $OutFile -Algorithm MD5).Hash
            if ($actualHash -ne $ExpectedMD5) {
                Write-Log "Warning: MD5 mismatch (Expected: $ExpectedMD5, Got: $actualHash). Retrying..." -Color Yellow
                $attempt++
                Start-Sleep -Seconds 5
                continue
            }
            Write-Log "MD5 hash verified: $actualHash" -Color Green
        }

        # Optional 7-Zip Archive Integrity Check (.cab, .esd, .zip, .wim)
        if ($VerifyArchive -and (Test-Path 'C:\Program Files\7-Zip\7z.exe')) {
            Write-Log "Verifying archive integrity for $OutFile..." -Color Cyan
            & 'C:\Program Files\7-Zip\7z.exe' t "$OutFile" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Log "Warning: Archive integrity check (7z t) failed for $OutFile (corrupted/truncated download). Retrying..." -Color Yellow
                $attempt++
                Start-Sleep -Seconds 5
                continue
            }
            Write-Log "Archive integrity verified successfully." -Color Green
        }

        Write-Log "Successfully downloaded $OutFile ($([Math]::Round((Get-Item $OutFile).Length / 1MB, 2)) MB)" -Color Green
        return
    }

    Write-Log "CRITICAL: Failed to download a valid copy of $Url after $MaxAttempts attempts." -Color Red
    exit 1
}

Write-Log "Starting Glazier WinPE Bootstrap script" -Color Green

# Global non-interactive preferences to avoid silent stdin blocking
$ConfirmPreference = 'None'
$ProgressPreference = 'SilentlyContinue'

# Ensure TLS 1.2 / TLS 1.3 are enabled for all web requests (PSGallery, Chocolatey, Python, curl.se)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# Disable IE Advanced Security, as it breaks OSDCloud calls:
$IEESC = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}"
Set-ItemProperty -Path $IEESC -Name IsInstalled -Value 0
Stop-Process -Name Explorer

# Enable IE Explorer from Cloud Build
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Internet Explorer\Main" -Name "DisableFirstRunCustomize" -Value 2 -ErrorAction SilentlyContinue

# $scriptPath is the absolute path where this script is executing from
$scriptPath = split-path -parent $MyInvocation.MyCommand.Definition

if ((Test-Path "$scriptPath\autobuild.ps1") -eq $False) {
    Write-Log "$scriptPath\autobuild.ps1 not found" -Color Red
    exit(1)
}

# Make sure glazier-resources is available to copy
if ((Test-Path "$scriptPath\..\glazier-resources\") -eq $False) {
    Write-Log "$scriptPath\..\glazier-resources\ not found" -Color Red
    exit(1)
}

# if $scriptPath\autobuild.json exists, get a value for $config_root_path from it. Note tools\autobuild.json is in the .gitignore file.
$abjson = "$scriptPath\autobuild.json"
if ((Test-Path $abjson) -eq $True) {
    $json = Get-Content $abjson | Out-String | ConvertFrom-Json
    $config_server = $json.config_server
# get a value for $config_server from the CLI flags. If it's empty, exit 1 (bail)
} else {
    if ($config_server -eq "") {
        Write-Log "config_server cannot be an empty string" -Color Red
        exit(1)
    }
}

function isURIWeb($address) {
	$uri = $address -as [System.URI]
	$uri.AbsoluteURI -ne $null -and $uri.Scheme -match '[http|https]'
}

# ensure $config_server is a valid url. This avoids avoid frustration, trust me.
if (!(isURIWeb($config_server))) {
    Write-Log "$config_server is not a valid url" -Color Red
    exit(1)
}

# $pyVersion is the Python version that will be downloaded
$pyVersion = "3.12.2"
# $pythonSavePath is place where the Python installer will be downloaded on disk
$downloadDir = "$env:TEMP\glazier_build"
if (!(Test-Path $downloadDir)) {
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
}
$pythonSavePath = "$downloadDir\python-$pyVersion-amd64.exe"
# $pythonInstallHash is the hash used to verify the Python installer download
$pythonInstallHash = "44abfae489d87cc005d50a9267b5d58d"
# $pyEXEUrl is the url where the Python installer will be obtained
$pyEXEUrl = "https://www.python.org/ftp/python/$pyVersion/python-$pyVersion-amd64.exe"

# Install Chocolatey. Borrowed from https://tseknet.com/blog/chocolatey.
Write-Log "Installing Chocolatey package manager..."
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Force
Invoke-WebRequest -Uri https://chocolatey.org/install.ps1 -UseBasicParsing | Invoke-Expression

# Install Windows ADK & 7-Zip via Chocolatey
Write-Log "Installing Windows ADK..."
choco install windows-adk -y --no-progress
Write-Log "Installing Windows ADK WinPE Add-on..."
choco install windows-adk-winpe -y --no-progress
Write-Log "Installing 7-Zip..."
choco install 7zip -y --no-progress

# Install NuGet Package Provider explicitly with -Confirm:$false to avoid silent prompt
Write-Log "Installing NuGet PackageProvider (non-interactive)..."
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Confirm:$false | Out-Null

# Configure PowerShell Gallery repository as trusted for non-interactive builds
Write-Log "Setting PSGallery repository to Trusted..."
Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction SilentlyContinue

# Install OSD and MSCatalog PowerShell Modules (latest available)
Write-Log "Installing OSD module from PowerShell Gallery..."
Install-Module -Name OSD -Force -AllowClobber -Confirm:$false -SkipPublisherCheck -Scope AllUsers
Write-Log "Installing MSCatalog module from PowerShell Gallery..."
Install-Module -Name MSCatalog -Force -AllowClobber -Confirm:$false -SkipPublisherCheck -Scope AllUsers

# Import the modules
Write-Log "Importing OSD & MSCatalog modules..."
Import-Module OSD -Force
Import-Module MSCatalog -Force -ErrorAction SilentlyContinue

$enableWinRE = ($use_winre -match '^(true|1|yes)$')
$forceRefreshWinRE = ($refresh_winre -match '^(true|1|yes)$')

# Always ensure WirelessConnect.exe is downloaded whenever WinRE is enabled
$wirelessConnectUrl = "https://github.com/okieselbach/Helpers/raw/master/WirelessConnect/WirelessConnect/bin/Release/WirelessConnect.exe"
$wirelessConnectExe = "$downloadDir\WirelessConnect.exe"
if ($enableWinRE -and (-not (Test-Path $wirelessConnectExe))) {
    Write-Log "Downloading WirelessConnect.exe for WinPE Wi-Fi GUI..."
    Invoke-DownloadWithRetry -Url $wirelessConnectUrl -OutFile $wirelessConnectExe
}

# If WinRE is requested, prepare and service WinRE.wim FIRST, then place it in the ADK directory
# so New-OSDCloudTemplate builds directly on top of WinRE (preserving both Wi-Fi and all ADK packages)
if ($enableWinRE) {
    Write-Log "=== WinRE Mode Requested: Preparing Windows Recovery Environment with Wi-Fi ===" -Color Magenta
    $cachedWinRE = "$downloadDir\cached_winre.wim"
    $hasCachedGCS = $false
    $extractedWinRE = "$downloadDir\winre_extract\Winre.wim"

    if ($storage_boot_upload_path -ne "" -and (-not $forceRefreshWinRE)) {
        Write-Log "Checking GCS for cached base WinRE image at $storage_boot_upload_path/base/winre.wim..."
        & gsutil -q stat "$storage_boot_upload_path/base/winre.wim"
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Found cached base WinRE in GCS. Downloading..."
            gsutil -m cp "$storage_boot_upload_path/base/winre.wim" $cachedWinRE
            if (Test-Path $cachedWinRE) {
                $hasCachedGCS = $true
                $extractedWinRE = $cachedWinRE
            }
        }
    }

    if ($hasCachedGCS) {
        Write-Log "Using cached WinRE from GCS." -Color Green
    } else {
        Write-Log "Resolving $winre_os_name ESD download URL from Microsoft OSD catalog..."
        $osMediaDir = "$downloadDir\OS"
        if (-not (Test-Path $osMediaDir)) {
            New-Item -ItemType Directory -Path $osMediaDir -Force | Out-Null
        }
        
        $fu = Get-FeatureUpdate -OSName $winre_os_name -OSLanguage 'en-us' -OSActivation 'Retail'
        if (-not $fu) {
            Write-Log "Failed to resolve Feature Update for $winre_os_name from OSD catalog" -Color Red
            exit 1
        }
        
        $esdFile = "$osMediaDir\$($fu.FileName)"
        if (-not (Test-Path $esdFile)) {
            Write-Log "Downloading $($fu.FileName) ($($fu.Build)) from Microsoft CDN..." -Color Yellow
            Invoke-DownloadWithRetry -Url $fu.Url -OutFile $esdFile -VerifyArchive
        } else {
            Write-Log "ESD already exists at $esdFile"
        }

        Write-Log "Extracting Winre.wim from ESD Index 1 using 7-Zip..."
        $extractDir = "$downloadDir\winre_extract"
        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
        & 'C:\Program Files\7-Zip\7z.exe' e "$esdFile" "1\Windows\System32\Recovery\Winre.wim" -o"$extractDir" -y
        if (-not (Test-Path "$extractDir\Winre.wim")) {
            & 'C:\Program Files\7-Zip\7z.exe' e "$esdFile" "6\Windows\System32\Recovery\Winre.wim" -o"$extractDir" -y
        }
        $extractedWinRE = (Get-ChildItem -Path $extractDir -Filter 'Winre.wim' -Recurse | Select-Object -First 1).FullName

        if (-not $extractedWinRE -or -not (Test-Path $extractedWinRE)) {
            Write-Log "Failed to extract Winre.wim from ESD" -Color Red
            exit 1
        }
        Write-Log "Extracted Winre.wim ($([Math]::Round((Get-Item $extractedWinRE).Length / 1MB)) MB)" -Color Green

        Write-Log "Extracting Windows 11 client WLAN/MDM DLLs from ESD Index 1..."
        $dllExtractDir = "$downloadDir\wlan_dlls"
        New-Item -ItemType Directory -Path $dllExtractDir -Force | Out-Null
        & 'C:\Program Files\7-Zip\7z.exe' e "$esdFile" "1\Windows\System32\dmcmnutils.dll" "1\Windows\System32\mdmpostprocessevaluator.dll" "1\Windows\System32\mdmregistration.dll" -o"$dllExtractDir" -y
        if (-not (Test-Path "$dllExtractDir\dmcmnutils.dll")) {
            & 'C:\Program Files\7-Zip\7z.exe' e "$esdFile" "6\Windows\System32\dmcmnutils.dll" "6\Windows\System32\mdmpostprocessevaluator.dll" "6\Windows\System32\mdmregistration.dll" -o"$dllExtractDir" -y
        }
        Write-Log "Extracted client WLAN DLLs: $(Get-ChildItem $dllExtractDir | Select-Object -ExpandProperty Name)" -Color Green

        Write-Log "Querying Microsoft Update Catalog for Safe OS Dynamic Updates..."
        $updatePkg = $null
        $catalogRetries = 3
        for ($cAttempt = 1; $cAttempt -le $catalogRetries; $cAttempt++) {
            try {
                $safeOSUpdate = Get-MSCatalogUpdate -Search "Safe OS Dynamic Update Windows 11 24H2" -ErrorAction Stop |
                    Where-Object { $_.Title -match 'x64-based' -and $_.Title -match 'Windows 11' } | Select-Object -First 1
                if ($safeOSUpdate) {
                    Write-Log "Found Safe OS Dynamic Update: $($safeOSUpdate.Title)" -Color Green
                    $updateDir = "$downloadDir\winre_update"
                    New-Item -ItemType Directory -Path $updateDir -Force | Out-Null
                    Save-MSCatalogUpdate -Update $safeOSUpdate -Destination $updateDir -ErrorAction Stop
                    $updatePkg = (Get-ChildItem -Path $updateDir -Include *.cab,*.msu -Recurse | Select-Object -First 1).FullName
                } else {
                    Write-Log "No newer Safe OS Dynamic Update found, using release WinRE."
                }
                break
            } catch {
                Write-Log "Warning: Microsoft Catalog query/download attempt $cAttempt of $catalogRetries failed: $_" -Color Yellow
                if ($cAttempt -lt $catalogRetries) {
                    Start-Sleep -Seconds (5 * $cAttempt)
                }
            }
        }

        # Mount base WinRE to slipstream updates, client WLAN DLLs, and WirelessConnect.exe
        Write-Log "Servicing base Winre.wim (updates, client WLAN DLLs, and Wi-Fi GUI)..."
        $mountDir = "$downloadDir\winre_mount"
        New-Item -ItemType Directory -Path $mountDir -Force | Out-Null
        Mount-WindowsImage -ImagePath $extractedWinRE -Index 1 -Path $mountDir

        if ($updatePkg) {
            Write-Log "Adding Safe OS update package..."
            Add-WindowsPackage -Path $mountDir -PackagePath $updatePkg
        }

        if (Test-Path "$dllExtractDir") {
            Write-Log "Injecting client WLAN DLLs into base WinRE..."
            robocopy "$dllExtractDir" "$mountDir\Windows\System32" dmcmnutils.dll mdmpostprocessevaluator.dll mdmregistration.dll /ndl /njh /njs /b /np | Out-Null
        }

        if (Test-Path "$wirelessConnectExe") {
            Write-Log "Injecting WirelessConnect.exe into base WinRE..."
            Copy-Item -Path "$wirelessConnectExe" -Destination "$mountDir\Windows\WirelessConnect.exe" -Force
            Copy-Item -Path "$wirelessConnectExe" -Destination "$mountDir\Windows\System32\WirelessConnect.exe" -Force
        }

        Write-Log "Performing DISM component cleanup on base WinRE..."
        DISM /Image:"$mountDir" /Cleanup-Image /StartComponentCleanup
        Write-Log "Dismounting and saving serviced base WinRE..."
        Dismount-WindowsImage -Path $mountDir -Save
        Remove-Item -Path $mountDir -Force -Recurse -ErrorAction SilentlyContinue
        Write-Log "Base WinRE servicing completed." -Color Green

        if ($storage_boot_upload_path -ne "") {
            Write-Log "Uploading fresh base WinRE to $storage_boot_upload_path/base/winre.wim for future builds..."
            gsutil -m cp "$extractedWinRE" "$storage_boot_upload_path/base/winre.wim"
        }
    }

    # Replace ADK winpe.wim with our serviced WinRE image so New-OSDCloudTemplate layers on top of it
    $adkWinPEPaths = @(
        "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\AMD64\en-us\winpe.wim",
        "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\AMD64\winpe.wim"
    )
    foreach ($adkP in $adkWinPEPaths) {
        if (Test-Path (Split-Path -Parent $adkP)) {
            Copy-Item -Path $extractedWinRE -Destination $adkP -Force
            & attrib.exe -r -s -h "$adkP"
            Write-Log "Replaced ADK WinPE source with serviced WinRE at $adkP" -Color Green
        }
    }
    # Reset any existing template so New-OSDCloudTemplate rebuilds fresh
    Remove-Item -Path "C:\ProgramData\OSDCloud" -Recurse -Force -ErrorAction SilentlyContinue
}

# Create OSDCloud template if not created yet.
if ((Get-OSDCloudTemplate) -eq "C:\ProgramData\OSDCloud") { 
    Write-Log "'New-OSDCloudTemplate -Verbose' already completed" -Color Green
} else {
    Write-Log "Running 'New-OSDCloudTemplate -Verbose' (mirroring ADK media and adding packages)..." -Color Yellow
    
    # Start background watcher to stream transcript lines live to stdout every 5 seconds
    $templateLogDir = "C:\ProgramData\OSDCloud\Logs\Template"
    if (-not (Test-Path $templateLogDir)) {
        New-Item -ItemType Directory -Path $templateLogDir -Force | Out-Null
    }
    
    $watcherJob = Start-Job -ScriptBlock {
        param($dir)
        $lastLine = 0
        $trackedFile = $null
        while ($true) {
            Start-Sleep -Seconds 5
            $latest = Get-ChildItem -Path $dir -Filter "*.log" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($latest) {
                if ($trackedFile -ne $latest.FullName) {
                    $trackedFile = $latest.FullName
                    $lastLine = 0
                }
                $lines = Get-Content -Path $trackedFile -ErrorAction SilentlyContinue
                if ($lines -and $lines.Count -gt $lastLine) {
                    for ($i = $lastLine; $i -lt $lines.Count; $i++) {
                        [Console]::WriteLine("  [ADK-Template] " + $lines[$i])
                    }
                    $lastLine = $lines.Count
                    [Console]::Out.Flush()
                }
            }
        }
    } -ArgumentList $templateLogDir

    try {
        New-OSDCloudTemplate -Verbose
    } finally {
        Stop-Job $watcherJob -ErrorAction SilentlyContinue
        Remove-Job $watcherJob -Force -ErrorAction SilentlyContinue
    }
    Write-Log "New-OSDCloudTemplate completed successfully." -Color Green
}

# Create OSDCloud workspace if not created yet (copies Media from template).
if ((Get-OSDCloudWorkspace) -eq "C:\OSDCloud") { 
    Write-Log "'New-OSDCloudWorkspace -WorkspacePath C:\OSDCloud' already completed" -Color Green
} else {
    Write-Log "Running 'New-OSDCloudWorkspace -WorkspacePath C:\OSDCloud'..." -Color Yellow
    New-OSDCloudWorkspace -WorkspacePath C:\OSDCloud
    Write-Log "OSDCloud workspace created successfully." -Color Green
}

Write-Log "Ensuring Python $pyVersion is downloaded and verified..."
Invoke-DownloadWithRetry -Url $pyEXEUrl -OutFile $pythonSavePath -ExpectedMD5 $pythonInstallHash

$intelWifiDir = "$downloadDir\drivers\IntelWiFi"
if ($enableWinRE) {
    Write-Log "Downloading Intel Wi-Fi Driver Pack (Wi-Fi 6/6E/7 / AX / BE) from Microsoft Update Catalog..." -Color Yellow
    $intelWifiCab = "$downloadDir\IntelWiFi.cab"
    $intelWifiUrl = "https://catalog.s.download.windowsupdate.com/d/msdownload/update/driver/drvs/2026/08/6be0cd42-ff38-4935-8303-c8a05b5d8537_504f637d63eec71ca35526881acfe2d672b2411c.cab"
    
    # Download and verify cabinet integrity before extracting
    Invoke-DownloadWithRetry -Url $intelWifiUrl -OutFile $intelWifiCab -VerifyArchive

    if (Test-Path "$intelWifiDir") {
        Remove-Item -Path "$intelWifiDir" -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path "$intelWifiDir" -Force | Out-Null
    
    & 'C:\Program Files\7-Zip\7z.exe' x "$intelWifiCab" -o"$intelWifiDir" -y | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Log "CRITICAL: Failed to extract Intel Wi-Fi drivers with 7-Zip (Exit code: $LASTEXITCODE)" -Color Red
        exit 1
    }
    Write-Log "Extracted Intel Wi-Fi drivers to $intelWifiDir" -Color Green
}

# Install OSDCloud driver packs (Dell Ethernet/Storage, IntelNet, USB, LenovoDock)
Write-Log "Injecting OSDCloud driver packs (Dell, IntelNet, USB, LenovoDock)..." -Color Yellow
$editParams = @{
    CloudDriver     = @('Dell', 'IntelNet', 'USB', 'LenovoDock')
    PSModuleInstall = @('MSCatalog')
}
if ($enableWinRE) {
    $editParams['WirelessConnect'] = $true
}
$wallpaperPath = "$scriptPath\wallpaper.jpg"
$tempLogoPng   = "$downloadDir\logo.png"
$convertedJpg  = "$downloadDir\logo_wallpaper.jpg"

if ($config_server -ne "") {
    $remoteLogoUrl = "$($config_server.TrimEnd('/'))/logo.png"
    Write-Log "Checking for custom logo at $remoteLogoUrl..." -Color Cyan
    & curl.exe -fsSL --retry 3 --retry-delay 3 --connect-timeout 15 -o "$tempLogoPng" "$remoteLogoUrl"
}

if ((-not (Test-Path $tempLogoPng) -or (Get-Item $tempLogoPng).Length -eq 0) -and $storage_boot_upload_path -ne "") {
    Write-Log "Checking GCS via gsutil for custom logo at $storage_boot_upload_path/logo.png..." -Color Cyan
    & gsutil -q cp "$storage_boot_upload_path/logo.png" "$tempLogoPng" 2>$null
}

if ((Test-Path $tempLogoPng) -and (Get-Item $tempLogoPng).Length -gt 0) {
    Write-Log "Converting downloaded logo.png to high-quality JPEG for WinPE/WinRE wallpaper..." -Color Green
    Add-Type -AssemblyName System.Drawing
    $img = [System.Drawing.Image]::FromFile($tempLogoPng)
    try {
        # Convert to 24-bit RGB Bitmap first (handles 8-bit indexed iPXE PNGs cleanly)
        $rgbBmp = New-Object System.Drawing.Bitmap($img.Width, $img.Height, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $g = [System.Drawing.Graphics]::FromImage($rgbBmp)
        try {
            $g.DrawImage($img, 0, 0, $img.Width, $img.Height)
        } finally {
            $g.Dispose()
        }
        try {
            $jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
                         Where-Object { $_.MimeType -eq 'image/jpeg' }
            $encoderParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
            $encoderParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
                [System.Drawing.Imaging.Encoder]::Quality, [long]100
            )
            $rgbBmp.Save($convertedJpg, $jpegCodec, $encoderParams)
            $wallpaperPath = $convertedJpg
        } finally {
            $rgbBmp.Dispose()
        }
    } finally {
        $img.Dispose()
    }
}

if (Test-Path $wallpaperPath) {
    Write-Log "Configuring wallpaper for WinPE at $wallpaperPath" -Color Green
    $editParams['Wallpaper'] = $wallpaperPath
} else {
    Write-Log "Wallpaper not available." -Color Yellow
}
Edit-OSDCloudWinPE @editParams
Write-Log "Edit-OSDCloudWinPE completed." -Color Green

# Mount our WIM. Borrowed from https://github.com/OSDeploy/OSD/blob/master/Public/OSDCloud/Edit-OSDCloud.winpe.ps1
Write-Log "Mounting WIM for Glazier, Wi-Fi, and Python injection..." -Color Yellow
$WorkspacePath = Get-OSDCloudWorkspace -ErrorAction Stop
$MountMyWindowsImage = Mount-MyWindowsImage -ImagePath "$WorkspacePath\Media\Sources\boot.wim"
$MountPath = $MountMyWindowsImage.Path

# Inject Intel Wi-Fi drivers if downloaded
if (Test-Path "$intelWifiDir") {
    Write-Log "Injecting Intel Wi-Fi drivers into WinPE image..." -Color Yellow
    Add-WindowsDriver -Path "$MountPath" -Driver "$intelWifiDir" -Recurse -ForceUnsigned -ErrorAction Stop | Out-Null
    Write-Log "Intel Wi-Fi drivers injected successfully." -Color Green
}

# $pyTargetDir is the directory where Python will get installed
$pyTargetDir = "$MountPath\Python"
$pyEXE = "$pyTargetDir\python.exe"

Write-Log "Installing Python into mounted WIM ($pyTargetDir)..."
mkdir $MountPath\Python -Force | Out-Null
& $pythonSavePath TargetDir=$pyTargetDir Include_launcher=0 /passive

# Install git
Write-Log "Installing Git via Chocolatey..."
choco install git -y --no-progress

# Configure Git to map git:// and http:// to https://
& 'C:\Program Files\Git\bin\git.exe' config --global url."https://github.com/".insteadOf "http://github.com/"
& 'C:\Program Files\Git\bin\git.exe' config --global url."https://github.com/".insteadOf "git://github.com/"

# Clone or update Glazier repository.
Write-Log "Cloning or updating Glazier github repo..."
if (-not (Test-Path "C:\glazier")) {
    & 'C:\Program Files\Git\bin\git.exe' clone https://github.com/google/glazier.git C:\glazier
} else {
    & 'C:\Program Files\Git\bin\git.exe' -C C:\glazier\ pull
}
Write-Log "Installing Glazier pip requirements..."
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User") + ";C:\Program Files\Git\bin;C:\Program Files\Git\cmd"
& $pyEXE -m pip install -r C:\glazier\requirements.txt
Write-Log "Installing pywin32..."
& $pyEXE -m pip install pywin32

Write-Log "Copying Glazier source and resources to mounted WIM..."
robocopy "C:\glazier\" "$MountPath\glazier\" /E /PURGE /ndl /njh /njs /np | Out-Null
mkdir "$MountPath\glazier-resources" -Force | Out-Null
robocopy "$scriptPath\..\glazier-resources\" "$MountPath\glazier-resources\" *.* /E /PURGE /ndl /njh /njs /np | Out-Null
robocopy "$scriptPath\" "$MountPath\Windows\System32\" autobuild.ps1 /PURGE /ndl /njh /njs /np | Out-Null
robocopy "C:\Windows\system32\" "$MountPath\Windows\System32\" shutdown.exe /PURGE /ndl /njh /njs /np | Out-Null
robocopy "C:\Windows\System32\WindowsPowerShell\v1.0\" "$MountPath\Windows\System32\WindowsPowerShell\v1.0\" pwrshsip.dll /PURGE /ndl /njh /njs /np | Out-Null
robocopy "$scriptPath\" "$MountPath\Windows\System32\WindowsPowerShell\v1.0\" pwrshsip.reg /PURGE /ndl /njh /njs /np | Out-Null

Write-Log "Downloading CA certificates bundle to WIM..."
Invoke-DownloadWithRetry -Url "https://curl.se/ca/cacert.pem" -OutFile "$MountPath\glazier-resources\ca-certs.crt"

Write-Log "Bundling pre-installed NuGet provider, PackageManagement, PowerShellGet, OSD, and MSCatalog into WIM..."
# 1. Pre-stage the NuGet provider DLL so WinPE never prompts to bootstrap NuGet at runtime
robocopy "C:\Program Files\PackageManagement\ProviderAssemblies\" "$MountPath\Program Files\PackageManagement\ProviderAssemblies\" /E /PURGE /ndl /njh /njs /np | Out-Null

# 2. Pre-stage updated PackageManagement & PowerShellGet alongside OSD and MSCatalog
robocopy "C:\Program Files\WindowsPowerShell\Modules\PackageManagement\" "$MountPath\Program Files\WindowsPowerShell\Modules\PackageManagement\" /E /PURGE /ndl /njh /njs /np | Out-Null
robocopy "C:\Program Files\WindowsPowerShell\Modules\PowerShellGet\" "$MountPath\Program Files\WindowsPowerShell\Modules\PowerShellGet\" /E /PURGE /ndl /njh /njs /np | Out-Null
robocopy "C:\Program Files\WindowsPowerShell\Modules\OSD\" "$MountPath\Program Files\WindowsPowerShell\Modules\OSD\" /E /PURGE /ndl /njh /njs /np | Out-Null
robocopy "C:\Program Files\WindowsPowerShell\Modules\MSCatalog\" "$MountPath\Program Files\WindowsPowerShell\Modules\MSCatalog\" /E /PURGE /ndl /njh /njs /np | Out-Null

# Copy client WLAN DLLs and WirelessConnect.exe to WinPE if WinRE mode
if ($enableWinRE) {
    if (Test-Path "$downloadDir\wlan_dlls") {
        Write-Log "Copying Windows 11 client WLAN DLLs to $MountPath\Windows\System32\..."
        robocopy "$downloadDir\wlan_dlls" "$MountPath\Windows\System32" dmcmnutils.dll mdmpostprocessevaluator.dll mdmregistration.dll /ndl /njh /njs /b /np | Out-Null
    }
    if (Test-Path "$downloadDir\WirelessConnect.exe") {
        Write-Log "Copying WirelessConnect.exe to $MountPath\Windows\ and $MountPath\Windows\System32\..."
        Copy-Item -Path "$downloadDir\WirelessConnect.exe" -Destination "$MountPath\Windows\WirelessConnect.exe" -Force
        Copy-Item -Path "$downloadDir\WirelessConnect.exe" -Destination "$MountPath\Windows\System32\WirelessConnect.exe" -Force
    }
}

Write-Log "Configuring offline WinPE registry wallpaper defaults..." -Color Cyan
& reg.exe load "HKLM\WinPE_Default" "$MountPath\Windows\System32\Config\DEFAULT" | Out-Null
& reg.exe add "HKLM\WinPE_Default\Control Panel\Desktop" /v WallpaperStyle /t REG_SZ /d "10" /f | Out-Null
& reg.exe add "HKLM\WinPE_Default\Control Panel\Desktop" /v TileWallpaper /t REG_SZ /d "0" /f | Out-Null
& reg.exe add "HKLM\WinPE_Default\Control Panel\Colors" /v Background /t REG_SZ /d "0 0 0" /f | Out-Null
& reg.exe unload "HKLM\WinPE_Default" | Out-Null

Write-Log "Writing Set-WinPEWallpaper.ps1 (resolution cascade + bottom-left crop) to System32..." -Color Cyan
$wallpaperScriptPath = "$MountPath\Windows\System32\Set-WinPEWallpaper.ps1"
$wallpaperScriptContent = @'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$win32Source = @"
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
    public string dmDeviceName;
    public short dmSpecVersion;
    public short dmDriverVersion;
    public short dmSize;
    public short dmDriverExtra;
    public int dmFields;
    public int dmPositionX;
    public int dmPositionY;
    public int dmDisplayOrientation;
    public int dmDisplayFixedOutput;
    public short dmColor;
    public short dmDuplex;
    public short dmYResolution;
    public short dmTTOption;
    public short dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
    public string dmFormName;
    public short dmLogPixels;
    public int dmBitsPerPel;
    public int dmPelsWidth;
    public int dmPelsHeight;
    public int dmDisplayFlags;
    public int dmDisplayFrequency;
    public int dmICMMethod;
    public int dmICMIntent;
    public int dmMediaType;
    public int dmDitherType;
    public int dmReserved1;
    public int dmReserved2;
    public int dmPanningWidth;
    public int dmPanningHeight;
}

public class WinPEGraphics {
    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    public static extern int EnumDisplaySettings(string lpszDeviceName, int iModeNum, ref DEVMODE lpDevMode);

    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    public static extern int ChangeDisplaySettings(ref DEVMODE lpDevMode, int dwFlags);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);

    public const int ENUM_CURRENT_SETTINGS = -1;
    public const int DM_PELSWIDTH = 0x00080000;
    public const int DM_PELSHEIGHT = 0x00100000;
    public const int CDS_TEST = 0x00000002;
    public const int CDS_UPDATEREGISTRY = 0x00000001;
    public const int DISP_CHANGE_SUCCESSFUL = 0;

    public static bool TrySetResolution(int width, int height) {
        DEVMODE dm = new DEVMODE();
        dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        if (EnumDisplaySettings(null, ENUM_CURRENT_SETTINGS, ref dm) == 0) {
            return false;
        }
        if (dm.dmPelsWidth == width && dm.dmPelsHeight == height) {
            return true;
        }
        dm.dmPelsWidth = width;
        dm.dmPelsHeight = height;
        dm.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT;

        if (ChangeDisplaySettings(ref dm, CDS_TEST) == DISP_CHANGE_SUCCESSFUL) {
            return ChangeDisplaySettings(ref dm, CDS_UPDATEREGISTRY) == DISP_CHANGE_SUCCESSFUL;
        }
        return false;
    }
}
"@

Add-Type -TypeDefinition $win32Source -ErrorAction SilentlyContinue

# 1. Cascading resolution fallback matching iPXE menu:
#    1920x1080 -> 1366x768 (or 1360x768) -> 1024x768 -> keep current
$candidateResolutions = @(
    @{ W = 1920; H = 1080 },
    @{ W = 1366; H = 768  },
    @{ W = 1360; H = 768  },
    @{ W = 1024; H = 768  }
)

foreach ($res in $candidateResolutions) {
    if ([WinPEGraphics]::TrySetResolution($res.W, $res.H)) {
        Start-Sleep -Milliseconds 250
        break
    }
}

# 2. Crop and scale wallpaper retaining bottom-left (X = 0, Y = Bottom)
$srcPath = "$env:SystemRoot\System32\winpe.jpg"
$dstPath = "$env:TEMP\winpe_cropped.jpg"
if (-not (Test-Path $srcPath)) { exit 0 }

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$targetW = [int]$screen.Width
$targetH = [int]$screen.Height
if ($targetW -le 0 -or $targetH -le 0) { exit 0 }

$srcImg = [System.Drawing.Image]::FromFile($srcPath)
try {
    $srcW = [double]$srcImg.Width
    $srcH = [double]$srcImg.Height
    $targetAspect = [double]$targetW / [double]$targetH
    $srcAspect    = $srcW / $srcH

    if ([Math]::Abs($srcAspect - $targetAspect) -lt 0.01) {
        # Matching aspect ratio (e.g. 1920x1080 or 1366x768): use full image
        $cropX = 0
        $cropY = 0
        $cropW = [int]$srcW
        $cropH = [int]$srcH
    } elseif ($srcAspect -gt $targetAspect) {
        # Narrower screen (e.g. 4:3 1024x768): retain full height and left edge (X = 0), crop right
        $cropH = [int]$srcH
        $cropW = [int][Math]::Round($srcH * $targetAspect)
        $cropX = 0
        $cropY = 0
    } else {
        # Wider screen (e.g. 21:9): retain full width and bottom edge (Y = srcH - cropH), crop top
        $cropW = [int]$srcW
        $cropH = [int][Math]::Round($srcW / $targetAspect)
        $cropX = 0
        $cropY = [int]($srcH - $cropH)
    }

    $bmp = New-Object System.Drawing.Bitmap($targetW, $targetH, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $graphics.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality

        $destRect = New-Object System.Drawing.Rectangle(0, 0, $targetW, $targetH)
        $srcRect  = New-Object System.Drawing.Rectangle($cropX, $cropY, $cropW, $cropH)
        $graphics.DrawImage($srcImg, $destRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)

        $jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
                     Where-Object { $_.MimeType -eq 'image/jpeg' }
        $encParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
        $encParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
            [System.Drawing.Imaging.Encoder]::Quality, [long]98
        )
        $bmp.Save($dstPath, $jpegCodec, $encParams)
    } finally {
        $graphics.Dispose()
        $bmp.Dispose()
    }
} finally {
    $srcImg.Dispose()
}

# 0x0014 = SPI_SETDESKWALLPAPER, 0x03 = SPIF_UPDATEINIFILE | SPIF_SENDWININICHANGE
[WinPEGraphics]::SystemParametersInfo(0x0014, 0, $dstPath, 0x03) | Out-Null
'@

Set-Content -Path $wallpaperScriptPath -Value $wallpaperScriptContent -Encoding UTF8 -Force

$osd_version = (Get-InstalledModule -Name OSD).Version.ToString()
Write-Log "Detected OSDCloud version $osd_version, writing to startup script..." -Color Green

# Write out Startnet.cmd, which will run when WinPE boots. This will detect network / Wi-Fi and then autobuild.ps1.
$Startnet = @"
@ECHO OFF
ECHO Glazier WinPE with OSDCloud {0}
ECHO Initialize WinPE
wpeinit
cd \
ECHO Apply PowerShell Registry Fixes....
X:\Windows\System32\reg.exe import "X:\Windows\System32\WindowsPowerShell\v1.0\pwrshsip.reg" /reg:64
ECHO Configuring Display Resolution and Wallpaper...
PowerShell -NoProfile -NoLogo -WindowStyle Hidden -ExecutionPolicy Bypass -File "X:\Windows\System32\Set-WinPEWallpaper.ps1"
ECHO Initialize Hardware
start /wait PowerShell -Nol -W Mi -C Start-Sleep -Seconds 10
ECHO Checking Network Connectivity...
start /wait PowerShell -NoL -C "& {{ if (Get-Service WlanSvc -ErrorAction SilentlyContinue) {{ if ((Get-Service WlanSvc).Status -ne 'Running') {{ Start-Service WlanSvc -ErrorAction SilentlyContinue }} }}; Start-Sleep -Seconds 5; `$activeIP = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {{ `$_.InterfaceAlias -notmatch 'Loopback' -and `$_.IPAddress -notlike '169.254.*' }}; if (-not `$activeIP) {{ Write-Host '[!] No active network connection detected. Prompting for Wi-Fi...' -ForegroundColor Yellow; if (Test-Path 'X:\Windows\WirelessConnect.exe') {{ Start-Process -FilePath 'X:\Windows\WirelessConnect.exe' -Wait }} elseif (Test-Path 'X:\Windows\System32\WirelessConnect.exe') {{ Start-Process -FilePath 'X:\Windows\System32\WirelessConnect.exe' -Wait }}; Start-Sleep -Seconds 5 }} else {{ Write-Host '[+] Network connection detected.' -ForegroundColor Green }} }}"
ECHO Checking OSD and MSCatalog PowerShell Module Updates (Minimized)
start /wait PowerShell -NoL -W Mi -C "& {{ `$ConfirmPreference = 'None'; `$ProgressPreference = 'SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Import-Module OSD -ErrorAction SilentlyContinue; if (Test-WebConnection) {{ if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {{ Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null }}; Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction SilentlyContinue; Install-Module OSD -Force -AllowClobber -SkipPublisherCheck -Confirm:`$false -ErrorAction SilentlyContinue; Install-Module MSCatalog -Force -AllowClobber -SkipPublisherCheck -Confirm:`$false -ErrorAction SilentlyContinue }} }}"
ECHO Initialize PowerShell (Minimized)
start PowerShell -Nol -W Mi
@ECHO ON
@ECHO OFF
ECHO Start PowerShell
start PowerShell -NoProfile -NoLogo -WindowStyle Maximized -NoExit -File "X:\Windows\System32\autobuild.ps1" -config_server {1}
"@ -f $osd_version, $config_server

Write-Log "Writing Startnet.cmd to WinPE..."
$Startnet | Out-File -FilePath "$MountPath\Windows\System32\Startnet.cmd" -Force -Encoding ascii

Write-Log "Saving mounted WIM..."
$MountMyWindowsImage | Dismount-MyWindowsImage -Save

Write-Log "Configuring BCD stores for 1920x1080 / highest native GOP resolution..." -Color Cyan
$bcdPaths = @(
    "$WorkspacePath\Media\Boot\BCD",
    "$WorkspacePath\Media\EFI\Microsoft\Boot\BCD"
)
foreach ($bcd in $bcdPaths) {
    if (Test-Path $bcd) {
        & bcdedit.exe /store "$bcd" /set '{globalsettings}' highestmode on | Out-Null
        & bcdedit.exe /store "$bcd" /set '{default}' graphicsresolution 1920x1080 2>$null | Out-Null
    }
}

Write-Log "Creating Base ISO..."
New-OSDCloudISO

if ($storage_boot_upload_path -ne "") {
    Write-Log "Writing WIM, BCD, and boot.sdi to $storage_boot_upload_path..."
    gsutil -m cp "$WorkspacePath\Media\Sources\boot.wim" "$storage_boot_upload_path/sources/boot.wim"
    gsutil -m cp "$WorkspacePath\Media\Boot\BCD" "$storage_boot_upload_path/Boot/BCD"
    gsutil -m cp "$WorkspacePath\Media\Boot\boot.sdi" "$storage_boot_upload_path/Boot/boot.sdi"
}

if ($storage_upload_path -ne "") {
    Write-Log "Writing Base ISO to $storage_upload_path.iso and $storage_upload_path-stable.iso..."
    gsutil -m cp "C:\OSDCloud\OSDCloud.iso" "$storage_upload_path.iso"
    gsutil -m cp "C:\OSDCloud\OSDCloud.iso" "$storage_upload_path-stable.iso"

    $configs = @("menu", "blank", "win10-stable", "win10-blank")
    foreach ($cnf in $configs) {
        $cnfDir = "$scriptPath\..\glazier-repo\$cnf"
        $cnfScript = "$cnfDir\autobuild.ps1"
        if (!(Test-Path $cnfScript)) {
            if (Test-Path "$scriptPath\autobuild-$cnf.ps1") {
                $cnfDir = $scriptPath
                $cnfScript = "$scriptPath\autobuild-$cnf.ps1"
            }
        }
        if (!(Test-Path $cnfScript)) {
            Write-Log "Warning: Config script $cnfScript not found, skipping $cnf" -Color Yellow
            continue
        }
        Write-Log "Building ISO for flavor: $cnf..."
        $MountMyWindowsImage = Mount-MyWindowsImage -ImagePath "$WorkspacePath\Media\Sources\boot.wim"
        $MountPath = $MountMyWindowsImage.Path

        if ($cnfDir -eq $scriptPath) {
            Copy-Item -Path "$scriptPath\autobuild-$cnf.ps1" -Destination "$MountPath\Windows\System32\autobuild.ps1" -Force
        } else {
            robocopy "$cnfDir\" "$MountPath\Windows\System32\" autobuild.ps1 /PURGE /ndl /njh /njs /np | Out-Null
        }
        $MountMyWindowsImage | Dismount-MyWindowsImage -Save
        New-OSDCloudISO

        Write-Log "Writing ISO to Cloud Storage at $storage_upload_path-$cnf.iso..."
        gsutil -m cp "C:\OSDCloud\OSDCloud.iso" "$storage_upload_path-$cnf.iso"
    }
}

Write-Log "All WinPE builds and uploads completed successfully!" -Color Green