/* Know Your Constellation v4.1.1: not ported yet (the Lua source: components/KnowYourConstellation/src in the Megapack v42). */
#include "../../core/vpm.h"

static int Start(VpmComponent* self) { return vpm_fail(self, "not ported to HellForge yet"); }

const VpmComponentDef vpm_component_know_your_constellation = {"know_your_constellation", "Know Your Constellation", "4.1.1", 0, Start, NULL};
