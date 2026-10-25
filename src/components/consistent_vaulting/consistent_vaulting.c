/* Consistent Vaulting v8.9.1: not ported yet (the Lua source: components/ConsistentVaulting/src in the Megapack v42). */
#include "../../core/vpm.h"

static int Start(VpmComponent* self) { return vpm_fail(self, "not ported to HellForge yet"); }

const VpmComponentDef vpm_component_consistent_vaulting = {"consistent_vaulting", "Consistent Vaulting", "8.9.1", 0, Start, NULL};
