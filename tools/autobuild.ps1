Param(
    [string]$config_server = "http://glazier",
    [string]$glazier_spec_os = "windows-stable"
)

if ($config_server -eq "") {
  $config_server = "http://glazier"
}
if ($glazier_spec_os -eq "") {
  $glazier_spec_os = "windows-stable"
}

$Host.UI.RawUI.WindowTitle = 'Glazier'
$env:LOCALAPPDATA = 'X:\'
$env:PYTHONPATH = 'X:\glazier\'
$env:SSL_CERT_FILE = 'X:\glazier-resources\ca-certs.crt'
Write-Output "Starting Glazier imaging process ($glazier_spec_os)..."

# For a full list of Glazier flags, execute `python autobuild.py --helpfull`
$py_args = @(
  "X:\glazier\glazier\autobuild.py",
  "--config_server=$config_server",
  '--resource_path=X:\glazier-resources',
  "--glazier_spec_os=$glazier_spec_os",
  '--preserve_tasks=true'
)

& X:\Python\python.exe $py_args
