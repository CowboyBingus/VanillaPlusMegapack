/* Mod Options Menu v1.2.1: not ported yet (the Lua source: components/ModOptionsMenu/src in the Megapack v42). */
#include "../../core/vpm.h"

static int Start(VpmComponent* self) { return vpm_fail(self, "not ported to HellForge yet"); }

const VpmComponentDef vpm_component_mod_options_menu = {"mod_options_menu", "Mod Options Menu", "1.2.1", 0, Start, NULL};
