/* Match Your Colors: the worker thread, where jobs, the cache save and the game-data reader's close run.
 *
 * Why a thread (lint C6). The Lua ran a job as a coroutine the step resumed with a budget of 1.5 ms per frame (BUDGET),
 * its game-data reads overlapped with later frames (src/files.lua's wait). C has no coroutines, and fibers would take
 * the core's crash guard off the job (its resume point is the thread's). A job whole on the game thread would cost tens
 * of milliseconds on the frame of a new outfit (a cold job reads 10-60 MB of game data and analyses textures). On the
 * worker the game thread pays one SetEvent per task and one plain load of the busy flag per frame while one runs.
 *
 * What the worker touches: the pipeline (game data files, the color model, analyses, plans, the disk cache), the
 * request (read; the game thread may only set its obsolete flag) and the result it makes. It reads game memory through
 * vpm_read (the kit records, the weapons' customization tables), never writes it and makes no engine call: everything
 * on the engine's objects (textures, bindings) stays on the game thread. The game thread reads the worker's fields only
 * while busy is 0 (an interlocked store after the task's last write).
 *
 * A task runs under the core's crash guard (vpm_guarded, thread-local): a fault stops the component from the worker
 * thread; stop() then leaves the game's objects alone (myc_worker_on_thread) and the game keeps the colors it shows. */
#include <windows.h>
#include "myc_addon.h"

static void MycWorkerJob(MycWorker* w)
{
    MycResult* result = myc_result_new();
    w->result = result;
    if (result == NULL) { myc_fail(&w->err, "out of memory (result)"); return; }
    MycJobFn job = w->job != NULL ? w->job : myc_job_run;
    w->ok = job(&w->pipeline, w->data_folder, w->has_cache ? w->cache_path : NULL, w->request, result, &w->err);
}

static void MycWorkerTask(void* arg)
{
    MycWorker* w = arg;
    if (w->task == MYC_TASK_JOB) MycWorkerJob(w);
    else if (w->task == MYC_TASK_SAVE) w->ok = myc_pipeline_save(w->pipeline, w->save_why, sizeof w->save_why);
    else if (w->task == MYC_TASK_CLOSE) myc_pipeline_close(w->pipeline);
}

static void MycWorkerRun(MycWorker* w)
{
    LARGE_INTEGER frequency, started, ended;
    QueryPerformanceFrequency(&frequency); /* lint-ok: C4 the worker thread's clock (inline only in the tests' synchronous mode) */
    QueryPerformanceCounter(&started); /* lint-ok: C4 as above */
    w->ok = 0;
    w->result = NULL;
    memset(&w->err, 0, sizeof w->err);
    w->save_why[0] = 0;
    if (!vpm_guarded(w->self, MycWorkerTask, w))
    {
        /* the core stopped the component (its stop ran on this thread); the half-made result is left as it is */
        w->result = NULL;
        w->ok = 0;
        InterlockedExchange(&w->faulted, 1);
        InterlockedExchange(&w->quit, 1);
    }
    QueryPerformanceCounter(&ended); /* lint-ok: C4 as above */
    w->seconds = frequency.QuadPart > 0 ? (double)(ended.QuadPart - started.QuadPart) / (double)frequency.QuadPart : 0.0;
}

static DWORD WINAPI MycWorkerMain(LPVOID arg)
{
    MycWorker* w = arg;
    while (WaitForSingleObject(w->wake, INFINITE) == WAIT_OBJECT_0 && !w->quit)
    {
        MycWorkerRun(w);
        InterlockedExchange(&w->busy, 0);
    }
    return 0;
}

/* The thread and its wake event, made with the first task (none while the component never has work). */
static int MycWorkerStart(MycWorker* w)
{
    if (w->thread != NULL) return 1;
    w->wake = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (w->wake == NULL) return 0;
    w->thread = CreateThread(NULL, 0, MycWorkerMain, w, 0, &w->thread_id); /* lint-ok: C6 the jobs' worker (header) */
    if (w->thread != NULL) return 1;
    CloseHandle(w->wake); /* lint-ok: C4 once, if the first task's thread cannot be made */
    w->wake = NULL;
    return 0;
}

int myc_worker_give(MycWorker* w, int task, MycRequest* request)
{
    if (w->busy || w->quit) return 0;
    w->task = task;
    w->request = request;
    if (w->synchronous)
    {
        MycWorkerRun(w);
        return 1;
    }
    if (!MycWorkerStart(w)) return 0;
    InterlockedExchange(&w->busy, 1);
    if (SetEvent(w->wake)) return 1; /* lint-ok: C4 one call per task, on the frame that gives it */
    InterlockedExchange(&w->busy, 0);
    return 0;
}

int myc_worker_stop(MycWorker* w, unsigned long timeout_ms)
{
    InterlockedExchange(&w->quit, 1);
    if (w->request != NULL && w->busy) w->request->obsolete = 1; /* a job ends at its next stage boundary */
    if (w->thread == NULL) return 1;
    SetEvent(w->wake);
    DWORD waited = WaitForSingleObject(w->thread, timeout_ms);
    if (waited != WAIT_OBJECT_0) return 0; /* still in a task: its memory stays (it is never freed) */
    CloseHandle(w->thread);
    CloseHandle(w->wake);
    w->thread = NULL;
    w->wake = NULL;
    return 1;
}

int myc_worker_on_thread(const MycWorker* w) { return w->thread != NULL && GetCurrentThreadId() == w->thread_id; }
