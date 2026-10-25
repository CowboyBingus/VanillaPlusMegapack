/* Reinforcement Beacons Fixed v4.6.1: not ported yet (the Lua source: components/ReinforcementBeaconsFixed/src in the Megapack v42). */
#include "../../core/vpm.h"

static int Start(VpmComponent* self) { return vpm_fail(self, "not ported to HellForge yet"); }

const VpmComponentDef vpm_component_reinforcement_beacons_fixed = {"reinforcement_beacons_fixed", "Reinforcement Beacons Fixed", "4.6.1", VPM_OVERLAPS_VANILLA_PLUS, Start, NULL};
