/* Hellpod Drop Hold: what its test reads of the component's state (tests/components/hellpod_drop_hold_test.c), as the
 * Lua tests read the session's fields. Built only into the tests (VPM_TEST). */
#ifndef HELLPOD_DROP_HOLD_H
#define HELLPOD_DROP_HOLD_H

#include <stdint.h>

typedef struct HdhTestView
{
    int loading;     /* a loading period lasts (session.loading) */
    int held;        /* a pod is held (session.held) */
    int retrying;    /* its release waits for a readable manager (session.held.retry) */
    uint32_t index;  /* the held pod's index in the manager, and its entity id */
    uint32_t id;
} HdhTestView;

void hellpod_drop_hold_test_view(HdhTestView* out);

#endif
