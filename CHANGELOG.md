# Changelog

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
