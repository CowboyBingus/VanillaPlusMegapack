# v1.7

- Windows functions and the memory-region record are declared under private names, so another mod that declared them first with other prototypes can no longer leave the addon idle for the session.
- Memory reads go into reused buffers and fields are decoded in place, cutting Lua garbage per frame from about 1.7 KB to 33 B when idle in a mission and from 2.6 KB to 8 B while firing (measured offline).
- While Fire is up, an update reads only the local Fire input (1 read instead of 16), and every 15th update checks the local avatar and the charge record in full. Outside a mission the updates between those checks make no Windows call.
- A press that starts just after the Fire input becomes readable again (joining a mission, a respawn) is picked up at the next full check, within the press's first charge.
- While Fire is held between full checks, an update verifies the avatar, Fire input and weapon-holder row found last instead of looking them up again: 12 memory reads per update while the Arc Thrower fires (26 before), 4 while another weapon fires (16 before).
- The charging flag is written only when the game has not already set it, and its memory page is checked to be private read-write game data before the first write of each hold.
- The weapon data record's page is checked, made writable for that one write and set back to read-only right after; a refused or failed protection change writes nothing and is logged.
- An error from the game's update or a mod below this one still reaches the game unchanged; the addon then ends the hold, puts the Arc Thrower's record back and pauses until 60 clean updates in a row.
- Eight errors in one burst stop the addon for the session with the record put back, and the count starts again after 3600 error-free updates. Before, its own errors were logged once and retried forever.
- A refused write stops the addon and puts the record back; the log names the refused page's state, protection and type.
- At shutdown the addon puts the record's auto-fire flag back; the log line reads `stopped`, or `stopped after: <first failure>` when something failed.
- Only the idle path and the memory-read helpers are compiled by LuaJIT, so the addon takes about 5 KB of the code cache shared by the game and every mod (v1.6.1: about 10 KB).
- Pause, stop and error handling now comes from Bingus Shared Runtime's update guard with the same behaviour; its log lines use the family's wording, for example `ArcThrowerRevamped paused: the previous update failed`.
- Licensed under the Zero-Clause BSD license (0BSD).

# v1.6.1

- Documentation-only release: the addon is identical to v1.6 (same packaged script).
- Rewrites the install notes packaged with the addon and the README status: one current status line instead of the compatibility-candidate notes left from the game-build update. In live play the addon loads and finds the Arc Thrower's charge record.
- Lists one loader requirement, Bingus Shared Loader v18.

# v1.6

- Refresh game-build guards for Steam build 25480438.
- Preserve repeated fire through mouse, controller and rebound fire commands.
- Offline builds and package checks pass; live gameplay validation remains pending.

# Changelog

## v1.5

- Revalidate the auto-fire record every 250 ms, repair a cleared flag, and
  rediscover replaced records without writing through an invalid old address.
- Search beyond an already-patched copy when charging stalls, including at full
  charge. Recovery scans retain the existing byte, step, and time budgets.
- Pause on unavailable input or weapon bindings for up to 250 ms; resume only
  after revalidating the same local weapon and uninterrupted hold. Confirmed
  release, changed identity/holder, and expired holds still cancel assistance.
- Discover active Arc commands in larger trigger tables with bounded candidate
  work, rather than rejecting the whole table above 64 entries.
- Correct diagnostic shot counts and clear stale failure reasons.
- Add regression coverage for recovery and cancellation, including slow reads.
  These fixes have offline proof; affected-session gameplay verification remains pending.

## v1.2

- Bound startup scanning to small chunks and revalidate matches before writing.
- Inspect active fire commands first and throttle discovery while ordinary weapons fire.
- Run the assist only from update and disable verbose shot/idle logging by default.
- Preserve continuous fire, second-weapon discovery, callback returns and build checks.
- Add synthetic work-budget and firing regressions; in-game validation is pending.

## v1.1

- Fix startup stopping with "kernel32 bindings unavailable" or a missing
  `GetModuleHandleA` declaration. Declare the API before use and accept native
  LuaJIT function bindings.
- Validate the first update and render callbacks with real Windows bindings,
  including the actual packaged script. Gameplay and build checks are unchanged.

## v1

- Hold the fire button to keep the ARC-3 Arc Thrower firing. The weapon's own
  charge -> fire cycle repeats while the button stays down instead of firing
  once per press and release.
- Follows whichever arc thrower the engine issued a fire command for, including
  a second thrower called down during the same mission.
- Build locked: a known `game.dll` fingerprint is verified before any write, and
  unsupported builds are refused.
- Charge times, cadence, damage, spread and arc settings are stock.
