Param(
    [string]$config_root_path = "",
    [string]$make_usb = $false,
    [string]$driver_path = "C:\drivers"
)

# $scriptPath is the absolute path where this script is executing from
$scriptPath = split-path -parent $MyInvocation.MyCommand.Definition

# if $scriptPath\autobuild.json exists, get a value for $config_root_path from it. Note tools\autobuild.json is in the .gitignore file.
$abjson = "$scriptPath\autobuild.json"
$config_root_path = ""
if ((Test-Path $abjson) -eq $True) {
    $json = Get-Content $abjson | Out-String | ConvertFrom-Json
    $config_root_path = $json.config_root_path
# get a value for $config_root_path from the CLI flags. If it's empty, exit 1 (bail)
} else {
    if ($config_root_path -eq "") {
        Write-Host "config_root_path cannot be an empty string"
        exit(1)
    }
}

# $pyVersion is the Python version that will be downloaded
$pyVersion = "3.9.5"
# $pythonSavePath is place where the Python installer will be downloaded on disk
$pythonSavePath = "~\Downloads\python-$pyVersion-amd64.exe"
# $pythonInstallHash is the hash used to verify the Python installer download
$pythonInstallHash = "53a354a15baed952ea9519a7f4d87c3f"
# $pyEXEUrl is the url where the Python installer will be obtained
$pyEXEUrl = "https://www.python.org/ftp/python/$pyVersion/python-$pyVersion-amd64.exe"

# Install Chocoately. Borrowed from https://tseknet.com/blog/chocolatey
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Force
iwr https://chocolatey.org/install.ps1 -UseBasicParsing | iex
# Install Windows ADK
choco install windows-adk -y
choco install windows-adk-winpe -y

# Install OSD Powershell Module. This isn't idempotent yet.
(Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force) -and (Install-Module OSD -Force)
# Import the module. This isn't idempotent yet
Import-Module OSD

# Create OSDCloud template if not created yet.
if ((Get-OSDCloud.template) -eq "C:\ProgramData\OSDCloud") { 
    Write-Host "'NEW-OSDCloud.template -WinRE -Verbose' already completed"
} else {
    Write-Host "Running 'NEW-OSDCloud.template -WinRE -Verbose'"
    New-OSDCloud.template -WinRE -Verbose
}

# Create OSDCloud workspace if not created yet.
if ((Get-OSDCloud.workspace) -eq "C:\OSDCloud") {
    Write-Host "'New-OSDCloud.workspace -WorkspacePath C:\OSDCloud' already completed"
} else {
    Write-Host "Running 'New-OSDCloud.workspace -WorkspacePath C:\OSDCloud'"
    New-OSDCloud.workspace -WorkspacePath C:\OSDCloud
}

# Download Python if needed
if ((Test-Path $pythonSavePath) -eq $False) {
    Write-Host "Downloading Python $pyVersion"
    curl $pyEXEUrl -UseBasicParsing -OutFile $pythonSavePath
} else {
    Write-Host "Python $pyVersion was already downloaded"
}

# Verify hash of Python installer
while ((Get-FileHash ($pythonSavePath) -Algorithm MD5).Hash -ne $pythonInstallHash) {
    Write-Host "Python hashes did not match. Removing and redownloading"
    rm $pythonSavePath
    curl $pyEXEUrl -UseBasicParsing -OutFile $pythonSavePath
}

# Add all of our drivers to WinPE. https://osdcloud.osdeploy.com/get-started/edit-osdcloud.winpe
# Edit-OSDCloud.winpe -DriverPath C:\drivers

# Mount our WIM. Borrowed from https://github.com/OSDeploy/OSD/blob/master/Public/OSDCloud/Edit-OSDCloud.winpe.ps1
$WorkspacePath = Get-OSDCloud.workspace -ErrorAction Stop
$MountMyWindowsImage = Mount-MyWindowsImage -ImagePath "$WorkspacePath\Media\Sources\boot.wim"
$MountPath = $MountMyWindowsImage.Path

# Add all the drivers. Copied from https://github.com/OSDeploy/OSD/blob/master/Public/OSDCloud/Edit-OSDCloud.winpe.ps1#L117-L119
foreach ($driver in $driver_path) {
    Add-WindowsDriver -Path "$($MountPath)" -Driver "$driver" -Recurse -ForceUnsigned
}

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

# Clone Glazier repository.
Write-Host "Cloning and pulling Glazier github repo..."
& 'C:\Program Files\Git\bin\git.exe' clone https://github.com/google/glazier.git C:\glazier
& 'C:\Program Files\Git\bin\git.exe' -C C:\glazier\ pull
Write-Host "Install Glazier pip requirements"
# Reload the path: https://stackoverflow.com/questions/17794507/reload-the-path-in-powershell
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User") 
# Install Glazier requirements
& $pyEXE -m pip install -r C:\glazier\requirements.txt
Write-Host "Running '$pyEXE -m pip install pywin32'"
# Install an additional Glazier dependency that isn't included in requirements.txt.
& $pyEXE -m pip install pywin32


# Recursively copy Glazier source code into WIM
Write-Host "Copying Glazier source code inside the image"
robocopy "C:\glazier\" "$MountPath\glazier\" /E

Write-Host "Copying autobuild.ps1 to WIM"
# Copy autobuild.ps1 into WIM
robocopy "$scriptPath\" "$MountPath\Windows\System32\" autobuild.ps1

# Write out Startnet.cmd, which will run when WinPE boots. In turn, this will launch autobuild.ps1 which will run autobuild.py (Glazier)
$Startnet = @"
wpeinit
start /wait PowerShell -NoL -C Start-WinREWiFi
powershell -NoProfile -NoLogo -Command Set-ExecutionPolicy -ExecutionPolicy Bypass -Force
powershell -NoProfile -NoLogo -WindowStyle Maximized -NoExit -File "X:\Windows\System32\autobuild.ps1" -config_root_path {0}
"@ -f $config_root_path
Write-Host "Writing Startnet.cmd"
# Save our changes to Startnet.cmd
$Startnet | Out-File -FilePath "$MountPath\Windows\System32\Startnet.cmd" -Force -Encoding ascii
Write-Host "Saving WIM"
# Dismount and save WIM
#Save-WindowsImage -Path $MountPath
$MountMyWindowsImage | Dismount-MyWindowsImage -Save
Write-Host "Creating ISO"
New-OSDCloud.iso
if ($make_usb) {
    Write-Host "Creating USB"
    New-OSDCloud.usb
}