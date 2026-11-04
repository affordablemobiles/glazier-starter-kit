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

# 2. Check for logo.png and encode it to Base64 for inline embedding into autoexec.ipxe
LOGO_FILE="${WORK_DIR}/logo.png"
LOGO_B64=""
if [ -f "${LOGO_FILE}" ]; then
  echo "==> Encoding ${LOGO_FILE} to Base64 for inline embedding into autoexec.ipxe..."
  LOGO_B64="$(base64 -w 0 "${LOGO_FILE}" 2>/dev/null || base64 "${LOGO_FILE}" | tr -d '\r\n')"
else
  echo "==> Note: ${LOGO_FILE} not found; generating text-only autoexec.ipxe."
fi

# 3. Download latest upstream iPXE and wimboot releases
echo "==> Downloading latest upstream iPXE & wimboot releases from GitHub..."
curl -fsSL "https://github.com/ipxe/ipxe/releases/latest/download/ipxeboot.tar.gz"   -o "${TMP_DIR}/ipxeboot.tar.gz"

curl -fsSL "https://github.com/ipxe/ipxe/releases/latest/download/ipxe-x86_64-sb.usb"   -o "${WORK_DIR}/usb/glazier-ipxe-x86_64-sb.usb"

curl -fsSL "https://github.com/ipxe/wimboot/releases/latest/download/wimboot"   -o "${WORK_DIR}/wimboot"

# Keep wimboot.x86_64.efi copy for backwards compatibility with older Glazier scripts
cp -f "${WORK_DIR}/wimboot" "${WORK_DIR}/wimboot.x86_64.efi"

# 4. Extract x86_64-sb Secure Boot binaries (--dereference converts symlinks into real files for GCS/TFTP)
echo "==> Extracting x86_64-sb Secure Boot binaries..."
tar -xzf "${TMP_DIR}/ipxeboot.tar.gz" --dereference -C "${TMP_DIR}/extract"

cp -f "${TMP_DIR}/extract/ipxeboot/x86_64-sb/shimx64.efi" "${WORK_DIR}/shimx64.efi"
cp -f "${TMP_DIR}/extract/ipxeboot/x86_64-sb/shimx64.efi" "${WORK_DIR}/snponly-shim.efi"
cp -f "${TMP_DIR}/extract/ipxeboot/x86_64-sb/shimx64.efi" "${WORK_DIR}/ipxe-shim.efi"
cp -f "${TMP_DIR}/extract/ipxeboot/x86_64-sb/snponly.efi" "${WORK_DIR}/snponly.efi"
cp -f "${TMP_DIR}/extract/ipxeboot/x86_64-sb/ipxe.efi"    "${WORK_DIR}/ipxe.efi"

# 5. Generate resilient autoexec.ipxe (with optional inline Base64 splash, debug hotkey, DHCP/DNS retries, and cert check)
echo "==> Generating resilient ${WORK_DIR}/autoexec.ipxe..."
cat << EOF > "${WORK_DIR}/autoexec.ipxe"
#!ipxe

# Optional 500ms 'p' hotkey to drop directly into iPXE shell for debugging
prompt --key p --timeout 500 && shell ||

EOF

if [ -n "${LOGO_B64}" ]; then
  cat << EOF >> "${WORK_DIR}/autoexec.ipxe"
# Set 1024x768 graphical framebuffer with inline splash screen BEFORE DHCP
console --x 1024 --y 768 --picture data:image/png;base64,${LOGO_B64} && goto CONSOLEOK || goto CONSOLEDONE
:CONSOLEOK
colour --rgb 0xffffff 7 ||
cpair --foreground 7 0 ||
:CONSOLEDONE

EOF
else
  cat << EOF >> "${WORK_DIR}/autoexec.ipxe"
colour --rgb 0xffffff 7 ||
cpair --foreground 7 0 ||

EOF
fi

cat << EOF >> "${WORK_DIR}/autoexec.ipxe"
set esc:hex 1b && set esc \${esc:string} ||
set cls \${esc}[2J

set dhcpretries:int32 0
set chainretries:int32 0

:DHCP_TRY
echo -n \${cls}
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
echo -n \${cls}
echo Network configured (\${ip}/\${netmask}, GW: \${gateway}, DNS: \${dns}).
echo Loading Glazier Boot Menu from \${menu_url}...
chain --autofree \${menu_url} && exit 0 ||
set lasterr:uint32 \${builtin/errno:uint32}

# Check for TLS certificate / BIOS clock skew errors
iseq \${lasterr} 0x0216e48f && goto CERTERROR ||
iseq \${lasterr} 0x0216ea8f && goto CERTERROR ||
iseq \${lasterr} 0x0216eb8f && goto CERTERROR ||
iseq \${lasterr} 0x3c00e183 && goto CERTERROR ||
iseq \${lasterr} 0x410de13c && goto CERTERROR ||

inc chainretries
iseq \${chainretries} 10 && goto FAIL_CHAIN ||
echo Download failed with error \${lasterr:hexraw} (Attempt \${chainretries}/10).
# Normalize DNS to first IPv4 DNS entry in case multiple DHCP DNS servers confused iPXE
isset \${dns:ipv4} && set dns \${dns:ipv4} || set dns 8.8.8.8
echo Retrying in 5 seconds (DNS: \${dns})...
sleep 5 ||
goto CHAIN_TRY

:CERTERROR
echo
echo [ERROR] TLS Certificate validation failed! (https://ipxe.org/\${lasterr:hexraw})
echo Most likely cause: The BIOS/CMOS clock on this device is inaccurate.
echo Current device unixtime: \${unixtime:int32}
certstat ||
goto FAIL_PROMPT

:FAIL_DHCP
set lasterr:uint32 \${builtin/errno:uint32}
echo [ERROR] Failed to obtain a DHCP lease after \${dhcpretries} attempts.
goto FAIL_INFO

:FAIL_CHAIN
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

# 6. Inject autoexec.ipxe (and logo.png if present) into the USB image (FAT filesystem at offset 0)
echo "==> Injecting autoexec.ipxe into USB image..."
USB_IMG="${WORK_DIR}/usb/glazier-ipxe-x86_64-sb.usb"
mcopy -i "${USB_IMG}" -o "${WORK_DIR}/autoexec.ipxe" ::/autoexec.ipxe
if [ -f "${LOGO_FILE}" ]; then
  echo "==> Injecting logo.png into USB image..."
  mcopy -i "${USB_IMG}" -o "${LOGO_FILE}" ::/logo.png
fi

echo "==> USB filesystem contents:"
mdir -i "${USB_IMG}" ::/

# 7. Create a generic default boot.ipxe main menu if one does not already exist
if [ ! -f "${WORK_DIR}/boot.ipxe" ]; then
  echo "==> Creating starter ${WORK_DIR}/boot.ipxe menu..."
  cat << EOF > "${WORK_DIR}/boot.ipxe"
#!ipxe

# Re-apply background with --keep so it persists across menu redraws (if available)
console --x 1024 --y 768 --picture ${BUCKET_URL}/logo.png --keep ||

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
  echo "==> Existing ${WORK_DIR}/boot.ipxe found; leaving untouched."
fi

echo "==> Done! Prepared files in ${WORK_DIR}:"
ls -lh "${WORK_DIR}/shimx64.efi"        "${WORK_DIR}/snponly-shim.efi"        "${WORK_DIR}/ipxe-shim.efi"        "${WORK_DIR}/snponly.efi"        "${WORK_DIR}/ipxe.efi"        "${WORK_DIR}/wimboot"        "${WORK_DIR}/wimboot.x86_64.efi"        "${WORK_DIR}/autoexec.ipxe"        "${WORK_DIR}/boot.ipxe"        "${WORK_DIR}/usb/glazier-ipxe-x86_64-sb.usb"
[ -f "${LOGO_FILE}" ] && ls -lh "${LOGO_FILE}" || true
