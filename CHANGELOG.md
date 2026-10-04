# Changelog

## 1.0.1 (2026-10-04)

Fixes from player reports on Nexus Mods.

- **Expeditions now progress while the game is closed.** The finish time couldn't be written
  directly, so it's now written the way the game loads dates. The log says which way worked, or
  why it didn't.
- **No more phantom "finished" messages.** Empty incubators, and machines that say they're running
  but never move, were reported as finished on every load. Now only work that was seen making
  progress (just after loading, or during your last session) is advanced. Anything skipped is
  named in the log.
- **Breeding farms lay their eggs, and are on by default.** Right after a load a farm's Pals
  aren't back at it yet, so its own "can breed" answer was always no and farms were skipped. A
  farm with cake and room for eggs is now watched for up to a minute until its Pals return. The
  game lays each egg itself, one at a time, so cake is used as normal, and no more eggs are laid
  than there is cake for. Each farm's state is logged. (In 1.0.0 breeding was off and only logged.)
- Follow-up rounds can run longer (up to 2.5 minutes) and stop as soon as nothing is left.
- **Tidier summary.** It now arrives as one chat message, so the lines can't come in out of order.
  Each base gets its own heading, items are wrapped to fit the chat, and eggs, expeditions and
  food go on a line of their own. New setting `summary.maxLinesPerMessage`.
- Tested working in single-player too, so the world's Multiplayer setting is no longer recommended.

## 1.0.0 (2026-10-02)

First release, for Palworld 1.0.5.

### Catch-up
- Bases catch up for the time the world was offline, worked out directly (no replaying).
- Downtime is measured per world, from the loaded save or the last finished save.
- Per-base production rates are learned from live play, separately for day and night and for when
  the player is far away, and refresh themselves after balance patches or base changes.
- Storage limits, food running out and full feed boxes are taken into account.
- Incubators and other self-running work advance; expeditions and medical-bed revivals finish on time.

### Summaries
- After each catch-up, every player gets a private "while you were away" summary of their own bases
  (system chat plus pickup popups). Offline players receive theirs when they next join, including
  crossplay console players.

### Safety
- Every storage write is read back; a mismatch, or a catch-up that didn't make it into the save,
  switches the mod to log-only safe mode.
- Items with unique data (eggs, weapons, armour) are never counted, created or edited.
- Optional features (spoilage, Pal hunger and sanity, world clock, crafting queues, breeding, crops)
  ship switched off and only log what they would do.

### Performance
- No per-frame work. Game objects are looked up once per load; the player list is read directly
  from the game state.
