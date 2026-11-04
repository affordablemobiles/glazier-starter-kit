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

Write-Log "Starting Glazier WinPE Bootstrap script" -Color Green

# Global non-interactive preferences to avoid silent stdin blocking
$ConfirmPreference = 'None'
$ProgressPreference = 'SilentlyContinue'

# Ensure TLS 1.2 / TLS 1.3 are enabled for all web requests (PSGallery, Chocolatey, Python, curl.se)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# Disable IE Advanced Security, as it breaks OSDCloud calls:
Write-Log "Configuring system environment..."
$IEESC = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}"
Set-ItemProperty -Path $IEESC -Name IsInstalled -Value 0 -ErrorAction SilentlyContinue
Stop-Process -Name Explorer -Force -ErrorAction SilentlyContinue

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
Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -Confirm:$false -ErrorAction SilentlyContinue

# Install OSD and MSCatalog PowerShell Modules (latest available)
Write-Log "Installing OSD module from PowerShell Gallery..."
Install-Module -Name OSD -Force -AllowClobber -Confirm:$false -SkipPublisherCheck -Scope AllUsers
Write-Log "Installing MSCatalog module from PowerShell Gallery..."
Install-Module -Name MSCatalog -Force -AllowClobber -Confirm:$false -SkipPublisherCheck -Scope AllUsers

# Import the modules
Write-Log "Importing OSD & MSCatalog modules..."
Import-Module OSD -Force
Import-Module MSCatalog -Force -ErrorAction SilentlyContinue

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

$enableWinRE = ($use_winre -match '^(true|1|yes)$')
$forceRefreshWinRE = ($refresh_winre -match '^(true|1|yes)$')

# If WinRE is requested, replace ADK winpe.wim with serviced WinRE.wim (enabling native 802.11 Wi-Fi stack)
if ($enableWinRE) {
    Write-Log "=== WinRE Mode Requested: Preparing Windows Recovery Environment with Wi-Fi ===" -Color Magenta
    $cachedWinRE = "$downloadDir\cached_winre.wim"
    $hasCachedGCS = $false

    if ($storage_boot_upload_path -ne "" -and (-not $forceRefreshWinRE)) {
        Write-Log "Checking GCS for cached base WinRE image at $storage_boot_upload_path/base/winre.wim..."
        & gsutil -q stat "$storage_boot_upload_path/base/winre.wim"
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Found cached base WinRE in GCS. Downloading..."
            gsutil -m cp "$storage_boot_upload_path/base/winre.wim" $cachedWinRE
            if (Test-Path $cachedWinRE) {
                $hasCachedGCS = $true
            }
        }
    }

    if ($hasCachedGCS) {
        Write-Log "Using cached WinRE from GCS." -Color Green
        Copy-Item -Path $cachedWinRE -Destination "C:\ProgramData\OSDCloud\Media\sources\boot.wim" -Force
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
            Write-Log "URL: $($fu.Url)"
            & curl.exe -fL --progress-bar -o "$esdFile" "$($fu.Url)"
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path $esdFile)) {
                Write-Log "Download failed via curl.exe" -Color Red
                exit 1
            }
        } else {
            Write-Log "ESD already exists at $esdFile"
        }

        Write-Log "Extracting Winre.wim from ESD using 7-Zip..."
        $extractDir = "$downloadDir\winre_extract"
        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
        & 'C:\Program Files\7-Zip\7z.exe' e "$esdFile" -r "Winre.wim" -o"$extractDir" -y
        $extractedWinRE = (Get-ChildItem -Path $extractDir -Filter 'Winre.wim' -Recurse | Select-Object -First 1).FullName

        if (-not $extractedWinRE -or -not (Test-Path $extractedWinRE)) {
            Write-Log "Failed to extract Winre.wim from ESD" -Color Red
            exit 1
        }
        Write-Log "Extracted Winre.wim ($([Math]::Round((Get-Item $extractedWinRE).Length / 1MB)) MB)" -Color Green

        Write-Log "Extracting Windows 11 client WLAN/MDM DLLs from ESD..."
        $dllExtractDir = "$downloadDir\wlan_dlls"
        New-Item -ItemType Directory -Path $dllExtractDir -Force | Out-Null
        & 'C:\Program Files\7-Zip\7z.exe' e "$esdFile" -r "dmcmnutils.dll" "mdmpostprocessevaluator.dll" "mdmregistration.dll" -o"$dllExtractDir" -y
        Write-Log "Extracted client WLAN DLLs: $(Get-ChildItem $dllExtractDir | Select-Object -ExpandProperty Name)" -Color Green

        Write-Log "Downloading WirelessConnect.exe for WinPE Wi-Fi GUI..."
        $wirelessConnectUrl = "https://github.com/okieselbach/Helpers/raw/master/WirelessConnect/WirelessConnect/bin/Release/WirelessConnect.exe"
        $wirelessConnectExe = "$downloadDir\WirelessConnect.exe"
        try {
            & curl.exe -fsSL -o "$wirelessConnectExe" "$wirelessConnectUrl"
            Write-Log "Downloaded WirelessConnect.exe successfully" -Color Green
        } catch {
            Write-Log "Warning: Could not download WirelessConnect.exe: $_" -Color Yellow
        }

        Write-Log "Querying Microsoft Update Catalog for Safe OS Dynamic Updates..."
        try {
            $safeOSUpdate = Get-MSCatalogUpdate -Search "Safe OS Dynamic Update for Windows 11 Version 24H2 for x64" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($safeOSUpdate) {
                Write-Log "Found Safe OS Dynamic Update: $($safeOSUpdate.Title)" -Color Green
                $updateDir = "$downloadDir\winre_update"
                New-Item -ItemType Directory -Path $updateDir -Force | Out-Null
                Save-MSCatalogUpdate -Update $safeOSUpdate -Destination $updateDir
                $updatePkg = (Get-ChildItem -Path $updateDir -Include *.cab,*.msu -Recurse | Select-Object -First 1).FullName

                if ($updatePkg) {
                    Write-Log "Mounting Winre.wim to slipstream $updatePkg..."
                    $mountDir = "$downloadDir\winre_mount"
                    New-Item -ItemType Directory -Path $mountDir -Force | Out-Null
                    Mount-WindowsImage -ImagePath $extractedWinRE -Index 1 -Path $mountDir
                    Write-Log "Adding update package..."
                    Add-WindowsPackage -Path $mountDir -PackagePath $updatePkg
                    Write-Log "Performing DISM component cleanup..."
                    DISM /Image:"$mountDir" /Cleanup-Image /StartComponentCleanup
                    Write-Log "Dismounting and saving updated WinRE..."
                    Dismount-WindowsImage -Path $mountDir -Save
                    Remove-Item -Path $mountDir -Force -Recurse -ErrorAction SilentlyContinue
                    Write-Log "WinRE slipstreaming completed successfully." -Color Green
                }
            } else {
                Write-Log "No newer Safe OS Dynamic Update found, using release WinRE."
            }
        } catch {
            Write-Log "Warning during Safe OS update servicing: $_" -Color Yellow
        }

        Write-Log "Replacing template boot.wim with serviced WinRE..."
        Copy-Item -Path $extractedWinRE -Destination "C:\ProgramData\OSDCloud\Media\sources\boot.wim" -Force

        if ($storage_boot_upload_path -ne "") {
            Write-Log "Uploading fresh base WinRE to $storage_boot_upload_path/base/winre.wim for future builds..."
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
Write-Log "Mounting WIM for Glazier and Python injection..." -Color Yellow
$WorkspacePath = Get-OSDCloudWorkspace -ErrorAction Stop
$MountMyWindowsImage = Mount-MyWindowsImage -ImagePath "$WorkspacePath\Media\Sources\boot.wim"
$MountPath = $MountMyWindowsImage.Path

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
& curl.exe -fsSL -o "$MountPath\glazier-resources\ca-certs.crt" "https://curl.se/ca/cacert.pem"

Write-Log "Bundling OSD and MSCatalog modules into WIM..."
Save-Module -Name OSD -Path "$MountPath\Program Files\WindowsPowerShell\Modules" -Force -AcceptLicense -Confirm:$false
Save-Module -Name MSCatalog -Path "$MountPath\Program Files\WindowsPowerShell\Modules" -Force -AcceptLicense -Confirm:$false

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

Write-Log "Writing Startnet.cmd to WinPE..."
$Startnet | Out-File -FilePath "$MountPath\Windows\System32\Startnet.cmd" -Force -Encoding ascii

Write-Log "Saving mounted WIM..."
$MountMyWindowsImage | Dismount-MyWindowsImage -Save

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

    $configs = @("blank", "win10-stable", "win10-blank")
    foreach ($cnf in $configs) {
        $cnfScript = "$scriptPath\..\glazier-repo\$cnf\autobuild.ps1"
        if (!(Test-Path $cnfScript)) {
            Write-Log "Warning: Config script $cnfScript not found, skipping $cnf" -Color Yellow
            continue
        }
        Write-Log "Building ISO for flavor: $cnf..."
        $MountMyWindowsImage = Mount-MyWindowsImage -ImagePath "$WorkspacePath\Media\Sources\boot.wim"
        $MountPath = $MountMyWindowsImage.Path

        robocopy "$scriptPath\..\glazier-repo\$cnf\" "$MountPath\Windows\System32\" autobuild.ps1 /PURGE /ndl /njh /njs /np | Out-Null
        $MountMyWindowsImage | Dismount-MyWindowsImage -Save
        New-OSDCloudISO

        Write-Log "Writing ISO to Cloud Storage at $storage_upload_path-$cnf.iso..."
        gsutil -m cp "C:\OSDCloud\OSDCloud.iso" "$storage_upload_path-$cnf.iso"
    }
}

Write-Log "All WinPE builds and uploads completed successfully!" -Color Green