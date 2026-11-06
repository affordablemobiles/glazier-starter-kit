#!/usr/bin/env bash
# ==============================================================================
# update-netboot.sh
# Downloads, extracts, and prepares the latest Secure Boot signed iPXE & wimboot
# files (plus a pre-configured USB boot image) in the current working directory.
# ==============================================================================
set -euo pipefail

WORK_DIR="$(pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# Load local configuration file if present (gitignored for private/custom endpoints)
if [ -f "${WORK_DIR}/netboot.env" ]; then
  echo "==> Loading local configuration from ${WORK_DIR}/netboot.env"
  # shellcheck source=/dev/null
  . "${WORK_DIR}/netboot.env"
elif [ -f "${WORK_DIR}/.env" ]; then
  echo "==> Loading local configuration from ${WORK_DIR}/.env"
  # shellcheck source=/dev/null
  . "${WORK_DIR}/.env"
fi

# Configurable endpoints (override via netboot.env, environment variables, or CLI arguments)
BUCKET_URL="${1:-${BUCKET_URL:-https://storage.googleapis.com/CHANGE_ME_CONFIG_BUCKET}}"
BOOT_URL="${BOOT_URL:-https://storage.googleapis.com/CHANGE_ME_BOOT_BUCKET}"
BOOT_DEV_URL="${BOOT_DEV_URL:-https://storage.googleapis.com/CHANGE_ME_BOOT_DEV_BUCKET}"

if [[ "${BUCKET_URL}" == *"CHANGE_ME"* ]]; then
  echo "==> WARNING: BUCKET_URL is set to a placeholder: '${BUCKET_URL}'"
  echo "    To configure your real endpoints, copy netboot.env.example to netboot.env"
  echo "    or pass BUCKET_URL as an argument: ./update-netboot.sh https://storage.googleapis.com/<YOUR-CONFIG-BUCKET>"
fi

echo "==> Working directory: ${WORK_DIR}"
echo "==> Config Bucket URL : ${BUCKET_URL}"
echo "==> Boot Bucket URL   : ${BOOT_URL}"
mkdir -p "${WORK_DIR}/usb" "${TMP_DIR}/extract"

# 1. Check required tools (curl, tar, base64, mcopy from mtools)
for cmd in curl tar base64 mcopy; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "==> Missing '${cmd}'. Attempting to install via apt-get..."
    if command -v sudo >/dev/null 2>&1; then
      sudo apt-get update -qq && sudo apt-get install -y -qq curl tar coreutils mtools ca-certificates
    else
      apt-get update -qq && apt-get install -y -qq curl tar coreutils mtools ca-certificates
    fi
    break
  fi
done

# 2. Check for splash screen images and encode DHCP splash into 800-char Base64 chunks for autoexec.ipxe
DHCP_LOGO_FILE="${WORK_DIR}/logo_dhcp.png"
if [ ! -f "${DHCP_LOGO_FILE}" ] && [ -f "${WORK_DIR}/logo.png" ]; then
  DHCP_LOGO_FILE="${WORK_DIR}/logo.png"
fi

CONSOLE_BLOCK="# No logo_dhcp.png or logo.png found at build time; set widescreen console resolution if supported
console --x 1920 --y 1080 || console --x 1366 --y 768 || console --x 1024 --y 768 ||"

if [ -f "${DHCP_LOGO_FILE}" ]; then
  echo "==> Encoding ${DHCP_LOGO_FILE} into URL-escaped 800-char Base64 chunks for autoexec.ipxe..."
  # Encode PNG to Base64 and URL-escape '/' (%2F) and '+' (%2B) so iPXE parse_uri() never sees a '/'
  # (parse_uri() automatically runs uri_decode_inplace() on uri->opaque before base64_decode()!)
  RAW_B64="$( (base64 -w 0 "${DHCP_LOGO_FILE}" 2>/dev/null || base64 "${DHCP_LOGO_FILE}") | tr -d '\r\n\t ' | sed 's|/|%2F|g; s|+|%2B|g' )"
  CHUNK_LINES=""
  CONCAT_VARS=""
  CLEAR_VARS=""
  idx=0
  while [ -n "${RAW_B64}" ]; do
    chunk="${RAW_B64:0:800}"
    RAW_B64="${RAW_B64:800}"
    CHUNK_LINES+="set b${idx} ${chunk}"$'\n'
    CONCAT_VARS+="\${b${idx}}"
    CLEAR_VARS+="clear b${idx} ; "
    idx=$((idx + 1))
  done

  CONSOLE_BLOCK="# Reassemble inline DHCP splash PNG from ${idx} short chunks (avoids line-length truncation & slash parsing)
${CHUNK_LINES}set logo_uri data:;base64,${CONCAT_VARS}
${CLEAR_VARS% ; }
console --x 1920 --y 1080 --picture \${logo_uri} --keep || console --x 1366 --y 768 --picture \${logo_uri} --keep || console --x 1024 --y 768 --picture \${logo_uri} --keep || console --picture \${logo_uri} --keep ||
clear logo_uri"
fi

# 3. Download latest upstream iPXE and wimboot releases
echo "==> Downloading latest upstream iPXE & wimboot releases from GitHub..."
curl -fsSL "https://github.com/ipxe/ipxe/releases/latest/download/ipxeboot.tar.gz" \
  -o "${TMP_DIR}/ipxeboot.tar.gz"

curl -fsSL "https://github.com/ipxe/ipxe/releases/latest/download/ipxe-x86_64-sb.usb" \
  -o "${WORK_DIR}/usb/glazier-ipxe-x86_64-sb.usb"

curl -fsSL "https://github.com/ipxe/wimboot/releases/latest/download/wimboot" \
  -o "${WORK_DIR}/wimboot"

# Keep wimboot.x86_64.efi copy for backwards compatibility with older Glazier scripts
cp -f "${WORK_DIR}/wimboot" "${WORK_DIR}/wimboot.x86_64.efi"

# 4. Extract x86_64-sb Secure Boot binaries
#    IMPORTANT: Copy snponly.efi to BOTH snponly.efi AND ipxe.efi so that UEFI firmwares
#    hitting iPXE Issue #1684 (where shimx64.efi falls back to /ipxe.efi) still boot snponly.efi!
echo "==> Extracting x86_64-sb Secure Boot binaries (enforcing snponly.efi)..."
tar -xzf "${TMP_DIR}/ipxeboot.tar.gz" --dereference -C "${TMP_DIR}/extract"

cp -f "${TMP_DIR}/extract/ipxeboot/x86_64-sb/shimx64.efi" "${WORK_DIR}/shimx64.efi"
cp -f "${TMP_DIR}/extract/ipxeboot/x86_64-sb/shimx64.efi" "${WORK_DIR}/snponly-shim.efi"
cp -f "${TMP_DIR}/extract/ipxeboot/x86_64-sb/shimx64.efi" "${WORK_DIR}/ipxe-shim.efi"
cp -f "${TMP_DIR}/extract/ipxeboot/x86_64-sb/snponly.efi" "${WORK_DIR}/snponly.efi"
cp -f "${TMP_DIR}/extract/ipxeboot/x86_64-sb/snponly.efi" "${WORK_DIR}/ipxe.efi"

# Capture build-time UTC timestamp for autoexec.ipxe diagnostic reporting
BUILD_DATE_UTC="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
BUILD_EPOCH="$(date -u '+%s')"

# 5. Generate resilient autoexec.ipxe (with chunked inline Base64 splash, debug hotkey, DHCP/DNS retries, and cert check)
echo "==> Generating resilient ${WORK_DIR}/autoexec.ipxe..."
cat << EOF > "${WORK_DIR}/autoexec.ipxe"
#!ipxe

# Optional 500ms 'p' hotkey to drop directly into iPXE shell for debugging
prompt --key p --timeout 500 && shell ||

# Clear initial UEFI text console before activating graphical framebuffer
set esc:hex 1b && set esc \${esc:string} ||
set cls \${esc}[2J
echo -n \${cls}

${CONSOLE_BLOCK}

set dhcpretries:int32 0
set chainretries:int32 0

:DHCP_TRY
echo Initialising network interface and requesting DHCP lease...
ifconf && goto DHCP_OK ||
inc dhcpretries
iseq \${dhcpretries} 20 && goto FAIL_DHCP ||
echo DHCP failed (Attempt \${dhcpretries}/20). Checking link status:
ifstat ||
echo Retrying in 5 seconds...
sleep 5 ||
goto DHCP_TRY

:DHCP_OK
set menu_url ${BUCKET_URL}/boot.ipxe

:CHAIN_TRY
echo Network configured (\${ip}/\${netmask}, GW: \${gateway}, DNS: \${dns}).
echo Loading Glazier Boot Menu from \${menu_url}...
chain --autofree \${menu_url} && exit 0 ||
set lasterr:uint32 \${builtin/errno:uint32}
set errhex \${lasterr:hexraw}

# Check for TLS certificate / BIOS clock skew errors
iseq \${errhex} 0216e48f && set cert_reason Certificate is NOT YET VALID (BIOS clock is in the PAST - likely a flat CMOS/RTC battery) && goto CERTERROR ||
iseq \${errhex} 0216ea8f && set cert_reason Certificate has EXPIRED (BIOS clock is set too far in the FUTURE, or server cert expired) && goto CERTERROR ||
iseq \${errhex} 0216eb8f && set cert_reason Certificate validity period error (BIOS clock is inaccurate) && goto CERTERROR ||
iseq \${errhex} 3c00e183 && set cert_reason TLS handshake / certificate validation error && goto CERTERROR ||
iseq \${errhex} 410de13c && set cert_reason TLS certificate chain verification failed && goto CERTERROR ||

inc chainretries
iseq \${chainretries} 10 && goto FAIL_CHAIN ||
echo Download failed with error \${errhex} (Attempt \${chainretries}/10).
isset \${dns:ipv4} && set dns \${dns:ipv4} || set dns 8.8.8.8
echo Retrying in 5 seconds (DNS: \${dns})...
sleep 5 ||
goto CHAIN_TRY

:CERTERROR
# Reset console to standard full-screen text mode so debug output is completely unobstructed
console ||
echo ================================================================================
echo [ERROR] TLS Certificate Validation Failed! (https://ipxe.org/\${errhex})
echo ================================================================================
echo Diagnosis   : \${cert_reason}
echo Action      : Boot into BIOS/UEFI Setup (F2 / F10 / Del) and set the Date & Time.
echo
echo Device Unixtime: \${unixtime:int32}
echo Image Built    : ${BUILD_DATE_UTC} (epoch: ${BUILD_EPOCH})
echo ================================================================================
certstat ||
goto FAIL_INFO

:FAIL_DHCP
console ||
set lasterr:uint32 \${builtin/errno:uint32}
echo [ERROR] Failed to obtain a DHCP lease after \${dhcpretries} attempts.
goto FAIL_INFO

:FAIL_CHAIN
console ||
echo [ERROR] Failed to load \${menu_url} after \${chainretries} attempts.

:FAIL_INFO
echo
echo Error Code : https://ipxe.org/\${lasterr:hexraw} [\${builtin/errno}]
echo Make/Model : \${smbios/manufacturer} / \${smbios/product}
echo Serial/UUID: \${smbios/serial} / \${smbios/uuid:uuid}
echo MAC Address: \${mac} (System MAC: \${sysmac})
echo IP / DNS   : \${ip} / \${dns}
ifstat ||

:FAIL_PROMPT
echo
prompt --key 0x000a --timeout 30000 Press Enter for iPXE shell, or any other key (or wait 30s) to reboot... && shell || reboot
reboot
EOF

# 6. Inject autoexec.ipxe, splash logos (if present), AND snponly.efi (as EFI/BOOT/IPXE.EFI) into the USB image
echo "==> Injecting autoexec.ipxe, splash logos (if present), and snponly.efi into USB image..."
USB_IMG="${WORK_DIR}/usb/glazier-ipxe-x86_64-sb.usb"
# Support both GPT offset 1MiB (@@1M) and raw FAT offset 0
MTOOLS_TARGET="${USB_IMG}@@1M"
if ! mdir -i "${MTOOLS_TARGET}" ::/ >/dev/null 2>&1; then
  MTOOLS_TARGET="${USB_IMG}"
fi

mcopy -i "${MTOOLS_TARGET}" -o "${WORK_DIR}/autoexec.ipxe" ::/autoexec.ipxe
mcopy -i "${MTOOLS_TARGET}" -o "${WORK_DIR}/snponly.efi"   ::/EFI/BOOT/IPXE.EFI
[ -f "${WORK_DIR}/logo_dhcp.png" ] && mcopy -i "${MTOOLS_TARGET}" -o "${WORK_DIR}/logo_dhcp.png" ::/logo_dhcp.png || true
[ -f "${WORK_DIR}/logo.png" ]      && mcopy -i "${MTOOLS_TARGET}" -o "${WORK_DIR}/logo.png"      ::/logo.png      || true

echo "==> USB EFI System Partition contents:"
mdir -i "${MTOOLS_TARGET}" ::/
mdir -i "${MTOOLS_TARGET}" ::/EFI/BOOT/

# 7. Create a generic default boot.ipxe main menu if one does not already exist
if [ ! -f "${WORK_DIR}/boot.ipxe" ]; then
  echo "==> Creating starter ${WORK_DIR}/boot.ipxe menu..."
  cat << EOF > "${WORK_DIR}/boot.ipxe"
#!ipxe

# Re-apply 1920x1080 widescreen background with --keep so it persists across menu redraws
console --x 1920 --y 1080 --picture ${BUCKET_URL}/logo.png --keep || console --x 1366 --y 768 --picture ${BUCKET_URL}/logo.png --keep || console --x 1024 --y 768 --picture ${BUCKET_URL}/logo.png --keep || console --picture ${BUCKET_URL}/logo.png --keep ||

# Some menu defaults
set menu-timeout 60000
set submenu-timeout \${menu-timeout}
isset \${menu-default} || set menu-default glazier_prod

:start
menu Choose an operating system to boot
item --gap --             ------------------------- Glazier -------------------------
item --key g glazier_prod Boot Glazier (Production) [g]
item --key d glazier_dev  Boot Glazier (Development - NOT FOR NORMAL USE) [d]
item --gap --             ------------------------- Advanced ------------------------
item --key c config       Configure settings [c]
item shell                Drop to iPXE shell
item reboot               Reboot computer
item
item --key x exit         Exit iPXE and continue BIOS boot [x]
choose --timeout \${menu-timeout} --default \${menu-default} selected || goto cancel
set menu-timeout 0
goto \${selected}

:cancel
echo You cancelled the menu, dropping you to a shell
goto shell

:shell
echo Type 'exit' to get back to the menu
shell
set menu-timeout 0
set submenu-timeout 0
goto start

:failed
echo Booting failed, dropping to shell
goto shell

:reboot
reboot

:exit
exit

:config
config
goto start

:glazier_prod
kernel ${BUCKET_URL}/wimboot
initrd ${BUCKET_URL}/menu/autobuild.ps1          autobuild.ps1
initrd ${BOOT_URL}/Boot/BCD                      BCD
initrd ${BOOT_URL}/Boot/boot.sdi                 boot.sdi
initrd ${BOOT_URL}/sources/boot.wim              boot.wim
boot || goto failed
goto start

:glazier_dev
kernel ${BUCKET_URL}/wimboot
initrd ${BOOT_DEV_URL}/Boot/BCD                  BCD
initrd ${BOOT_DEV_URL}/Boot/boot.sdi             boot.sdi
initrd ${BOOT_DEV_URL}/sources/boot.wim          boot.wim
boot || goto failed
goto start
EOF
else
  echo "==> Existing ${WORK_DIR}/boot.ipxe found; make sure its console line uses '--x 1920 --y 1080'!"
fi

echo "==> Done! Prepared files in ${WORK_DIR}:"
ls -lh "${WORK_DIR}/shimx64.efi" \
       "${WORK_DIR}/snponly-shim.efi" \
       "${WORK_DIR}/ipxe-shim.efi" \
       "${WORK_DIR}/snponly.efi" \
       "${WORK_DIR}/ipxe.efi" \
       "${WORK_DIR}/wimboot" \
       "${WORK_DIR}/wimboot.x86_64.efi" \
       "${WORK_DIR}/autoexec.ipxe" \
       "${WORK_DIR}/boot.ipxe" \
       "${WORK_DIR}/usb/glazier-ipxe-x86_64-sb.usb"
[ -f "${WORK_DIR}/logo_dhcp.png" ] && ls -lh "${WORK_DIR}/logo_dhcp.png" || true
[ -f "${WORK_DIR}/logo.png" ]      && ls -lh "${WORK_DIR}/logo.png"      || true
