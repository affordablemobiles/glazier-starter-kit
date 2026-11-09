#!/usr/bin/env python3
"""Validates scripts and configuration files in glazier-starter-kit.

Checks:
  1. Pure ASCII encoding (<= 127) across all .ps1, .cmd, .json, .yaml, .yml files.
  2. No invalid PowerShell scope references ($var: where var is not a known scope).
  3. No corrupted assignments or ASCII bell characters (\x07) from unescaped heredocs.
  4. Balanced here-strings (@"..."@ and @'...'@) and balanced braces ({ vs }).
  5. No unparenthesized arithmetic (+ or -) in any New-Object argument.
  6. File synchronization across mirrors (glazier-repo vs tools/resources).
  7. Python syntax compilation (py_compile) across all .py files without writing .pyc files.
"""

import os
import py_compile
import re
import sys
import tempfile

sys.dont_write_bytecode = True

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

SYNCED_FILE_PAIRS = [
    (
        'glazier-resources/GlazierDeploymentGUI.ps1',
        'glazier-repo/glazier-resources/GlazierDeploymentGUI.ps1',
    ),
    (
        'glazier-resources/GlazierWiFi.ps1',
        'glazier-repo/glazier-resources/GlazierWiFi.ps1',
    ),
    (
        'glazier-resources/Stage-GlazierWifiProfiles.ps1',
        'glazier-repo/glazier-resources/Stage-GlazierWifiProfiles.ps1',
    ),
    (
        'glazier-repo/menu/autobuild.ps1',
        'tools/autobuild-menu.ps1',
    ),
]


def has_unparenthesized_new_object_arithmetic(line):
  """Checks if any comma-separated argument in New-Object has unparenthesized arithmetic."""
  if 'New-Object' not in line:
    return False

  idx = 0
  while True:
    no_pos = line.find('New-Object', idx)
    if no_pos == -1:
      break
    open_paren = line.find('(', no_pos)
    if open_paren == -1:
      break

    depth = 0
    arg_start = open_paren + 1
    arg_tokens = []
    i = open_paren
    while i < len(line):
      c = line[i]
      if c == '(':
        depth += 1
      elif c == ')':
        depth -= 1
        if depth == 0:
          arg_tokens.append(line[arg_start:i].strip())
          break
      elif c == ',' and depth == 1:
        arg_tokens.append(line[arg_start:i].strip())
        arg_start = i + 1
      i += 1

    for arg in arg_tokens:
      is_parenthesized = False
      if arg.startswith('(') and arg.endswith(')'):
        d = 0
        for ci, ch in enumerate(arg):
          if ch == '(':
            d += 1
          elif ch == ')':
            d -= 1
            if d == 0 and ci == len(arg) - 1:
              is_parenthesized = True
      elif arg.startswith('[') and arg.endswith(']'):
        is_parenthesized = True

      if not is_parenthesized:
        if re.search(r'(\$[A-Za-z0-9_.:]+|\d+)\s+[-+]\s+', arg):
          return True

    idx = (i + 1) if depth == 0 else (no_pos + 10)

  return False


def check_ps_braces(text, relpath):
  """Checks that braces are properly balanced outside strings and comments."""
  stripped_text = re.sub(r'(?s)@"[ \t]*\r?\n.*?\r?\n[ \t]*"@', '', text)
  stripped_text = re.sub(r"(?s)@'[ \t]*\r?\n.*?\r?\n[ \t]*'@", '', stripped_text)
  stripped_text = re.sub(r'(?s)<#.*?#>', '', stripped_text)

  lines = stripped_text.splitlines()
  brace_depth = 0
  for idx, line in enumerate(lines, 1):
    clean = ''
    in_sq = False
    in_dq = False
    i = 0
    while i < len(line):
      c = line[i]
      if c == "'" and not in_dq:
        in_sq = not in_sq
      elif c == '"' and not in_sq:
        in_dq = not in_dq
      elif c == '#' and not in_sq and not in_dq:
        break
      elif not in_sq and not in_dq:
        clean += c
      i += 1

    for c in clean:
      if c == '{':
        brace_depth += 1
      elif c == '}':
        brace_depth -= 1
        if brace_depth < 0:
          return f'{relpath}:{idx}: Unexpected closing brace "}}"'

  if brace_depth != 0:
    return f'{relpath}: Mismatched braces (net depth {brace_depth})'

  return None


def check_ascii_and_powershell(root_dir='.'):
  errors = []

  # Check synced file pairs
  for path1, path2 in SYNCED_FILE_PAIRS:
    p1 = os.path.join(root_dir, path1)
    p2 = os.path.join(root_dir, path2)
    if os.path.exists(p1) and os.path.exists(p2):
      with open(p1, 'rb') as f1, open(p2, 'rb') as f2:
        if f1.read() != f2.read():
          errors.append(f'File sync mismatch between {path1} and {path2}')
    elif os.path.exists(p1) != os.path.exists(p2):
      errors.append(f'File sync missing counterpart between {path1} and {path2}')

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

          # Check for unparenthesized binary + or - arithmetic inside New-Object ...(...) argument lists
          if has_unparenthesized_new_object_arithmetic(line):
            errors.append(
                f'{relpath}:{idx}: Unparenthesized arithmetic inside New-Object arguments in: {line.strip()}'
            )

        # Check here-strings balance
        hs_double_open = len(re.findall(r'@"\s*\r?\n', text))
        hs_double_close = len(re.findall(r'(?m)^\s*"@', text))
        if hs_double_open != hs_double_close:
          errors.append(
              f'{relpath}: Mismatched double-quote here-strings (@" vs "@): {hs_double_open} vs {hs_double_close}'
          )

        hs_single_open = len(re.findall(r"@'\s*\r?\n", text))
        hs_single_close = len(re.findall(r"(?m)^\s*'@", text))
        if hs_single_open != hs_single_close:
          errors.append(
              f'{relpath}: Mismatched single-quote here-strings (@\' vs \'@): {hs_single_open} vs {hs_single_close}'
          )

        # Check brace balance
        brace_err = check_ps_braces(text, relpath)
        if brace_err:
          errors.append(brace_err)

      # 3. Python syntax compilation check without persisting .pyc files
      if ext_lower == '.py':
        temp_pyc = None
        try:
          with tempfile.NamedTemporaryFile(suffix='.pyc', delete=False) as tf:
            temp_pyc = tf.name
          py_compile.compile(fpath, cfile=temp_pyc, doraise=True)
        except py_compile.PyCompileError as e:
          errors.append(f'{relpath}: Python compilation failed: {e}')
        finally:
          if temp_pyc and os.path.exists(temp_pyc):
            try:
              os.remove(temp_pyc)
            except OSError:
              pass

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
