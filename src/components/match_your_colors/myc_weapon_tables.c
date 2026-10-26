/* Match Your Colors: lookups in the generated weapon tables (myc_weapon_data.c): Kits.weapon_rows and the unit_of and
 * attachment_archive tables of src/weapon_data.lua. Used by the worker's jobs. */
#include <stdlib.h>
#include <string.h>
#include "myc_weapons.h"

static const MycWdText* MycWdUnit(uint64_t unit)
{
    int lo = 0, hi = myc_wd_unit_count - 1;
    while (lo <= hi)
    {
        int mid = (lo + hi) / 2;
        if (myc_wd_units[mid].unit == unit) return &myc_wd_units[mid];
        if (myc_wd_units[mid].unit < unit) lo = mid + 1;
        else hi = mid - 1;
    }
    return NULL;
}

/* One 'material:triangles:row=share,...' entry from p (to '|' or the end) for material; 1 when it is that material. */
static int MycWdEntry(const char* p, const char* stop, uint64_t material, double* triangles, double shares[8])
{
    char* end = NULL;
    unsigned long long name = strtoull(p, &end, 16);
    if (end == p || *end != ':' || name != material) return 0;
    p = end + 1;
    double t = strtod(p, &end);
    if (end == p || *end != ':') return 0;
    p = end + 1;
    for (int r = 0; r < 8; r++) shares[r] = 0;
    while (p < stop)
    {
        long r = strtol(p, &end, 10);
        if (end == p || *end != '=') break;
        p = end + 1;
        double s = strtod(p, &end);
        if (end == p) break;
        if (r >= 0 && r < 8) shares[r] = s;
        p = end;
        if (*p == ',') p++;
    }
    *triangles = t;
    return 1;
}

int myc_weapon_rows(uint64_t unit, uint64_t material, double* triangles, double shares[8])
{
    const MycWdText* t = MycWdUnit(unit);
    int found = 0;
    for (const char* p = t != NULL ? t->text : NULL; p != NULL && *p;)
    {
        const char* bar = strchr(p, '|');
        const char* stop = bar != NULL ? bar : p + strlen(p);
        double tri, s[8];
        if (MycWdEntry(p, stop, material, &tri, s)) /* a material listed twice keeps its last entry */
        {
            *triangles = tri;
            memcpy(shares, s, sizeof s);
            found = 1;
        }
        p = bar != NULL ? bar + 1 : NULL;
    }
    return found;
}

static int MycWdPairOf(const MycWdPair* table, int count, uint64_t key, uint64_t* out)
{
    int lo = 0, hi = count - 1;
    while (lo <= hi)
    {
        int mid = (lo + hi) / 2;
        if (table[mid].key == key) { *out = table[mid].value; return 1; }
        if (table[mid].key < key) lo = mid + 1;
        else hi = mid - 1;
    }
    return 0;
}

int myc_weapon_unit_of(uint64_t weapon, uint64_t* out) { return MycWdPairOf(myc_wd_unit_of, myc_wd_unit_of_count, weapon, out); }

int myc_weapon_attachment_archive(uint64_t unit, uint64_t* out)
{
    return MycWdPairOf(myc_wd_attachment_archive, myc_wd_attachment_archive_count, unit, out);
}
