/* Match Your Colors: Hide Cape (cloak.lua), 1:1. A cape is hidden through the engine's own set_unit_visibility (one
 * queued command per cape unit); each of its meshes then reads 0 in its visibility mask (+0xDC). Targets: "local" (the
 * unit watch's refs, no read of its own) and other players whose shared value hides their cape (sync flag 32), or every
 * other player with Everyone's Capes. A new cape is young for GRACE_FRAMES: its helmet's mask is read so the hellpod's
 * exit, which shows every unit again, has it hidden again the next frame. Game thread; no memory writes. */
#include <stdio.h>
#include <string.h>
#include "myc_squad.h"

#define NO_UNIT 0xFFFFFFFFu

void myc_cloak_init(MycCloak* c, const MycNative* native, void (*note)(const char* line))
{
    memset(c, 0, sizeof *c);
    c->native = native;
    c->note = note;
}

static uint64_t MycCloakFirstMesh(const MycCloak* c, uint32_t unit)
{
    return c->native->meshes(unit) == 0 ? 0 : c->native->mesh(unit, 0);
}

static void MycCloakWhose(const char* key, char* out, size_t size)
{
    if (strcmp(key, "local") == 0) snprintf(out, size, "your");
    else snprintf(out, size, "%s's", key);
}

static MycCloakTarget* MycCloakFind(MycCloak* c, const char* key)
{
    for (int i = 0; i < c->ntargets; i++)
        if (strcmp(c->targets[i].key, key) == 0) return &c->targets[i];
    return NULL;
}

static void MycCloakYoungUntil(MycCloak* c, MycCloakTarget* t, uint32_t frame)
{
    t->young_until = frame;
    if (strcmp(t->key, "local") == 0) c->young_until = frame;
}

static int MycCloakHas(const MycCloakTarget* t, uint32_t unit)
{
    for (int i = 0; i < t->ncapes; i++)
        if (t->cape_units[i] == unit) return 1;
    return 0;
}

/* A new cape unit hidden; 1 when it was new. */
static int MycCloakHide(MycCloak* c, MycCloakTarget* t, uint32_t unit, uint32_t frame)
{
    if (MycCloakHas(t, unit) || t->ncapes >= MYC_CLOAK_CAPES || c->native->alive(unit) == 0) return 0;
    c->native->visibility(unit, 0, 1);
    t->cape_units[t->ncapes] = unit;
    t->cape_meshes[t->ncapes++] = MycCloakFirstMesh(c, unit);
    t->hidden_at = frame;
    t->pod = 0;
    MycCloakYoungUntil(c, t, frame + MYC_CLOAK_GRACE_FRAMES);
    c->hidden++;
    char whose[48], line[128];
    MycCloakWhose(t->key, whose, sizeof whose);
    snprintf(line, sizeof line, "Hide Cape: %s cape hidden (unit %x).", whose, unit);
    c->note(line);
    return 1;
}

/* A cape something showed again (its mask not 0) hidden again while its unit lives. */
static void MycCloakRehide(MycCloak* c, MycCloakTarget* t, uint32_t frame, int pod)
{
    for (int i = 0; i < t->ncapes; i++)
    {
        uint8_t mask;
        if (t->cape_meshes[i] == 0 || !vpm_read_u8((uintptr_t)t->cape_meshes[i] + MYC_MESH_VISIBILITY, &mask)) continue;
        if (mask == 0 || c->native->alive(t->cape_units[i]) == 0) continue;
        c->native->visibility(t->cape_units[i], 0, 1);
        if (++c->reshown > MYC_CLOAK_NOTES) continue;
        char whose[48], line[192];
        MycCloakWhose(t->key, whose, sizeof whose);
        if (pod)
            snprintf(line, sizeof line, "Hide Cape: the hellpod opened and showed %s cape %u frames after it was hidden; hidden "
                "again the next frame.", whose, frame - t->hidden_at);
        else snprintf(line, sizeof line, "Hide Cape: the game showed %s cape again %u frames after it was hidden; hidden again.",
            whose, frame - t->hidden_at);
        c->note(line);
    }
}

static MycCloakTarget* MycCloakAdd(MycCloak* c, const char* key, int other)
{
    if (c->ntargets >= MYC_CLOAK_TARGETS) return NULL;
    MycCloakTarget* t = &c->targets[c->ntargets++];
    memset(t, 0, sizeof *t);
    snprintf(t->key, sizeof t->key, "%s", key);
    t->other = other;
    return t;
}

void myc_cloak_wear(MycCloak* c, const char* key, const uint32_t* refs, int other, uint32_t frame)
{
    MycCloakTarget* t = MycCloakFind(c, key);
    if (t == NULL) t = MycCloakAdd(c, key, other);
    if (t == NULL) return;
    uint32_t worn[3];
    int nworn = 0, fresh = 0;
    for (int a = 0; a < 3; a++)
    {
        uint32_t unit = refs[10 * a + 1];
        if (unit == 0 || unit == NO_UNIT) continue;
        worn[nworn++] = unit;
        fresh |= MycCloakHide(c, t, unit, frame);
    }
    int keep = 0;
    for (int i = 0; i < t->ncapes; i++)
    {
        int still = 0;
        for (int k = 0; k < nworn; k++) still |= worn[k] == t->cape_units[i];
        if (!still) continue;
        t->cape_units[keep] = t->cape_units[i];
        t->cape_meshes[keep++] = t->cape_meshes[i];
    }
    t->ncapes = keep;
    if (!fresh) return;
    uint32_t helmet = refs[0];
    t->helmet_mesh = helmet != 0 && helmet != NO_UNIT && c->native->alive(helmet) != 0 ? MycCloakFirstMesh(c, helmet) : 0;
}

static void MycCloakYoungTurn(MycCloak* c, MycCloakTarget* t, uint32_t frame)
{
    uint8_t mask;
    if (t->helmet_mesh == 0 || !vpm_read_u8((uintptr_t)t->helmet_mesh + MYC_MESH_VISIBILITY, &mask)) { MycCloakYoungUntil(c, t, 0); return; }
    if (mask == 0)
    {
        t->pod = 1;
        uint32_t grace = frame + MYC_CLOAK_GRACE_FRAMES, pod = t->hidden_at + MYC_CLOAK_POD_FRAMES;
        MycCloakYoungUntil(c, t, grace < pod ? grace : pod);
        return;
    }
    if (!t->pod) return;
    t->pod = 0;
    MycCloakYoungUntil(c, t, 0);
    MycCloakRehide(c, t, frame, 1);
}

void myc_cloak_drop(MycCloak* c, const char* key, int show)
{
    MycCloakTarget* t = MycCloakFind(c, key);
    if (t == NULL) return;
    if (show)
    {
        for (int i = 0; i < t->ncapes; i++)
            if (c->native->alive(t->cape_units[i]) != 0) { c->native->visibility(t->cape_units[i], 1, 1); c->shown++; }
        char whose[48], line[96];
        MycCloakWhose(key, whose, sizeof whose);
        snprintf(line, sizeof line, "Hide Cape: %s cape shown again.", whose);
        c->note(line);
    }
    if (strcmp(t->key, "local") == 0) c->young_until = 0;
    int at = (int)(t - c->targets);
    memmove(&c->targets[at], &c->targets[at + 1], sizeof c->targets[0] * (size_t)(c->ntargets - at - 1));
    c->ntargets--;
}

void myc_cloak_clear(MycCloak* c)
{
    while (c->ntargets > 0)
    {
        char key[32];
        snprintf(key, sizeof key, "%s", c->targets[0].key);
        myc_cloak_drop(c, key, 1);
    }
}

void myc_cloak_check(MycCloak* c, uint32_t frame)
{
    if (c->ntargets == 0) return;
    c->turn = c->turn % c->ntargets + 1;
    MycCloakRehide(c, &c->targets[c->turn - 1], frame, 0);
}

/* lint: per-frame */
int myc_cloak_young(MycCloak* c, uint32_t frame)
{
    MycCloakTarget* t = MycCloakFind(c, "local");
    if (t == NULL || frame > t->young_until) return 0;
    MycCloakYoungTurn(c, t, frame);
    return 1;
}

int myc_cloak_others(const MycCloak* c)
{
    int n = 0;
    for (int i = 0; i < c->ntargets; i++) n += c->targets[i].other;
    return n;
}

static MycCloakTarget* MycCloakOther(MycCloak* c, int index)
{
    for (int i = 0; i < c->ntargets; i++)
        if (c->targets[i].other && index-- == 0) return &c->targets[i];
    return NULL;
}

void myc_cloak_step(MycCloak* c, uint32_t frame)
{
    int n = myc_cloak_others(c);
    if (n == 0) return;
    c->cursor = c->cursor % n + 1;
    MycCloakTarget* t = MycCloakOther(c, c->cursor - 1);
    uint32_t refs[30];
    if (t->units_at == 0 || !vpm_read(t->units_at, refs, 120)) return;
    for (int a = 0; a < 3; a++)
    {
        uint32_t unit = refs[10 * a + 1];
        if (unit != 0 && unit != NO_UNIT && !MycCloakHas(t, unit))
        {
            char key[32];
            snprintf(key, sizeof key, "%s", t->key);
            myc_cloak_wear(c, key, refs, 1, frame);
            return;
        }
    }
    if (frame <= t->young_until) MycCloakYoungTurn(c, t, frame);
}

/* Whether a member's value hides its cape (decoded once per text). */
static int MycCloakHides(MycCloak* c, const MycMember* m)
{
    if (!m->has_text) return 0;
    for (int i = 0; i < c->ndecoded; i++)
        if (strcmp(c->decoded[i], m->text) == 0) return c->decoded_hides[i];
    if (c->ndecoded >= 32) c->ndecoded = 0;
    MycSettings o;
    int hides = myc_sync_decode(m->text, &o) && o.cape_hidden;
    snprintf(c->decoded[c->ndecoded], sizeof c->decoded[0], "%s", m->text);
    c->decoded_hides[c->ndecoded++] = hides;
    return hides;
}

static int MycCloakAnyHides(MycCloak* c, const MycMember* members, int n)
{
    for (int i = 0; i < n; i++)
        if (!members[i].is_local && MycCloakHides(c, &members[i])) return 1;
    return 0;
}

int myc_cloak_needed(MycCloak* c, const MycMember* members, int n, int everyone)
{
    return everyone || myc_cloak_others(c) > 0 || MycCloakAnyHides(c, members, n);
}

static int MycCloakWanted(MycCloak* c, const MycPlayer* p, const MycMember* members, int n, int everyone)
{
    if (p->is_local) return 0;
    if (everyone) return 1;
    for (int i = 0; i < n; i++)
        if (!members[i].is_local && members[i].peer_low == p->peer_low && members[i].peer_high == p->peer_high) return MycCloakHides(c, &members[i]);
    return 0;
}

/* A wanted player: their Helldiver resolved once per Helldiver unit, their capes hidden. */
static void MycCloakFollow(MycCloak* c, const MycPlayer* p, uint32_t frame)
{
    char key[32];
    snprintf(key, sizeof key, "player %u", p->player);
    MycCloakTarget* t = MycCloakFind(c, key);
    if (t != NULL && t->has_unit && t->unit == p->unit) return;
    MycIdentity player, identity;
    memset(&player, 0, sizeof player);
    player.player = p->player;
    player.unit = p->unit;
    player.peer_low = p->peer_low;
    player.peer_high = p->peer_high;
    const char* why;
    uint32_t refs[30];
    if (!myc_avatar_resolve_remote(&player, &identity, &why) || !vpm_read(identity.units_at, refs, 120)) return;
    myc_cloak_wear(c, key, refs, 1, frame);
    t = MycCloakFind(c, key);
    if (t == NULL) return;
    t->unit = p->unit;
    t->has_unit = 1;
    t->units_at = identity.units_at;
}

void myc_cloak_update(MycCloak* c, const MycMember* members, int n, int everyone, uint32_t frame)
{
    char seen[MYC_MAX_PLAYERS][32];
    int nseen = 0;
    if (everyone || MycCloakAnyHides(c, members, n))
    {
        MycPlayer players[MYC_MAX_PLAYERS];
        int np = myc_avatar_players(players);
        for (int i = 0; i < np; i++)
        {
            if (!MycCloakWanted(c, &players[i], members, n, everyone)) continue;
            snprintf(seen[nseen++], sizeof seen[0], "player %u", players[i].player);
            MycCloakFollow(c, &players[i], frame);
        }
    }
    for (int i = c->ntargets - 1; i >= 0; i--)
    {
        if (!c->targets[i].other) continue;
        int kept = 0;
        for (int k = 0; k < nseen; k++) kept |= strcmp(seen[k], c->targets[i].key) == 0;
        if (kept) continue;
        char key[32];
        snprintf(key, sizeof key, "%s", c->targets[i].key);
        myc_cloak_drop(c, key, 1);
    }
}
