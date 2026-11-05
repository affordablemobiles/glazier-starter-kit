# GCS TFTP Server (`gcs-tftp-server`)

A lightweight, stateless, read-only TFTP server written in Go that serves files directly from a public Google Cloud Storage (GCS) bucket over HTTPS—requiring **zero local boot files** and **zero Google Cloud credentials**.

Designed for PXE / UEFI Secure Boot network booting with [iPXE](https://ipxe.org/) and [Glazier](https://github.com/google/glazier), allowing IT staff or remote branch locations to run a local TFTP relay backed by a central cloud bucket.

## Key Features

- **Stateless & Credential-Free:** Fetches requested TFTP paths directly from `https://storage.googleapis.com/<GCS_BUCKET>/<path>`.
- **In-Memory TTL Cache (`CACHE_TTL=5m`):** Caches downloaded `.efi` and `.ipxe` files in RAM so multi-block TFTP transfers run at local LAN speed while automatically picking up bucket updates once the TTL expires.
- **Single-Port UDP Mode (`TFTP_SINGLE_PORT=true`):** Serves all TFTP traffic over UDP port `69` rather than ephemeral high UDP ports, making Docker port publishing (`-p 69:69/udp`) and local host firewalls effortless.
- **UEFI PXE Path Normalization:** Automatically strips trailing null bytes (`\x00`), converts Windows-style backslashes (`\`) to forward slashes (`/`), and blocks directory traversal (`..`).

---

## Configuration

All options can be configured via environment variables or command-line flags:

| Environment Variable | CLI Flag | Default | Description |
| :--- | :--- | :--- | :--- |
| `GCS_BUCKET` | `-bucket` | *(Required)* | Name of the publicly readable Google Cloud Storage bucket |
| `GCS_PREFIX` | `-prefix` | `""` | Optional folder prefix inside the bucket (e.g., `netboot`) |
| `TFTP_LISTEN` | `-listen` | `:69` | UDP address and port to listen on |
| `TFTP_SINGLE_PORT` | `-single-port` | `true` | Serve all TFTP transfers over port `69/udp` |
| `CACHE_TTL` | `-cache-ttl` | `5m` | In-memory cache duration per file (`0s` to disable caching) |
| `TFTP_TIMEOUT` | `-timeout` | `5s` | TFTP block ACK timeout |

---

## Usage Option 1: Docker

Pre-built multi-architecture (`linux/amd64` and `linux/arm64`) images are published to GitHub Container Registry:

```bash
docker run -d \
  --name gcs-tftp-server \
  --restart unless-stopped \
  -p 69:69/udp \
  -e GCS_BUCKET="your-public-gcs-bucket" \
  ghcr.io/affordablemobiles/glazier-starter-kit/gcs-tftp-server:latest
```

---

## Usage Option 2: Docker Compose

1. Copy `docker-compose.yml` to your host and set `GCS_BUCKET` in a `.env` file (or inline):

```bash
echo "GCS_BUCKET=your-public-gcs-bucket" > .env
docker compose up -d
```
2. View live TFTP transfer logs:

```bash
docker compose logs -f
```

---

## Usage Option 3: Linux `systemd` Service

1. **Build and install the binary:**

```bash
cd tools/gcs-tftp-server
CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o gcs-tftp-server main.go
sudo install -m 0755 gcs-tftp-server /usr/local/bin/gcs-tftp-server
```
2. **Install the configuration and `systemd` unit:**

```bash
sudo install -m 0644 gcs-tftp-server.default /etc/default/gcs-tftp-server
sudo install -m 0644 gcs-tftp-server.service /etc/systemd/system/gcs-tftp-server.service
```
3. **Set your bucket name in `/etc/default/gcs-tftp-server`:**

```bash
sudo sed -i 's/GCS_BUCKET=.*/GCS_BUCKET=your-public-gcs-bucket/' /etc/default/gcs-tftp-server
```
4. **Enable and start the service:**

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now gcs-tftp-server
sudo journalctl -u gcs-tftp-server -f
```

> **Note:** On Ubuntu/Debian systems where `systemd-resolved` or `dnsmasq` is running, ensure nothing else is already bound to `0.0.0.0:69/udp` (`sudo ss -ulnp | grep :69`).

---

## DHCP Server Configuration
Configure your local DHCP server (Windows Server DHCP, dnsmasq, Ubiquiti UniFi, pfSense/OPNsense, etc.) with:

- **DHCP Option 66 (`Next Server` / `TFTP Server`):** `<IP address of the host running gcs-tftp-server>`
- **DHCP Option 67 (`Bootfile Name`):** `snponly-shim.efi` (or `ipxe-shim.efi` for full iPXE driver support)
