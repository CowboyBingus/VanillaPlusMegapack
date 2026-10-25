/* Controllable Hover Pack v1.8.1: not ported yet (the Lua source: components/ControllableHoverPack/src in the Megapack v42). */
#include "../../core/vpm.h"

static int Start(VpmComponent* self) { return vpm_fail(self, "not ported to HellForge yet"); }

const VpmComponentDef vpm_component_controllable_hover_pack = {"controllable_hover_pack", "Controllable Hover Pack", "1.8.1", 0, Start, NULL};
