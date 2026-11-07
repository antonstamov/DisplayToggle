# DisplayToggle

One hotkey to cycle the primary display on a multi-monitor Windows setup.
No third-party tools, no install — just a shortcut that toggles.

## How it works

`Monitor-Toggle.lnk` → `Toggle-Primary-Silent.vbs` → `Toggle-Primary.ps1`,
which uses the modern display API (`QueryDisplayConfig` / `SetDisplayConfig`):

- Only **source positions** are shifted; source/target modes (resolution,
  refresh rate, timings) are passed through untouched. Your refresh rate
  never resets (e.g. no 60 Hz → 59.95 Hz drop).
- 1 display → does nothing. 2 → switches to the other one.
  3+ → cycles to the next one.
- Applies immediately, no delayed mode re-apply.
- If the next display is **disabled in OS settings**, it is first enabled
  (extended to the right of the desktop, duplicates untouched) and then
  made primary — in a single press. Mode preference for the enable step:
  `display-modes.txt` journal → registry-stored mode → best probed mode
  (max area, refresh closest to `$PreferFreq`).

Why not the legacy API (`ChangeDisplaySettingsEx`, used by tools like
MultiMonitorTool): every such call re-applies the driver mode stored in the
registry (legacy store), while a mode picked manually in Settings may not
be there — so the refresh rate silently rolled back after each switch and
the monitor started flickering. The modern API leaves timings alone.

## Requirements

- Windows 10 / 11 (uses inbox `user32.dll` only).
- Built-in Windows PowerShell 5.1. No modules, no downloads.

## Installation

1. Double-click **`Install.bat`** — it creates `Monitor-Toggle.lnk`
   next to the scripts.
2. Pin that shortcut to the taskbar (right-click → *Pin to taskbar*),
   or keep/move it anywhere convenient.

No hotkey is assigned to the shortcut on purpose (avoids accidental
triggers in games).

## Usage

Press once and wait ~2 seconds. A second press within a minute is ignored
(single-instance guard: overlapping runs with opposite targets used to
fight each other and looked like a "double toggle").

- `toggle.log` — what happened on each run (screens before/after,
  `SetDisplayConfig` result codes, timing checks).
- `display-modes.txt` — journal of last seen modes per display, written by
  every successful run. Used to restore the exact mode when re-enabling a
  disabled display. Local state, do not commit.
- `$PreferFreq` at the top of `Toggle-Primary.ps1` — preferred
  refresh rate (Hz) when a detached display has no stored mode
  (default `60`).

## Troubleshooting

- If the toggle stops applying at all (`SetDisplayConfig` failing several
  runs in a row): this matches a known Windows 11 25H2 display-API
  flakiness. Workaround — open Settings → Display, change something
  (scale/position) and change it back, or reboot.
- See `toggle.log` first: it shows `screens before/after`, `VALIDATE` /
  `APPLY` result codes and whether timings were kept.

## Files

| File | Purpose |
|---|---|
| `Install.bat` | Creates `Monitor-Toggle.lnk` (run once) |
| `Monitor-Toggle.lnk` | Entry point (generated locally, not committed) |
| `Toggle-Primary-Silent.vbs` | Launches the toggle windowless |
| `Toggle-Primary.ps1` | The toggle (DisplayConfig API) |
| `icon.ico` | Shortcut icon |

## License

MIT — see [LICENSE](LICENSE).
