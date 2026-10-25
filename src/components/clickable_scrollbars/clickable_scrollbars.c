/* Clickable Scrollbars v2.15.1: not ported yet (the Lua source: components/ClickableScrollbars/src in the Megapack v42). */
#include "../../core/vpm.h"

static int Start(VpmComponent* self) { return vpm_fail(self, "not ported to HellForge yet"); }

const VpmComponentDef vpm_component_clickable_scrollbars = {"clickable_scrollbars", "Clickable Scrollbars", "2.15.1", 0, Start, NULL};
