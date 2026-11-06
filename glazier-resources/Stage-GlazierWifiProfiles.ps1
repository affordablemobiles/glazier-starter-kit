# Stage Wi-Fi profiles from WinPE RAM (X:\glazier-resources\wifi_profiles)
# into the target Windows installation (C:\Windows\Setup\Scripts\wifi_profiles)
# and configure C:\Windows\Setup\Scripts\SetupComplete.cmd so Windows Setup
# connects to Wi-Fi before OOBE or AutoLogon starts.

$sourceDirs = @(
    "X:\glazier-resources\wifi_profiles",
    "C:\glazier-resources\wifi_profiles"
)

$profiles = @()
foreach ($sDir in $sourceDirs) {
    if (Test-Path $sDir) {
        $found = Get-ChildItem -Path $sDir -Filter "*.xml" -ErrorAction SilentlyContinue
        if ($found) {
            $profiles += $found
        }
    }
}

if (-not $profiles -or $profiles.Count -eq 0) {
    Write-Output "No Wi-Fi profiles found in WinPE RAM or cache to stage. Skipping SetupComplete.cmd configuration."
    exit 0
}

$destDir = "C:\Windows\Setup\Scripts\wifi_profiles"
if (-not (Test-Path $destDir)) {
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
}

$copiedCount = 0
foreach ($pf in $profiles) {
    $targetFile = Join-Path $destDir $pf.Name
    if (-not (Test-Path $targetFile)) {
        Copy-Item -Path $pf.FullName -Destination $targetFile -Force -ErrorAction SilentlyContinue
        $copiedCount++
    }
}
Write-Output "Staged $copiedCount Wi-Fi profile(s) to $destDir."

$scriptsDir = "C:\Windows\Setup\Scripts"
if (-not (Test-Path $scriptsDir)) {
    New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null
}

$setupCompletePath = Join-Path $scriptsDir "SetupComplete.cmd"

$setupCompleteSnippet = @'
net start WlanSvc >nul 2>&1
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "for ($i=0; $i -lt 15; $i++) { if ((& netsh.exe wlan show interfaces) -match 'Name\s*:') { break }; Start-Sleep -Seconds 1 }; Get-ChildItem 'C:\Windows\Setup\Scripts\wifi_profiles\*.xml' -ErrorAction SilentlyContinue | ForEach-Object { $fn = $_.FullName; & netsh.exe wlan add profile ('filename=' + $fn) user=all | Out-Null; [xml]$x = Get-Content $fn -Raw; if ($x.WLANProfile.name) { $pn = $x.WLANProfile.name; & netsh.exe wlan connect ('name=' + $pn) | Out-Null }; Remove-Item $fn -Force -ErrorAction SilentlyContinue }; Remove-Item 'C:\Windows\Setup\Scripts\wifi_profiles' -Recurse -Force -ErrorAction SilentlyContinue"
'@

if (Test-Path $setupCompletePath) {
    $existing = Get-Content -Path $setupCompletePath -Raw -ErrorAction SilentlyContinue
    if ($existing -notmatch 'wifi_profiles') {
        Add-Content -Path $setupCompletePath -Value "`r`n$setupCompleteSnippet" -Encoding ASCII
        Write-Output "Appended Wi-Fi auto-import snippet to existing $setupCompletePath."
    } else {
        Write-Output "Wi-Fi auto-import snippet already present in $setupCompletePath."
    }
} else {
    $newContent = "@echo off`r`n$setupCompleteSnippet`r`n"
    [System.IO.File]::WriteAllText($setupCompletePath, $newContent, [System.Text.Encoding]::ASCII)
    Write-Output "Created $setupCompletePath with Wi-Fi auto-import snippet."
}

exit 0
