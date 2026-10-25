/* Hellpod Drop Hold v1.2.1: not ported yet (the Lua source: components/HellpodDropHold/src in the Megapack v42). */
#include "../../core/vpm.h"

static int Start(VpmComponent* self) { return vpm_fail(self, "not ported to HellForge yet"); }

const VpmComponentDef vpm_component_hellpod_drop_hold = {"hellpod_drop_hold", "Hellpod Drop Hold", "1.2.1", 0, Start, NULL};
