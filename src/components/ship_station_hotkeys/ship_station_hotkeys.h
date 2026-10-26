/* Ship Station Hotkeys: the interface between its two files. ship_station_hotkeys.c reads the shortcuts and the context
 * (ship, mission, window focus) every frame; stations.c holds the game's own station entries the shortcuts call (the
 * presenters, the arcade cabinet, the Hellpod) and the Hellpod wait and seat that run over several frames. */
#ifndef SHIP_STATION_HOTKEYS_H
#define SHIP_STATION_HOTKEYS_H

#include <stdint.h>
#include "../../core/vpm.h"

#define SSH_PRESENTER 0 /* a ship menu presenter (Galactic Map, Armory, Control Center, Ship Management) */
#define SSH_ARCADE 1    /* the Stratagem Hero cabinet */
#define SSH_HELLPOD 2   /* the Hellpod */

/* Every station's state to its start (from start()). */
void ssh_stations_reset(void);
/* The native check, once per session when the ship is first found (the Lua's initialize_native): the reviewed code
 * bytes of the four entries, the UI state, and the world-position function the arcade's distance check uses. 1 ready
 * (or checked before), 0 refused: vpm_fail has stopped the component. */
int ssh_stations_check(VpmComponent* self);
/* A newly pressed shortcut's action (the Lua's act): name for the log, presenter for SSH_PRESENTER. */
void ssh_station_act(VpmComponent* self, int station, const char* name, uint32_t presenter);
/* A Hellpod wait (pressed while the pod was not open yet) or seat (behind the open briefing) in progress. */
int ssh_hellpod_pending(void);
/* One frame of it: the wait's step, then the seat's (the Lua's service_hellpod, service_hellpod_seat). */
void ssh_hellpod_service(VpmComponent* self, float dt);
/* Arriving on or leaving the ship drops both, without a log line (the Lua's enter_world). */
void ssh_hellpod_forget(void);

#endif
