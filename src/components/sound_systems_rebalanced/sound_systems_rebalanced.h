/* Sound Systems Rebalanced: the two entry points of the game's Wwise plugin it calls, and (for its test) where it finds
 * them. */
#ifndef SOUND_SYSTEMS_REBALANCED_H
#define SOUND_SYSTEMS_REBALANCED_H

#include <stdint.h>

/* AK::SoundEngine::SetState(AkStateGroupID, AkStateID) returns an AKRESULT (AK_Success is 1);
 * AK::SoundEngine::IsInitialized() returns a bool (in al). */
typedef int32_t (*SsrSetStateFn)(uint32_t group, uint32_t state);
typedef uint8_t (*SsrIsInitializedFn)(void);
typedef struct SsrWwise
{
    SsrSetStateFn set_state;
    SsrIsInitializedFn is_initialized;
} SsrWwise;

/* What a lookup of the plugin's exports found. */
#define SSR_WWISE_FOUND 0
#define SSR_WWISE_NO_PLUGIN 1 /* wwise_pluginw64_release.dll is not loaded */
#define SSR_WWISE_NO_EXPORT 2 /* it lacks SetState(AkStateGroupID, AkStateID) or IsInitialized() */

#ifdef VPM_TEST
/* Tests: the lookup the component uses at HF_EVENT_ENTITIES_READY instead of GetModuleHandleW and GetProcAddress; NULL
 * puts the real one back. */
void sound_systems_rebalanced_test_wwise(int (*lookup)(SsrWwise* out));
#endif

#endif
