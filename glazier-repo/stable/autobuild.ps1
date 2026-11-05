Param(
    [string] = "http://glazier"
)

if ( -eq "") {
   = "http://glazier"
}
 = .TrimEnd('/')
 = "windows-stable"

 = Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT'
 = if () { "X:" } else { "C:" }

.UI.RawUI.WindowTitle = 'Glazier'
:LOCALAPPDATA = ""
:PYTHONPATH = "\glazier"
:SSL_CERT_FILE = "\glazier-resources\ca-certs.crt"
Write-Output "Starting Glazier imaging process ()..."

 = @(
    "\glazier-resources\GlazierDeploymentGUI.ps1",
    "X:\glazier-resources\GlazierDeploymentGUI.ps1",
    "C:\glazier-resources\GlazierDeploymentGUI.ps1",
    ":SystemRoot\System32\GlazierDeploymentGUI.ps1",
    "\GlazierDeploymentGUI.ps1"
)
 = 
foreach ( in ) {
    if (Test-Path ) {
         = 
        break
    }
}

if () {
    . 
    Start-GlazierDeploymentGUI -ConfigServer  -GlazierSpecOS 
} else {
     = @(
        "\glazier\glazierutobuild.py",
        "--config_server=",
        "--resource_path=\glazier-resources",
        "--glazier_spec_os=",
        '--preserve_tasks=true'
    )
    & "\Python\python.exe" 
}
