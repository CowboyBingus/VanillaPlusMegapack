/* Holster Your Shield v1.0: not ported yet (the Lua source: components/HolsterYourShield/src in the Megapack v42). */
#include "../../core/vpm.h"

static int Start(VpmComponent* self) { return vpm_fail(self, "not ported to HellForge yet"); }

const VpmComponentDef vpm_component_holster_your_shield = {"holster_your_shield", "Holster Your Shield", "1.0", 0, Start, NULL};
