# LG Dual Mode for Gamescope

Switch an LG 27GM950B from its 5K165 desktop mode to 1440p330 for fullscreen
Gamescope, then restore the saved GNOME display configuration when Gamescope exits.
One installed Lua file handles both startup and the independent lifecycle watcher.

> **Experimental, with live validation on one setup.**
> Normal exit, Gamescope SIGKILL and watcher SIGKILL restored the saved desktop
> on an LG 27GM950B under Fedora 45 / GNOME 51.1. Visible output on the intended
> monitor was confirmed. See [tested compatibility](docs/VALIDATION.md) for
> exact versions and remaining limits.

**Keep the mouse pointer on the gaming LG during launch and reconnection.**
GNOME chooses the window's output; this script does not pin Gamescope to a monitor.
Switching Dual Mode briefly blanks the monitor.

## Requirements

- **LG 27GM950B**, identified by EDID vendor/product **GSM / 0x5cf8**.
  Other LG models are not assumed compatible.
- GNOME on Wayland, with Mutter's display configuration interface available.
- Gamescope with Lua scripting, plus a separate **LuaJIT interpreter** with FFI.
- `ddcutil`, working DDC/CI access and the necessary I2C permissions.
- A systemd user session, systemd **254+**, `timeout` and `env`.
- GLib/GIO shared libraries and Linux pidfd support.

Live validation used Gamescope 3.16.29, GNOME 51.1 and systemd 262. These are not
verified minimum versions. Gamescope's scripting API is
[experimental](https://github.com/ValveSoftware/gamescope/blob/master/scripts/README.md).
This integration targets a desktop GNOME session, not SteamOS Gaming Mode.

## Install

Install from the latest GitHub release:

```sh
curl -fsSL https://github.com/smazurov/gamescope-lg-dual-mode/releases/latest/download/install.sh | bash
```

This executes the downloaded installer as your user. It downloads both installation
files from its own pinned release tag before running preflight; a new `latest`
release cannot mix their versions. Failed or empty downloads abort installation,
and temporary downloads are removed on success or failure. `curl` is required for
this path. For a fixed version, replace `latest/download` with `download/v0.1.0`.

To check prerequisites without installing:

```sh
curl -fsSL https://github.com/smazurov/gamescope-lg-dual-mode/releases/latest/download/install.sh | bash -s -- --check
```

### Install from a checkout

From a reviewed source checkout or extracted release, keep
`gamescope-lg-dual-mode.lua` and `install.sh` in the same directory:

```sh
make check-install   # Read-only preflight; installs nothing
make install         # Preflight, then install one user-local Lua file
```

For a two-file download, or without Make, use `bash install.sh --check` and
`bash install.sh` directly.

Run as your desktop user, **not with sudo**. The installer checks the desktop,
executables, Gamescope script loader, systemd user manager, pidfd support,
monitor identity, enabled layout and read-only DDC access. It never installs
packages, writes monitor settings or switches display modes during preflight.
An unrecognized Gamescope wrapper may fail the loader check.

Exactly one file is copied to:

```text
${XDG_CONFIG_HOME:-$HOME/.config}/gamescope/scripts/90-lg-dual-mode.lua
```

The downloaded files can be removed afterward. No Python helper, permanent
daemon, Gamescope patch, GNOME extension or Steam configuration change is needed.
Existing symlinks and unrelated files are never overwritten. Resolve a conflicting
installation before installing this script.

## Launch a game

Existing fullscreen 1440p Gamescope launch options work unchanged:

```sh
gamescope --backend wayland -w 2560 -h 1440 -W 2560 -H 1440 -f -- %command%
```

Only fullscreen 2560×1440 output with the Wayland or automatic backend under
GNOME Wayland is managed. Windowed launches, other resolutions, other backends,
help commands and unsupported monitors are skipped. Mirrored LG layouts are
rejected before switching. Gamescope adaptive sync is enabled for managed launches.

If several supported LGs are connected, select one explicitly:

```sh
GAMESCOPE_LG_MONITOR_SERIAL=YOUR_SERIAL gamescope ... -- %command%
```

Bypass switching for one launch:

```sh
GAMESCOPE_LG_DUAL_MODE=0 gamescope ... -- %command%
```

## Restore the desktop

The Gamescope startup hook launches the **same Lua file** through the host LuaJIT
interpreter in a transient systemd user service. The watcher:

1. Saves Mutter's display configuration before any monitor write.
2. Sends LG VCP `B1 = 0x2100`, then waits for the high-refresh modes to appear.
3. Applies 2560×1440 above 300 Hz, preserving the original VRR preference and
   other displays' settings. It chooses a supported scale closest to the saved
   desktop's logical size.
4. Watches Gamescope through a pidfd, without polling DDC during gameplay.
5. Sends `B1 = 0x2200` if it enabled Dual Mode, then restores the saved desktop.

If the monitor started in Dual Mode, it stays in Dual Mode on exit. Only one
managed session can hold the lock at a time. Saved settings include resolution,
refresh-rate mode, scaling, positions, transforms, primary display and color mode.

The service's `ExecStopPost` invokes recovery if the watcher is terminated. A
later launch also attempts recovery of an abandoned snapshot. Failed restoration
keeps the snapshot for another attempt. Connected-monitor changes cause layout
restoration to fail rather than silently removing a newly connected display.

Normal exit, Gamescope SIGKILL and watcher SIGKILL have live validation on the
recorded setup. Recovery still depends on the desktop session and runtime snapshot
remaining available; it is not a guarantee across logout, reboot or power loss.
Color settings were checked during restoration; end-to-end HDR rendering has not
been validated. Already-in-Dual-Mode behavior and hotplug refusal have hardware-free
coverage only.

## Diagnose or recover

```sh
script="${XDG_CONFIG_HOME:-$HOME/.config}/gamescope/scripts/90-lg-dual-mode.lua"
luajit -E "$script" --check     # Read-only
luajit -E "$script" --recover   # Writes monitor/display settings if a snapshot exists
journalctl --user -u 'gamescope-lg-lua-*' -n 100
```

Do not run recovery against a display you cannot afford to interrupt. Snapshots
use GLib's typed GVariant format and user-only permissions at
`$XDG_RUNTIME_DIR/gamescope-lg-dual-mode/session.gv`. Invalid snapshots are
rejected before hardware commands. There is no Lua D-Bus or JSON dependency.
Redact monitor serials and personal paths before sharing logs or snapshots.

## Update or uninstall

Close managed Gamescope sessions and restore the desktop first:

```sh
make upgrade
make uninstall
```

Both actions refuse unrelated files and symlinks. Uninstall removes only
a recognized, inactive standalone copy, not logs or recovery snapshots. Keep a
copy of the checkout, or run `bash install.sh --upgrade` / `bash install.sh --uninstall`
directly from the same reviewed version. The release one-liner also accepts flags:

```sh
curl -fsSL https://github.com/smazurov/gamescope-lg-dual-mode/releases/latest/download/install.sh | bash -s -- --upgrade
curl -fsSL https://github.com/smazurov/gamescope-lg-dual-mode/releases/latest/download/install.sh | bash -s -- --uninstall
```

## Test without hardware

Development dependencies: LuaJIT, GLib/GIO, Bash, Make,
[Luacheck](https://github.com/lunarmodules/luacheck) and ShellCheck. No Gamescope,
GNOME session, systemd user manager or DDC hardware is needed for the tests.

```sh
make check
```

Tests exercise configuration serialization, VRR/HDR preservation, rollback,
recovery, locking, monitor identity, argument parsing, shell quoting and isolated
installation/update/removal. Release-download tests use a fake curl and verify
version-pinned asset URLs, failure cleanup and argument forwarding without network
access. Installer tests use a fake LuaJIT and temporary HOME/configuration/runtime
directories, and must run as a non-root user.
`make check` also runs Luacheck with the LuaJIT standard and a narrowly defined
Gamescope global, plus Bash syntax checks and ShellCheck. Luacheck checks for
undefined globals, unused variables and unreachable code; it does not execute
hardware operations. Use `make check LUACHECK=/path/to/luacheck` for a local tool.
CI runs only these hardware-free checks.

See [acknowledgements](ACKNOWLEDGEMENTS.md) for protocol references.

## License

[MIT](LICENSE). External dependencies retain their own licenses and are not bundled.
