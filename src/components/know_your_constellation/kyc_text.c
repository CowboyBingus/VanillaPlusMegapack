/* Know Your Constellation's text layout (Bingus Text v1, bingus_text.lua: decode, check, length, boundaries, pieces,
 * wrap), for UTF-8 in any script: measured, wrapped and scrolled by character, never by byte. Translations and the
 * game's Text Language (the rest of bingus_text.lua) are not ported: the pack's texts are English (vpm_text). Nothing
 * here runs per frame: the panel lays out text when its report, geometry or font changes. */
#include <string.h>
#include "kyc.h"

/* A lead byte: the continuation bytes it needs and its value bits, and the range of the first continuation byte (no
 * overlong forms, surrogates or values above U+10FFFF); 0 when it cannot start a character. */
static int Lead(uint8_t c, uint32_t* v, uint8_t* lo, uint8_t* hi)
{
    *lo = 0x80;
    *hi = 0xBF;
    if (c >= 0xC2 && c <= 0xDF) { *v = c - 0xC0u; return 1; }
    if (c >= 0xE0 && c <= 0xEF)
    {
        *v = c - 0xE0u;
        if (c == 0xE0) *lo = 0xA0;
        if (c == 0xED) *hi = 0x9F;
        return 2;
    }
    if (c < 0xF0 || c > 0xF4) return 0;
    *v = c - 0xF0u;
    if (c == 0xF0) *lo = 0x90;
    if (c == 0xF4) *hi = 0x8F;
    return 3;
}

int kyc_utf8_decode(const char* text, size_t length, size_t at, uint32_t* value, size_t* after)
{
    if (at >= length) return 0;
    uint8_t c = (uint8_t)text[at], lo, hi;
    if (c < 0x80) { *value = c; *after = at + 1; return 1; }
    uint32_t v;
    int n = Lead(c, &v, &lo, &hi);
    if (n == 0) return 0;
    for (int k = 1; k <= n; k++)
    {
        if (at + (size_t)k >= length) return 0;
        uint8_t d = (uint8_t)text[at + (size_t)k];
        if (d < lo || d > hi) return 0;
        v = v * 64u + (d - 0x80u);
        lo = 0x80;
        hi = 0xBF;
    }
    *value = v;
    *after = at + (size_t)n + 1;
    return 1;
}

int kyc_text_check(const char* text, size_t length, size_t* bad, const char** why)
{
    size_t i = 0;
    while (i < length)
    {
        uint32_t v;
        size_t after;
        if (!kyc_utf8_decode(text, length, i, &v, &after)) { *bad = i + 1; *why = "invalid UTF-8"; return 0; }
        if (v < 32 || v == 127 || (v >= 0x80 && v < 0xA0)) { *bad = i + 1; *why = "control character"; return 0; }
        i = after;
    }
    return 1;
}

size_t kyc_text_length(const char* text, size_t length)
{
    size_t count = 0, i = 0;
    while (i < length)
    {
        uint32_t v;
        size_t after;
        i = kyc_utf8_decode(text, length, i, &v, &after) ? after : i + 1;
        count++;
    }
    return count;
}

/* The code point at i (U+FFFD for a byte that is not valid UTF-8) and the byte after it. */
static uint32_t Next(const char* text, size_t length, size_t i, size_t* after)
{
    uint32_t v;
    if (kyc_utf8_decode(text, length, i, &v, after)) return v;
    *after = i + 1;
    return 0xFFFDu;
}

/* ---- line breaking: a small subset of Unicode UAX #14 ------------------------------------------------------- */

#define ZWJ 0x200Du

/* Never break before these: closing punctuation, small kana, the prolonged sound mark. */
static const uint32_t kClose[] = {0x21, 0x25, 0x29, 0x2C, 0x2E, 0x3A, 0x3B, 0x3F, 0x5D, 0x7D,
    0x2010, 0x2013, 0x2019, 0x201D, 0x2025, 0x2026, 0x2030, 0x2103,
    0x3001, 0x3002, 0x3005, 0x3009, 0x300B, 0x300D, 0x300F, 0x3011, 0x3015, 0x3017, 0x3019, 0x301B,
    0x301C, 0x301E, 0x301F, 0x303B,
    0x3041, 0x3043, 0x3045, 0x3047, 0x3049, 0x3063, 0x3083, 0x3085, 0x3087, 0x308E, 0x3095, 0x3096,
    0x309B, 0x309C, 0x309D, 0x309E, 0x30A0, 0x30A1, 0x30A3, 0x30A5, 0x30A7, 0x30A9, 0x30C3, 0x30E3,
    0x30E5, 0x30E7, 0x30EE, 0x30F5, 0x30F6, 0x30FB, 0x30FC, 0x30FD, 0x30FE,
    0xFF01, 0xFF05, 0xFF09, 0xFF0C, 0xFF0E, 0xFF1A, 0xFF1B, 0xFF1F, 0xFF3D, 0xFF5D, 0xFF5E, 0xFF60,
    0xFF61, 0xFF63, 0xFF64, 0xFF65};
/* Never break after these: opening punctuation and currency signs. */
static const uint32_t kOpen[] = {0x24, 0x28, 0x5B, 0x7B, 0xA3, 0xA5, 0x2018, 0x201C, 0x20A9, 0x20AC,
    0x3008, 0x300A, 0x300C, 0x300E, 0x3010, 0x3014, 0x3016, 0x3018, 0x301A, 0x301D,
    0xFF04, 0xFF08, 0xFF3B, 0xFF5B, 0xFF5F, 0xFF62, 0xFFE1, 0xFFE5};

static int InList(const uint32_t* list, size_t count, uint32_t v)
{
    for (size_t i = 0; i < count; i++)
        if (list[i] == v) return 1;
    return 0;
}

static int Close(uint32_t v) { return InList(kClose, sizeof kClose / sizeof kClose[0], v); }
static int Open(uint32_t v) { return InList(kOpen, sizeof kOpen / sizeof kOpen[0], v); }

/* Characters that belong to the one before them: combining marks, joiners, variation selectors, emoji skin tones,
 * Hangul vowel and final jamo. */
static int Mark(uint32_t v)
{
    return (v >= 0x300 && v <= 0x36F) || (v >= 0x483 && v <= 0x489) || v == 0xE31 || (v >= 0xE34 && v <= 0xE3A) ||
        (v >= 0xE47 && v <= 0xE4E) || (v >= 0x1160 && v <= 0x11FF) || (v >= 0x1AB0 && v <= 0x1AFF) ||
        (v >= 0x1DC0 && v <= 0x1DFF) || v == 0x200C || v == ZWJ || (v >= 0x20D0 && v <= 0x20FF) || v == 0x3099 ||
        v == 0x309A || (v >= 0xFE00 && v <= 0xFE0F) || (v >= 0xFE20 && v <= 0xFE2F) || (v >= 0x1F3FB && v <= 0x1F3FF) ||
        (v >= 0xE0100 && v <= 0xE01EF);
}

/* Scripts written without spaces between words (Chinese, Japanese) and Korean syllables. */
static int Wide(uint32_t v)
{
    return (v >= 0x1100 && v <= 0x115F) || (v >= 0x2E80 && v <= 0xA4CF) || (v >= 0xA960 && v <= 0xA97F) ||
        (v >= 0xAC00 && v <= 0xD7FF) || (v >= 0xF900 && v <= 0xFAFF) || (v >= 0xFE10 && v <= 0xFE1F) ||
        (v >= 0xFE30 && v <= 0xFE4F) || (v >= 0xFF00 && v <= 0xFF60) || (v >= 0xFFE0 && v <= 0xFFE6) ||
        (v >= 0x1F300 && v <= 0x1FAFF) || (v >= 0x20000 && v <= 0x3FFFD);
}

static int Space(uint32_t v) { return v == 32 || v == 0x3000; }

int kyc_text_boundaries(const char* text, size_t length, uint16_t* out, int capacity)
{
    int n = 0;
    size_t i = 0;
    uint32_t previous = 0;
    int first = 1;
    while (i < length)
    {
        size_t after;
        uint32_t v = Next(text, length, i, &after);
        if (first || !(Mark(v) || previous == ZWJ))
        {
            if (n >= capacity || i > 0xFFFF) return -1;
            out[n++] = (uint16_t)i;
        }
        first = 0;
        previous = v;
        i = after;
    }
    if (n >= capacity || length > 0xFFFF) return -1;
    out[n++] = (uint16_t)length;
    return n;
}

/* An unbreakable piece: its bytes, the separator before it (gap_at, gap_length: spaces) and the line feeds before it. */
typedef struct Piece { size_t first, last, gap_at, gap_length; int feeds; } Piece;

typedef struct Pieces
{
    const char* text;
    size_t length, i;
    int has_first, feeds;
    size_t first, last, gap_at, gap_length;
    uint32_t previous; /* the last character of the piece being built */
} Pieces;

/* The piece being built ends: 1 with it in *out, 0 when there is none. The separator and line feeds start over. */
static int Finish(Pieces* p, Piece* out)
{
    if (!p->has_first) return 0;
    *out = (Piece){p->first, p->last, p->gap_at, p->gap_length, p->feeds};
    p->has_first = p->feeds = 0;
    p->gap_length = 0;
    return 1;
}

/* Whether a character stays in the piece before it: marks, after a joiner, closing punctuation, after opening
 * punctuation, and between characters of scripts that space their words. */
static int Joins(uint32_t previous, uint32_t v)
{
    return Mark(v) || previous == ZWJ || Close(v) || Open(previous) || !(Wide(v) || Wide(previous));
}

/* One character into the pieces: 1 when a finished piece went to *out. */
static int Feed(Pieces* p, size_t at, size_t after, uint32_t v, Piece* out)
{
    int done = 0;
    if (v == 10)
    {
        done = Finish(p, out);
        p->feeds++;
        p->gap_length = 0;
        return done;
    }
    if (Space(v))
    {
        if (p->has_first) done = Finish(p, out);
        if (p->gap_length == 0) p->gap_at = at;
        p->gap_length += after - at;
        return done;
    }
    if (p->has_first && Joins(p->previous, v)) p->last = after - 1;
    else
    {
        done = Finish(p, out);
        p->has_first = 1;
        p->first = at;
        p->last = after - 1;
    }
    p->previous = v;
    return done;
}

/* The next unbreakable piece of the text (pieces() in the Lua, one at a time): 1, or 0 at the end. */
static int NextPiece(Pieces* p, Piece* out)
{
    while (p->i < p->length)
    {
        size_t after, at = p->i;
        uint32_t v = Next(p->text, p->length, at, &after);
        p->i = after;
        if (Feed(p, at, after, v, out)) return 1;
    }
    return Finish(p, out);
}

typedef struct Wrap
{
    const char* text;
    double width;
    KycMeasureFn measure;
    void* context;
    KycLine* lines;
    int capacity, count;
    size_t line_at, line_length; /* the line being built: text[line_at, line_at + line_length) */
} Wrap;

static int Emit(Wrap* w, size_t at, size_t length)
{
    if (w->count >= w->capacity) return kyc_fail("Too many forecast lines");
    w->lines[w->count++] = (KycLine){at, length};
    return 1;
}

static int Fits(Wrap* w, size_t at, size_t length, int* fits)
{
    double width;
    if (!w->measure(w->context, w->text + at, length, &width)) return 0;
    *fits = width <= w->width;
    return 1;
}

/* A piece wider than a whole line breaks between characters. */
static int BreakPiece(Wrap* w, size_t first, size_t length)
{
    static uint16_t edges[1025];
    int n = kyc_text_boundaries(w->text + first, length, edges, 1025);
    if (n < 0) return kyc_fail("Forecast text too long");
    w->line_length = 0;
    for (int k = 0; k + 1 < n; k++)
    {
        size_t glyph = first + edges[k], glyph_length = (size_t)(edges[k + 1] - edges[k]);
        size_t start = w->line_length > 0 ? w->line_at : glyph;
        int fits;
        if (!Fits(w, start, glyph + glyph_length - start, &fits)) return 0;
        if (fits) { w->line_at = start; w->line_length = glyph + glyph_length - start; continue; }
        if (w->line_length == 0) return kyc_fail("Text column too narrow");
        if (!Emit(w, w->line_at, w->line_length)) return 0;
        w->line_at = glyph;
        w->line_length = glyph_length;
    }
    return 1;
}

static int AddPiece(Wrap* w, const Piece* piece)
{
    size_t value = piece->first, value_length = piece->last + 1 - piece->first;
    for (int k = 0; k < piece->feeds; k++)
    {
        if (!Emit(w, w->line_at, w->line_length)) return 0;
        w->line_length = 0;
    }
    /* The candidate: the line, the separator and the piece, which follow each other in the text. */
    size_t start = w->line_length > 0 ? w->line_at : value;
    int fits;
    if (!Fits(w, start, value + value_length - start, &fits)) return 0;
    if (fits) { w->line_at = start; w->line_length = value + value_length - start; return 1; }
    if (w->line_length > 0 && !Emit(w, w->line_at, w->line_length)) return 0;
    if (!Fits(w, value, value_length, &fits)) return 0;
    if (fits) { w->line_at = value; w->line_length = value_length; return 1; }
    return BreakPiece(w, value, value_length);
}

int kyc_text_wrap(const char* text, size_t length, double width, KycMeasureFn measure, void* context, KycLine* lines,
    int capacity)
{
    Wrap w = {text, width, measure, context, lines, capacity, 0, 0, 0};
    Pieces p;
    memset(&p, 0, sizeof p);
    p.text = text;
    p.length = length;
    Piece piece;
    while (NextPiece(&p, &piece))
        if (!AddPiece(&w, &piece)) return -1;
    if (w.line_length > 0 && !Emit(&w, w.line_at, w.line_length)) return -1;
    return w.count;
}
