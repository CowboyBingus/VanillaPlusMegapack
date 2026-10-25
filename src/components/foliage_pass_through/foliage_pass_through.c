/* Foliage Pass-Through v1.0: not ported yet (the Lua source: components/FoliagePassThrough/src in the Megapack v42). */
#include "../../core/vpm.h"

static int Start(VpmComponent* self) { return vpm_fail(self, "not ported to HellForge yet"); }

const VpmComponentDef vpm_component_foliage_pass_through = {"foliage_pass_through", "Foliage Pass-Through", "1.0", 0, Start, NULL};
