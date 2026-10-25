/* Armory Preview Cache v23.1: not ported yet (the Lua source: components/ArmoryPreviewCache/src in the Megapack v42). */
#include "../../core/vpm.h"

static int Start(VpmComponent* self) { return vpm_fail(self, "not ported to HellForge yet"); }

const VpmComponentDef vpm_component_armory_preview_cache = {"armory_preview_cache", "Armory Preview Cache", "23.1", 0, Start, NULL};
