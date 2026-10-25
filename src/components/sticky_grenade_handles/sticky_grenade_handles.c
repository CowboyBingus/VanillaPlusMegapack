/* Sticky Grenade Handles v1.0.1: not ported yet (the Lua source: components/StickyGrenadeHandles/src in the Megapack v42). */
#include "../../core/vpm.h"

static int Start(VpmComponent* self) { return vpm_fail(self, "not ported to HellForge yet"); }

const VpmComponentDef vpm_component_sticky_grenade_handles = {"sticky_grenade_handles", "Sticky Grenade Handles", "1.0.1", 0, Start, NULL};
