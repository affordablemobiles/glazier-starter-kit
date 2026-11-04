Param(
    [string]$config_server = "",
    [string]$storage_upload_path = "",
    [string]$storage_boot_upload_path = "",
    [string]$use_winre = "true",
    [string]$refresh_winre = "true",
    [string]$winre_os_name = "Windows 11 24H2 amd64"
)

# Ensure TLS 1.2 / TLS 1.3 are enabled for all web requests (PSGallery, Chocolatey, Python, curl.se)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# Disable IE Advanced Security, as it breaks OSDCloud calls:
$IEESC = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}"
Set-ItemProperty -Path $IEESC -Name IsInstalled -Value 0 -ErrorAction SilentlyContinue
Stop-Process -Name Explorer -Force -ErrorAction SilentlyContinue

# Enable IE Explorer from Cloud Build
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Internet Explorer\Main" -Name "DisableFirstRunCustomize" -Value 2 -ErrorAction SilentlyContinue

# $scriptPath is the absolute path where this script is executing from
$scriptPath = split-path -parent $MyInvocation.MyCommand.Definition

if ((Test-Path "$scriptPath\autobuild.ps1") -eq $False) {
    Write-Host "$scriptPath\autobuild.ps1 not found"
    exit(1)
}

# Make sure glazier-resources is available to copy
if ((Test-Path "$scriptPath\..\glazier-resources\") -eq $False) {
    Write-Host "$scriptPath\..\glazier-resources\ not found"
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
        Write-Host "config_server cannot be an empty string"
        exit(1)
    }
}

function isURIWeb($address) {
	$uri = $address -as [System.URI]
	$uri.AbsoluteURI -ne $null -and $uri.Scheme -match '[http|https]'
}

# ensure $config_server is a valid url. This avoids avoid frustration, trust me.
if (!(isURIWeb($config_server))) {
    Write-Host "$config_server is not a valid url"
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
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Force
Invoke-WebRequest -Uri https://chocolatey.org/install.ps1 -UseBasicParsing | Invoke-Expression

# Install Windows ADK
choco install windows-adk -y
choco install windows-adk-winpe -y
choco install 7zip -y

# Configure PowerShell Gallery repository as trusted for non-interactive builds
Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction SilentlyContinue

# Install NuGet Package Provider
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force

# Install OSD and MSCatalog PowerShell Modules (latest available)
Install-Module -Name OSD -Force -AllowClobber -SkipPublisherCheck
Install-Module -Name MSCatalog -Force -AllowClobber -SkipPublisherCheck

# Import the module
Import-Module OSD -Force
Import-Module MSCatalog -Force -ErrorAction SilentlyContinue

# Create OSDCloud template if not created yet.
if ((Get-OSDCloudTemplate) -eq "C:\ProgramData\OSDCloud") { 
    Write-Host "'New-OSDCloudTemplate -Verbose' already completed"
} else {
    Write-Host "Running 'New-OSDCloudTemplate -Verbose'"
    New-OSDCloudTemplate -Verbose
}

$enableWinRE = ($use_winre -match '^(true|1|yes)$')
$forceRefreshWinRE = ($refresh_winre -match '^(true|1|yes)$')

# If WinRE is requested, replace ADK winpe.wim with serviced WinRE.wim (enabling native 802.11 Wi-Fi stack)
if ($enableWinRE) {
    Write-Host "=== WinRE Mode Requested: Preparing Windows Recovery Environment with Wi-Fi ==="
    $cachedWinRE = "$downloadDir\cached_winre.wim"
    $hasCachedGCS = $false

    if ($storage_boot_upload_path -ne "" -and (-not $forceRefreshWinRE)) {
        Write-Host "Checking GCS for cached base WinRE image at $storage_boot_upload_path/base/winre.wim..."
        & gsutil -q stat "$storage_boot_upload_path/base/winre.wim"
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Found cached base WinRE in GCS. Downloading..."
            gsutil -m cp "$storage_boot_upload_path/base/winre.wim" $cachedWinRE
            if (Test-Path $cachedWinRE) {
                $hasCachedGCS = $true
            }
        }
    }

    if ($hasCachedGCS) {
        Write-Host "Using cached WinRE from GCS."
        Copy-Item -Path $cachedWinRE -Destination "C:\ProgramData\OSDCloud\Media\sources\boot.wim" -Force
    } else {
        Write-Host "Fetching $winre_os_name ESD directly from Microsoft via OSDCloud..."
        Start-Service -Name BITS -ErrorAction SilentlyContinue
        $osMediaDir = "$downloadDir\OS"
        $fu = Save-FeatureUpdate -OSName $winre_os_name -OSLanguage 'en-us' -OSActivation 'Retail' -DownloadPath $osMediaDir

        if (-not $fu -or -not (Test-Path $fu.FullName)) {
            Write-Error "Failed to download $winre_os_name from Microsoft"
            exit 1
        }

        Write-Host "Extracting Winre.wim from $($fu.FullName) using 7-Zip..."
        $extractDir = "$downloadDir\winre_extract"
        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
        & 'C:\Program Files\7-Zip\7z.exe' e "$($fu.FullName)" -r "Winre.wim" -o"$extractDir" -y
        $extractedWinRE = (Get-ChildItem -Path $extractDir -Filter 'Winre.wim' -Recurse | Select-Object -First 1).FullName

        if (-not $extractedWinRE -or -not (Test-Path $extractedWinRE)) {
            Write-Error "Failed to extract Winre.wim from ESD"
            exit 1
        }

        Write-Host "Extracting Windows 11 client WLAN/MDM DLLs from ESD..."
        $dllExtractDir = "$downloadDir\wlan_dlls"
        New-Item -ItemType Directory -Path $dllExtractDir -Force | Out-Null
        & 'C:\Program Files\7-Zip\7z.exe' e "$($fu.FullName)" -r "dmcmnutils.dll" "mdmpostprocessevaluator.dll" "mdmregistration.dll" -o"$dllExtractDir" -y

        Write-Host "Downloading WirelessConnect.exe for WinPE Wi-Fi GUI..."
        $wirelessConnectUrl = "https://github.com/okieselbach/Helpers/raw/master/WirelessConnect/WirelessConnect/bin/Release/WirelessConnect.exe"
        $wirelessConnectExe = "$downloadDir\WirelessConnect.exe"
        try {
            Invoke-WebRequest -Uri $wirelessConnectUrl -OutFile $wirelessConnectExe -UseBasicParsing
        } catch {
            Write-Warning "Could not download WirelessConnect.exe: $_"
        }

        Write-Host "Querying Microsoft Update Catalog for matching Safe OS Dynamic Updates..."
        try {
            # Search for matching Safe OS Dynamic Update for matching OS
            $safeOSUpdate = Get-MSCatalogUpdate -Search "Safe OS Dynamic Update for Windows 11 Version 24H2 for x64" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($safeOSUpdate) {
                Write-Host "Found Safe OS Dynamic Update: $($safeOSUpdate.Title)"
                $updateDir = "$downloadDir\winre_update"
                New-Item -ItemType Directory -Path $updateDir -Force | Out-Null
                Save-MSCatalogUpdate -Update $safeOSUpdate -Destination $updateDir
                $updatePkg = (Get-ChildItem -Path $updateDir -Include *.cab,*.msu -Recurse | Select-Object -First 1).FullName

                if ($updatePkg) {
                    Write-Host "Slipstreaming $updatePkg into WinRE image..."
                    $mountDir = "$downloadDir\winre_mount"
                    New-Item -ItemType Directory -Path $mountDir -Force | Out-Null
                    Mount-WindowsImage -ImagePath $extractedWinRE -Index 1 -Path $mountDir
                    Add-WindowsPackage -Path $mountDir -PackagePath $updatePkg
                    DISM /Image:"$mountDir" /Cleanup-Image /StartComponentCleanup
                    Dismount-WindowsImage -Path $mountDir -Save
                    Remove-Item -Path $mountDir -Force -Recurse -ErrorAction SilentlyContinue
                }
            } else {
                Write-Host "No newer Safe OS Dynamic Update found, using release WinRE."
            }
        } catch {
            Write-Warning "Safe OS update servicing encountered a non-fatal warning: $_"
        }

        # Replace template boot.wim with our serviced WinRE
        Copy-Item -Path $extractedWinRE -Destination "C:\ProgramData\OSDCloud\Media\sources\boot.wim" -Force

        # Cache to GCS if upload path provided
        if ($storage_boot_upload_path -ne "") {
            Write-Host "Uploading fresh base WinRE to $storage_boot_upload_path/base/winre.wim for future builds..."
            gsutil -m cp "$extractedWinRE" "$storage_boot_upload_path/base/winre.wim"
        }
    }
}

# Create OSDCloud workspace if not created yet (copies Media from template).
if ((Get-OSDCloudWorkspace) -eq "C:\OSDCloud") {
    Write-Host "'New-OSDCloudWorkspace -WorkspacePath C:\OSDCloud' already completed"
} else {
    Write-Host "Running 'New-OSDCloudWorkspace -WorkspacePath C:\OSDCloud'"
    New-OSDCloudWorkspace -WorkspacePath C:\OSDCloud
}

# Download Python if needed
if ((Test-Path $pythonSavePath) -eq $False) {
    Write-Host "Downloading Python $pyVersion"
    Invoke-WebRequest -Uri $pyEXEUrl -UseBasicParsing -OutFile $pythonSavePath
} else {
    Write-Host "Python $pyVersion was already downloaded"
}

# Verify hash of Python installer
while ((Get-FileHash ($pythonSavePath) -Algorithm MD5).Hash -ne $pythonInstallHash) {
    Write-Host "Python hashes did not match. Removing and redownloading"
    rm $pythonSavePath
    Invoke-WebRequest -Uri $pyEXEUrl -UseBasicParsing -OutFile $pythonSavePath
}

# Install OSDCloud driver packs, bundle MSCatalog, and configure wallpaper in a single pass
Write-Host "Installing OSDCloud driver packs and configuring WinPE..."
$cloudDrivers = if ($enableWinRE) {
    @('Dell', 'IntelNet', 'USB', 'LenovoDock', 'WiFi')
} else {
    @('Dell', 'IntelNet', 'USB', 'LenovoDock')
}
$editParams = @{
    CloudDriver     = $cloudDrivers
    PSModuleInstall = @('MSCatalog')
}
$wallpaperPath = "$scriptPath\wallpaper.jpg"
if (Test-Path $wallpaperPath) {
    Write-Host "Configuring wallpaper for WinPE at $wallpaperPath"
    $editParams['Wallpaper'] = $wallpaperPath
} else {
    Write-Host "Wallpaper not available."
}
Edit-OSDCloudWinPE @editParams

# Mount our WIM. Borrowed from https://github.com/OSDeploy/OSD/blob/master/Public/OSDCloud/Edit-OSDCloud.winpe.ps1
Write-Host "Preparing WIM for Glazier, mount..."
$WorkspacePath = Get-OSDCloudWorkspace -ErrorAction Stop
$MountMyWindowsImage = Mount-MyWindowsImage -ImagePath "$WorkspacePath\Media\Sources\boot.wim"
$MountPath = $MountMyWindowsImage.Path

# $pyTargetDir is the directory where Python will get installed
$pyTargetDir = "$MountPath\Python"
# $pyEXE is shorthand for referring to python.exe. This variable will be used to install pip modules later.
$pyEXE = "$pyTargetDir\python.exe"

# This is not idempotent yet
Write-Host "Installing Python $pyVersion"
mkdir $MountPath\Python
# Install Python in the mounted WIM
& $pythonSavePath TargetDir=$pyTargetDir Include_launcher=0 /passive

# Install git
choco install git -y

# Configure Git to map git:// and http:// to https://
& 'C:\Program Files\Git\bin\git.exe' config --global url."https://github.com/".insteadOf "http://github.com/"
& 'C:\Program Files\Git\bin\git.exe' config --global url."https://github.com/".insteadOf "git://github.com/"

# Clone or update Glazier repository.
Write-Host "Cloning or updating Glazier github repo..."
if (-not (Test-Path "C:\glazier")) {
    & 'C:\Program Files\Git\bin\git.exe' clone https://github.com/google/glazier.git C:\glazier
} else {
    & 'C:\Program Files\Git\bin\git.exe' -C C:\glazier\ pull
}
Write-Host "Install Glazier pip requirements"
# Reload the path: https://stackoverflow.com/questions/17794507/reload-the-path-in-powershell
# This is required so pip can install from git repositories
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User") + ";C:\Program Files\Git\bin;C:\Program Files\Git\cmd"
# Install Glazier requirements
& $pyEXE -m pip install -r C:\glazier\requirements.txt
Write-Host "Running '$pyEXE -m pip install pywin32'"
# Install an additional Glazier dependency that isn't included in requirements.txt.
& $pyEXE -m pip install pywin32

Write-Host "Copying Glazier source code inside the image"
robocopy "C:\glazier\" "$MountPath\glazier\" /E /PURGE

Write-Host "Copying glazier-resources to WIM"
mkdir "$MountPath\glazier-resources"
robocopy "$scriptPath\..\glazier-resources\" "$MountPath\glazier-resources\" *.* /E /PURGE

Write-Host "Copying autobuild.ps1 to WIM"
robocopy "$scriptPath\" "$MountPath\Windows\System32\" autobuild.ps1 /PURGE

Write-Host "Copying shutdown.exe to WIM"
robocopy "C:\Windows\system32\" "$MountPath\Windows\System32\" shutdown.exe /PURGE

Write-Host "Copying pwrshsip.dll to WIM"
robocopy "C:\Windows\System32\WindowsPowerShell\v1.0\" "$MountPath\Windows\System32\WindowsPowerShell\v1.0\" pwrshsip.dll /PURGE

Write-Host "Copying pwrshsip.reg to WIM"
robocopy "$scriptPath\" "$MountPath\Windows\System32\WindowsPowerShell\v1.0\" pwrshsip.reg /PURGE

Write-Host "Downloading https://curl.se/ca/cacert.pem to WIM"
Invoke-WebRequest -Uri "https://curl.se/ca/cacert.pem" -OutFile "$MountPath\glazier-resources\ca-certs.crt" -UseBasicParsing

# Pre-bundle latest OSD and MSCatalog PowerShell modules directly into WinPE
Write-Host "Ensuring latest OSD and MSCatalog modules are bundled in WIM"
Save-Module -Name OSD -Path "$MountPath\Program Files\WindowsPowerShell\Modules" -Force -AcceptLicense
Save-Module -Name MSCatalog -Path "$MountPath\Program Files\WindowsPowerShell\Modules" -Force -AcceptLicense

# Copy client WLAN DLLs and WirelessConnect.exe to WinPE if WinRE mode
if ($enableWinRE) {
    if (Test-Path "$downloadDir\wlan_dlls") {
        Write-Host "Copying Windows 11 client WLAN DLLs to $MountPath\Windows\System32\..."
        robocopy "$downloadDir\wlan_dlls" "$MountPath\Windows\System32" dmcmnutils.dll mdmpostprocessevaluator.dll mdmregistration.dll /ndl /njh /njs /b /np
    }
    if (Test-Path "$downloadDir\WirelessConnect.exe") {
        Write-Host "Copying WirelessConnect.exe to $MountPath\Windows\ and $MountPath\Windows\System32\..."
        Copy-Item -Path "$downloadDir\WirelessConnect.exe" -Destination "$MountPath\Windows\WirelessConnect.exe" -Force
        Copy-Item -Path "$downloadDir\WirelessConnect.exe" -Destination "$MountPath\Windows\System32\WirelessConnect.exe" -Force
    }
}

$osd_version = (Get-InstalledModule -Name OSD).Version.ToString()
Write-Host "Detected OSDCloud version $osd_version, writing to startup script..."

# Write out Startnet.cmd, which will run when WinPE boots. This will detect network / Wi-Fi and then autobuild.ps1.
$Startnet = @"
@ECHO OFF
ECHO Glazier WinPE with OSDCloud {0}
ECHO Initialize WinPE
wpeinit
cd \
ECHO Apply PowerShell Registry Fixes....
X:\Windows\System32\reg.exe import "X:\Windows\System32\WindowsPowerShell\v1.0\pwrshsip.reg" /reg:64
ECHO Initialize Hardware
start /wait PowerShell -Nol -W Mi -C Start-Sleep -Seconds 10
ECHO Checking Network Connectivity...
start /wait PowerShell -NoL -C "& {{
    # Start WLAN service if installed in WinPE
    if (Get-Service WlanSvc -ErrorAction SilentlyContinue) {{
        if ((Get-Service WlanSvc).Status -ne 'Running') {{
            Start-Service WlanSvc -ErrorAction SilentlyContinue
        }}
    }}
    Start-Sleep -Seconds 5
    if (-not (Test-WebConnection)) {{
        Write-Host '[!] No active network connection detected.' -ForegroundColor Yellow
        Write-Host '[*] Prompting for Wi-Fi connection...' -ForegroundColor Cyan
        if (Test-Path 'X:\Windows\WirelessConnect.exe') {{
            Start-Process -FilePath 'X:\Windows\WirelessConnect.exe' -Wait
        }} elseif (Get-Command Start-WinREWiFi -ErrorAction SilentlyContinue) {{
            Start-WinREWiFi -WirelessConnect
        }}
    }} else {{
        Write-Host '[+] Network connection detected.' -ForegroundColor Green
    }}
}}"
ECHO Checking OSD PowerShell Module Updates (Minimized)
start /wait PowerShell -NoL -W Mi -C "& {{if (Test-WebConnection) {{[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Install-Module OSD -Force -AllowClobber -SkipPublisherCheck -Verbose}}}}"
ECHO Checking MSCatalog PowerShell Module Updates (Minimized)
start /wait PowerShell -NoL -W Mi -C "& {{if (Test-WebConnection) {{[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Install-Module MSCatalog -Force -AllowClobber -SkipPublisherCheck -Verbose}}}}"
ECHO Initialize PowerShell (Minimized)
start PowerShell -Nol -W Mi
@ECHO ON
@ECHO OFF
ECHO Start PowerShell
start PowerShell -NoProfile -NoLogo -WindowStyle Maximized -NoExit -File "X:\Windows\System32\autobuild.ps1" -config_server {1}
"@ -f $osd_version, $config_server

Write-Host "Writing Startnet.cmd"
$Startnet | Out-File -FilePath "$MountPath\Windows\System32\Startnet.cmd" -Force -Encoding ascii

Write-Host "Saving WIM"
$MountMyWindowsImage | Dismount-MyWindowsImage -Save

Write-Host "Creating ISO"
New-OSDCloudISO

if ($storage_boot_upload_path -ne "") {
    Write-Host "Writing WIM to Cloud Storage at $storage_boot_upload_path/sources/boot.wim"
    gsutil -m cp "$WorkspacePath\Media\Sources\boot.wim" "$storage_boot_upload_path/sources/boot.wim"

    Write-Host "Writing BCD to Cloud Storage at $storage_boot_upload_path/Boot/BCD"
    gsutil -m cp "$WorkspacePath\Media\Boot\BCD" "$storage_boot_upload_path/Boot/BCD"

    Write-Host "Writing WIM to Cloud Storage at $storage_boot_upload_path/Boot/boot.sdi"
    gsutil -m cp "$WorkspacePath\Media\Boot\boot.sdi" "$storage_boot_upload_path/Boot/boot.sdi"
}

if ($storage_upload_path -ne "") {
    Write-Host "Writing ISO to Cloud Storage at $storage_upload_path.iso and $storage_upload_path-stable.iso"
    gsutil -m cp "C:\OSDCloud\OSDCloud.iso" "$storage_upload_path.iso"
    gsutil -m cp "C:\OSDCloud\OSDCloud.iso" "$storage_upload_path-stable.iso"

    $configs = @("blank", "win10-stable", "win10-blank")
    foreach ($cnf in $configs) {
        $cnfScript = "$scriptPath\..\glazier-repo\$cnf\autobuild.ps1"
        if (!(Test-Path $cnfScript)) {
            Write-Warning "Config script $cnfScript not found, skipping $cnf"
            continue
        }
        Write-Host "Re-Mounting WinPE Image for $cnf"
        $MountMyWindowsImage = Mount-MyWindowsImage -ImagePath "$WorkspacePath\Media\Sources\boot.wim"
        $MountPath = $MountMyWindowsImage.Path

        Write-Host "Copying autobuild.ps1 to WIM"
        robocopy "$scriptPath\..\glazier-repo\$cnf\" "$MountPath\Windows\System32\" autobuild.ps1 /PURGE

        Write-Host "Saving WIM"
        $MountMyWindowsImage | Dismount-MyWindowsImage -Save

        Write-Host "Creating ISO"
        New-OSDCloudISO

        Write-Host "Writing ISO to Cloud Storage at $storage_upload_path-$cnf.iso"
        gsutil -m cp "C:\OSDCloud\OSDCloud.iso" "$storage_upload_path-$cnf.iso"
    }
}