/* Match Your Colors v1.5: not ported yet (the Lua source: components/MatchYourColors/src in the Megapack v42). */
#include "../../core/vpm.h"

static int Start(VpmComponent* self) { return vpm_fail(self, "not ported to HellForge yet"); }

const VpmComponentDef vpm_component_match_your_colors = {"match_your_colors", "Match Your Colors", "1.5", 0, Start, NULL};
