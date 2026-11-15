# Tested compatibility

Supported monitor profile: **LG 27GM950B**, EDID vendor/product **GSM / 0x5cf8**.
Other models and desktop environments are not validated.

## Tested environment

Live checks performed on 2026-11-15 (UTC):

| Component | Version or setup |
| --- | --- |
| Distribution | Fedora 45, x86-64 |
| Kernel | 7.3.3-300.fc45 |
| GPU | AMD Navi 48 / Radeon RX 9070 family |
| Connection | DisplayPort, connector DP-1 |
| Gamescope | 3.16.29-1.fc45 |
| GNOME Shell / Mutter | 51.1-1.fc45 |
| systemd | 262.1-1.fc45 |
| LuaJIT | 2.1.1767980792-2.fc45 |
| ddcutil | 3.0.2-1.fc45 |
| GLib/GIO | 2.90.1-1.fc45 |

The desktop used a second 3840×2160 display at 60 Hz. The gaming LG started at
5120×2880 / 165.058 Hz with VRR. Its desktop scale was 2.0; the second display's
scale was 1.5. Monitor firmware was not recorded during these checks.

## Live results

| Check | Result |
| --- | --- |
| Read-only preflight, including DDC access | Pass |
| Gamescope presentation on DP-1 at 1440p330 with VRR selected | Pass |
| Visible rotating cube on the gaming LG | Confirmed by the user |
| Desktop restoration after normal Gamescope exit | Pass |
| Desktop restoration after Gamescope SIGKILL | Pass |
| Desktop restoration after watcher SIGKILL through systemd cleanup | Pass |

Physical presentation was checked by matching Wayland output names to presentation
feedback, not merely by observing a changed monitor mode. Restoration compared
saved modes, refresh-rate mode, layout, scaling, transforms, primary display and
color settings. Independent recovery was armed but not needed in the passing runs.

## Limits

- Keep the pointer on the gaming LG through launch and reconnection. Automatic
  output targeting is not implemented.
- End-to-end HDR rendering, physical hotplug, multiple supported LGs and launches
  starting in Dual Mode have not been live-tested. Related hardware-free tests
  do not establish hardware compatibility.
- Recovery across logout, reboot or power loss is not guaranteed.
- These are functional checks, not latency, frame-pacing or image-quality benchmarks.
- Gamescope's Lua API is experimental; other versions require validation.
