/* Match Your Colors: a job's context (recolor.lua Recolor.job and weapons_job), shared by myc_job.c (the helmet, armor
 * and cape) and myc_job_weapons.c (Recolor Weapons). Worker thread. */
#ifndef MYC_JOB_H
#define MYC_JOB_H

#include "myc_pipeline.h"
#include "myc_weapon_mem.h"

typedef struct MycJob
{
    MycPipeline* p;
    MycRequest* request;
    const MycScheme* scheme;
    char records[9];
    MycKit* helmet_kit;
    MycKit* armor_kit;
    MycKit* source_kit;
    MycKit* cape_kit;
    MycKit* cape_source_kit;
    MycAnalysis* cape;
    MycAnalysis* cape_source;
    MycAnalysis* kit_source;
    MycAnalysis* source;
    char cape_source_key[64], kit_source_key[64];
    int cape_mode, set;
    /* the source item, made once (source_item) */
    MycItem* s;
    MycSourceLuts source_luts;
    MycArena arena;                 /* the job's: items, plans, weapon kits */
    MycGroup* camo;                 /* a weapon template's camo source group (camo_copies) */
    MycErr* err;
} MycJob;

#define MYC_JOB_OK 1
#define MYC_JOB_DONE 0              /* the result is set: return it */
#define MYC_JOB_FAILED -1           /* after myc_fail */

int myc_job_obsolete(const MycJob* j);
/* Recolor's records_sum of up to 5 kits (Adler-32 of their signatures one after the other). */
void myc_records_sum(MycKit* const* kits, int n, char out[9]);
/* The kit's analysis for the request's body, or NULL (j->err set on a failure). */
MycAnalysis* myc_job_analysis(MycJob* j, MycKit* kit);
/* The key of one item's plan against a source that is not the other item (item_key). */
void myc_job_item_key(MycJob* j, const char* source, MycKit* kit, char* out, size_t size);
/* The plan of targets under key, made once and kept (planned); NULL after myc_fail. */
MycMade* myc_job_planned(MycJob* j, const char* key, MycAnalysis* const* targets, int n);
/* With Helmet and Armor Match Cape: the worn cape's kit, analysis and key part into j; 0 when there is no cape or no
 * analysis of it (MYC_JOB_FAILED after myc_fail). */
int myc_job_cape_source(MycJob* j);
/* The job's source item (source_item): made once. 0 after myc_fail. */
int myc_job_source_item(MycJob* j);
/* The result's restore or obsolete outcome with a reason. */
void myc_result_restore(MycResult* r, const MycJob* j, const char* reason);

/* Recolor.weapons_job (myc_job_weapons.c). */
int myc_weapons_job(MycJob* j, MycResult* out);

#endif
