/* Hellpod Steering Unlocked v7.5.1: not ported yet (the Lua source: components/HellpodSteeringUnlocked/src in the Megapack v42). */
#include "../../core/vpm.h"

static int Start(VpmComponent* self) { return vpm_fail(self, "not ported to HellForge yet"); }

const VpmComponentDef vpm_component_hellpod_steering_unlocked = {"hellpod_steering_unlocked", "Hellpod Steering Unlocked", "7.5.1", VPM_OVERLAPS_VANILLA_PLUS, Start, NULL};
