Param(
    [string]$config_server = "http://glazier",
    [string]$glazier_spec_os = "windows-stable-enterprise"
)

if ($config_server -eq "") {
  $config_server = "http://glazier"
}
if ($glazier_spec_os -eq "") {
  $glazier_spec_os = "windows-stable-enterprise"
}
$config_server = $config_server.TrimEnd('/')

$isWinPE = Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT'
$rootDrive = if ($isWinPE) { "X:" } else { "C:" }

$Host.UI.RawUI.WindowTitle = 'Glazier'
$env:LOCALAPPDATA = "$rootDrive\"
$env:PYTHONPATH = "$rootDrive\glazier\"
$env:SSL_CERT_FILE = "$rootDrive\glazier-resources\ca-certs.crt"
Write-Output "Starting Glazier imaging process ($glazier_spec_os)..."

try {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 -bor 12288
    } catch {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
    $remoteGuiUrl = "$($config_server.TrimEnd('/'))/glazier-resources/GlazierDeploymentGUI.ps1"
    $targetGuiDir = "$rootDrive\glazier-resources"
    $targetGuiPath = "$targetGuiDir\GlazierDeploymentGUI.ps1"
    $tmpGuiPath = "$env:TEMP\GlazierDeploymentGUI.ps1.tmp"
    if (Test-Path $tmpGuiPath) { Remove-Item $tmpGuiPath -Force -ErrorAction SilentlyContinue }
    if (-not (Test-Path $targetGuiDir)) {
        New-Item -ItemType Directory -Path $targetGuiDir -Force | Out-Null
    }
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($remoteGuiUrl, $tmpGuiPath)
    if ((Test-Path $tmpGuiPath) -and (Get-Item $tmpGuiPath).Length -gt 1024) {
        $content = Get-Content -Path $tmpGuiPath -Raw -ErrorAction SilentlyContinue
        if ($content -and $content -match 'Start-GlazierDeploymentGUI') {
            Move-Item -Path $tmpGuiPath -Destination $targetGuiPath -Force
        }
    }
    $remoteWifiUrl = "$($config_server.TrimEnd('/'))/glazier-resources/GlazierWiFi.ps1"
    $targetWifiPath = "$targetGuiDir\GlazierWiFi.ps1"
    $tmpWifiPath = "$env:TEMP\GlazierWiFi.ps1.tmp"
    if (Test-Path $tmpWifiPath) { Remove-Item $tmpWifiPath -Force -ErrorAction SilentlyContinue }
    try {
        $wc.DownloadFile($remoteWifiUrl, $tmpWifiPath)
        if ((Test-Path $tmpWifiPath) -and (Get-Item $tmpWifiPath).Length -gt 1024) {
            $wifiContent = Get-Content -Path $tmpWifiPath -Raw -ErrorAction SilentlyContinue
            if ($wifiContent -and $wifiContent -match 'GlazierNativeWlan') {
                Move-Item -Path $tmpWifiPath -Destination $targetWifiPath -Force
            }
        }
    } catch {
    } finally {
        if (Test-Path $tmpWifiPath) { Remove-Item $tmpWifiPath -Force -ErrorAction SilentlyContinue }
    }
} catch {
} finally {
    if (Test-Path $tmpGuiPath) { Remove-Item $tmpGuiPath -Force -ErrorAction SilentlyContinue }
    if (Test-Path $tmpWifiPath) { Remove-Item $tmpWifiPath -Force -ErrorAction SilentlyContinue }
}

$guiCandidates = @(
    "$rootDrive\glazier-resources\GlazierDeploymentGUI.ps1",
    "X:\glazier-resources\GlazierDeploymentGUI.ps1",
    "C:\glazier-resources\GlazierDeploymentGUI.ps1",
    "$env:SystemRoot\System32\GlazierDeploymentGUI.ps1",
    "$PSScriptRoot\GlazierDeploymentGUI.ps1"
)
$guiScript = $null
foreach ($cand in $guiCandidates) {
    if (Test-Path $cand) {
        $guiScript = $cand
        break
    }
}

if ($guiScript) {
    . $guiScript
    Start-GlazierDeploymentGUI -ConfigServer $config_server -GlazierSpecOS $glazier_spec_os
} else {
    $py_args = @(
        "$rootDrive\glazier\glazier\autobuild.py",
        "--config_server=$config_server",
        "--resource_path=$rootDrive\glazier-resources",
        "--glazier_spec_os=$glazier_spec_os",
        '--preserve_tasks=true'
    )
    & "$rootDrive\Python\python.exe" $py_args
}
