Param(
    [string]$config_server = "http://glazier",
    [string]$glazier_spec_os = "windows-blank"
)

if ($config_server -eq "") {
  $config_server = "http://glazier"
}
if ($glazier_spec_os -eq "") {
  $glazier_spec_os = "windows-blank"
}
$config_server = $config_server.TrimEnd('/')

$isWinPE = Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT'
$rootDrive = if ($isWinPE) { "X:" } else { "C:" }

$Host.UI.RawUI.WindowTitle = 'Glazier'
$env:LOCALAPPDATA = "$rootDrive\"
$env:PYTHONPATH = "$rootDrive\glazier\"
$env:SSL_CERT_FILE = "$rootDrive\glazier-resources\ca-certs.crt"
Write-Output "Starting Glazier imaging process ($glazier_spec_os)..."

if ($isWinPE) {
    try {
        $remoteGuiUrl = "$($config_server.TrimEnd('/'))/glazier-resources/GlazierDeploymentGUI.ps1"
        $targetGuiPath = "X:\glazier-resources\GlazierDeploymentGUI.ps1"
        if (-not (Test-Path "X:\glazier-resources")) {
            New-Item -ItemType Directory -Path "X:\glazier-resources" -Force | Out-Null
        }
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($remoteGuiUrl, $targetGuiPath)
    } catch {}
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
