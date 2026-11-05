# UEFI Network Booting (Secure Boot Enabled)

In a controlled network environment, UEFI network booting is possible with Microsoft Secure Boot enabled.

`iPXE` and `wimboot` are used to load the Glazier `WinPE` image over HTTP/HTTPS.

## Upstream iPXE Secure Boot Signing

Historically, booting iPXE under Secure Boot required third-party signed binaries such as 2Pint iPXE Anywhere. Upstream [iPXE](https://ipxe.org) now provides official signed Secure Boot binaries (`x86_64-sb`) via GitHub releases:

- **shimx64.efi**: Microsoft UEFI CA signed shim bootloader.
- **snponly.efi**: Standard UEFI Simple Network Protocol driver.
- **ipxe.efi**: Full iPXE binary with native network drivers.
- **wimboot**: Official Secure Boot signed bootloader for booting Windows PE from RAM.

The `glazier-repo/update-netboot.sh` script automatically downloads and prepares these official upstream binaries, generates a bootable USB image (`usb/glazier-ipxe-x86_64-sb.usb`), and configures the `autoexec.ipxe` loader.

## Custom Splash Screen (logo.png) Specifications

If you wish to display custom branding splash screens during iPXE boot:

- **File Names**:
  - `logo_dhcp.png`: Splash screen displayed during Stage 1 (hardware init and DHCP in `autoexec.ipxe`). If omitted, `update-netboot.sh` falls back to `logo.png` (or text mode if neither is present).
  - `logo.png`: Splash screen displayed during Stage 2 (interactive boot menu in `boot.ipxe`).
- **Resolution**: `1920x1080` (native 16:9 widescreen Full HD recommended for modern UEFI laptops) or `1024x768`.
- **Color Depth / Format**: **8-bit Indexed PNG (colormap palette)**, non-interlaced, 256 colors maximum.
- **Why this format matters**: iPXE uses a minimalist embedded PNG decoder. 24-bit/32-bit truecolor or interlaced PNGs can cause memory allocation errors or fail to render in early UEFI video modes.
- **Tooling to generate compatible PNGs**:
  ```bash
  # Using ImageMagick:
  convert input.png -resize 1920x1080\! -colors 256 -type Palette png8:logo.png
  
  # Using pngquant:
  pngquant 256 --strip input.png -o logo.png
  ```
- **Embedding**: When `logo_dhcp.png` (or `logo.png`) is present, `glazier-repo/update-netboot.sh` automatically encodes it into Base64 and embeds it inline into `autoexec.ipxe`, as well as copying all present splash images to the root of the USB boot image. If omitted, a clean text console is used. When errors occur during DHCP or chaining, `autoexec.ipxe` automatically drops the splash screen back to standard text console mode so debug output is clear and unobstructed.

## Configuration & Boot Files

- **`glazier-repo/netboot.env.example`**: Example environment file for `update-netboot.sh`. Copy to `glazier-repo/netboot.env` (gitignored) to set your bucket endpoints.
- **`tools/iPXE/Boot.ipxe`**: Example iPXE boot menu template. Replace `CHANGE_ME` with your Cloud Storage bucket URL.
- **`glazier-repo/update-netboot.sh`**: Helper script to fetch latest upstream iPXE/wimboot releases and configure the netboot environment.
- **DHCP Option 67 / Boot File**: Set to `shimx64.efi` for UEFI clients.