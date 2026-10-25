/* Better Lobby Management v1.2.1: not ported yet (the Lua source: components/BetterLobbyManagement/src in the Megapack v42). */
#include "../../core/vpm.h"

static int Start(VpmComponent* self) { return vpm_fail(self, "not ported to HellForge yet"); }

const VpmComponentDef vpm_component_better_lobby_management = {"better_lobby_management", "Better Lobby Management", "1.2.1", 0, Start, NULL};
