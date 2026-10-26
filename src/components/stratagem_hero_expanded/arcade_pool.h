/* Stratagem Hero Expanded v1.0's data (stratagem_hero_expanded.lua, Mod.VANILLA_TIERS, Mod.VANILLA_GROUPS, Mod.GROUPS,
 * Mod.THEMES): build 25480438's arcade tables, which are checked byte for byte before anything is written, and the
 * expanded pool. Stratagem types of build 25480438. Weights are written as the f32 nearest to these doubles, as the Lua's
 * encoder wrote them. The array sizes are the picker's limits (8 groups a tier, 16 stratagems a group, 9 usable
 * groups), so a list that breaks one does not compile (the Lua's encoder refused it at run time). */
#ifndef ARCADE_POOL_H
#define ARCADE_POOL_H

#define TIERS 9
#define TIER_ENTRIES 8
#define GROUPS 10        /* group 0 is empty: 0 ends a tier's list, so it is never picked */
#define GROUP_SLOTS 16
#define POOL_GROUPS 8
#define THEMED_TIERS 4

typedef struct ArcadePick { uint32_t group; double weight; } ArcadePick;
typedef struct ArcadeTier { uint32_t banner; ArcadePick picks[TIER_ENTRIES]; } ArcadeTier; /* group 0 ends the picks */
typedef struct ArcadeTheme { uint32_t groups[2]; double share; } ArcadeTheme;              /* 0 ends the groups */

static const ArcadeTier kVanillaTiers[TIERS] = {
    {1197656392u, {{6, 1.0}, {1, 0.5}, {2, 0.2}, {3, 0.05}, {8, 0.075}}}, /* BACK-PACKING A PUNCH */
    {1224989586u, {{4, 1.0}, {1, 0.5}, {2, 0.2}, {3, 0.05}, {8, 0.075}}}, /* FLY LIKE AN EAGLE */
    {4059426536u, {{7, 1.0}, {1, 0.5}, {2, 0.2}, {3, 0.05}, {8, 0.075}}}, /* RAIN DOWN FROM ABOVE */
    {2594389917u, {{9, 0.6}, {1, 0.5}, {2, 0.2}, {3, 0.05}, {8, 0.075}}}, /* OVERWHELMING FIREPOWER */
    {0, {{1, 0.5}, {2, 0.2}, {3, 0.05}, {8, 0.075}}},
    {0, {{1, 0.6}, {2, 0.4}, {3, 0.1}, {8, 0.075}}},
    {0, {{1, 0.3}, {2, 0.5}, {3, 0.4}, {8, 0.075}}},
    {0, {{1, 0.1}, {2, 0.5}, {3, 0.5}, {8, 0.075}}},
    {0, {{1, 0.1}, {2, 0.2}, {3, 0.8}, {8, 0.1}}},
};

/* Groups 1-9 (0 ends a group). */
static const uint32_t kVanillaGroups[GROUPS - 1][GROUP_SLOTS] = {
    {83, 136, 33, 30, 119, 66},
    {3, 140, 125, 107, 92, 130, 42, 147, 53, 117},
    {43, 73, 134, 25, 141, 144},
    {30, 3, 140, 18},
    {137, 66, 117, 53}, /* no tier lists this group */
    {43, 73, 134},
    {83, 136, 125, 107},
    {124},
    {56, 13, 63},
};

/* The new pool: the 96 stratagems this build's settings mark selectable for a loadout, and the 12 mission stratagems
 * every squad calls, grouped by the class each stratagem's settings give it (StratagemInfo +0x188: 1-6 orbitals, 7-10
 * Eagles, 11-20 support weapons, 21-24 backpacks, 26-28 vehicles, 29-32 sentries, 33-35 emplacements, 36 mines, 0
 * mission), in the order of those classes. A round draws from at most 8 groups, so sentries share a group with
 * emplacements and vehicles with mines; neither pair is a theme, and every group's weight follows its size, so sharing
 * changes no stratagem's odds. Groups 1-8; group 9 stays empty. */
static const uint32_t kPool[POOL_GROUPS][GROUP_SLOTS] = {
    /* 1, backpacks: Supply Pack, Portable Hellbomb, C4 Pack, Jump Pack, Hover Pack, Warp Pack, Ballistic Shield,
     * Directional Shield, Shield Generator Pack, Guard Dog, Rover, Dog Breath, Hot Dog, K-9 */
    {101, 120, 14, 134, 55, 24, 96, 67, 43, 73, 115, 142, 57, 2},
    /* 2, Eagles: Strafing Run, 500kg Bomb, Eagle Rearm, 110mm Rocket Pods, Airstrike, Napalm Airstrike, Cluster Bomb,
     * Gas Airstrike, Smoke Strike */
    {30, 3, 49, 140, 18, 133, 65, 126, 38},
    /* 3, orbitals: Precision Strike, Airburst Strike, Gatling Barrage, 120mm HE Barrage, Napalm Barrage, 380mm HE
     * Barrage, Walking Barrage, Walking Barrage Smoke, Laser, Railcannon Strike, Gas Strike, Smoke Strike, EMS Strike */
    {118, 83, 4, 136, 106, 125, 21, 62, 107, 58, 41, 74, 34},
    /* 4, support weapons: One True Flag, Defoliation Tool, Breaching Hammer, Machine Gun, Heavy Machine Gun, Stalwart,
     * Railgun, Speargun, Anti-Materiel Rifle, Grenade Launcher, De-Escalator, Epoch, Meltagun, Flamethrower,
     * Sterilizer, Laser Cannon */
    {114, 51, 100, 92, 32, 13, 56, 113, 141, 80, 131, 45, 81, 112, 61, 63},
    /* 5, support weapons: Quasar Cannon, Arc Thrower, Expendable Anti-Tank, Expendable Napalm, Leveller, Commando,
     * Bullet Storm, Solo Silo, Autocannon, Belt-Fed Grenade Launcher, Recoilless Rifle, Airburst Rocket Launcher, Spear,
     * W.A.S.P. Launcher, Maxigun, Cremator */
    {149, 68, 147, 39, 16, 6, 99, 89, 25, 127, 130, 54, 75, 97, 110, 87},
    /* 6, sentries and emplacements: Machine Gun, Gatling, Flame, Laser, Rocket, Autocannon, Mortar, EMS Mortar and Gas
     * Mortar Sentries, Grenadier Battlement, Shield Generator Relay, HMG Emplacement, Anti-Tank Emplacement, Tesla Tower */
    {121, 66, 8, 23, 53, 137, 117, 44, 52, 59, 22, 144, 9, 104},
    /* 7, vehicles and mines: Gunner FRV, Supply FRV, Incinerator FRV, Bastion, Storm tank, Patriot, Emancipator,
     * Lumberer and Breakthrough Exosuits, Anti-Personnel Minefield, Incendiary Mines, Anti-Tank Mines, Gas Mines */
    {105, 26, 135, 1, 50, 27, 10, 91, 88, 119, 139, 12, 46},
    /* 8, mission: Reinforce, Resupply, SOS Beacon, Hellbomb, SEAF Artillery, Super Earth Flag, Upload Data, Seismic
     * Probe, Prospecting Drill, Illumination Flare, Extraction, SEAF Squad, Nuke */
    {124, 33, 145, 42, 28, 11, 128, 19, 70, 5, 148, 116, 132},
};

/* The themed tiers 0-3 keep their banners. Their theme groups get the share of picks vanilla gives its theme group (1.0
 * of 1.825 in tiers 0-2, 0.6 of 1.425 in tier 3); the rest of each tier is even. */
static const ArcadeTheme kThemes[THEMED_TIERS] = {
    {{1}, 1 / 1.825},     /* BACK-PACKING A PUNCH: backpacks */
    {{2}, 1 / 1.825},     /* FLY LIKE AN EAGLE: Eagles */
    {{3}, 1 / 1.825},     /* RAIN DOWN FROM ABOVE: orbitals */
    {{4, 5}, 0.6 / 1.425}, /* OVERWHELMING FIREPOWER: support weapons */
};

#endif
