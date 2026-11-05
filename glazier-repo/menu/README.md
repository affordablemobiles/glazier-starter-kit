# Interactive WinPE Menu Profile

This folder provides the `autobuild.ps1` script for the interactive menu ISO flavor (`OSDCloud-WinPE-Glazier-menu.iso`).

When booted into WinPE, it launches a native graphical WPF/WinForms profile chooser that:
1. Dynamically fetches `profiles.json` (or falls back to `version-info.yaml`) from the GCS configuration bucket.
2. Presents a profile selection dropdown, build description, and auto-start countdown timer.
3. Automatically launches Glazier (`autobuild.py`) with `--glazier_spec_os=<chosen-profile>`.
