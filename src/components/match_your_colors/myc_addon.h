/* Match Your Colors: the per-frame step and its state (addon.lua), shared by myc_addon.c (the local Helldiver, the UI
 * preview, the binding checks, the squad's step, options and the restore), myc_addon_jobs.c (requests, jobs and their
 * results, the cache save, the reader's close) and myc_worker.c (the worker thread). Game thread unless a comment says
 * otherwise. */
#ifndef MYC_ADDON_H
#define MYC_ADDON_H

#include "../../core/vpm.h"
#include "myc_pipeline.h"
#include "myc_squad.h"

#define MYC_RESOLVE_FRAMES 15
#define MYC_VERIFY_FRAMES 120
#define MYC_CHECK_FRAMES 30
#define MYC_UI_GATE_FRAMES 4
#define MYC_SAVE_DELAY_FRAMES 300
#define MYC_KEEP_FRAMES 600
#define MYC_FAILURE_LIMIT 3
#define MYC_FAILURES 64
#define MYC_REQUEST_KEY 512
#define MYC_ERROR_LIMIT 8           /* the Lua guard's: errors of the step before it stopped the mod */
#define MYC_CLEAN_FRAMES 3600       /* the Lua guard's: frames without an error that clear the count */
#define MYC_SQUAD_OFF 1
#define MYC_SQUAD_MISSING 2
#define MYC_SQUAD_EVERYONE 3
#define MYC_SQUAD_OWN 1
#define MYC_SQUAD_YOURS 2
#define MYC_HIDE_OFF 1
#define MYC_HIDE_YOURS 2
#define MYC_HIDE_EVERYONE 3

typedef struct MycOptions
{
    int mode, keep_sets, recolor_hoods, match_materials, recolor_cape, recolor_weapons, scheme, squad, squad_colors, hide_cape,
        cape_hidden;
} MycOptions;

/* The UI preview of the local player (state.ui). */
typedef struct MycUi
{
    MycWhere where;
    MycPreviewWatch watch;
    int shown, dirty, has_kits, has_applied;
    uint32_t helmet, armor, body, cape;
    MycRequest applied;
} MycUi;

/* The worker's tasks (myc_worker.c): a job, the cache save, the game-data reader's close. */
#define MYC_TASK_JOB 1
#define MYC_TASK_SAVE 2
#define MYC_TASK_CLOSE 3
typedef struct MycWorker
{
    VpmComponent* self;
    void* thread;
    void* wake;
    unsigned long thread_id;
    int synchronous;                /* tests: a task runs inside myc_worker_give (no thread) */
    volatile long busy;             /* a task given and not finished: the worker's fields below are its */
    volatile long quit;
    volatile long faulted;          /* a task faulted (the core stopped the component from the worker) */
    int task;
    MycRequest* request;            /* the game thread's (it may set obsolete) */
    MycResult* result;
    MycErr err;
    int ok;
    char save_why[192];
    double seconds;                 /* the task's time on the worker */
    MycPipeline* pipeline;          /* the worker's; the game thread reads it while the worker is idle */
    wchar_t data_folder[1024], cache_path[1100];
    int has_cache;
} MycWorker;

typedef struct MycFailure { char key[MYC_REQUEST_KEY]; int count; } MycFailure;

typedef struct MycAddon
{
    VpmComponent* self;
    MycNative native;
    MycPool pool;
    MycController controller, ui_controller;
    uint32_t frame, next_resolve, next_verify, next_check, next_sync, verified_at, found_at, job_frame;
    int has_identity, has_found_at, dirty, active, loopback, syncing, has_verified;
    MycIdentity identity, probe;
    MycWatch watch;
    uintptr_t slot;
    char why[96];
    int has_why;
    MycOptions options;
    char sync_text[MYC_SYNC_TEXT_MAX + 1];
    MycCatalogue* kits;             /* the pipeline's catalogue, taken from the worker after a job (records_same) */
    /* jobs */
    int job;                        /* a job is with the worker */
    int saving;                     /* the cache save is with the worker */
    int close_due;                  /* the kept reader is to be closed (on the worker, once it is idle) */
    MycRequest request;
    MycFailure failures[MYC_FAILURES];
    int nfailures;
    MycRequest applied;
    int has_applied;
    char prepared[MYC_REQUEST_KEY];
    int has_prepared, has_warm, pipeline_asked;
    MycRequest warm;
    int has_reader_kept, has_save_at, cache_logged, patches_logged, expired_noted;
    uint32_t reader_kept, save_at;
    char last_reason[64];
    int has_last_reason;
    uint64_t albedo_report, cape_report; /* hashes of the last reports logged */
    char weapons_reason[64];
    int has_weapons_reason;
    double last_job_seconds;
    uint32_t last_job_frames;
    int errors, clean_run;          /* the Lua guard's count of the step's errors */
    char error_burst[192];          /* the first of them */
    /* the UI preview */
    int has_ui;
    MycUi ui;
    /* the squad, weapons and capes */
    int has_squad_mine;
    MycSettings squad_mine;
    int cloak_due;
    MycMember cloak_members[MYC_SYNC_MAX_MEMBERS];
    int ncloak_members;
    MycSync session;
    MycRemote remote;
    MycLineup lineup;
    MycLoadout loadout;
    MycCloak cloak;
    int has_sync, has_lineup, has_loadout, has_cloak;
    MycWorker worker;
} MycAddon;

extern MycAddon myc_g;
void myc_note(const char* line);
void myc_notef(const char* format, ...) __attribute__((format(printf, 1, 2)));

/* myc_addon.c */
int myc_cape_counts(int mode, int scheme, int capes);
void myc_mode_of(int target, int* mode, int* scheme);
int myc_options_cape_counts(int target);
int myc_options_changed(const MycRequest* r);
int myc_kits_changed(const MycRequest* r, uint32_t helmet, uint32_t armor, uint32_t body, uint32_t cape);
int myc_records_same(void* ctx, const MycResult* result, uint32_t helmet, uint32_t armor, uint32_t cape, int has_cape);
void myc_request_key(const MycRequest* r, char* out, size_t size);
MycApplyTo myc_apply_to(uintptr_t units_at, uint32_t body, uintptr_t slot);
void myc_addon_adopt(const MycIdentity* identity, uint32_t frame);
void myc_addon_lose(uint32_t frame, const char* why);
void myc_addon_poll_ui(uint32_t frame);
void myc_addon_ui_hidden(uint32_t frame);
void myc_addon_close_kept(void);
int myc_weapons_on(void);
void myc_addon_cloak_local(void);
void myc_addon_settle(void* ctx, MycController* c, uint32_t frame, const char* what);
void myc_addon_step(void);
void myc_addon_set_option(const char* name, int value, int toggle);
void myc_addon_options_text(char* out, size_t size);
void myc_addon_init_sync_text(void);
void myc_addon_restore_all(void);
/* An error of the step (the Lua guard's "error: ..." line, once per burst): MYC_ERROR_LIMIT of them stop the component. */
void myc_addon_error(const char* why);
/* myc_addon_jobs.c */
void myc_addon_plan_ahead(int found);
/* A job for target (given: a request made ahead, plan_ahead's); 1 started, 0 none (none due, failed too often, or the
 * worker still busy with a save or a close: the flags that ask for it stay set). */
int myc_addon_start_job(uint32_t frame, int target, const MycRequest* given);
void myc_addon_job_step(uint32_t frame);
void myc_addon_save_step(uint32_t frame);
void myc_addon_close_step(void);
int myc_addon_still_current(const MycRequest* request, uint32_t frame, MycIdentity* now);
/* myc_worker.c */
int myc_worker_give(MycWorker* w, int task, MycRequest* request);
/* Stops the thread (waits up to timeout_ms for a task to end); 1 when it has ended, 0 when it still runs. */
int myc_worker_stop(MycWorker* w, unsigned long timeout_ms);
int myc_worker_on_thread(const MycWorker* w);
static inline int myc_worker_busy(const MycWorker* w) { return w->busy != 0; }

#endif
