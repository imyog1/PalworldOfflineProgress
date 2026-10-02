import io
def edit(path, pairs):
    s = io.open(path, encoding="utf-8").read()
    for old, new in pairs:
        assert s.count(old) == 1, (path, old[:60])
        s = s.replace(old, new)
    io.open(path, "w", encoding="utf-8", newline="\n").write(s)

edit("README.md", [
("""> Built for **Palworld 1.0.5** with **UE4SS** (Okaetsu's experimental Palworld build).
> Tested as a Steam co-op host, including with a PS5 player who joins by crossplay.""",
"""> Built for **Palworld 1.0.5** with **UE4SS** (Okaetsu's experimental Palworld build).
> Tested with a Steam host and a PS5 player joining through crossplay."""),
("""### Your first session

The mod needs about an hour of play to learn each base: six 10-minute measurements, taken while
nobody is inside that base. Until then that base isn't caught up. Learned rates are kept in
`OfflineProgress/state.lua` and carry over between sessions.""",
"""### Your first session

There's no setup step, but an hour of normal play is recommended before relying on it. The mod
learns from your bases as you play, measuring each one every 10 minutes while nobody is inside
it, and catches an item up once it has 6 measurements. In normal play that's about an hour, often
less for bases you're away from. Items without enough measurements yet simply aren't added.

To start sooner, lower `minSamples` in the config. Fewer measurements means less accurate rates.
Learned rates are kept in `OfflineProgress/state.lua` and carry over between sessions."""),
("""- **Nothing was added.** Each base needs about an hour of measuring first (see
  [Your first session](#your-first-session)). Look for `N rate(s)` in the log.""",
"""- **Nothing was added.** Each item needs 6 measurements first, about an hour of normal play
  (see [Your first session](#your-first-session)). Look for `N rate(s)` in the log."""),
("""- Tested on Steam. Game Pass and dedicated servers haven't been tested.""",
"""- Tested with a Steam host and a PS5 player joining through crossplay. Game Pass hosts and
  dedicated servers haven't been tested yet."""),
])

edit("nexus/description.bbcode", [
("""[b]Your first session[/b]
The mod needs about an hour of play to learn each base: six 10-minute measurements, taken while nobody is inside that base. Until then that base isn't caught up. Learned rates carry over between sessions.""",
"""[b]Your first session[/b]
There's no setup step, but an hour of normal play is recommended before relying on it. The mod learns from your bases as you play, measuring each one every 10 minutes while nobody is inside it, and catches an item up once it has 6 measurements. In normal play that's about an hour, often less for bases you're away from. To start sooner, lower minSamples in the config; fewer measurements means less accurate rates. Learned rates carry over between sessions."""),
("""[b]Nothing was added after I loaded in.[/b]
Each base needs about an hour of measuring first.""",
"""[b]Nothing was added after I loaded in.[/b]
Each item needs 6 measurements first, about an hour of normal play."""),
("""[*]Tested on Steam. Game Pass and dedicated servers haven't been tested.""",
"""[*]Tested with a Steam host and a PS5 player joining through crossplay. Game Pass hosts and dedicated servers haven't been tested yet."""),
])
print("ok")
