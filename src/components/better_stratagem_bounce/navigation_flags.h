/* Better Stratagem Bounce v15.4.1's supported-build flags (navigation_patch.lua vanilla_flags, build 25480438): each of
 * the game's stratagem types 1 .. 149 with its beacon_flags byte (StratagemDefinition +0x170) as the game ships it,
 * kNavigationFlags[type - 1]. The 103 types with bit 0x02 (deploy_on_navmesh_only) are the rows the component owns:
 * it clears that bit in them, and only in them. */
#ifndef NAVIGATION_FLAGS_H
#define NAVIGATION_FLAGS_H

#include <stdint.h>

#define NAVIGATION_TYPES 149 /* the game's stratagem types, 1 .. 149: every one has a record in the settings */
#define NAVIGATION_OWNED 103 /* the types whose flags have bit 0x02 */
#define NAVIGATION_OWNED_BIT 0x02u

static const uint8_t kNavigationFlags[NAVIGATION_TYPES] = {
    2, 2, 0, 0, 2, 2, 0, 2, 2, 0, 2, 2, 2, 2, 2, 2, 2, 0, 2, 3, 0,
    2, 2, 2, 2, 2, 0, 0, 2, 0, 2, 2, 2, 0, 1, 2, 1, 0, 2, 1, 0, 2,
    2, 2, 2, 2, 2, 2, 0, 2, 2, 2, 2, 2, 2, 2, 2, 0, 2, 2, 2, 0, 2,
    2, 0, 2, 2, 2, 3, 2, 0, 0, 2, 0, 2, 2, 2, 2, 2, 2, 2, 3, 0, 2,
    3, 2, 2, 0, 2, 3, 0, 2, 1, 0, 2, 2, 2, 1, 2, 2, 2, 0, 2, 2, 2,
    0, 0, 2, 3, 2, 0, 2, 2, 2, 2, 2, 2, 0, 2, 2, 2, 2, 0, 0, 0, 0,
    2, 0, 2, 2, 2, 0, 0, 2, 2, 0, 2, 0, 2, 0, 2, 2, 3, 2, 0, 0, 2,
    0, 2,
};

#endif
