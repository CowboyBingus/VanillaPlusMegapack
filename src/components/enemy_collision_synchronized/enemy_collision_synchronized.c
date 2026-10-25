/* Enemy Collision Synchronized v2.13.0: not ported yet (the Lua source: components/EnemyCollisionSynchronized/src in the Megapack v42). */
#include "../../core/vpm.h"

static int Start(VpmComponent* self) { return vpm_fail(self, "not ported to HellForge yet"); }

const VpmComponentDef vpm_component_enemy_collision_synchronized = {"enemy_collision_synchronized", "Enemy Collision Synchronized", "2.13.0", 0, Start, NULL};
