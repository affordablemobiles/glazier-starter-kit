#!/usr/bin/env python3
"""Validates scripts and configuration files in glazier-starter-kit.

Checks:
  1. Pure ASCII encoding (<= 127) across all .ps1, .cmd, .json, .yaml, .yml files.
  2. No invalid PowerShell scope references ($var: where var is not a known scope).
  3. No corrupted assignments or ASCII bell characters (\x07) from unescaped heredocs.
  4. Balanced here-strings (@"..."@ and @'...'@).
  5. Python syntax compilation (py_compile) across all .py files.
"""

import os
import py_compile
import re
import sys

KNOWN_PS_SCOPES = {
    'env',
    'script',
    'global',
    'local',
    'private',
    'using',
    'function',
    'variable',
    'alias',
    'hklm',
    'hkcu',
    'true',
    'false',
    'null',
}

ASCII_CHECK_EXTENSIONS = {'.ps1', '.cmd', '.json', '.yaml', '.yml'}
EXCLUDED_DIRS = {'.git', '.github', 'glazier', '__pycache__', 'node_modules', 'bin', 'obj'}


def check_ascii_and_powershell(root_dir='.'):
  errors = []

  for root, dirs, files in os.walk(root_dir):
    dirs[:] = [d for d in dirs if d not in EXCLUDED_DIRS]
    for filename in files:
      fpath = os.path.join(root, filename)
      relpath = os.path.relpath(fpath, root_dir)
      _, ext = os.path.splitext(filename)
      ext_lower = ext.lower()

      # 1. ASCII Encoding check
      if ext_lower in ASCII_CHECK_EXTENSIONS:
        with open(fpath, 'rb') as fp:
          content = fp.read()
        for idx, byte in enumerate(content):
          if byte >= 128:
            line_no = content[:idx].count(b'\n') + 1
            errors.append(
                f'{relpath}:{line_no}: Non-ASCII byte 0x{byte:02x} found'
            )
            break

      # 2. PowerShell-specific checks
      if ext_lower == '.ps1':
        with open(fpath, 'rb') as fp:
          raw_bytes = fp.read()

        # Check for ASCII bell character (\x07) from unescaped bash strings
        if b'\x07' in raw_bytes:
          errors.append(f'{relpath}: Found ASCII bell character \\x07')

        text = raw_bytes.decode('utf-8', errors='replace')
        lines = text.splitlines()

        # Check for corrupted lines starting with '= "' or "= '"
        for idx, line in enumerate(lines, 1):
          stripped = line.strip()
          if stripped.startswith('= "') or stripped.startswith("= '"):
            errors.append(
                f'{relpath}:{idx}: Corrupted assignment starting with "="'
            )

          # Check for invalid $var: references
          for m in re.finditer(r'\$([A-Za-z0-9_]+):', line):
            scope = m.group(1).lower()
            if scope not in KNOWN_PS_SCOPES:
              errors.append(
                  f'{relpath}:{idx}: Invalid scope prefix "${m.group(1)}:" in: {line.strip()}'
              )

        # Check here-strings balance
        hs_double_open = len(text.split('@"')) - 1
        hs_double_close = len(text.split('"@')) - 1
        if hs_double_open != hs_double_close:
          errors.append(
              f'{relpath}: Mismatched double-quote here-strings (@" vs "@): {hs_double_open} vs {hs_double_close}'
          )

        hs_single_open = len(text.split("@'")) - 1
        hs_single_close = len(text.split("'@")) - 1
        if hs_single_open != hs_single_close:
          errors.append(
              f'{relpath}: Mismatched single-quote here-strings (@\' vs \'@): {hs_single_open} vs {hs_single_close}'
          )

      # 3. Python syntax compilation check
      if ext_lower == '.py':
        try:
          py_compile.compile(fpath, doraise=True)
        except py_compile.PyCompileError as e:
          errors.append(f'{relpath}: Python compilation failed: {e}')

  return errors


def main():
  print('Running glazier-starter-kit script and syntax validation...')
  errors = check_ascii_and_powershell('.')

  if errors:
    print(f'Validation FAILED with {len(errors)} error(s):')
    for err in errors:
      print(f'  [ERROR] {err}')
    sys.exit(1)

  print('All script encoding, PowerShell scope, and Python syntax checks PASSED!')
  sys.exit(0)


if __name__ == '__main__':
  main()
