/* Shallow Water Diving v3.10.1: not ported yet (the Lua source: components/ShallowWaterDiving/src in the Megapack v42). */
#include "../../core/vpm.h"

static int Start(VpmComponent* self) { return vpm_fail(self, "not ported to HellForge yet"); }

const VpmComponentDef vpm_component_shallow_water_diving = {"shallow_water_diving", "Shallow Water Diving", "3.10.1", 0, Start, NULL};
