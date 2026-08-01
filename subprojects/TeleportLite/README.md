# Gothic 1 Remake Teleport Lite

Teleport-only, lightweight edition of the Gothic 1 Remake Teleport & Integrated Mod.

This project runs in-game through UE4SS and one native x64 DLL. It has no external EXE, PowerShell UI, installer, network access, free flight, item tools, NPC tools, unlocking, or highlighting.

## Features

- Native bilingual English/Chinese UI (`F6`)
- 108 built-in destinations with bilingual names
- Search, group filtering, double-click teleport, and manual X/Y/Z teleport
- Custom nodes: save, rename, delete, import, export
- Stable Numpad `1–9/0` bindings
- `F1` saves the current position; `F3` writes a diagnostic node list

## Requirements

- Gothic 1 Remake for Windows
- A compatible x64 UE4SS installation, installed separately
- Do not enable Lite and the full `TeleportMod` / Integrated Mod together

## Installation

The release ZIP starts at `Gothic 1 Remake`. Copy that complete folder into your Steam `steamapps\\common` directory, then add:

```text
TeleportLite : 1
```

to `Gothic 1 Remake\\G1R\\Binaries\\Win64\\Mods\\mods.txt`.

For complete bilingual manual-installation, troubleshooting, runtime-file, and uninstall instructions, see [README_zh-en.txt](README_zh-en.txt).

After teleporting, the view may appear unchanged. Take one step to let the game refresh the position.

## Building a release

Run `Build-Package.ps1`. It compiles the x64 DLL, stages only the Lite runtime files, produces the release ZIP, and writes `SHA256SUMS.txt`.

## License

GPL-3.0-or-later. See [LICENSE.txt](LICENSE.txt).

## Related project

The full integrated mod source is available at [Gothic-1-Remake-Teleport-Integrated-Mod](https://github.com/azk78lun-collab/Gothic-1-Remake-Teleport-Integrated-Mod).
