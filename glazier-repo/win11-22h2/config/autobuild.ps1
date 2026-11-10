$config_server = "https://storage.googleapis.com/a1comms-glazier-config"
$glazier_spec_os = "win11-22h2"

$isWinPE = Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT'
$rootDrive = if ($isWinPE) { "X:" } else { "C:" }

$Host.UI.RawUI.WindowTitle = 'Glazier'
$env:LOCALAPPDATA = "$rootDrive\"
$env:PYTHONPATH = "$rootDrive\glazier\"
$env:SSL_CERT_FILE = "$rootDrive\glazier-resources\ca-certs.crt"
Write-Output "Starting Glazier imaging process ($glazier_spec_os)..."

function Test-GlazierIPv4Ready {
    try {
        $interfaces = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()
        foreach ($iface in $interfaces) {
            if ($iface.OperationalStatus.ToString() -eq "Up" -and
                $iface.NetworkInterfaceType.ToString() -ne "Loopback") {
                $ipProps = $iface.GetIPProperties()
                $hasGw = $false
                if ($ipProps -and $ipProps.GatewayAddresses) {
                    foreach ($gw in $ipProps.GatewayAddresses) {
                        if ($gw.Address -and $gw.Address.AddressFamily.ToString() -eq "InterNetwork" -and $gw.Address.ToString() -ne "0.0.0.0") {
                            $hasGw = $true
                            break
                        }
                    }
                }
                if ($hasGw -and $ipProps.UnicastAddresses) {
                    foreach ($uni in $ipProps.UnicastAddresses) {
                        if ($uni.Address -and $uni.Address.AddressFamily.ToString() -eq "InterNetwork") {
                            $ipStr = $uni.Address.ToString()
                            if ($ipStr -notlike "169.254.*" -and $ipStr -notlike "127.*" -and $ipStr -ne "0.0.0.0") {
                                return $true
                            }
                        }
                    }
                }
            }
        }
    } catch {}
    return $false
}

function Invoke-GlazierFastDownload {
    param([string]$Url, [string]$OutPath)
    $resp = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Timeout = 3000
        $req.ReadWriteTimeout = 3000
        $resp = $req.GetResponse()
        $inStream = $resp.GetResponseStream()
        $outStream = [System.IO.File]::Create($OutPath)
        try {
            $inStream.CopyTo($outStream)
        } finally {
            if ($outStream) { $outStream.Dispose() }
            if ($inStream) { $inStream.Dispose() }
        }
        return $true
    } catch {
        return $false
    } finally {
        if ($resp) {
            try { $resp.Close() } catch {}
            try { $resp.Dispose() } catch {}
        }
    }
}

# Connect Wi-Fi or verify IPv4 before attempting pre-GUI self-heal downloads
if (-not (Test-GlazierIPv4Ready)) {
    $wifiScriptCandidates = @(
        "$rootDrive\glazier-resources\GlazierWiFi.ps1",
        "C:\glazier-resources\GlazierWiFi.ps1",
        "X:\glazier-resources\GlazierWiFi.ps1",
        "$env:SystemRoot\System32\GlazierWiFi.ps1"
    )
    $wScript = $wifiScriptCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($wScript) {
        try {
            . $wScript
            if (Get-Command Invoke-GlazierWiFiAutoConnect -ErrorAction SilentlyContinue) {
                Invoke-GlazierWiFiAutoConnect -ProfileDirs @("$rootDrive\glazier-resources\wifi_profiles", "C:\glazier-resources\wifi_profiles") -TimeoutSeconds 6 | Out-Null
            }
        } catch {}
    }
}

if (Test-GlazierIPv4Ready) {
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
        if (Invoke-GlazierFastDownload -Url $remoteGuiUrl -OutPath $tmpGuiPath) {
            if ((Test-Path $tmpGuiPath) -and (Get-Item $tmpGuiPath).Length -gt 1024) {
                $content = Get-Content -Path $tmpGuiPath -Raw -ErrorAction SilentlyContinue
                if ($content -and $content -match 'Start-GlazierDeploymentGUI') {
                    Move-Item -Path $tmpGuiPath -Destination $targetGuiPath -Force
                }
            }
        }
        $remoteWifiUrl = "$($config_server.TrimEnd('/'))/glazier-resources/GlazierWiFi.ps1"
        $targetWifiPath = "$targetGuiDir\GlazierWiFi.ps1"
        $tmpWifiPath = "$env:TEMP\GlazierWiFi.ps1.tmp"
        if (Test-Path $tmpWifiPath) { Remove-Item $tmpWifiPath -Force -ErrorAction SilentlyContinue }
        if (Invoke-GlazierFastDownload -Url $remoteWifiUrl -OutPath $tmpWifiPath) {
            if ((Test-Path $tmpWifiPath) -and (Get-Item $tmpWifiPath).Length -gt 1024) {
                $wifiContent = Get-Content -Path $tmpWifiPath -Raw -ErrorAction SilentlyContinue
                if ($wifiContent -and $wifiContent -match 'GlazierNativeWlan') {
                    Move-Item -Path $tmpWifiPath -Destination $targetWifiPath -Force
                }
            }
        }
    } catch {
    } finally {
        if (Test-Path $tmpGuiPath) { Remove-Item $tmpGuiPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path $tmpWifiPath) { Remove-Item $tmpWifiPath -Force -ErrorAction SilentlyContinue }
    }
}

$guiCandidates = @(
    "$rootDrive\glazier-resources\GlazierDeploymentGUI.ps1",
    "C:\glazier-resources\GlazierDeploymentGUI.ps1",
    "X:\glazier-resources\GlazierDeploymentGUI.ps1",
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
    Start-GlazierDeploymentGUI -ConfigServer $config_server -GlazierSpecOS $glazier_spec_os -ConfigRootPath "/config"
} else {
    $py_args = @(
        "$rootDrive\glazier\glazier\autobuild.py",
        "--config_server=$config_server",
        "--config_root_path=/config",
        "--resource_path=$rootDrive\glazier-resources",
        "--glazier_spec_os=$glazier_spec_os",
        '--preserve_tasks=true'
    )
    & "$rootDrive\Python\python.exe" $py_args
}
