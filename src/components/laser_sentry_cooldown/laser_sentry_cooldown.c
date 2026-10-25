/* Laser Sentry Cooldown v1.1.1: not ported yet (the Lua source: components/LaserSentryCooldown/src in the Megapack v42). */
#include "../../core/vpm.h"

static int Start(VpmComponent* self) { return vpm_fail(self, "not ported to HellForge yet"); }

const VpmComponentDef vpm_component_laser_sentry_cooldown = {"laser_sentry_cooldown", "Laser Sentry Cooldown", "1.1.1", 0, Start, NULL};
