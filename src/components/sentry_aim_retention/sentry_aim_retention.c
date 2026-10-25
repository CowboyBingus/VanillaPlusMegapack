/* Sentry Aim Retention v1.1.1: not ported yet (the Lua source: components/SentryAimRetention/src in the Megapack v42). */
#include "../../core/vpm.h"

static int Start(VpmComponent* self) { return vpm_fail(self, "not ported to HellForge yet"); }

const VpmComponentDef vpm_component_sentry_aim_retention = {"sentry_aim_retention", "Sentry Aim Retention", "1.1.1", 0, Start, NULL};
