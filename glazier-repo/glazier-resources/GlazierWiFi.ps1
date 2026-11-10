Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

$wlanNativeTypeDef = @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class WlanInterfaceInfo {
    public Guid InterfaceGuid;
    public string Description;
    public int State;
}

public class WlanAvailableNetworkInfo {
    public string SSID;
    public uint SignalQuality;
    public bool SecurityEnabled;
    public uint AuthAlgorithm;
    public string AuthAlgorithmName;
    public uint CipherAlgorithm;
    public string CipherAlgorithmName;
    public uint Flags;
    public string ProfileName;
}

public class GlazierNativeWlan {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WLAN_INTERFACE_INFO {
        public Guid InterfaceGuid;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string strInterfaceDescription;
        public int isState;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WLAN_PROFILE_INFO {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string strProfileName;
        public uint dwFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DOT11_SSID {
        public uint uSSIDLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)]
        public byte[] ucSSID;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WLAN_AVAILABLE_NETWORK {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string strProfileName;
        public DOT11_SSID dot11Ssid;
        public int dot11BssType;
        public uint uNumberOfBssids;
        [MarshalAs(UnmanagedType.Bool)]
        public bool bNetworkConnectable;
        public uint wlanNotConnectableReason;
        public uint uNumberOfPhyTypes;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 8)]
        public uint[] dot11PhyTypes;
        [MarshalAs(UnmanagedType.Bool)]
        public bool bMorePhyTypes;
        public uint wlanSignalQuality;
        [MarshalAs(UnmanagedType.Bool)]
        public bool bSecurityEnabled;
        public uint dot11DefaultAuthAlgorithm;
        public uint dot11DefaultCipherAlgorithm;
        public uint dwFlags;
        public uint dwReserved;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WLAN_CONNECTION_PARAMETERS {
        public int wlanConnectionMode;
        [MarshalAs(UnmanagedType.LPWStr)]
        public string strProfile;
        public IntPtr pDot11Ssid;
        public IntPtr pDesiredBssidList;
        public int dot11BssType;
        public uint dwFlags;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WLAN_ASSOCIATION_ATTRIBUTES {
        public DOT11_SSID dot11Ssid;
        public int dot11BssType;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 6)]
        public byte[] dot11Bssid;
        public int dot11PhyType;
        public uint uDot11PhyIndex;
        public uint wlanSignalQuality;
        public uint ulRxRate;
        public uint ulTxRate;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WLAN_SECURITY_ATTRIBUTES {
        [MarshalAs(UnmanagedType.Bool)]
        public bool bSecurityEnabled;
        [MarshalAs(UnmanagedType.Bool)]
        public bool bOneXEnabled;
        public uint dot11AuthAlgorithm;
        public uint dot11CipherAlgorithm;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WLAN_CONNECTION_ATTRIBUTES {
        public int isState;
        public int wlanConnectionMode;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string strProfileName;
        public WLAN_ASSOCIATION_ATTRIBUTES wlanAssociationAttributes;
        public WLAN_SECURITY_ATTRIBUTES wlanSecurityAttributes;
    }

    [DllImport("wlanapi.dll", SetLastError = true)]
    public static extern uint WlanOpenHandle(
        uint dwClientVersion,
        IntPtr pReserved,
        out uint pdwNegotiatedVersion,
        out IntPtr phClient);

    [DllImport("wlanapi.dll", SetLastError = true)]
    public static extern uint WlanCloseHandle(
        IntPtr hClient,
        IntPtr pReserved);

    [DllImport("wlanapi.dll")]
    public static extern void WlanFreeMemory(IntPtr pMemory);

    [DllImport("wlanapi.dll", SetLastError = true)]
    public static extern uint WlanEnumInterfaces(
        IntPtr hClient,
        IntPtr pReserved,
        out IntPtr ppInterfaceList);

    [DllImport("wlanapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern uint WlanGetProfileList(
        IntPtr hClient,
        ref Guid interfaceGuid,
        IntPtr pReserved,
        out IntPtr ppProfileList);

    [DllImport("wlanapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern uint WlanGetProfile(
        IntPtr hClient,
        ref Guid interfaceGuid,
        [MarshalAs(UnmanagedType.LPWStr)] string strProfileName,
        IntPtr pReserved,
        out IntPtr pstrProfileXml,
        ref uint pdwFlags,
        out uint pdwGrantedAccess);

    [DllImport("wlanapi.dll", SetLastError = true)]
    public static extern uint WlanScan(
        IntPtr hClient,
        ref Guid interfaceGuid,
        IntPtr pDot11Ssid,
        IntPtr pIeData,
        IntPtr pReserved);

    [DllImport("wlanapi.dll", SetLastError = true)]
    public static extern uint WlanGetAvailableNetworkList(
        IntPtr hClient,
        ref Guid interfaceGuid,
        uint dwFlags,
        IntPtr pReserved,
        out IntPtr ppAvailableNetworkList);

    [DllImport("wlanapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern uint WlanSetProfile(
        IntPtr hClient,
        ref Guid interfaceGuid,
        uint dwFlags,
        string strProfileXml,
        string strAllUserProfileSecurity,
        bool bOverwrite,
        IntPtr pReserved,
        out uint pdwReasonCode);

    [DllImport("wlanapi.dll", CharSet = CharSet.Unicode)]
    public static extern uint WlanReasonCodeToString(
        uint dwReasonCode,
        int dwBufferSize,
        StringBuilder pStringBuffer,
        IntPtr pReserved);

    [DllImport("wlanapi.dll", SetLastError = true)]
    public static extern uint WlanConnect(
        IntPtr hClient,
        ref Guid interfaceGuid,
        ref WLAN_CONNECTION_PARAMETERS pConnectionParameters,
        IntPtr pReserved);

    [DllImport("wlanapi.dll", SetLastError = true)]
    public static extern uint WlanQueryInterface(
        IntPtr hClient,
        ref Guid interfaceGuid,
        int opCode,
        IntPtr pReserved,
        out uint pdwDataSize,
        out IntPtr ppData,
        IntPtr pWlanOpcodeValueType);

    [StructLayout(LayoutKind.Sequential)]
    public struct SYSTEM_POWER_STATUS {
        public byte ACLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public int BatteryLifeTime;
        public int BatteryFullLifeTime;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS lpSystemPowerStatus);

    public static bool GetPowerStatus(out SYSTEM_POWER_STATUS sps) {
        return GetSystemPowerStatus(out sps);
    }

    public static string GetAuthAlgorithmName(uint auth) {
        switch (auth) {
            case 1: return "Open";
            case 2: return "Shared";
            case 3: return "WPA-Enterprise";
            case 4: return "WPA-Personal";
            case 5: return "WPA-None";
            case 6: return "WPA2-Enterprise";
            case 7: return "WPA2-Personal";
            case 8: return "WPA3-Enterprise";
            case 9: return "WPA3-Personal";
            case 10: return "OWE";
            default: return "Unknown (" + auth + ")";
        }
    }

    public static string GetCipherAlgorithmName(uint cipher) {
        switch (cipher) {
            case 0: return "None";
            case 1: return "WEP40";
            case 2: return "TKIP";
            case 4: return "AES";
            case 5: return "WEP104";
            case 8: return "GCMP";
            case 9: return "GCMP-256";
            default: return "Unknown (" + cipher + ")";
        }
    }

    public static string ReasonCodeToString(uint pdwReasonCode) {
        if (pdwReasonCode == 0) return "Success";
        StringBuilder sb = new StringBuilder(1024);
        uint ret = WlanReasonCodeToString(pdwReasonCode, 1024, sb, IntPtr.Zero);
        if (ret == 0) {
            return sb.ToString();
        }
        return "Reason code: " + pdwReasonCode;
    }

    public static WlanInterfaceInfo[] EnumInterfaces() {
        IntPtr hClient = IntPtr.Zero;
        IntPtr pList = IntPtr.Zero;
        uint negVer = 0;
        var result = new List<WlanInterfaceInfo>();

        try {
            uint ret = WlanOpenHandle(2, IntPtr.Zero, out negVer, out hClient);
            if (ret != 0) return result.ToArray();

            ret = WlanEnumInterfaces(hClient, IntPtr.Zero, out pList);
            if (ret != 0 || pList == IntPtr.Zero) return result.ToArray();

            uint count = (uint)Marshal.ReadInt32(pList);
            int infoSize = Marshal.SizeOf(typeof(WLAN_INTERFACE_INFO));
            long basePtr = pList.ToInt64() + 8;

            for (int i = 0; i < count; i++) {
                IntPtr itemPtr = new IntPtr(basePtr + (i * infoSize));
                var info = (WLAN_INTERFACE_INFO)Marshal.PtrToStructure(itemPtr, typeof(WLAN_INTERFACE_INFO));
                result.Add(new WlanInterfaceInfo {
                    InterfaceGuid = info.InterfaceGuid,
                    Description = info.strInterfaceDescription,
                    State = info.isState
                });
            }
        } catch {
        } finally {
            if (pList != IntPtr.Zero) WlanFreeMemory(pList);
            if (hClient != IntPtr.Zero) WlanCloseHandle(hClient, IntPtr.Zero);
        }

        return result.ToArray();
    }

    public static bool TriggerScan(Guid interfaceGuid) {
        IntPtr hClient = IntPtr.Zero;
        uint negVer = 0;
        try {
            uint ret = WlanOpenHandle(2, IntPtr.Zero, out negVer, out hClient);
            if (ret != 0) return false;
            uint scanRet = WlanScan(hClient, ref interfaceGuid, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            return scanRet == 0;
        } catch {
            return false;
        } finally {
            if (hClient != IntPtr.Zero) WlanCloseHandle(hClient, IntPtr.Zero);
        }
    }

    public static WlanAvailableNetworkInfo[] GetAvailableNetworks(Guid interfaceGuid) {
        IntPtr hClient = IntPtr.Zero;
        IntPtr pList = IntPtr.Zero;
        uint negVer = 0;
        var map = new Dictionary<string, WlanAvailableNetworkInfo>();

        try {
            uint ret = WlanOpenHandle(2, IntPtr.Zero, out negVer, out hClient);
            if (ret != 0) return new WlanAvailableNetworkInfo[0];

            ret = WlanGetAvailableNetworkList(hClient, ref interfaceGuid, 3, IntPtr.Zero, out pList);
            if (ret != 0 || pList == IntPtr.Zero) return new WlanAvailableNetworkInfo[0];

            uint count = (uint)Marshal.ReadInt32(pList);
            int itemSize = Marshal.SizeOf(typeof(WLAN_AVAILABLE_NETWORK));
            long basePtr = pList.ToInt64() + 8;

            for (int i = 0; i < count; i++) {
                IntPtr itemPtr = new IntPtr(basePtr + (i * itemSize));
                var net = (WLAN_AVAILABLE_NETWORK)Marshal.PtrToStructure(itemPtr, typeof(WLAN_AVAILABLE_NETWORK));

                string ssidStr = "";
                if (net.dot11Ssid.uSSIDLength > 0 && net.dot11Ssid.ucSSID != null) {
                    int len = (int)Math.Min((long)net.dot11Ssid.uSSIDLength, (long)net.dot11Ssid.ucSSID.Length);
                    ssidStr = Encoding.UTF8.GetString(net.dot11Ssid.ucSSID, 0, len);
                }

                if (string.IsNullOrEmpty(ssidStr) && !string.IsNullOrEmpty(net.strProfileName)) {
                    ssidStr = net.strProfileName;
                }
                if (string.IsNullOrEmpty(ssidStr)) {
                    continue;
                }

                var item = new WlanAvailableNetworkInfo {
                    SSID = ssidStr,
                    ProfileName = net.strProfileName,
                    SignalQuality = net.wlanSignalQuality,
                    SecurityEnabled = net.bSecurityEnabled,
                    AuthAlgorithm = net.dot11DefaultAuthAlgorithm,
                    AuthAlgorithmName = GetAuthAlgorithmName(net.dot11DefaultAuthAlgorithm),
                    CipherAlgorithm = net.dot11DefaultCipherAlgorithm,
                    CipherAlgorithmName = GetCipherAlgorithmName(net.dot11DefaultCipherAlgorithm),
                    Flags = net.dwFlags
                };

                if (map.ContainsKey(ssidStr)) {
                    if (item.SignalQuality > map[ssidStr].SignalQuality) {
                        map[ssidStr] = item;
                    }
                } else {
                    map[ssidStr] = item;
                }
            }
        } catch {
        } finally {
            if (pList != IntPtr.Zero) WlanFreeMemory(pList);
            if (hClient != IntPtr.Zero) WlanCloseHandle(hClient, IntPtr.Zero);
        }

        var list = new List<WlanAvailableNetworkInfo>(map.Values);
        list.Sort((a, b) => b.SignalQuality.CompareTo(a.SignalQuality));
        return list.ToArray();
    }

    public static bool SetProfile(Guid interfaceGuid, string profileXml, out uint pdwReasonCode) {
        IntPtr hClient = IntPtr.Zero;
        uint negVer = 0;
        pdwReasonCode = 0;
        try {
            uint ret = WlanOpenHandle(2, IntPtr.Zero, out negVer, out hClient);
            if (ret != 0) return false;
            uint setRet = WlanSetProfile(hClient, ref interfaceGuid, 0, profileXml, null, true, IntPtr.Zero, out pdwReasonCode);
            return setRet == 0;
        } catch {
            return false;
        } finally {
            if (hClient != IntPtr.Zero) WlanCloseHandle(hClient, IntPtr.Zero);
        }
    }

    public static bool Connect(Guid interfaceGuid, string profileName) {
        IntPtr hClient = IntPtr.Zero;
        uint negVer = 0;
        try {
            uint ret = WlanOpenHandle(2, IntPtr.Zero, out negVer, out hClient);
            if (ret != 0) return false;
            var connParams = new WLAN_CONNECTION_PARAMETERS {
                wlanConnectionMode = 0,
                strProfile = profileName,
                pDot11Ssid = IntPtr.Zero,
                pDesiredBssidList = IntPtr.Zero,
                dot11BssType = 3,
                dwFlags = 0
            };
            uint res = WlanConnect(hClient, ref interfaceGuid, ref connParams, IntPtr.Zero);
            return res == 0;
        } catch {
            return false;
        } finally {
            if (hClient != IntPtr.Zero) WlanCloseHandle(hClient, IntPtr.Zero);
        }
    }

    public static int GetInterfaceState(Guid interfaceGuid) {
        var ifaces = EnumInterfaces();
        foreach (var iface in ifaces) {
            if (iface.InterfaceGuid == interfaceGuid) {
                return iface.State;
            }
        }
        return -1;
    }

    public static string GetCurrentConnectionSSID(Guid interfaceGuid) {
        IntPtr hClient = IntPtr.Zero;
        IntPtr pData = IntPtr.Zero;
        uint negVer = 0;
        uint dataSize = 0;
        try {
            uint ret = WlanOpenHandle(2, IntPtr.Zero, out negVer, out hClient);
            if (ret != 0) return "";
            ret = WlanQueryInterface(hClient, ref interfaceGuid, 7, IntPtr.Zero, out dataSize, out pData, IntPtr.Zero);
            if (ret != 0 || pData == IntPtr.Zero) return "";
            var attrs = (WLAN_CONNECTION_ATTRIBUTES)Marshal.PtrToStructure(pData, typeof(WLAN_CONNECTION_ATTRIBUTES));
            if (attrs.wlanAssociationAttributes.dot11Ssid.uSSIDLength > 0 && attrs.wlanAssociationAttributes.dot11Ssid.ucSSID != null) {
                int len = (int)Math.Min((long)attrs.wlanAssociationAttributes.dot11Ssid.uSSIDLength, (long)attrs.wlanAssociationAttributes.dot11Ssid.ucSSID.Length);
                string ssid = Encoding.UTF8.GetString(attrs.wlanAssociationAttributes.dot11Ssid.ucSSID, 0, len);
                if (!string.IsNullOrEmpty(ssid)) return ssid;
            }
            if (!string.IsNullOrEmpty(attrs.strProfileName)) {
                return attrs.strProfileName;
            }
        } catch {
        } finally {
            if (pData != IntPtr.Zero) WlanFreeMemory(pData);
            if (hClient != IntPtr.Zero) WlanCloseHandle(hClient, IntPtr.Zero);
        }
        return "";
    }

    public static string[] GetProfilesXml(Guid interfaceGuid) {
        IntPtr hClient = IntPtr.Zero;
        IntPtr pList = IntPtr.Zero;
        uint negVer = 0;
        var result = new List<string>();

        try {
            uint ret = WlanOpenHandle(2, IntPtr.Zero, out negVer, out hClient);
            if (ret != 0) return result.ToArray();

            ret = WlanGetProfileList(hClient, ref interfaceGuid, IntPtr.Zero, out pList);
            if (ret != 0 || pList == IntPtr.Zero) return result.ToArray();

            uint count = (uint)Marshal.ReadInt32(pList);
            int itemSize = Marshal.SizeOf(typeof(WLAN_PROFILE_INFO));
            long basePtr = pList.ToInt64() + 8;

            for (int i = 0; i < count; i++) {
                IntPtr itemPtr = new IntPtr(basePtr + (i * itemSize));
                var info = (WLAN_PROFILE_INFO)Marshal.PtrToStructure(itemPtr, typeof(WLAN_PROFILE_INFO));
                if (string.IsNullOrEmpty(info.strProfileName)) continue;

                IntPtr pXml = IntPtr.Zero;
                uint flags = 4; // WLAN_PROFILE_GET_PLAINTEXT_KEY
                uint grantedAccess = 0;
                uint getRet = WlanGetProfile(hClient, ref interfaceGuid, info.strProfileName, IntPtr.Zero, out pXml, ref flags, out grantedAccess);
                if (getRet != 0) {
                    flags = 0;
                    getRet = WlanGetProfile(hClient, ref interfaceGuid, info.strProfileName, IntPtr.Zero, out pXml, ref flags, out grantedAccess);
                }

                if (getRet == 0 && pXml != IntPtr.Zero) {
                    try {
                        string xml = Marshal.PtrToStringUni(pXml);
                        if (!string.IsNullOrEmpty(xml)) {
                            result.Add(xml);
                        }
                    } finally {
                        WlanFreeMemory(pXml);
                    }
                }
            }
        } catch {
        } finally {
            if (pList != IntPtr.Zero) WlanFreeMemory(pList);
            if (hClient != IntPtr.Zero) WlanCloseHandle(hClient, IntPtr.Zero);
        }

        return result.ToArray();
    }
}
"@

if (-not ('GlazierNativeWlan' -as [type])) {
    Add-Type -TypeDefinition $wlanNativeTypeDef -ErrorAction SilentlyContinue
}

function New-GlazierWiFiProfileXml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SSID,
        [string]$Password = "",
        [string]$AuthType = "WPA2PSK",
        [bool]$IsHidden = $false
    )

    $ssidBytes = [System.Text.Encoding]::UTF8.GetBytes($SSID)
    $ssidHex = ($ssidBytes | ForEach-Object { $_.ToString("X2") }) -join ""
    $nonBroadcast = if ($IsHidden) { "true" } else { "false" }
    $escapedSSID = [System.Security.SecurityElement]::Escape($SSID)
    $escapedKey = [System.Security.SecurityElement]::Escape($Password)

    $secXml = ""
    switch -Regex ($AuthType) {
        '^(open|Open)$' {
            $secXml = @"
        <security>
            <authEncryption>
                <authentication>open</authentication>
                <encryption>none</encryption>
                <useOneX>false</useOneX>
            </authEncryption>
        </security>
"@
        }
        '^(OWE|owe)$' {
            $secXml = @"
        <security>
            <authEncryption>
                <authentication>OWE</authentication>
                <encryption>AES</encryption>
                <useOneX>false</useOneX>
            </authEncryption>
        </security>
"@
        }
        '^(WPAPSK|WPA|WPA-Personal)$' {
            $secXml = @"
        <security>
            <authEncryption>
                <authentication>WPAPSK</authentication>
                <encryption>TKIP</encryption>
                <useOneX>false</useOneX>
            </authEncryption>
            <sharedKey>
                <keyType>passPhrase</keyType>
                <protected>false</protected>
                <keyMaterial>$escapedKey</keyMaterial>
            </sharedKey>
        </security>
"@
        }
        '^(WPA3SAE|WPA3|WPA3-Personal)$' {
            $secXml = @"
        <security>
            <authEncryption>
                <authentication>WPA3SAE</authentication>
                <encryption>AES</encryption>
                <useOneX>false</useOneX>
                <transitionMode xmlns="http://www.microsoft.com/networking/WLAN/profile/v4">true</transitionMode>
            </authEncryption>
            <sharedKey>
                <keyType>passPhrase</keyType>
                <protected>false</protected>
                <keyMaterial>$escapedKey</keyMaterial>
            </sharedKey>
        </security>
"@
        }
        default {
            $secXml = @"
        <security>
            <authEncryption>
                <authentication>WPA2PSK</authentication>
                <encryption>AES</encryption>
                <useOneX>false</useOneX>
            </authEncryption>
            <sharedKey>
                <keyType>passPhrase</keyType>
                <protected>false</protected>
                <keyMaterial>$escapedKey</keyMaterial>
            </sharedKey>
        </security>
"@
        }
    }

    return @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
    <name>$escapedSSID</name>
    <SSIDConfig>
        <SSID>
            <hex>$ssidHex</hex>
            <name>$escapedSSID</name>
        </SSID>
        <nonBroadcast>$nonBroadcast</nonBroadcast>
    </SSIDConfig>
    <connectionType>ESS</connectionType>
    <connectionMode>auto</connectionMode>
    <MSM>
$secXml
    </MSM>
    <MacRandomization xmlns="http://www.microsoft.com/networking/WLAN/profile/v3">
        <enableRandomization>false</enableRandomization>
    </MacRandomization>
</WLANProfile>
"@
}

function Export-GlazierHostWiFiProfiles {
    param(
        [string]$OutputDir = "C:\sources\wifi_profiles"
    )

    $wlanSvc = Get-Service -Name WlanSvc -ErrorAction SilentlyContinue
    if ($wlanSvc -and $wlanSvc.Status -ne 'Running') {
        Start-Service -Name WlanSvc -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    $ifaces = [GlazierNativeWlan]::EnumInterfaces()
    if (-not $ifaces -or $ifaces.Count -eq 0) {
        return @()
    }

    $exportedFiles = @()
    foreach ($iface in $ifaces) {
        $xmlList = [GlazierNativeWlan]::GetProfilesXml($iface.InterfaceGuid)
        foreach ($xmlStr in $xmlList) {
            try {
                [xml]$wx = $xmlStr
                if (-not $wx -or -not $wx.WLANProfile) { continue }
                $auth = [string]$wx.WLANProfile.MSM.security.authEncryption.authentication
                $oneX = [string]$wx.WLANProfile.MSM.security.authEncryption.useOneX
                if ($oneX -match '^(?i:true)$' -or ($auth -and $auth -notin @('WPAPSK', 'WPA2PSK', 'WPA3SAE', 'WPA', 'WPA2', 'open', 'OWE'))) {
                    continue
                }
                $ssid = if ($wx.WLANProfile.SSIDConfig.SSID.name) { [string]$wx.WLANProfile.SSIDConfig.SSID.name } else { [string]$wx.WLANProfile.name }
                if (-not $ssid) { continue }
                $key = [string]$wx.WLANProfile.MSM.security.sharedKey.keyMaterial
                $isHidden = ([string]$wx.WLANProfile.SSIDConfig.nonBroadcast -eq 'true')
                if (-not $auth) {
                    $auth = if ($key) { "WPA2PSK" } else { "open" }
                }

                $cleanXml = New-GlazierWiFiProfileXml -SSID $ssid -Password $key -AuthType $auth -IsHidden $isHidden
                $safeFileName = ($ssid -replace '[\\/:*?"<>|]', '_')
                $outPath = Join-Path $OutputDir "$safeFileName.xml"
                Set-Content -Path $outPath -Value $cleanXml -Encoding ASCII -Force
                $exportedFiles += $outPath
            } catch {}
        }
    }
    return $exportedFiles
}

function Get-GlazierPowerStatus {
    $sps = New-Object GlazierNativeWlan+SYSTEM_POWER_STATUS
    $ret = [GlazierNativeWlan]::GetPowerStatus([ref]$sps)
    if (-not $ret) {
        return [PSCustomObject]@{
            IsOnBattery    = $false
            ACLineStatus   = 255
            BatteryPercent = 255
        }
    }
    $isOnBattery = ($sps.ACLineStatus -eq 0 -and ($sps.BatteryFlag -band 128) -eq 0 -and $sps.BatteryFlag -ne 255)
    return [PSCustomObject]@{
        IsOnBattery    = $isOnBattery
        ACLineStatus   = [int]$sps.ACLineStatus
        BatteryPercent = [int]$sps.BatteryLifePercent
    }
}

function Wait-GlazierACPowerGUI {
    $pwr = Get-GlazierPowerStatus
    if (-not $pwr.IsOnBattery) {
        return $true
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "AC Power Required"
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $form.ClientSize = New-Object System.Drawing.Size(620, 300)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.ControlBox = $false
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)

    # 1. Amber/Red Warning Header Panel
    $panelHeader = New-Object System.Windows.Forms.Panel
    $panelHeader.Location = New-Object System.Drawing.Point(0, 0)
    $panelHeader.Size = New-Object System.Drawing.Size(620, 68)
    $panelHeader.BackColor = [System.Drawing.Color]::FromArgb(254, 243, 199)
    $form.Controls.Add($panelHeader)

    $lblBadge = New-Object System.Windows.Forms.Label
    $lblBadge.Text = "[!]"
    $lblBadge.Location = New-Object System.Drawing.Point(20, 18)
    $lblBadge.Size = New-Object System.Drawing.Size(36, 32)
    $lblBadge.Font = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $lblBadge.ForeColor = [System.Drawing.Color]::FromArgb(180, 83, 9)
    $panelHeader.Controls.Add($lblBadge)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "AC Power Required - Please Connect Charger"
    $lblTitle.Location = New-Object System.Drawing.Point(60, 20)
    $lblTitle.Size = New-Object System.Drawing.Size(540, 32)
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(180, 83, 9)
    $panelHeader.Controls.Add($lblTitle)

    # 2. Main Body Message
    $lblBody = New-Object System.Windows.Forms.Label
    $lblBody.Text = "This laptop is currently running on battery power. Please plug in the AC power adapter now to prevent firmware or OS installation failures."
    $lblBody.Location = New-Object System.Drawing.Point(28, 86)
    $lblBody.Size = New-Object System.Drawing.Size(564, 46)
    $lblBody.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $lblBody.ForeColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
    $form.Controls.Add($lblBody)

    # 3. Live Status Readout
    $lblStatus = New-Object System.Windows.Forms.Label
    $battText = if ($pwr.BatteryPercent -ne 255) { "$($pwr.BatteryPercent)%" } else { "Unknown" }
    $lblStatus.Text = "Battery Level: $battText - Waiting for AC power adapter..."
    $lblStatus.Location = New-Object System.Drawing.Point(28, 140)
    $lblStatus.Size = New-Object System.Drawing.Size(564, 26)
    $lblStatus.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
    $form.Controls.Add($lblStatus)

    # 4. 3-Panel Aero Shimmer Bar Pulsing in Amber (245, 158, 11)
    $trackW = 564
    $trackH = 20

    $progressTrack = New-Object System.Windows.Forms.Panel
    $progressTrack.Location = New-Object System.Drawing.Point(28, 178)
    $progressTrack.Size = New-Object System.Drawing.Size($trackW, $trackH)
    $progressTrack.BackColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
    $progressTrack.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $form.Controls.Add($progressTrack)

    $progressFill = New-Object System.Windows.Forms.Panel
    $progressFill.Location = New-Object System.Drawing.Point(0, 0)
    $progressFill.Size = New-Object System.Drawing.Size([int]($trackW * 0.4), $trackH)
    $progressFill.BackColor = [System.Drawing.Color]::FromArgb(245, 158, 11)
    $progressTrack.Controls.Add($progressFill)

    $progressPulse = New-Object System.Windows.Forms.Panel
    $progressPulse.Location = New-Object System.Drawing.Point(-70, 0)
    $progressPulse.Size = New-Object System.Drawing.Size(70, $trackH)
    $progressPulse.BackColor = [System.Drawing.Color]::FromArgb(251, 191, 36)
    $progressFill.Controls.Add($progressPulse)

    $progressPulseCore = New-Object System.Windows.Forms.Panel
    $progressPulseCore.Location = New-Object System.Drawing.Point(20, 0)
    $progressPulseCore.Size = New-Object System.Drawing.Size(30, $trackH)
    $progressPulseCore.BackColor = [System.Drawing.Color]::FromArgb(253, 230, 138)
    $progressPulse.Controls.Add($progressPulseCore)

    # 5. Bottom Continue on Battery Button
    $btnContinueBattery = New-Object System.Windows.Forms.Button
    $btnContinueBattery.Text = "Continue on Battery (Not Recommended)"
    $btnContinueBattery.Location = New-Object System.Drawing.Point(340, 230)
    $btnContinueBattery.Size = New-Object System.Drawing.Size(252, 38)
    $btnContinueBattery.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnContinueBattery.BackColor = [System.Drawing.Color]::FromArgb(240, 242, 245)
    $btnContinueBattery.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
    $btnContinueBattery.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $btnContinueBattery.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
    $btnContinueBattery.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
    $form.Controls.Add($btnContinueBattery)

    $btnContinueBattery.Add_Click({
        $form.DialogResult = [System.Windows.Forms.DialogResult]::Ignore
        $form.Close()
    })

    $shimmerTimer = New-Object System.Windows.Forms.Timer
    $shimmerTimer.Interval = 50
    $script:pwrShimmerPos = -70
    $shimmerTimer.Add_Tick({
        $script:pwrShimmerPos = ($script:pwrShimmerPos + 16)
        if ($script:pwrShimmerPos -gt ($progressFill.Width + 70)) {
            $script:pwrShimmerPos = -70
        }
        $progressPulse.Left = $script:pwrShimmerPos
    })

    $checkTimer = New-Object System.Windows.Forms.Timer
    $checkTimer.Interval = 500

    $checkTimer.Add_Tick({
        $curPwr = Get-GlazierPowerStatus
        $bPct = if ($curPwr.BatteryPercent -ne 255) { "$($curPwr.BatteryPercent)%" } else { "Unknown" }

        if (-not $curPwr.IsOnBattery) {
            $checkTimer.Stop()
            $shimmerTimer.Stop()

            $panelHeader.BackColor = [System.Drawing.Color]::FromArgb(209, 250, 229)
            $lblBadge.Text = "[OK]"
            $lblBadge.ForeColor = [System.Drawing.Color]::FromArgb(4, 120, 87)
            $lblTitle.Text = "AC Power Connected"
            $lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(4, 120, 87)
            $lblStatus.Text = "AC Power Connected! Continuing deployment..."
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(4, 120, 87)

            $progressFill.Width = $trackW
            $progressFill.BackColor = [System.Drawing.Color]::FromArgb(16, 185, 129)
            $progressPulse.Visible = $false
            $btnContinueBattery.Enabled = $false

            $form.Refresh()
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 800

            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        } else {
            $lblStatus.Text = "Battery Level: $bPct - Waiting for AC power adapter..."
        }
    })

    $form.Add_FormClosing({
        param($sender, $e)
        if ($form.DialogResult -ne [System.Windows.Forms.DialogResult]::OK -and
            $form.DialogResult -ne [System.Windows.Forms.DialogResult]::Ignore) {
            $e.Cancel = $true
        }
    })

    $shimmerTimer.Start()
    $checkTimer.Start()

    $form.ShowDialog() | Out-Null

    $checkTimer.Stop()
    $shimmerTimer.Stop()
    $checkTimer.Dispose()
    $shimmerTimer.Dispose()
    $form.Dispose()

    return $true
}

function Test-GlazierInternetReachability {
    $endpoints = @('http://www.msftncsi.com/ncsi.txt', 'https://storage.googleapis.com')
    foreach ($url in $endpoints) {
        $resp = $null
        try {
            $req = [System.Net.HttpWebRequest]::Create($url)
            $req.Method = "HEAD"
            $req.Timeout = 1200
            $req.ReadWriteTimeout = 1200
            $req.AllowAutoRedirect = $false
            $resp = $req.GetResponse()
            try {
                $code = [int]$resp.StatusCode
                if ($code -ge 200 -and $code -lt 500) {
                    return $true
                }
            } finally {
                if ($resp) {
                    try { $resp.Close() } catch {}
                    try { $resp.Dispose() } catch {}
                }
            }
        } catch [System.Net.WebException] {
            if ($_.Response) {
                $code = [int]$_.Response.StatusCode
                if ($code -ge 200 -and $code -lt 500) {
                    return $true
                }
            }
        } catch {}
    }
    return $false
}

function Get-GlazierNetworkTelemetry {
    $wiredState = 'Red'
    $wiredDetail = 'No Wired Adapter'
    $wirelessState = 'Red'
    $wirelessDetail = 'No Wi-Fi Hardware'
    $hasHardware = $false
    $hasBoundDriver = $false
    $adapterName = ''
    $errorCode = 0
    $internetState = 'Red'
    $internetDetail = 'Offline'
    $activeIP = ''
    $activeInterface = ''

    # 1. Wired Inspection
    $wiredInterfaces = @()
    try {
        $allInterfaces = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()
        foreach ($nic in $allInterfaces) {
            $nicType = $nic.NetworkInterfaceType.ToString()
            $desc = $nic.Description
            if ($nicType -in @('Loopback', 'Tunnel', 'Wireless80211', 'Ppp') -or
                $desc -match 'Virtual|Hyper-V|vEthernet|Bluetooth|TAP|VPN|Loopback|Wireless|Wi-Fi|802\.11|WLAN') {
                continue
            }
            $wiredInterfaces += $nic
        }
    } catch {}

    if ($wiredInterfaces.Count -gt 0) {
        $upWired = $wiredInterfaces | Where-Object { $_.OperationalStatus.ToString() -eq 'Up' }
        if ($upWired) {
            $wiredState = 'Amber'
            $wiredDetail = 'Link Up - Waiting for DHCP...'
            foreach ($wnic in $upWired) {
                $ipProps = $wnic.GetIPProperties()
                $hasGw = $false
                if ($ipProps -and $ipProps.GatewayAddresses) {
                    foreach ($gw in $ipProps.GatewayAddresses) {
                        if ($gw.Address -and $gw.Address.AddressFamily.ToString() -eq 'InterNetwork' -and $gw.Address.ToString() -ne '0.0.0.0') {
                            $hasGw = $true
                            break
                        }
                    }
                }
                $validIp = $null
                if ($ipProps -and $ipProps.UnicastAddresses) {
                    foreach ($uni in $ipProps.UnicastAddresses) {
                        if ($uni.Address -and $uni.Address.AddressFamily.ToString() -eq 'InterNetwork') {
                            $ipStr = $uni.Address.ToString()
                            if ($ipStr -notlike '169.254.*' -and $ipStr -notlike '127.*' -and $ipStr -ne '0.0.0.0') {
                                $validIp = $ipStr
                                break
                            }
                        }
                    }
                }
                if ($validIp -and $hasGw) {
                    $wiredState = 'Green'
                    $wiredDetail = "Connected ($validIp)"
                    $activeIP = $validIp
                    $activeInterface = $wnic.Description
                    break
                }
            }
        } else {
            $wiredState = 'Red'
            $wiredDetail = 'Cable Unplugged'
        }
    }

    # 2. Wireless Inspection via PnP + NativeWlan
    try {
        $wlanIfaces = [GlazierNativeWlan]::EnumInterfaces()
        if ($wlanIfaces -and $wlanIfaces.Count -gt 0) {
            $hasHardware = $true
            $hasBoundDriver = $true
            $adapterName = $wlanIfaces[0].Description
        }
    } catch {}

    if (-not $hasHardware) {
        $now = [System.DateTime]::UtcNow
        if ($script:cachedPnpWifi -and $script:cachedPnpWifiTime -and (($now - $script:cachedPnpWifiTime).TotalSeconds -lt 5)) {
            $hasHardware = $script:cachedPnpWifi.HasHardware
            $hasBoundDriver = $script:cachedPnpWifi.HasBoundDriver
            $adapterName = $script:cachedPnpWifi.AdapterName
            $errorCode = $script:cachedPnpWifi.ErrorCode
        } else {
            try {
                $pnpDevs = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue)
                if (-not $pnpDevs -or $pnpDevs.Count -eq 0) {
                    $pnpDevs = @(Get-WmiObject Win32_PnPEntity -ErrorAction SilentlyContinue)
                }
                $matchingDevs = @()
                foreach ($dev in $pnpDevs) {
                    $cids = "$($dev.CompatibleID -join ' ') $($dev.HardwareID -join ' ') $($dev.DeviceID)"
                    $devName = "$($dev.Name) $($dev.Description)"
                    if ($devName -match 'Bluetooth|Wi-Fi Direct|WAN Miniport|Virtual|Hyper-V|TAP|VPN|RasSstp|AgileVPN' -or
                        $cids -match 'Bluetooth|Wi-Fi Direct|WAN Miniport|Virtual|Hyper-V|TAP|VPN|RasSstp|AgileVPN') {
                        continue
                    }
                    if ($cids -match 'CC_0280' -or $devName -match 'Wi-Fi|Wireless|802\.11|WLAN') {
                        $matchingDevs += $dev
                    }
                }
                if ($matchingDevs.Count -gt 0) {
                    $bestDev = $matchingDevs | Where-Object { [int]$_.ConfigManagerErrorCode -eq 0 } | Select-Object -First 1
                    if (-not $bestDev) {
                        $bestDev = $matchingDevs[0]
                    }
                    $hasHardware = $true
                    $adapterName = $bestDev.Name
                    $errorCode = [int]$bestDev.ConfigManagerErrorCode
                    if ($errorCode -eq 0) {
                        $hasBoundDriver = $true
                    } else {
                        $hasBoundDriver = $false
                    }
                }
            } catch {}

            $script:cachedPnpWifi = [PSCustomObject]@{
                HasHardware    = $hasHardware
                HasBoundDriver = $hasBoundDriver
                AdapterName    = $adapterName
                ErrorCode      = $errorCode
            }
            $script:cachedPnpWifiTime = $now
        }
    }

    if (-not $hasHardware) {
        $wirelessState = 'Red'
        $wirelessDetail = 'No Wi-Fi Hardware'
    } elseif (-not $hasBoundDriver) {
        $wirelessState = 'Red'
        $wirelessDetail = "Driver Missing (Code $errorCode)"
    } else {
        $wlanIfaces = @()
        try {
            $wlanIfaces = [GlazierNativeWlan]::EnumInterfaces()
        } catch {}

        if ($wlanIfaces -and $wlanIfaces.Count -gt 0) {
            $wIface = $wlanIfaces[0]
            $wState = $wIface.State

            $wValidIp = $null
            $wHasGw = $false
            try {
                $allNics = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()
                foreach ($nic in $allNics) {
                    if ($nic.NetworkInterfaceType.ToString() -eq 'Wireless80211' -or
                        $nic.Description -eq $wIface.Description -or
                        $nic.Id -eq $wIface.InterfaceGuid.ToString("B") -or
                        $nic.Id -eq $wIface.InterfaceGuid.ToString("D")) {
                        $ipProps = $nic.GetIPProperties()
                        if ($ipProps -and $ipProps.GatewayAddresses) {
                            foreach ($gw in $ipProps.GatewayAddresses) {
                                if ($gw.Address -and $gw.Address.AddressFamily.ToString() -eq 'InterNetwork' -and $gw.Address.ToString() -ne '0.0.0.0') {
                                    $wHasGw = $true
                                    break
                                }
                            }
                        }
                        if ($ipProps -and $ipProps.UnicastAddresses) {
                            foreach ($uni in $ipProps.UnicastAddresses) {
                                if ($uni.Address -and $uni.Address.AddressFamily.ToString() -eq 'InterNetwork') {
                                    $ipStr = $uni.Address.ToString()
                                    if ($ipStr -notlike '169.254.*' -and $ipStr -notlike '127.*' -and $ipStr -ne '0.0.0.0') {
                                        $wValidIp = $ipStr
                                        break
                                    }
                                }
                            }
                        }
                        if ($wValidIp) { break }
                    }
                }
            } catch {}

            $wSsid = ""
            try {
                $wSsid = [GlazierNativeWlan]::GetCurrentConnectionSSID($wIface.InterfaceGuid)
            } catch {}

            if ($wState -eq 1 -and $wValidIp -and $wHasGw) {
                $wirelessState = 'Green'
                $wirelessDetail = if ($wSsid) { "Connected ($wSsid - $wValidIp)" } else { "Connected ($wValidIp)" }
                if (-not $activeIP) {
                    $activeIP = $wValidIp
                    $activeInterface = $wIface.Description
                }
            } elseif ($wState -in @(1, 5, 7)) {
                $wirelessState = 'Amber'
                $wirelessDetail = 'Associating / Acquiring IP...'
            } elseif ($wState -eq 4) {
                $wirelessState = 'Amber'
                $wirelessDetail = 'Ready (Disconnected)'
            } else {
                $wirelessState = 'Amber'
                $wirelessDetail = 'Ready (Disconnected)'
            }
        } else {
            $wirelessState = 'Amber'
            $wirelessDetail = 'Ready (Disconnected)'
        }
    }

    # 3. Internet Inspection
    $hasValidIpAndGw = ($wiredState -eq 'Green' -or $wirelessState -eq 'Green')
    if ($hasValidIpAndGw) {
        $isOnline = Test-GlazierInternetReachability
        if ($isOnline) {
            $internetState = 'Green'
            $internetDetail = 'Online'
        } else {
            $internetState = 'Amber'
            $internetDetail = 'Local IP Only (No Internet)'
        }
    } else {
        $internetState = 'Red'
        $internetDetail = 'Offline'
    }

    return [PSCustomObject]@{
        WiredState      = $wiredState
        WiredDetail     = $wiredDetail
        WirelessState   = $wirelessState
        WirelessDetail  = $wirelessDetail
        HasHardware     = $hasHardware
        HasBoundDriver  = $hasBoundDriver
        AdapterName     = $adapterName
        ErrorCode       = $errorCode
        InternetState   = $internetState
        InternetDetail  = $internetDetail
        ActiveIP        = $activeIP
        ActiveInterface = $activeInterface
    }
}

function Invoke-GlazierWiFiAutoConnect {
    param(
        [string[]]$ProfileDirs,
        [scriptblock]$OnStatus = $null,
        [scriptblock]$OnPulse = $null,
        [int]$TimeoutSeconds = 20
    )

    $wlanSvc = Get-Service -Name WlanSvc -ErrorAction SilentlyContinue
    if ($wlanSvc -and $wlanSvc.Status -ne 'Running') {
        Start-Service -Name WlanSvc -ErrorAction SilentlyContinue
    }

    $isWinPE = (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT') -or (Test-Path 'X:\')
    if (-not $ProfileDirs -or $ProfileDirs.Count -eq 0) {
        $ProfileDirs = if ($isWinPE) {
            @("X:\glazier-resources\wifi_profiles", "C:\glazier-resources\wifi_profiles")
        } else {
            @("C:\glazier-resources\wifi_profiles")
        }
    }

    # 1. Staging Wi-Fi XML profiles in WinPE RAM
    if ($isWinPE) {
        $wifiRamDir = "X:\glazier-resources\wifi_profiles"
        if (-not (Test-Path $wifiRamDir)) {
            New-Item -ItemType Directory -Path $wifiRamDir -Force | Out-Null
        }
        try {
            $candidateDrives = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.Name -ne 'X:\' }
            foreach ($cDrive in $candidateDrives) {
                $stagedSourcesDir = Join-Path $cDrive.RootDirectory.FullName "sources\wifi_profiles"
                if (Test-Path $stagedSourcesDir) {
                    $stagedXmls = Get-ChildItem -Path $stagedSourcesDir -Filter "*.xml" -ErrorAction SilentlyContinue
                    if ($stagedXmls) {
                        foreach ($sXml in $stagedXmls) {
                            Copy-Item -Path $sXml.FullName -Destination $wifiRamDir -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
            }
        } catch {}
    }

    foreach ($pDir in $ProfileDirs) {
        if (Test-Path $pDir) {
            $xmlFiles = Get-ChildItem -Path $pDir -Filter "*.xml" -ErrorAction SilentlyContinue
            foreach ($xf in $xmlFiles) {
                try {
                    $raw = Get-Content -Path $xf.FullName -Raw -ErrorAction SilentlyContinue
                    if ($raw -and $raw -match '<connectionMode>manual</connectionMode>') {
                        $raw = $raw.Replace('<connectionMode>manual</connectionMode>', '<connectionMode>auto</connectionMode>')
                        Set-Content -Path $xf.FullName -Value $raw -Encoding ASCII -Force
                    }
                } catch {}
            }
        }
    }

    # 2. Network Telemetry Pre-check
    $tel = Get-GlazierNetworkTelemetry
    if ($tel.InternetState -eq 'Green') {
        return $true
    }

    if (-not $tel.HasHardware -or -not $tel.HasBoundDriver) {
        if ($tel.WiredState -eq 'Amber') {
            for ($i = 0; $i -lt 15; $i++) {
                if ($OnStatus) { & $OnStatus "Wired link detected - waiting for DHCP lease..." }
                for ($pTick = 0; $pTick -lt 20; $pTick++) {
                    if ($OnPulse) { & $OnPulse }
                    Start-Sleep -Milliseconds 50
                }
                $tel = Get-GlazierNetworkTelemetry
                if ($tel.InternetState -eq 'Green') {
                    return $true
                }
            }
        }
        return $false
    }

    # 3. Wi-Fi Adapter Initialisation & Auto-Connect
    $wlanSvc = Get-Service -Name WlanSvc -ErrorAction SilentlyContinue
    if ($wlanSvc -and $wlanSvc.Status -ne 'Running') {
        Start-Service -Name WlanSvc -ErrorAction SilentlyContinue
    }

    $ifaces = $null
    for ($wTick = 0; $wTick -lt 48; $wTick++) {
        try {
            $ifaces = [GlazierNativeWlan]::EnumInterfaces()
            if ($ifaces -and $ifaces.Count -gt 0) { break }
        } catch {}
        for ($pTick = 0; $pTick -lt 5; $pTick++) {
            if ($OnPulse) { & $OnPulse }
            Start-Sleep -Milliseconds 50
        }
    }

    if (-not $ifaces -or $ifaces.Count -eq 0) {
        return $false
    }

    $wlanIface = $ifaces[0]

    $stagedXmlFiles = @()
    foreach ($pDir in $ProfileDirs) {
        if (Test-Path $pDir) {
            $stagedXmlFiles += @(Get-ChildItem -Path $pDir -Filter "*.xml" -ErrorAction SilentlyContinue)
        }
    }

    if ($stagedXmlFiles.Count -eq 0) {
        return $false
    }

    $profileNames = @()
    foreach ($pf in $stagedXmlFiles) {
        try {
            $xmlContent = Get-Content -Path $pf.FullName -Raw -ErrorAction SilentlyContinue
            [xml]$px = $xmlContent
            if ($px -and $px.WLANProfile) {
                $ssid = if ($px.WLANProfile.SSIDConfig.SSID.name) { [string]$px.WLANProfile.SSIDConfig.SSID.name } else { [string]$px.WLANProfile.name }
                $auth = [string]$px.WLANProfile.MSM.security.authEncryption.authentication
                if ($isWinPE -and ($auth -match '^(WPA3SAE|WPA3|WPA3-Personal)$')) {
                    $auth = "WPA2PSK"
                }
                if (-not $auth) { $auth = "WPA2PSK" }
                $key = [string]$px.WLANProfile.MSM.security.sharedKey.keyMaterial
                $isHidden = ([string]$px.WLANProfile.SSIDConfig.nonBroadcast -eq 'true')
                $cleanXml = New-GlazierWiFiProfileXml -SSID $ssid -Password $key -AuthType $auth -IsHidden $isHidden
                Set-Content -Path $pf.FullName -Value $cleanXml -Encoding ASCII -Force
                $reasonCode = 0
                $setOk = [GlazierNativeWlan]::SetProfile($wlanIface.InterfaceGuid, $cleanXml, [ref]$reasonCode)
                if (-not $setOk -and ($auth -match '^(WPA3SAE|WPA3|WPA3-Personal)$')) {
                    $auth = "WPA2PSK"
                    $cleanXml = New-GlazierWiFiProfileXml -SSID $ssid -Password $key -AuthType $auth -IsHidden $isHidden
                    Set-Content -Path $pf.FullName -Value $cleanXml -Encoding ASCII -Force
                    $setOk = [GlazierNativeWlan]::SetProfile($wlanIface.InterfaceGuid, $cleanXml, [ref]$reasonCode)
                }
                if (-not $setOk) {
                    & netsh.exe wlan add profile ('filename=' + $pf.FullName) user=all | Out-Null
                }
                $profileNames += $ssid
            } else {
                $pn = $pf.BaseName
                if ($pn) {
                    $reasonCode = 0
                    $setOk = [GlazierNativeWlan]::SetProfile($wlanIface.InterfaceGuid, $xmlContent, [ref]$reasonCode)
                    if (-not $setOk) {
                        & netsh.exe wlan add profile ('filename=' + $pf.FullName) user=all | Out-Null
                    }
                    $profileNames += $pn
                }
            }
        } catch {}
    }

    [GlazierNativeWlan]::TriggerScan($wlanIface.InterfaceGuid) | Out-Null

    $lastConnectAttempt = [DateTime]::MinValue
    $lastStatusMsg = ""
    $maxIterations = [int]($TimeoutSeconds * 2)
    for ($poll = 0; $poll -lt $maxIterations; $poll++) {
        $curTel = Get-GlazierNetworkTelemetry
        if ($curTel.InternetState -eq 'Green') {
            return $true
        }

        $curState = [GlazierNativeWlan]::GetInterfaceState($wlanIface.InterfaceGuid)
        $primaryProfile = if ($profileNames.Count -gt 0) { $profileNames[0] } else { "Wi-Fi" }

        $statusMsg = ""
        if ($curState -eq 5) {
            $statusMsg = "Associating with '$primaryProfile'..."
        } elseif ($curState -eq 7) {
            $statusMsg = "Authenticating with '$primaryProfile'..."
        } elseif ($curState -eq 1) {
            $statusMsg = "Acquiring DHCP IPv4 lease..."
        } elseif ($curState -eq 4) {
            $statusMsg = "Scanning channels for '$primaryProfile'..."
            $timeSinceConnect = ([DateTime]::UtcNow - $lastConnectAttempt).TotalSeconds
            if (($timeSinceConnect -ge 7) -and ($poll -ge 4)) {
                $isTargetVisible = $false
                try {
                    $availNets = [GlazierNativeWlan]::GetAvailableNetworks($wlanIface.InterfaceGuid)
                    foreach ($an in $availNets) {
                        if ($profileNames -contains $an.SSID) {
                            $isTargetVisible = $true
                            break
                        }
                    }
                } catch {}

                if ($isTargetVisible -or $poll -ge 8) {
                    foreach ($pn in $profileNames) {
                        [GlazierNativeWlan]::Connect($wlanIface.InterfaceGuid, $pn) | Out-Null
                    }
                    $lastConnectAttempt = [DateTime]::UtcNow
                }
            }

            if ($timeSinceConnect -ge 4 -and ($poll % 16 -eq 0)) {
                [GlazierNativeWlan]::TriggerScan($wlanIface.InterfaceGuid) | Out-Null
            }
        }
        if ($OnStatus -and $statusMsg -and ($statusMsg -ne $lastStatusMsg)) {
            $lastStatusMsg = $statusMsg
            & $OnStatus $statusMsg
        }

        for ($pTick = 0; $pTick -lt 10; $pTick++) {
            if ($OnPulse) { & $OnPulse }
            Start-Sleep -Milliseconds 50
        }
    }

    return $false
}

function Show-GlazierNetworkGUI {
    $wlanSvc = Get-Service -Name WlanSvc -ErrorAction SilentlyContinue
    if ($wlanSvc -and $wlanSvc.Status -ne 'Running') {
        Start-Service -Name WlanSvc -ErrorAction SilentlyContinue
    }

    $initTel = Get-GlazierNetworkTelemetry
    $hasWifi = ($initTel.HasHardware -and $initTel.HasBoundDriver)

    $stagedProfileDirs = @("X:\glazier-resources\wifi_profiles", "C:\glazier-resources\wifi_profiles")
    $stagedProfileNames = @()
    $firstStagedSSID = ""
    $firstStagedKey = ""
    $isWinPELocal = (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT') -or (Test-Path 'X:\')
    foreach ($spd in $stagedProfileDirs) {
        if (Test-Path $spd) {
            $sXmls = Get-ChildItem -Path $spd -Filter "*.xml" -ErrorAction SilentlyContinue
            foreach ($sx in $sXmls) {
                try {
                    $rawContent = Get-Content -Path $sx.FullName -Raw -ErrorAction SilentlyContinue
                    [xml]$xDoc = $rawContent
                    if ($xDoc -and $xDoc.WLANProfile) {
                        $pName = if ($xDoc.WLANProfile.SSIDConfig.SSID.name) { [string]$xDoc.WLANProfile.SSIDConfig.SSID.name } else { [string]$xDoc.WLANProfile.name }
                        $pAuth = [string]$xDoc.WLANProfile.MSM.security.authEncryption.authentication
                        $pKey = [string]$xDoc.WLANProfile.MSM.security.sharedKey.keyMaterial
                        $pHidden = ([string]$xDoc.WLANProfile.SSIDConfig.nonBroadcast -eq 'true')
                        if ($isWinPELocal -and ($pAuth -match '^(WPA3SAE|WPA3|WPA3-Personal)$')) {
                            $pAuth = "WPA2PSK"
                        }
                        if (-not $pAuth) { $pAuth = if ($pKey) { "WPA2PSK" } else { "open" } }
                        $cleanXml = New-GlazierWiFiProfileXml -SSID $pName -Password $pKey -AuthType $pAuth -IsHidden $pHidden
                        Set-Content -Path $sx.FullName -Value $cleanXml -Encoding ASCII -Force
                        if ($pName -and -not ($stagedProfileNames -contains $pName)) {
                            $stagedProfileNames += $pName
                        }
                        if (-not $firstStagedSSID) {
                            $firstStagedSSID = $pName
                            $firstStagedKey = $pKey
                        }
                    }
                } catch {}
            }
        }
    }

    if ($hasWifi) {
        try {
            $wIfaces = [GlazierNativeWlan]::EnumInterfaces()
            if ($wIfaces -and $wIfaces.Count -gt 0) {
                $targetGuid = $wIfaces[0].InterfaceGuid
                foreach ($spd in $stagedProfileDirs) {
                    if (Test-Path $spd) {
                        $sXmls = Get-ChildItem -Path $spd -Filter "*.xml" -ErrorAction SilentlyContinue
                        foreach ($sx in $sXmls) {
                            try {
                                $cXml = Get-Content -Path $sx.FullName -Raw -ErrorAction SilentlyContinue
                                $rCode = 0
                                $sOk = [GlazierNativeWlan]::SetProfile($targetGuid, $cXml, [ref]$rCode)
                                if (-not $sOk) {
                                    & netsh.exe wlan add profile ('filename=' + $sx.FullName) user=all | Out-Null
                                }
                            } catch {}
                        }
                    }
                }
                [GlazierNativeWlan]::TriggerScan($targetGuid) | Out-Null
            }
        } catch {}
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Network & Wi-Fi Configuration"
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $form.ClientSize = New-Object System.Drawing.Size(660, 480)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.ControlBox = $false
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)

    # 1. Top Header
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "Network & Wi-Fi Configuration"
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 20, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
    $lblTitle.Location = New-Object System.Drawing.Point(28, 18)
    $lblTitle.Size = New-Object System.Drawing.Size(604, 32)
    $form.Controls.Add($lblTitle)

    $lblSubtitle = New-Object System.Windows.Forms.Label
    $lblSubtitle.Text = "Waiting for network connection..."
    $lblSubtitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $lblSubtitle.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
    $lblSubtitle.Location = New-Object System.Drawing.Point(28, 52)
    $lblSubtitle.Size = New-Object System.Drawing.Size(604, 20)
    $form.Controls.Add($lblSubtitle)

    $progressTrack = New-Object System.Windows.Forms.Panel
    $progressTrack.Location = New-Object System.Drawing.Point(28, 76)
    $progressTrack.Size = New-Object System.Drawing.Size(604, 16)
    $progressTrack.BackColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
    $progressTrack.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $form.Controls.Add($progressTrack)

    $progressFill = New-Object System.Windows.Forms.Panel
    $progressFill.Location = New-Object System.Drawing.Point(0, 0)
    $progressFill.Size = New-Object System.Drawing.Size(150, 16)
    $progressFill.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
    $progressTrack.Controls.Add($progressFill)

    $progressPulse = New-Object System.Windows.Forms.Panel
    $progressPulse.Location = New-Object System.Drawing.Point(-70, 0)
    $progressPulse.Size = New-Object System.Drawing.Size(70, 16)
    $progressPulse.BackColor = [System.Drawing.Color]::FromArgb(96, 165, 250)
    $progressFill.Controls.Add($progressPulse)

    $progressPulseCore = New-Object System.Windows.Forms.Panel
    $progressPulseCore.Location = New-Object System.Drawing.Point(20, 0)
    $progressPulseCore.Size = New-Object System.Drawing.Size(30, 16)
    $progressPulseCore.BackColor = [System.Drawing.Color]::FromArgb(147, 197, 253)
    $progressPulse.Controls.Add($progressPulseCore)

    # 2. Middle Content Area
    $listView = $null
    $txtSSID = $null
    $txtPassword = $null
    $chkShow = $null
    $chkHidden = $null
    $btnConnect = $null
    $btnRefresh = $null
    $lblWiFiStatus = $null

    if ($hasWifi) {
        $listView = New-Object System.Windows.Forms.ListView
        $listView.Location = New-Object System.Drawing.Point(28, 102)
        $listView.Size = New-Object System.Drawing.Size(604, 138)
        $listView.View = [System.Windows.Forms.View]::Details
        $listView.FullRowSelect = $true
        $listView.MultiSelect = $false
        $listView.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        $listView.BackColor = [System.Drawing.Color]::White
        $listView.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)

        $colSsid = $listView.Columns.Add("Network (SSID)", 300)
        $colSignal = $listView.Columns.Add("Signal", 110)
        $colSecurity = $listView.Columns.Add("Security", 170)
        $form.Controls.Add($listView)

        # Row 1 Controls (Y = 248)
        $lblSSID = New-Object System.Windows.Forms.Label
        $lblSSID.Text = "SSID:"
        $lblSSID.Location = New-Object System.Drawing.Point(28, 250)
        $lblSSID.Size = New-Object System.Drawing.Size(42, 22)
        $lblSSID.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $lblSSID.ForeColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
        $form.Controls.Add($lblSSID)

        $txtSSID = New-Object System.Windows.Forms.TextBox
        $txtSSID.Location = New-Object System.Drawing.Point(72, 248)
        $txtSSID.Size = New-Object System.Drawing.Size(160, 24)
        $txtSSID.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        if ($firstStagedSSID) {
            $txtSSID.Text = $firstStagedSSID
        }
        $form.Controls.Add($txtSSID)

        $lblPass = New-Object System.Windows.Forms.Label
        $lblPass.Text = "Key:"
        $lblPass.Location = New-Object System.Drawing.Point(240, 250)
        $lblPass.Size = New-Object System.Drawing.Size(36, 22)
        $lblPass.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $lblPass.ForeColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
        $form.Controls.Add($lblPass)

        $txtPassword = New-Object System.Windows.Forms.TextBox
        $txtPassword.Location = New-Object System.Drawing.Point(278, 248)
        $txtPassword.Size = New-Object System.Drawing.Size(140, 24)
        $txtPassword.PasswordChar = '*'
        $txtPassword.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        if ($firstStagedKey) {
            $txtPassword.Text = $firstStagedKey
        }
        $form.Controls.Add($txtPassword)

        $chkShow = New-Object System.Windows.Forms.CheckBox
        $chkShow.Text = "Show"
        $chkShow.Location = New-Object System.Drawing.Point(426, 249)
        $chkShow.Size = New-Object System.Drawing.Size(60, 22)
        $chkShow.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $chkShow.ForeColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
        $form.Controls.Add($chkShow)

        $chkHidden = New-Object System.Windows.Forms.CheckBox
        $chkHidden.Text = "Hidden Network"
        $chkHidden.Location = New-Object System.Drawing.Point(492, 249)
        $chkHidden.Size = New-Object System.Drawing.Size(140, 22)
        $chkHidden.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $chkHidden.ForeColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
        $form.Controls.Add($chkHidden)

        # Row 2 Controls (Y = 280)
        $btnConnect = New-Object System.Windows.Forms.Button
        $btnConnect.Text = "Connect Wi-Fi"
        $btnConnect.Location = New-Object System.Drawing.Point(28, 280)
        $btnConnect.Size = New-Object System.Drawing.Size(115, 28)
        $btnConnect.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnConnect.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
        $btnConnect.ForeColor = [System.Drawing.Color]::White
        $btnConnect.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $btnConnect.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(29, 78, 216)
        $btnConnect.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(29, 78, 216)
        $form.Controls.Add($btnConnect)

        $btnRefresh = New-Object System.Windows.Forms.Button
        $btnRefresh.Text = "Refresh"
        $btnRefresh.Location = New-Object System.Drawing.Point(150, 280)
        $btnRefresh.Size = New-Object System.Drawing.Size(80, 28)
        $btnRefresh.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnRefresh.BackColor = [System.Drawing.Color]::FromArgb(240, 242, 245)
        $btnRefresh.ForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
        $btnRefresh.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $btnRefresh.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
        $btnRefresh.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
        $form.Controls.Add($btnRefresh)

        $lblWiFiStatus = New-Object System.Windows.Forms.Label
        $lblWiFiStatus.Text = ""
        $lblWiFiStatus.Location = New-Object System.Drawing.Point(238, 284)
        $lblWiFiStatus.Size = New-Object System.Drawing.Size(394, 22)
        $lblWiFiStatus.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $lblWiFiStatus.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
        $form.Controls.Add($lblWiFiStatus)

        $chkShow.Add_CheckedChanged({
            if ($chkShow.Checked) {
                $txtPassword.PasswordChar = [char]0
            } else {
                $txtPassword.PasswordChar = '*'
            }
        })

        $txtPassword.Add_KeyDown({
            param($sender, $e)
            if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
                $e.SuppressKeyPress = $true
                $btnConnect.PerformClick()
            }
        })

        $listView.Add_DoubleClick({
            if ($listView.SelectedItems.Count -gt 0) {
                $sel = $listView.SelectedItems[0]
                $netInfo = $sel.Tag
                if ($netInfo -and -not $netInfo.SecurityEnabled) {
                    $btnConnect.PerformClick()
                } else {
                    $txtPassword.Focus()
                }
            }
        })

        $listView.Add_SelectedIndexChanged({
            if ($listView.SelectedItems.Count -gt 0) {
                $selItem = $listView.SelectedItems[0]
                $netInfo = $selItem.Tag
                $isSameSsid = ($txtSSID.Text -eq $selItem.Text)
                $txtSSID.Text = $selItem.Text
                if ($netInfo -and -not $netInfo.SecurityEnabled) {
                    $txtPassword.Text = ""
                    $txtPassword.Enabled = $false
                    $lblWiFiStatus.Text = "Open network (no password required)."
                } else {
                    $txtPassword.Enabled = $true
                    $secName = if ($netInfo) { $netInfo.AuthAlgorithmName } else { "Secured" }
                    $lblWiFiStatus.Text = "Selected $secName network. Enter password to connect."
                    if (-not $isSameSsid -and -not $script:isPopulating) {
                        $txtPassword.Text = ""
                    }
                }
            }
        })
    } else {
        $cardPanel = New-Object System.Windows.Forms.Panel
        $cardPanel.Location = New-Object System.Drawing.Point(28, 102)
        $cardPanel.Size = New-Object System.Drawing.Size(604, 198)
        $cardPanel.BackColor = [System.Drawing.Color]::White
        $cardPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        $form.Controls.Add($cardPanel)

        $lblCardTitle = New-Object System.Windows.Forms.Label
        if (-not $initTel.HasHardware) {
            $lblCardTitle.Text = "No Wireless Hardware Detected"
        } else {
            $lblCardTitle.Text = "Wireless Driver Missing"
        }
        $lblCardTitle.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $lblCardTitle.ForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
        $lblCardTitle.Location = New-Object System.Drawing.Point(20, 16)
        $lblCardTitle.Size = New-Object System.Drawing.Size(564, 26)
        $cardPanel.Controls.Add($lblCardTitle)

        $lblCardDetail = New-Object System.Windows.Forms.Label
        if (-not $initTel.HasHardware) {
            $lblCardDetail.Text = "No wireless adapter detected on this machine."
        } else {
            $lblCardDetail.Text = "Wireless hardware detected ($($initTel.AdapterName)) but no driver is loaded (Error Code $($initTel.ErrorCode))."
        }
        $lblCardDetail.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $lblCardDetail.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
        $lblCardDetail.Location = New-Object System.Drawing.Point(20, 46)
        $lblCardDetail.Size = New-Object System.Drawing.Size(564, 38)
        $cardPanel.Controls.Add($lblCardDetail)

        $sepPanel = New-Object System.Windows.Forms.Panel
        $sepPanel.Location = New-Object System.Drawing.Point(20, 92)
        $sepPanel.Size = New-Object System.Drawing.Size(564, 1)
        $sepPanel.BackColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
        $cardPanel.Controls.Add($sepPanel)

        $lblCardEthernet = New-Object System.Windows.Forms.Label
        $lblCardEthernet.Text = "Waiting for Wired Ethernet connection. Plug in a network cable or USB-C Ethernet adapter - deployment will continue automatically as soon as DHCP and Internet become active."
        $lblCardEthernet.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $lblCardEthernet.ForeColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
        $lblCardEthernet.Location = New-Object System.Drawing.Point(20, 104)
        $lblCardEthernet.Size = New-Object System.Drawing.Size(564, 75)
        $cardPanel.Controls.Add($lblCardEthernet)
    }

    # 3. Bottom 3-Pill Traffic Light Bar (Y = 320, Height = 80)
    $pillWired = New-Object System.Windows.Forms.Panel
    $pillWired.Location = New-Object System.Drawing.Point(28, 320)
    $pillWired.Size = New-Object System.Drawing.Size(194, 80)
    $pillWired.BackColor = [System.Drawing.Color]::White
    $pillWired.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $form.Controls.Add($pillWired)

    $dotWired = New-Object System.Windows.Forms.Panel
    $dotWired.Location = New-Object System.Drawing.Point(14, 14)
    $dotWired.Size = New-Object System.Drawing.Size(12, 12)
    $dotWired.BackColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
    $pillWired.Controls.Add($dotWired)

    $lblWiredTitle = New-Object System.Windows.Forms.Label
    $lblWiredTitle.Text = "Wired"
    $lblWiredTitle.Location = New-Object System.Drawing.Point(32, 11)
    $lblWiredTitle.Size = New-Object System.Drawing.Size(150, 18)
    $lblWiredTitle.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $lblWiredTitle.ForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
    $pillWired.Controls.Add($lblWiredTitle)

    $lblWiredDetail = New-Object System.Windows.Forms.Label
    $lblWiredDetail.Text = "Checking..."
    $lblWiredDetail.Location = New-Object System.Drawing.Point(14, 32)
    $lblWiredDetail.Size = New-Object System.Drawing.Size(166, 42)
    $lblWiredDetail.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $lblWiredDetail.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
    $pillWired.Controls.Add($lblWiredDetail)

    $pillWireless = New-Object System.Windows.Forms.Panel
    $pillWireless.Location = New-Object System.Drawing.Point(233, 320)
    $pillWireless.Size = New-Object System.Drawing.Size(194, 80)
    $pillWireless.BackColor = [System.Drawing.Color]::White
    $pillWireless.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $form.Controls.Add($pillWireless)

    $dotWireless = New-Object System.Windows.Forms.Panel
    $dotWireless.Location = New-Object System.Drawing.Point(14, 14)
    $dotWireless.Size = New-Object System.Drawing.Size(12, 12)
    $dotWireless.BackColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
    $pillWireless.Controls.Add($dotWireless)

    $lblWirelessTitle = New-Object System.Windows.Forms.Label
    $lblWirelessTitle.Text = "Wireless"
    $lblWirelessTitle.Location = New-Object System.Drawing.Point(32, 11)
    $lblWirelessTitle.Size = New-Object System.Drawing.Size(150, 18)
    $lblWirelessTitle.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $lblWirelessTitle.ForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
    $pillWireless.Controls.Add($lblWirelessTitle)

    $lblWirelessDetail = New-Object System.Windows.Forms.Label
    $lblWirelessDetail.Text = "Checking..."
    $lblWirelessDetail.Location = New-Object System.Drawing.Point(14, 32)
    $lblWirelessDetail.Size = New-Object System.Drawing.Size(166, 42)
    $lblWirelessDetail.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $lblWirelessDetail.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
    $pillWireless.Controls.Add($lblWirelessDetail)

    $pillInternet = New-Object System.Windows.Forms.Panel
    $pillInternet.Location = New-Object System.Drawing.Point(438, 320)
    $pillInternet.Size = New-Object System.Drawing.Size(194, 80)
    $pillInternet.BackColor = [System.Drawing.Color]::White
    $pillInternet.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $form.Controls.Add($pillInternet)

    $dotInternet = New-Object System.Windows.Forms.Panel
    $dotInternet.Location = New-Object System.Drawing.Point(14, 14)
    $dotInternet.Size = New-Object System.Drawing.Size(12, 12)
    $dotInternet.BackColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
    $pillInternet.Controls.Add($dotInternet)

    $lblInternetTitle = New-Object System.Windows.Forms.Label
    $lblInternetTitle.Text = "Internet"
    $lblInternetTitle.Location = New-Object System.Drawing.Point(32, 11)
    $lblInternetTitle.Size = New-Object System.Drawing.Size(150, 18)
    $lblInternetTitle.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $lblInternetTitle.ForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
    $pillInternet.Controls.Add($lblInternetTitle)

    $lblInternetDetail = New-Object System.Windows.Forms.Label
    $lblInternetDetail.Text = "Checking..."
    $lblInternetDetail.Location = New-Object System.Drawing.Point(14, 32)
    $lblInternetDetail.Size = New-Object System.Drawing.Size(166, 42)
    $lblInternetDetail.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $lblInternetDetail.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
    $pillInternet.Controls.Add($lblInternetDetail)

    # 4. Bottom Action Buttons (Y = 420, Height = 40)
    $btnTerminal = New-Object System.Windows.Forms.Button
    $btnTerminal.Text = "Open Terminal"
    $btnTerminal.Location = New-Object System.Drawing.Point(28, 420)
    $btnTerminal.Size = New-Object System.Drawing.Size(140, 40)
    $btnTerminal.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnTerminal.BackColor = [System.Drawing.Color]::FromArgb(240, 242, 245)
    $btnTerminal.ForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
    $btnTerminal.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $btnTerminal.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
    $btnTerminal.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
    $form.Controls.Add($btnTerminal)

    $btnSkip = New-Object System.Windows.Forms.Button
    $btnSkip.Text = "Skip / Continue Offline"
    $btnSkip.Location = New-Object System.Drawing.Point(180, 420)
    $btnSkip.Size = New-Object System.Drawing.Size(180, 40)
    $btnSkip.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnSkip.BackColor = [System.Drawing.Color]::FromArgb(240, 242, 245)
    $btnSkip.ForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
    $btnSkip.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $btnSkip.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
    $btnSkip.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
    $form.Controls.Add($btnSkip)

    $btnContinue = New-Object System.Windows.Forms.Button
    $btnContinue.Text = "Continue"
    $btnContinue.Location = New-Object System.Drawing.Point(492, 420)
    $btnContinue.Size = New-Object System.Drawing.Size(140, 40)
    $btnContinue.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnContinue.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
    $btnContinue.ForeColor = [System.Drawing.Color]::White
    $btnContinue.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $btnContinue.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(29, 78, 216)
    $btnContinue.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(29, 78, 216)
    $btnContinue.Enabled = $false
    $form.Controls.Add($btnContinue)

    # Wi-Fi List Population
    $script:isPopulating = $false
    $populateNetworksAction = {
        if ($listView) {
            $prevSsid = if ($listView.SelectedItems.Count -gt 0) { $listView.SelectedItems[0].Text } else { $null }
            $script:isPopulating = $true
            $listView.BeginUpdate()
            try {
                $listView.Items.Clear()
                $wIfs = [GlazierNativeWlan]::EnumInterfaces()
                if ($wIfs -and $wIfs.Count -gt 0) {
                    $nets = [GlazierNativeWlan]::GetAvailableNetworks($wIfs[0].InterfaceGuid)
                    foreach ($n in $nets) {
                        $item = New-Object System.Windows.Forms.ListViewItem($n.SSID)
                        $item.SubItems.Add("$($n.SignalQuality)%") | Out-Null
                        $secText = if (-not $n.SecurityEnabled) { "Open" } else { $n.AuthAlgorithmName }
                        $item.SubItems.Add($secText) | Out-Null
                        $item.Tag = $n
                        if ($prevSsid -and $n.SSID -eq $prevSsid) {
                            $item.Selected = $true
                        }
                        $listView.Items.Add($item) | Out-Null
                    }
                }
            } finally {
                $listView.EndUpdate()
                $script:isPopulating = $false
            }
        }
    }

    if ($hasWifi) {
        & $populateNetworksAction

        $btnRefresh.Add_Click({
            $lblWiFiStatus.Text = "Scanning Wi-Fi channels..."
            try {
                $wIfs = [GlazierNativeWlan]::EnumInterfaces()
                if ($wIfs -and $wIfs.Count -gt 0) {
                    [GlazierNativeWlan]::TriggerScan($wIfs[0].InterfaceGuid) | Out-Null
                }
                $script:refreshPendingTicks = 2
            } catch {
                $lblWiFiStatus.Text = "Scan failed: $_"
            }
        })

        $btnConnect.Add_Click({
            $targetSSID = $txtSSID.Text.Trim()
            if (-not $targetSSID) {
                $lblWiFiStatus.Text = "Please enter or select a Wi-Fi network SSID."
                return
            }

            $pass = $txtPassword.Text
            $isHidden = $chkHidden.Checked

            $wIfs = [GlazierNativeWlan]::EnumInterfaces()
            if (-not $wIfs -or $wIfs.Count -eq 0) {
                $lblWiFiStatus.Text = "Error: No wireless interface available."
                return
            }
            $targetGuid = $wIfs[0].InterfaceGuid

            $auth = "WPA2PSK"
            if ($listView.SelectedItems.Count -gt 0 -and $listView.SelectedItems[0].Tag) {
                $tagNet = $listView.SelectedItems[0].Tag
                if (-not $tagNet.SecurityEnabled) {
                    $auth = "open"
                } elseif ($tagNet.AuthAlgorithm -eq 9) {
                    $auth = "WPA3SAE"
                } elseif ($tagNet.AuthAlgorithm -eq 10) {
                    $auth = "OWE"
                } elseif ($tagNet.AuthAlgorithm -eq 4) {
                    $auth = "WPAPSK"
                } else {
                    $auth = "WPA2PSK"
                }
            } else {
                if (-not $pass) { $auth = "open" }
            }

            $isWinPELocal = (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT') -or (Test-Path 'X:\')
            if ($isWinPELocal -and ($auth -match '^(WPA3SAE|WPA3|WPA3-Personal)$')) {
                $auth = "WPA2PSK"
            }

            $lblWiFiStatus.Text = "Configuring profile and connecting to '$targetSSID'..."
            [System.Windows.Forms.Application]::DoEvents()

            try {
                $xml = New-GlazierWiFiProfileXml -SSID $targetSSID -Password $pass -AuthType $auth -IsHidden $isHidden
                $reason = 0
                $setOk = [GlazierNativeWlan]::SetProfile($targetGuid, $xml, [ref]$reason)
                if (-not $setOk -and ($auth -match '^(WPA3SAE|WPA3|WPA3-Personal)$')) {
                    $auth = "WPA2PSK"
                    $xml = New-GlazierWiFiProfileXml -SSID $targetSSID -Password $pass -AuthType $auth -IsHidden $isHidden
                    $setOk = [GlazierNativeWlan]::SetProfile($targetGuid, $xml, [ref]$reason)
                }

                $saveDir = if ($isWinPELocal) { "X:\glazier-resources\wifi_profiles" } else { "C:\glazier-resources\wifi_profiles" }
                if (-not (Test-Path $saveDir)) {
                    New-Item -ItemType Directory -Path $saveDir -Force | Out-Null
                }
                $safeFileName = ($targetSSID -replace '[\\/:*?"<>|]', '_') + ".xml"
                $savedPath = Join-Path $saveDir $safeFileName
                Set-Content -Path $savedPath -Value $xml -Encoding ASCII -Force

                if (-not $setOk) {
                    & netsh.exe wlan add profile ('filename=' + $savedPath) user=all | Out-Null
                }

                $connOk = [GlazierNativeWlan]::Connect($targetGuid, $targetSSID)
                if ($connOk) {
                    $lblWiFiStatus.Text = "Associating with '$targetSSID'..."
                } else {
                    $lblWiFiStatus.Text = "Connection request failed."
                }
            } catch {
                $lblWiFiStatus.Text = "Connection error: $_"
            }
        })
    }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1500

    $timerPulse = New-Object System.Windows.Forms.Timer
    $timerPulse.Interval = 50

    $script:guiShimmerPos = -70
    $timerPulse.Add_Tick({
        $script:guiShimmerPos = ($script:guiShimmerPos + 16)
        if ($script:guiShimmerPos -gt ($progressFill.Width + 70)) {
            $script:guiShimmerPos = -70
        }
        $progressPulse.Left = $script:guiShimmerPos
    })

    $script:autoContinueRemaining = 3
    $script:hasStartedCountdown = $false
    $script:tickCount = 0
    $script:refreshPendingTicks = 0

    $timer.Add_Tick({
        $script:tickCount++
        $curTel = Get-GlazierNetworkTelemetry

        if ($curTel.WiredState -eq 'Green') {
            $dotWired.BackColor = [System.Drawing.Color]::FromArgb(16, 185, 129)
        } elseif ($curTel.WiredState -eq 'Amber') {
            $dotWired.BackColor = [System.Drawing.Color]::FromArgb(245, 158, 11)
        } else {
            $dotWired.BackColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
        }
        $lblWiredDetail.Text = $curTel.WiredDetail

        if ($curTel.WirelessState -eq 'Green') {
            $dotWireless.BackColor = [System.Drawing.Color]::FromArgb(16, 185, 129)
        } elseif ($curTel.WirelessState -eq 'Amber') {
            $dotWireless.BackColor = [System.Drawing.Color]::FromArgb(245, 158, 11)
        } else {
            $dotWireless.BackColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
        }
        $lblWirelessDetail.Text = $curTel.WirelessDetail

        if ($curTel.InternetState -eq 'Green') {
            $dotInternet.BackColor = [System.Drawing.Color]::FromArgb(16, 185, 129)
        } elseif ($curTel.InternetState -eq 'Amber') {
            $dotInternet.BackColor = [System.Drawing.Color]::FromArgb(245, 158, 11)
        } else {
            $dotInternet.BackColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
        }
        $lblInternetDetail.Text = $curTel.InternetDetail

        if ($hasWifi) {
            if ($script:refreshPendingTicks -gt 0) {
                $script:refreshPendingTicks--
                & $populateNetworksAction
                if ($script:refreshPendingTicks -eq 0) {
                    $lblWiFiStatus.Text = "Scan completed. Found $($listView.Items.Count) network(s)."
                }
            } elseif ($curTel.WirelessState -ne 'Green') {
                if ($script:tickCount -eq 1 -or $script:tickCount -eq 2 -or ($listView.Items.Count -eq 0) -or ($script:tickCount % 4 -eq 0)) {
                    & $populateNetworksAction
                }
            }
        }

        if ($stagedProfileNames.Count -gt 0 -and $curTel.WirelessState -ne 'Green') {
            if ($script:tickCount % 6 -eq 2 -and ($null -eq $txtPassword -or -not $txtPassword.Focused)) {
                try {
                    $wIfs = [GlazierNativeWlan]::EnumInterfaces()
                    if ($wIfs -and $wIfs.Count -gt 0 -and $wIfs[0].State -eq 4) {
                        foreach ($spn in $stagedProfileNames) {
                            [GlazierNativeWlan]::Connect($wIfs[0].InterfaceGuid, $spn) | Out-Null
                        }
                    }
                } catch {}
            }
        }

        if ($curTel.InternetState -eq 'Green') {
            $progressFill.Width = 604
            $progressFill.BackColor = [System.Drawing.Color]::FromArgb(16, 185, 129)
            $progressPulse.Visible = $false
            $btnContinue.Enabled = $true
            $btnContinue.BackColor = [System.Drawing.Color]::FromArgb(16, 185, 129)
            $btnContinue.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(5, 150, 105)
            $btnContinue.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(5, 150, 105)

            if (-not $script:hasStartedCountdown) {
                $script:hasStartedCountdown = $true
                $script:autoContinueRemaining = 3
            }

            if ($script:autoContinueRemaining -gt 0) {
                $lblSubtitle.Text = "Connected! Continuing in $($script:autoContinueRemaining)s..."
                $btnContinue.Text = "Continue ($($script:autoContinueRemaining)s)"
                $script:autoContinueRemaining--
            } else {
                $timer.Stop()
                $timerPulse.Stop()
                $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
                $form.Close()
            }
        } else {
            if ($script:hasStartedCountdown) {
                $script:hasStartedCountdown = $false
                $script:autoContinueRemaining = 3
                $progressFill.Width = 150
                $progressFill.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
                $progressPulse.Visible = $true
                $btnContinue.Enabled = $false
                $btnContinue.Text = "Continue"
                $btnContinue.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
                $btnContinue.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(29, 78, 216)
                $btnContinue.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(29, 78, 216)
            }
            if ($curTel.WiredState -eq 'Amber') {
                $lblSubtitle.Text = "Wired link up - acquiring DHCP lease..."
            } elseif ($curTel.WirelessState -eq 'Amber' -and $curTel.WirelessDetail -match 'Associating') {
                $lblSubtitle.Text = "Wireless associating / acquiring DHCP lease..."
            } else {
                $lblSubtitle.Text = "Waiting for network connection..."
            }
        }
    })

    $btnTerminal.Add_Click({
        $form.TopMost = $false
        Start-Process -FilePath "cmd.exe" -ArgumentList '/c start "Glazier Network Debug Terminal" PowerShell.exe -NoProfile -NoLogo -NoExit'
    })

    $btnSkip.Add_Click({
        $timer.Stop()
        $timerPulse.Stop()
        $form.DialogResult = [System.Windows.Forms.DialogResult]::Ignore
        $form.Close()
    })

    $btnContinue.Add_Click({
        $timer.Stop()
        $timerPulse.Stop()
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })

    $form.Add_FormClosing({
        param($sender, $e)
        if ($form.DialogResult -ne [System.Windows.Forms.DialogResult]::OK -and
            $form.DialogResult -ne [System.Windows.Forms.DialogResult]::Ignore) {
            $e.Cancel = $true
        }
    })

    $timer.Start()
    $timerPulse.Start()

    $form.ShowDialog() | Out-Null

    $timer.Stop()
    $timerPulse.Stop()
    $timer.Dispose()
    $timerPulse.Dispose()

    $isWinPEExit = (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT') -or (Test-Path 'X:\')
    if ($isWinPEExit -and (Get-Service -Name WlanSvc -ErrorAction SilentlyContinue).Status -eq 'Running') {
        try {
            $wifiExportDir = "X:\glazier-resources\wifi_profiles"
            if (-not (Test-Path $wifiExportDir)) {
                New-Item -ItemType Directory -Path $wifiExportDir -Force | Out-Null
            }
            if (Get-Command Export-GlazierHostWiFiProfiles -ErrorAction SilentlyContinue) {
                Export-GlazierHostWiFiProfiles -OutputDir $wifiExportDir
            }
        } catch {}
    }

    $dialogSuccess = ($form.DialogResult -eq [System.Windows.Forms.DialogResult]::OK)
    $form.Dispose()

    return $dialogSuccess
}
