/* Sound Systems Rebalanced v1.0: not ported yet (the Lua source: components/SoundSystemsRebalanced/src in the Megapack v42). */
#include "../../core/vpm.h"

static int Start(VpmComponent* self) { return vpm_fail(self, "not ported to HellForge yet"); }

const VpmComponentDef vpm_component_sound_systems_rebalanced = {"sound_systems_rebalanced", "Sound Systems Rebalanced", "1.0", 0, Start, NULL};
