$config_server = "https://storage.googleapis.com/a1comms-glazier-config"
$glazier_spec_os = "windows-stable-gcpw"

$isWinPE = Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT'
$rootDrive = if ($isWinPE) { "X:" } else { "C:" }

$Host.UI.RawUI.WindowTitle = 'Glazier'
$env:LOCALAPPDATA = "$rootDrive\"
$env:PYTHONPATH = "$rootDrive\glazier\"
$env:SSL_CERT_FILE = "$rootDrive\glazier-resources\ca-certs.crt"
Write-Output "Starting Glazier imaging process ($glazier_spec_os)..."

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
