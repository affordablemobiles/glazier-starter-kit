# Google Glazier & OSDCloud Starter Kit

A production-ready starter kit combining [Google Glazier](https://github.com/google/glazier) and [OSDCloud](https://www.osdcloud.com/) to provision Windows 10 and 11 directly from Microsoft Update, with automated Cloud Build image generation and Secure Boot network booting via upstream iPXE.

## Key Features

- **Direct Microsoft CDN Streaming**: Installs official Windows 10/11 ESDs straight from Microsoft during provisioning, minimizing on-premise infrastructure requirements.
- **Automated WinPE Builder on Cloud Build**: Headless Google Cloud Build pipeline (`cloudbuild.yaml`) running on Windows Server 2025 to build, patch, and publish WinPE ISOs and netboot WIMs to Cloud Storage.
- **Native Wi-Fi & WinRE Support**: Extracts and services `WinRE.wim` directly from official Windows 11 ESDs with matching Microsoft Safe OS Dynamic Updates and client WLAN DLLs, enabling full Wi-Fi support (with interactive GUI prompt) on modern laptops.
- **Upstream Secure Boot iPXE**: Modern UEFI netbooting using official Microsoft UEFI CA signed upstream iPXE and `wimboot` binaries (`x86_64-sb`).

## Repository Overview

- **`cloudbuild.yaml`**: Cloud Build pipeline definition that orchestrates building WinPE in an ephemeral GCE VM.
- **`tools/bootstrap_winpe.ps1`**: PowerShell script executed inside the build VM to install ADK, fetch WinRE, bundle OSDCloud and MSCatalog, inject drivers, and export ISOs and `boot.wim`.
- **`tools/iPXE/`**: [UEFI network boot documentation and template](tools/iPXE/README.md).
- **`glazier-repo/`**: Glazier configuration root deployed to your web server or Cloud Storage bucket:
  - `stable/`: Windows 11 Stable configuration with management agent & software install.
  - `blank/`: Windows 11 Blank minimal configuration.
  - `win10-stable/`: Windows 10 Stable configuration.
  - `win10-blank/`: Windows 10 Blank minimal configuration.
  - `update-netboot.sh`: Automation script to fetch signed iPXE/wimboot binaries and prepare USB and HTTP netboot files.

## User-Supplied Assets & Configuration

To keep this repository public-safe, company-specific files and binary installers are excluded via `.gitignore`. Users should supply:

1. **Unattend Files**: Copy `unattend.xml.example` to `unattend.xml` in each desired configuration folder (e.g. `glazier-repo/stable/config/unattend.xml`) and adjust settings/passwords.
2. **Software Packages**: Place any required deployment tools in `config/` (such as the Office Deployment Tool executable or management client installer).
3. **Boot Splash Screen (Optional)**: Place an 8-bit indexed 1920x1080 (or 1024x768) PNG named `logo_dhcp.png` (for Stage 1 pre-DHCP) and/or `logo.png` (for Stage 2 boot menu) into `glazier-repo/` before running `update-netboot.sh` (see [tools/iPXE/README.md](tools/iPXE/README.md) for image specs).
4. **Cloud Build Substitutions**: Provide your GCP bucket and service account details via Cloud Build trigger substitutions:
   - `_CONFIG_SERVER`: URL of your config bucket/server (e.g., `https://storage.googleapis.com/<YOUR-CONFIG-BUCKET>/`)
   - `_STORAGE_BOOT_UPLOAD_PATH`: GCS path for PXE boot files (e.g., `gs://<YOUR-BUCKET>/winpe`)
   - `_STORAGE_UPLOAD_PATH`: GCS path for bootable ISOs (e.g., `gs://<YOUR-BUCKET>/winpe/OSDCloud-WinPE-Glazier`)
   - `_SERVICEACCOUNT`: Custom GCE service account for the builder VM.