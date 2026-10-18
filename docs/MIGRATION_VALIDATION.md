Supports Helldivers 2 Steam build 25480438 / EXE 1.8.46015.0.

Offline source, package and read-only module checks passed. v42 updates Mod
Bindings Menu to v2.3, whose label fix is not yet checked in game in another
language, and Match Your Colors to v1.5, whose test builds were checked in the
game in the Armory, on the ship and in one solo mission. v42 also adds
Stratagem Hero Expanded (v1.0): its release build and the refreshed package
ran to the ship and quit cleanly with loader v19, the package with all
twenty-two options; its tables were written at load and held at shutdown.
v42 also adds Sound Systems Rebalanced (v1.0): its release build and the package
with all twenty-three options ran to the ship and quit cleanly with loader
v19, its patched music bank loaded (the ship's music played), and its
release build played its fallback music on a swamp planet in a solo mission.
v42 also adds Foliage Pass-Through (v1.0): its release build and the package
with all twenty-four options ran to the ship and quit cleanly with loader
v19, and each changed all 99 projectile types at load and still had them
changed at shutdown. Its test build kept the change through four solo
missions on this build; a shot passing through a tree in play has not been
observed yet.
v42 also adds Holster Your Shield (v1.0): its release build and the package
with all twenty-five options ran to the ship and quit cleanly with loader v19;
each checked the first bytes of the three game functions it calls and found the
local Helldiver, and its release build also found it in a solo mission. A
shield stowed or drawn in play has not been observed yet.
v42 also updates Mod Bindings Menu to v2.3: the package with all twenty-five
options ran to the ship, into a solo mission and back, and quit cleanly with
loader v19; Mod Bindings Menu reported version 4, its guard ran without errors,
its mission check read true in the mission and false on the ship, and its MORE
MODS panel never drew. The bindings pages and MORE MODS with a player have not
been checked in game yet.
v42 also updates Arc Thrower Revamped to v1.7.1 and Clickable Scrollbars to
v2.15.1, which check the game build first: the package with all twenty-five
options ran to the ship, into a solo mission and back, and quit cleanly with
loader v19; Arc Thrower Revamped logged that it initialised on game build
25480438 and Clickable Scrollbars reported running, both without errors. Their
refusal on another game build is checked by their tests only.
v42 then updates Mod Bindings Menu v2.3 so that it never changes the game's
memory protection and no longer replaces content/input: the package with all
twenty-five options ran to the ship, into a solo mission and back, and quit
cleanly with loader v20; no deployed archive held content/input, and Mod
Bindings Menu reported version 4, its guard ran without errors and it logged
that it added its keyboard defaults to 12 binding records. Rebinding them in
the binding pages has not been checked in game yet.
v42 also gives each option its own cover: every file a manager deploys is byte
for byte the previous v42 package's, and Arsenal 0.36.0 and HD2MM 1.3
imported it and resolved each option's own image.
v41 updates Match
Your Colors to v1.4, whose release build was played on this build on the ship
and in the Armory. v40 updates Match
Your Colors to v1.3, played on this build as its standalone release (its colors
shared between a host and a client). v39 updates Laser
Sentry Cooldown to v1.1, played in a mission on this build as its standalone
release: an overheated sentry cooled, its turret powered up and it fired again.
v38 adds Hellpod
Drop Hold (v1.2), Laser Sentry Cooldown (v1.0), Match Your Colors (v1.2) and
Sticky Grenade Handles (v1.0), each played in recorded real play on this build as its standalone
release, in joined missions (Hellpod Drop Hold held the pod in two joins). The v38
package ran to the ship and quit cleanly with loader v19 and all twenty-one
options: every option loaded and none reported a failure. v36 updates Know
Your Constellation (v4.0), Better Lobby Management (v1.1), Mod Options Menu
(v1.1), Mod Bindings Menu (v2.1), Ship Station Hotkeys (v1.8) and Shallow
Water Diving (v3.9). The v36 package ran in recorded real play on this build
with loader v18 and all seventeen options, aboard the ship and in a joined
mission: every option loaded and none reported a failure. v35 adds only
Better Lobby Management (v1.0), checked in recorded live play as its release
candidate with a host and one friend (its scanner as the earlier Fast Lobby
Scanner); the v35 package itself has not yet run in game. v34 changes only
Flame Damage Fixed (v1.1), checked in recorded live play as its standalone
release; the v34 package itself has not yet run in game. The v33 package ran in
recorded real play on this build with loader v18 and fifteen of its options (its
Flame Damage Fixed option off), aboard the ship and in a joined mission: every
enabled option loaded and none reported a failure. v33 added Flame Damage Fixed
v1.0, Mod Options Menu v1.0.1 and Mod Bindings Menu v2.0, each checked in
recorded live play as its standalone release. v32 changes only
Shallow Water Diving (v3.8), checked in recorded live play with its depth slider. v31 with all
thirteen options ran in recorded real play on this build with loader v18,
aboard the ship and in a joined mission: every option loaded and none reported
a failure. The 21
external live checks did not write game memory or installed files.

Public source excludes raw memory captures and private session recordings.
Install with the game closed, then Purge / Deploy in one mod manager.
Use Bingus Shared Loader v18.
