# Testing the Vanilla Plus Megapack alpha

Thanks for testing. The Vanilla Plus Megapack is twenty-five Helldivers 2 mods in one HellForge mod. This alpha is the
first native build of it. Below: how to install it, what to try, and what to send when something goes wrong. When
something goes wrong, the pack's log is usually all we need to find out why.

## 1. Install

You need HellForge 0.3.0-beta or newer (game build 25480438). Close the game before changing mods.

1. **The pack.** This zip holds a folder named `cowboybingus.vanilla-plus-megapack`. Copy that whole folder into
   HellForge's `mods` folder, inside your HellForge installation (for example `C:\HellForge\mods`). Keep the folder's
   name and everything in it, including its `data` folder.
2. **Bingus Shared Loader v20.** Only Know Your Constellation's forecast panel needs it; everything else runs without
   it. Download `Bingus-Shared-Loader-v20.zip` from
   <https://github.com/CowboyBingus/BingusSharedLoader/releases/tag/v20> and unzip it into a new folder in the same
   `mods` folder, for example `C:\HellForge\mods\bingus-shared-loader`, keeping its files as they are.
3. **Don't run the old Lua Vanilla Plus Megapack at the same time.** Both would change the same things.
4. **HellForge's own "Vanilla Plus"** (on the Mods page) overlaps three of the pack's mods: Better Stratagem Bounce,
   Hellpod Steering Unlocked and Reinforcement Beacons Fixed. While it is on, those three stay off. Switch it off on
   the Mods page to test them.
5. Open HellForge's **Mods** page: "Vanilla Plus Megapack" (and "Bingus Shared Loader", if you installed it) should be
   listed and on. Start a session.

To update to a newer alpha later, close the game and replace the `cowboybingus.vanilla-plus-megapack` folder.

## 2. Before you play: switch on Crash dump

In HellForge, open **Settings**, and under **Troubleshooting** tick **Crash dump**. It applies from the next session.

If the game crashes, HellForge then writes a memory dump of the game into that session's logs. Know two things about
it:

- **It is big:** about 1 GB, sometimes more.
- **It is private:** it holds whatever the game had in memory, your Steam account name included. "Save logs to
  Desktop" scrubs the logs, but puts the dump into the zip as it is.

So after a crash, send the logs without the dump first: in HellForge, **Settings > Open session logs**, and move every
`.dmp` file out of that folder (to your Desktop, say) before you save the logs. Keep them until we say we don't need
them. We will ask for a dump only when the log is not enough, and then you send it to us privately, never in a public
channel.

## 3. Switch on detailed logging

Press Escape in game, open the **MODS** tab and go to the **VANILLA PLUS MEGAPACK** category. Set **Diagnostics** to
**Detailed** and apply. The mods then also log the steps behind what they do. That's what we need to understand a
problem, and it costs nothing you'd notice. It stays set for later sessions.

In the same tab, each of the twenty-five mods has its own switch and options. Most switches apply at once, without a
restart. Mod Options Menu, Mod Bindings Menu and Match Your Colors apply from the next session, and their rows say so.

## 4. What to try

Play as you normally would. Tell us both when a mod works and when it doesn't. A "looks good" is useful too. Things
worth checking:

**On the ship**

- **Ship Station Hotkeys:** Tab, F1 and F5-F8 open the ship's stations from anywhere aboard.
- **Mod Options Menu:** the MODS tab in the options. Changes stick after a restart.
- **Mod Bindings Menu:** the Controls page has a MODS tab with the hotkeys' bindings, named and rebindable.
- **Clickable Scrollbars:** drag the scrollbars in the equipment lists, Career, Controls and Settings with the mouse.
- **Armory Preview Cache:** Armory previews appear quickly, and items you've looked at show at once.
- **Match Your Colors:** wear a helmet and armor that don't match (not a complete set, or switch off "Keep sets"). The
  helmet should match the armor on your Helldiver on the ship, not only in the Armory preview. Try its other options
  too (cape, materials, weapons).
- **Stratagem Hero Expanded:** the Stratagem Hero machine draws from every stratagem.
- **Know Your Constellation:** on the war table, hover a mission. A "FORECAST // INTEL AND RECON" panel under the
  planet's panel lists the enemies you're likely to meet. It needs Bingus Shared Loader.

**In a mission (solo is fine)**

- **Shallow Water Diving:** dives in shallow water (about shin-deep) go through instead of being cancelled.
- **Consistent Vaulting:** ledges and slopes you could only climb now and then climb every time.
- **Sentry Aim Retention:** a Gatling sentry that loses its target holds its aim instead of snapping back.
- **Laser Sentry Cooldown:** an overheated Laser Sentry cools down and fires again instead of exploding.
- **Holster Your Shield:** a holstered shield stays on your back, also when you swap weapons.
- **Controllable Hover Pack:** pressing the jump key again mid-hover ends the hover.
- **Arc Thrower Revamped:** holding fire keeps firing on its charge.
- **Sticky Grenade Handles:** the Thermite and the sticky stun grenade stick even when they land handle first.
- **Foliage Pass-Through:** shots go through bushes instead of detonating on them.
- **Flame Damage Fixed:** flamethrowers, including the Cremator, burn as they should and don't hurt you.
- **Better Stratagem Bounce:** hellpod stratagem beacons stick where you throw them.
- **Hellpod Steering Unlocked:** your drop pod steers over any ground.
- **Reinforcement Beacons Fixed:** reinforcements land at their beacon.
- **Hellpod Drop Hold:** your drop at the mission's start behaves as it did with the old Megapack.
- **Sound Systems Rebalanced:** the music at a mission's start doesn't jump in loudness.

**With friends (co-op, ideally all with the pack)**

- **Better Lobby Management:** the escape menu's lobby actions (promote, disband, cancel SOS).
- **Match Your Colors:** friends with the pack see your colors, and you theirs.
- **Enemy Collision Synchronized:** big enemies and their corpses are in the same place for everyone.

Not in this alpha: Know Your Constellation's panel on the planet view without Bingus Shared Loader, and Mod Bindings
Menu's MORE MODS page.

## 5. When something looks wrong: "Note a problem now"

Press Escape, open the **MODS** tab, go to the **VANILLA PLUS MEGAPACK** category, switch on **Note a problem now** and
apply. It switches itself back off and writes a numbered `MARK` line into the log, with what every mod was doing at
that moment. Do it right away, while the problem is still on screen, and tell us the mark's number or roughly when you
pressed it.

## 6. Soon after: Save logs to Desktop

Close the game first. In HellForge, open **Console** and press **Save logs to Desktop**. It zips the last session's
logs onto your Desktop. Send us that zip.

Do it soon: HellForge keeps only the newest 10 sessions and deletes older ones, so a few more launches lose it.

## 7. What to write in your report

- Your HellForge version and game build. Both are in HellForge's sidebar, under the session state, as a line such as
  `HellForge 0.3.0` with the game build below it. Copy both lines.
- Solo or co-op, and on the ship or in a mission.
- What you did, what you expected and what happened, in a few words. Include a screenshot if it shows the problem.
- The `MARK` number, if you noted one.
- The logs zip from step 6 (without any `.dmp` file).
