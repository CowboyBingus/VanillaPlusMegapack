/* Arc Thrower Revamped v1.7.1: not ported yet (the Lua source: components/ArcThrowerRevamped/src in the Megapack v42). */
#include "../../core/vpm.h"

static int Start(VpmComponent* self) { return vpm_fail(self, "not ported to HellForge yet"); }

const VpmComponentDef vpm_component_arc_thrower_revamped = {"arc_thrower_revamped", "Arc Thrower Revamped", "1.7.1", 0, Start, NULL};
