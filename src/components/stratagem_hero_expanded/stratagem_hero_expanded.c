/* Stratagem Hero Expanded v1.0: not ported yet (the Lua source: components/StratagemHeroExpanded/src in the Megapack v42). */
#include "../../core/vpm.h"

static int Start(VpmComponent* self) { return vpm_fail(self, "not ported to HellForge yet"); }

const VpmComponentDef vpm_component_stratagem_hero_expanded = {"stratagem_hero_expanded", "Stratagem Hero Expanded", "1.0", 0, Start, NULL};
