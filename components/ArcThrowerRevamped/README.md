> Release v1.7 for Steam build 25480438 / EXE 1.8.46015.0. Offline checks passed; in live play the addon loads and finds the Arc Thrower's charge record.

# Arc Thrower Revamped

Hold the fire button and the ARC-3 Arc Thrower keeps firing. Vanilla charges
while the trigger is held but only fires when it is released, so firing
repeatedly means pressing and releasing over and over; with this addon the
engine's own charge -> fire cycle simply repeats while the button stays down.

Nothing else is changed. Charge times, cadence, damage, spread and the arc's own
settings are stock, and the addon is inert unless the physical fire button is
held and an arc thrower is the weapon the engine issued a fire command for.

## Install

1. Close Helldivers 2.
2. Import `Arc-Thrower-Revamped-v1.7.zip` and **Bingus Shared Loader v18 or newer**
   into Arsenal or HD2MM, then enable both.
3. With Arsenal's default priority, put the loader last at the bottom of the
   load order.
4. Purge / Deploy, then start the game.

Only one mod manager should be used, and older packages that bundle their own
loader should be removed before deploying this one.

## Behaviour and limits

- The first shot of a press is the weapon's own; the addon keeps the cycle
  going after that one.
- The game's processed Fire action drives the assist, including mouse,
  controller, and rebound input. Actual controller coverage still needs gameplay testing.
- Unavailable input or bindings pause assistance. Recovery requires the same
  local weapon within 250 ms; release, ownership changes, and longer outages
  require a new engine fire command.
- A second arc thrower called down later has its own entity and charge entry,
  so the addon follows whichever thrower the engine issued a fire command for.
- No executable code is modified. The addon writes the thrower's charge record
  (`auto_fire_in_safety`) and its runtime charge entry, and verifies a known
  `game.dll` fingerprint before touching anything. Every write is checked
  first: the charge entry must be private read-write game data, and the
  record's page private memory the game keeps read-only, which is made
  writable for that one write and read-only again right after.
- If the game's update (or a mod's below this one) raises an error, the error
  still reaches the game unchanged; on the next update the addon puts the
  charge record back and pauses, and it resumes after 60 clean updates.
  Eight errors in one burst, or a refused write, stop it for the session with
  the record put back. At shutdown it puts the record back as well; the log's
  shutdown line keeps the first failure (`stopped after: <reason>`).
- Targets Steam build 25480438 / EXE 1.8.46015.0. Auto-fire was validated in a
  solo session with an earlier build; this release loads and finds its charge
  record in live play. Other builds are refused by design.

`%LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs/ArcThrowerAuto.log` records startup,
the patched charge record, and the first error. Routine shot and hold diagnostics
are disabled unless `ArcThrowerDiagnostics` is explicitly enabled.

## Build

The addon is one plaintext script discovered by Bingus Shared Loader through
its `-- HD2-Addon:` declaration. Package it from this checkout:

```powershell
python -B scripts/build.py --loader ..\BingusSharedLoader `
  --output releases\Arc-Thrower-Revamped-v1.7.zip
```

The builder runs `python check.py --archive <zip>` before finishing. The check
validates the source and packaged entry with Windows x64 LuaJIT (set
`HD2_LUAJIT` or have `luajit` on `PATH`). It runs the first update and render
callbacks with clean and predeclared native bindings, checks that a synthetic
unsupported game image is rejected without writes, and, with Windows SDK-style
prototypes declared first by another mod, scans the test process and patches a
synthetic charge record in a real read-only region. These offline checks do not
validate live gameplay.

Requires [Bingus Shared Loader](https://github.com/CowboyBingus/BingusSharedLoader/releases/latest)
v18 or newer (API 1). Artwork is not included; the repository ships source and
the packaged release only.

## Performance and recovery

The startup scan runs incrementally, reading at most 64 KiB at once with bounded work per update. Active fire commands are checked before looking through charged weapons; unsuccessful discovery is retried at most ten times per second while the button stays held. Render does not run a second assist. Normal shot, hold and idle diagnostics are disabled; startup and actual errors remain logged.

While Fire is up, an update reads only the local Fire input found at the last full check and stops there; every 15th update checks the local avatar and the charge record in full. While Fire is held between those checks, the update verifies the kept avatar, Fire input and weapon-holder row instead of resolving them again: 12 memory reads per update while the Arc Thrower fires (26 before) and 4 while another weapon fires (16 before). Reads go into reused buffers, so an idle update allocates nothing.

Offline binding, work-budget and synthetic firing tests pass. Measured in live play (v1.7) the addon costs 0.018 ms per frame in missions and 0.016 ms on the ship.

Release **v1.6** adds bounded recovery without changing charge times, cadence,
damage, or arc settings. It revalidates the cached auto-fire record every 250 ms
and searches for a replacement after a sustained charge stall. Trigger discovery
accepts up to 4096 entries and examines at most 64 active candidates per attempt.
Recovery, release, changed-weapon, work-budget, and packaged-payload checks run
offline; the recovery paths have not been reproduced in live play.

Current version: **v1.7**, for game build **25480438**. See [changes](CHANGELOG.md) and [validation coverage](docs/MIGRATION_VALIDATION.md).

**AI disclosure:** Claude Opus 5.5 assisted with research, implementation, tests and documentation.

## License

Zero-Clause BSD (0BSD): use, copy, modify and distribute for any purpose, with no conditions. See `LICENSE`.
