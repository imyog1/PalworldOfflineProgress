# Nexus Mods upload checklist

Fill in on the Nexus "Add a mod" form:

| Field | Value |
|---|---|
| Mod name | Offline Progress |
| Summary | Contents of `summary.txt` |
| Description | Contents of `description.bbcode` |
| Category | Gameplay |
| Version | 1.0.0 |
| Language | English |
| Tags | Gameplay, Quality of Life, Bases, Multiplayer, Lua |
| Requirements | UE4SS Experimental (Palworld): https://www.nexusmods.com/palworld/mods/2237 |
| Main file | `dist/OfflineProgress-v1.0.0.zip` (build with `python tools/build_release.py`) |
| File name | Offline Progress |
| File description | Extract into your Palworld (or PalServer) folder. Requires UE4SS for Palworld. |

Permissions tab (matches the MIT license in the repository):

- Upload permission: Yes, with credit
- Modification permission: Yes, with credit
- Conversion permission: Yes, with credit
- Asset use permission: Yes, with credit
- Credits: Okaetsu (UE4SS for Palworld)

Images: Nexus needs at least one. A screenshot of the in-game chat summary works well.

Before uploading, update the GitHub link in `description.bbcode` if the repository ends up at a
different address than github.com/sayikii/PalworldOfflineProgress.
