/* Mod Bindings Menu v2.3: not ported yet (the Lua source: components/ModBindingsMenu/src in the Megapack v42). */
#include "../../core/vpm.h"

static int Start(VpmComponent* self) { return vpm_fail(self, "not ported to HellForge yet"); }

const VpmComponentDef vpm_component_mod_bindings_menu = {"mod_bindings_menu", "Mod Bindings Menu", "2.3", 0, Start, NULL};
