# Bundled tools

Place verified macOS builds of the following tools in `Tools/bin/` before creating a distributable bundle:

- `adb`
- `scrcpy`
- `scrcpy-server`

Do not commit binaries until the exact release, architecture, checksum, and license/NOTICE files have been recorded in the repository. Local development can use tools installed through Android SDK Platform-Tools, Homebrew, or `PATH`.
