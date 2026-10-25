/* Ship Station Hotkeys v1.9.1: not ported yet (the Lua source: components/GalacticMenuHotkey/src in the Megapack v42). */
#include "../../core/vpm.h"

static int Start(VpmComponent* self) { return vpm_fail(self, "not ported to HellForge yet"); }

const VpmComponentDef vpm_component_ship_station_hotkeys = {"ship_station_hotkeys", "Ship Station Hotkeys", "1.9.1", 0, Start, NULL};
