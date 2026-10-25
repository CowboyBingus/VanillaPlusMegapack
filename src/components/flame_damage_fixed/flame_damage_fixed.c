/* Flame Damage Fixed v1.2: not ported yet (the Lua source: components/FlameDamageFixed/src in the Megapack v42). */
#include "../../core/vpm.h"

static int Start(VpmComponent* self) { return vpm_fail(self, "not ported to HellForge yet"); }

const VpmComponentDef vpm_component_flame_damage_fixed = {"flame_damage_fixed", "Flame Damage Fixed", "1.2", 0, Start, NULL};
