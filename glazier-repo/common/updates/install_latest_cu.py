#!/usr/bin/env python3
"""Dynamically resolves the latest Windows Cumulative Update (and any layered
Checkpoint KBs + SHA256 hashes) from the Microsoft Update Catalog and hands
them off to Glazier's native UpdateMSU action.
"""

import argparse
import base64
from datetime import datetime
import html
import json
import ntpath
import os
import re
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# Ensure X:\glazier and C:\glazier are on sys.path when invoked in WinPE or host
for glazier_path in (r'X:\glazier', r'C:\glazier'):
  if os.path.isdir(glazier_path) and glazier_path not in sys.path:
    sys.path.insert(0, glazier_path)

from glazier.lib import buildinfo
from glazier.lib import logs
from glazier.lib.actions import updates

logging = logs.logging

CATALOG_SEARCH_URL = 'https://www.catalog.update.microsoft.com/Search.aspx?q={}'
CATALOG_DIALOG_URL = 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx'

# Build number to (OS Name, Primary Version, Fallback Version) mapping
BUILD_MAP = {
    '26200': ('Windows 11', '25H2', '24H2'),
    '26100': ('Windows 11', '24H2', '25H2'),
    '22631': ('Windows 11', '23H2', '22H2'),
    '22621': ('Windows 11', '22H2', None),
    '19045': ('Windows 10', '22H2', None),
    '19044': ('Windows 10', '21H2', '22H2'),
}


def fetch_with_retry(
    url: str,
    data: bytes = None,
    headers: dict = None,
    retries: int = 5,
    base_delay: float = 3.0,
    timeout: int = 30,
) -> str:
  """Performs an HTTP GET/POST request with exponential backoff and SSL fallback."""
  req_headers = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'}
  if headers:
    req_headers.update(headers)

  last_err = None
  for attempt in range(1, retries + 1):
    for use_machine_ctx in (False, True):
      try:
        req = urllib.request.Request(url, data=data, headers=req_headers)
        ctx = None
        if use_machine_ctx:
          ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        elif os.environ.get('SSL_CERT_FILE') and os.path.exists(
            os.environ['SSL_CERT_FILE']
        ):
          ctx = ssl.create_default_context(cafile=os.environ['SSL_CERT_FILE'])

        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
          if resp.getcode() == 200:
            return resp.read().decode('utf-8', errors='ignore')
          raise urllib.error.HTTPError(
              url, resp.getcode(), f'Unexpected HTTP {resp.getcode()}', resp.headers, None
          )
      except Exception as e:  # pylint: disable=broad-except
        last_err = e
        if not use_machine_ctx:
          continue

    if attempt < retries:
      sleep_sec = base_delay * (2 ** (attempt - 1))
      logging.warning(
          'Catalog request to %s failed (attempt %d/%d): %s. Retrying in %.1fs...',
          url,
          attempt,
          retries,
          last_err,
          sleep_sec,
      )
      time.sleep(sleep_sec)

  raise RuntimeError(
      f'Catalog request to {url} failed after {retries} attempts: {last_err}'
  )


def detect_offline_os(target_drive: str = r'C:\\') -> tuple:
  """Detects (os_name, primary_ver, fallback_ver, arch) from offline C:\\Windows."""
  software_hive = os.path.join(
      target_drive, 'Windows', 'System32', 'config', 'SOFTWARE'
  )
  temp_key = r'HKLM\GLAZIER_OFFLINE_SW'
  build_num = None
  display_ver = None
  arch = 'x64'

  if os.path.exists(software_hive):
    try:
      subprocess.run(
          ['reg.exe', 'load', temp_key, software_hive],
          check=True,
          stdout=subprocess.PIPE,
          stderr=subprocess.PIPE,
      )
      res = subprocess.run(
          [
              'reg.exe',
              'query',
              rf'{temp_key}\Microsoft\Windows NT\CurrentVersion',
          ],
          check=True,
          stdout=subprocess.PIPE,
          stderr=subprocess.PIPE,
          text=True,
      )
      for line in res.stdout.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3:
          name, _, val = parts
          if name in ('CurrentBuild', 'CurrentBuildNumber'):
            build_num = val.strip()
          elif name == 'DisplayVersion':
            display_ver = val.strip().upper()
          elif name == 'BuildLabEx' and 'arm64' in val.lower():
            arch = 'arm64'
    except Exception as e:  # pylint: disable=broad-except
      logging.warning('Failed to read offline registry hive: %s', e)
    finally:
      subprocess.run(
          ['reg.exe', 'unload', temp_key],
          stdout=subprocess.PIPE,
          stderr=subprocess.PIPE,
      )

  if build_num in BUILD_MAP:
    os_name, mapped_ver, fallback_ver = BUILD_MAP[build_num]
    if display_ver and re.match(r'^\d{2}H\d$', display_ver):
      if display_ver != mapped_ver:
        fallback_ver = mapped_ver
        mapped_ver = display_ver
    logging.info(
        'Detected offline OS on %s -> %s %s (Build %s, Arch %s)',
        target_drive,
        os_name,
        mapped_ver,
        build_num,
        arch,
    )
    return os_name, mapped_ver, fallback_ver, arch
  elif build_num and build_num.isdigit():
    # Future-proofing: Auto-detect future Windows 10/11 major releases dynamically
    os_name = 'Windows 11' if int(build_num) >= 22000 else 'Windows 10'
    mapped_ver = (
        display_ver
        if display_ver and re.match(r'^\d{2}H\d$', display_ver)
        else None
    )
    if mapped_ver:
      logging.info(
          'Detected offline OS on %s -> %s %s (Build %s, Arch %s) via registry DisplayVersion',
          target_drive,
          os_name,
          mapped_ver,
          build_num,
          arch,
      )
      return os_name, mapped_ver, None, arch

  raise RuntimeError(
      f'Could not auto-detect Windows build from {software_hive} (build={build_num})'
  )


def find_latest_cu_update_id(os_name: str, os_ver: str, arch: str = 'x64') -> tuple:
  """Searches the Microsoft Update Catalog for the latest monthly Cumulative Update."""
  query = f'Cumulative Update for {os_name} Version {os_ver} for {arch}-based Systems'
  search_url = CATALOG_SEARCH_URL.format(urllib.parse.quote(query))
  logging.info('Searching Microsoft Update Catalog: "%s"', query)

  page_html = fetch_with_retry(search_url)

  # Title pattern: matches monthly Cumulative Updates, optional comma before version,
  # optional build suffix like (26100.9725), while excluding Preview, Dynamic Update,
  # .NET Framework, Server, and Out-of-Band non-standard titles.
  title_regex = re.compile(
      rf'^\d{{4}}-\d{{2}}\s+Cumulative Update for {re.escape(os_name)}'
      rf'[,]?\s+version\s+{re.escape(os_ver)}\s+for\s+{re.escape(arch)}-based\s+Systems\s+\(KB\d+\)'
      rf'(?:\s+\([0-9.]+\))?$',
      re.IGNORECASE,
  )

  row_pattern = re.compile(
      r'<tr\s+id=[\'"]([0-9a-fA-F-]{36})_R\d+[\'"].*?</tr>', re.DOTALL
  )
  candidates = []
  for row_match in row_pattern.finditer(page_html):
    update_id = row_match.group(1)
    row_html = row_match.group(0)

    title_match = re.search(
        r'id=[\'"][0-9a-fA-F-]+_link[\'"][^>]*>\s*(.*?)\s*</a>', row_html, re.DOTALL
    )
    if not title_match:
      continue
    title = html.unescape(re.sub(r'<[^>]+>', '', title_match.group(1))).strip()

    if not title_regex.match(title):
      continue

    date_match = re.search(r'(\d{1,2}/\d{1,2}/\d{4})', row_html)
    parsed_date = (
        datetime.strptime(date_match.group(1), '%m/%d/%Y')
        if date_match
        else datetime.min
    )
    candidates.append((parsed_date, update_id, title))

  if not candidates:
    return None

  candidates.sort(key=lambda x: x[0], reverse=True)
  best_date, best_id, best_title = candidates[0]
  logging.info(
      'Selected latest Cumulative Update: "%s" (UpdateID: %s, Date: %s)',
      best_title,
      best_id,
      best_date.strftime('%Y-%m-%d') if best_date != datetime.min else 'Unknown',
  )
  return best_id, best_title


def resolve_layered_msu_packages(update_id: str, cache_dir: str) -> list:
  """Queries DownloadDialog.aspx and returns ordered [[url, local_path, hex_sha256], ...]."""
  payload = json.dumps(
      [{'size': 0, 'languages': '', 'uidInfo': update_id, 'updateID': update_id}]
  )
  post_data = urllib.parse.urlencode({'updateIDs': payload}).encode('utf-8')
  headers = {'Content-Type': 'application/x-www-form-urlencoded'}

  dialog_html = fetch_with_retry(CATALOG_DIALOG_URL, data=post_data, headers=headers)

  prop_pattern = re.compile(
      r"downloadInformation\[\d+\]\.files\[(\d+)\]\.(url|sha256|digest)\s*=\s*['\"]([^'\"]*)['\"];"
  )
  files_map = {}
  for match in prop_pattern.finditer(dialog_html):
    idx = int(match.group(1))
    prop = match.group(2)
    val = match.group(3)
    files_map.setdefault(idx, {})[prop] = val

  if not files_map:
    raise RuntimeError(
        f'No download files returned by DownloadDialog.aspx for UpdateID {update_id}'
    )

  layers = []
  for idx in sorted(files_map.keys()):
    entry = files_map[idx]
    url = entry.get('url', '')
    if not url.lower().endswith('.msu'):
      logging.info('Skipping non-MSU file in catalog bundle: %s', url)
      continue

    filename = url.split('/')[-1]
    kb_match = re.search(r'(kb(\d+))', filename, re.IGNORECASE)
    kb_name = kb_match.group(1).lower() if kb_match else f'update_{idx}'
    kb_num = int(kb_match.group(2)) if kb_match else (99999999 + idx)

    b64_sha256 = entry.get('sha256')
    # If the catalog provided a Base64 SHA256, convert to lowercase hex.
    # If missing/empty (as on some legacy Windows 10 catalog entries), keep as None.
    hex_sha256 = None
    if b64_sha256:
      hex_sha256 = base64.b64decode(b64_sha256).hex().lower()

    local_path = ntpath.join(cache_dir, f'{kb_name}.msu')

    layers.append({
        'kb_name': kb_name,
        'kb_num': kb_num,
        'url': url,
        'local_path': local_path,
        'sha256': hex_sha256,
    })

  if not layers:
    raise RuntimeError(
        f'No .msu files found in DownloadDialog.aspx for UpdateID {update_id}'
    )

  # CRITICAL FOR UPDATE LAYERING:
  # Sort ascending by KB number so prerequisite Checkpoint CUs (e.g. KB5043080)
  # are always downloaded and applied BEFORE the dependent monthly LCU (e.g. KB5134133).
  layers.sort(key=lambda x: x['kb_num'])

  msu_args = []
  for i, layer in enumerate(layers, 1):
    logging.info(
        'Layer %d/%d: %s -> %s (SHA256: %s)',
        i,
        len(layers),
        layer['kb_name'].upper(),
        layer['local_path'],
        layer['sha256'] if layer['sha256'] else 'Not published by catalog',
    )
    if layer['sha256']:
      msu_args.append([layer['url'], layer['local_path'], layer['sha256']])
    else:
      msu_args.append([layer['url'], layer['local_path']])

  return msu_args


def main():
  parser = argparse.ArgumentParser(
      description='Resolve and install latest Windows Cumulative Update via Glazier UpdateMSU.'
  )
  parser.add_argument('--os-name', help='e.g. "Windows 11" or "Windows 10"')
  parser.add_argument('--os-version', help='e.g. "25H2", "24H2", "23H2", "22H2"')
  parser.add_argument('--fallback-version', help='Optional fallback version (e.g. "24H2")')
  parser.add_argument('--arch', default='x64', help='Architecture (default: x64)')
  parser.add_argument(
      '--cache-dir', default=r'C:\glazier_cache', help='Local cache directory'
  )
  args = parser.parse_args()

  os.makedirs(args.cache_dir, exist_ok=True)

  if args.os_name and args.os_version:
    os_name = args.os_name
    os_ver = args.os_version
    fallback_ver = args.fallback_version
    arch = args.arch
  else:
    os_name, os_ver, fallback_ver, arch = detect_offline_os(r'C:\\')

  result = find_latest_cu_update_id(os_name, os_ver, arch)
  if not result and fallback_ver:
    logging.warning(
        'No Cumulative Update found for %s %s; falling back to %s %s...',
        os_name,
        os_ver,
        os_name,
        fallback_ver,
    )
    result = find_latest_cu_update_id(os_name, fallback_ver, arch)

  if not result:
    raise RuntimeError(
        f'Unable to find any Cumulative Update in Microsoft Update Catalog for {os_name} {os_ver}'
    )

  update_id, _ = result
  msu_args = resolve_layered_msu_packages(update_id, args.cache_dir)

  logging.info(
      'Handing off %d layered MSU package(s) to Glazier UpdateMSU...',
      len(msu_args),
  )
  bi = buildinfo.BuildInfo()
  um = updates.UpdateMSU(msu_args, bi)
  um.Validate()
  um.Run()
  logging.info('Successfully slipstreamed all Cumulative Update layers.')


if __name__ == '__main__':
  main()
