/* Better Stratagem Bounce v15.4.1: not ported yet (the Lua source: components/BetterStratagemBounce/src in the Megapack v42). */
#include "../../core/vpm.h"

static int Start(VpmComponent* self) { return vpm_fail(self, "not ported to HellForge yet"); }

const VpmComponentDef vpm_component_better_stratagem_bounce = {"better_stratagem_bounce", "Better Stratagem Bounce", "15.4.1", VPM_OVERLAPS_VANILLA_PLUS, Start, NULL};
