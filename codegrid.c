// ----------------------------------------------------------------------------------------------------------------------------------------------------------------

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include "codegrid_tiles.h"

// ----------------------------------------------------------------------------------------------------------------------------------------------------------------

#ifdef ZOOM9_ONLY
static const int ZLIST[] = { 9 };
static const struct cg_ztile *zoom_tables[] = { _cgz9 };
static const int zoom_counts[] = { CG_Z9_COUNT };
#else
static const int ZLIST[] = { 9, 13 };
static const struct cg_ztile *zoom_tables[] = { _cgz9, _cgz13 };
static const int zoom_counts[] = { CG_Z9_COUNT, CG_Z13_COUNT };
#endif
#define ZLIST_LEN ((int)(sizeof(ZLIST) / sizeof(ZLIST[0])))

// ----------------------------------------------------------------------------------------------------------------------------------------------------------------

static inline int lon2tile(double lon, int zoom) {
    return (int)floor(fmod(fmod((lon + 180.0) / 360.0, 1.0) + 1.0, 1.0) * pow(2.0, zoom));
}

static inline int lat2tile(double lat, int zoom) {
    return fabs(lat) >= 85.05112877980659 ? -1 : (int)floor((1.0 - log(tan(lat * M_PI / 180.0) + 1.0 / cos(lat * M_PI / 180.0)) / M_PI) / 2.0 * pow(2.0, zoom));
}

// ----------------------------------------------------------------------------------------------------------------------------------------------------------------

static inline uint32_t cg_read_bits2(const uint8_t *s, uint32_t *boff, int n) {
    const uint32_t v = cg_read_bits(s, *boff, n);
    *boff += (uint32_t)n;
    return v;
}

static inline int cgrd_next(uint32_t *off) {
    const uint32_t v = cg_read_bits2(_cgrd, off, 3);
    return v == 7 ? (int)cg_read_bits2(_cgrd, off, 9) : (int)v;
}

static inline int cgrd_len(uint32_t row_boff) {
    return (int)cg_read_bits(_cgrd, row_boff, 10);
}

static inline int cgrd_at(uint32_t row_boff, int pos) {
    uint32_t off = row_boff + 10;
    int v = 0;
    for (int i = 0; i <= pos; i++)
        v = cgrd_next(&off);
    return v;
}

static inline int cgr_next(uint32_t *off) {
    const uint32_t c = cg_read_bits2(_cgrb, off, 4);
    return c < 15 ? (int)_cgr_lut[c] : (int)cg_read_bits2(_cgrb, off, 13);
}

static inline int cgr_at(uint32_t seq_boff, int pos) {
    uint32_t off = seq_boff;
    int v = 0;
    for (int i = 0; i <= pos; i++)
        v = cgr_next(&off);
    return v;
}

// ----------------------------------------------------------------------------------------------------------------------------------------------------------------

static const struct cg_attr *find_attr(int attrs_off, int count, int key) {
    for (int i = 0; i < count; i++) {
        const struct cg_attr *a = &_cga[attrs_off + i];
        if ((int)a->key == key)
            return a;
        if ((int)a->key > key)
            break;
    }
    return NULL;
}

static const char *attr_code(const struct cg_attr *a) {
    return CGB(a->code_off);
}

static const char *attr_subcode(const struct cg_attr *a) {
    return a->subcode_off >= 0 ? CGB(a->subcode_off) : NULL;
}

// ----------------------------------------------------------------------------------------------------------------------------------------------------------------

static const struct cg_ztile *find_ztile(const struct cg_ztile *table, int count, int tx, int ty) {
    const uint32_t needle = ((uint32_t)tx << 16) | (uint32_t)ty;
    int lo = 0, hi = count - 1;
    while (lo <= hi) {
        const int mid = (lo + hi) >> 1;
        const uint32_t key = ((uint32_t)table[mid].tx << 16) | (uint32_t)table[mid].ty;
        if (key == needle)
            return &table[mid];
        if (key < needle)
            lo = mid + 1;
        else
            hi = mid - 1;
    }
    return NULL;
}

// ----------------------------------------------------------------------------------------------------------------------------------------------------------------

static int grid_lookup_world(double lat, double lng, int fb_attrs_off, int fb_attrs_count, char *out, size_t outlen) {
    const int size = cg_world.size;
    if (size <= 0)
        return -1;

    const int ez = (int)round(log2((double)size));
    const int gx = lon2tile(lng, ez);
    const int gy = lat2tile(lat, ez);
    if (gx < 0 || gy < 0 || gx >= size || gy >= size)
        return -1;

    const int ri = cgr_at(cg_world.ri_off, gy);
    const uint32_t row_boff = _cgro[ri];
    const int row_len = cgrd_len(row_boff);

    int idx = 0;
    if (row_len == size)
        idx = cgrd_at(row_boff, gx);
    else if (row_len == 1)
        idx = cgrd_at(row_boff, 0);
    else
        for (uint32_t off = row_boff + 10, p = 0, x0 = (uint32_t)gx; p < (unsigned)row_len - 1; p += 2) {
            int val = cgrd_next(&off);
            int cnt = cgrd_next(&off);
            x0 -= (uint32_t)cnt;
            if ((int)x0 < 0) {
                idx = val;
                break;
            }
        }

    if (idx < 0 || idx >= cg_world.num_keys)
        return -1;
    const int key = _cgk[(int)cg_world.keys_off + idx];
    if (key < 0) {
        snprintf(out, outlen, "None");
        return 0;
    }

    const int a_off = cg_world.num_attrs > 0 ? cg_world.attrs_off : fb_attrs_off;
    const int a_count = cg_world.num_attrs > 0 ? cg_world.num_attrs : fb_attrs_count;
    const struct cg_attr *entry = find_attr(a_off, a_count, key);
    if (!entry)
        return -1;

    const char *code = attr_code(entry);
    if (!code || code[0] == '\0') {
        snprintf(out, outlen, "None");
        return 0;
    }

    const char *sub = attr_subcode(entry);
    snprintf(out, outlen, sub ? "%s:%s" : "%s", code, sub);

    return (strcmp(out, "*") == 0) ? 1 : 0;
}

static int grid_lookup_zoom(const struct cg_ztile *zt, int tx, int ty, int zoom, double lat, double lng, char *out, size_t outlen) {
    const struct cg_profile *p = &_cgp[zt->profile_id];
    const int size = p->size;

    const int ez = (int)round(log2((double)size)) + zoom;
    const int gx = lon2tile(lng, ez) - (tx << (ez - zoom));
    const int gy = lat2tile(lat, ez) - (ty << (ez - zoom));
    if (gx < 0 || gy < 0 || gx >= size || gy >= size)
        return -1;

    const int ri = cgr_at(zt->ri_off, gy);
    const uint32_t row_boff = _cgro[ri];
    const int row_len = cgrd_len(row_boff);

    int idx = 0;
    if (row_len == size)
        idx = cgrd_at(row_boff, gx);
    else if (row_len == 1)
        idx = cgrd_at(row_boff, 0);
    else {
        uint32_t off = row_boff + 10;
        for (int rp = 0, x0 = gx; rp < row_len - 1; rp += 2) {
            const int val = cgrd_next(&off);
            const int cnt = cgrd_next(&off);
            x0 -= cnt;
            if (x0 < 0) {
                idx = val;
                break;
            }
        }
    }

    if (idx < 0 || idx >= p->num_keys)
        return -1;
    const int key = _cgk[(int)p->keys_off + idx];
    if (key < 0) {
        snprintf(out, outlen, "None");
        return 0;
    }

    /* zoom tiles always use global attrs */
    const struct cg_attr *entry = find_attr(CG_GA_OFF, CG_GA_COUNT, key);
    if (!entry)
        return -1;

    const char *code = attr_code(entry);
    if (!code || code[0] == '\0') {
        snprintf(out, outlen, "None");
        return 0;
    }

    const char *sub = attr_subcode(entry);
    snprintf(out, outlen, sub ? "%s:%s" : "%s", code, sub);

    return (strcmp(out, "*") == 0) ? 1 : 0;
}

// ----------------------------------------------------------------------------------------------------------------------------------------------------------------

int codegrid_lookup(double lat, double lng, char *out, size_t outlen) {
    const int rc_grid = grid_lookup_world(lat, lng, CG_GA_OFF, CG_GA_COUNT, out, outlen);
    if (rc_grid <= 0)
        return rc_grid;
    for (int i = 0; i < ZLIST_LEN; i++) {
        const int zoom = ZLIST[i], tx = lon2tile(lng, zoom), ty = lat2tile(lat, zoom);
        const struct cg_ztile *zt = find_ztile(zoom_tables[i], zoom_counts[i], tx, ty);
        if (!zt)
            break;
        const int rc = grid_lookup_zoom(zt, tx, ty, zoom, lat, lng, out, outlen);
        if (rc <= 0)
            return rc;
    }
    return -1;
}

// ----------------------------------------------------------------------------------------------------------------------------------------------------------------

#ifdef TEST_MAIN
int main(void) {
    const struct {
        double lat, lng;
        const char *expect, *label;
    } tests[] = {
        { 51.5074, -0.1278, "gb", "London" },       { 48.8566, 2.3522, "fr", "Paris" },      { 52.5200, 13.4050, "de", "Berlin" },    { 40.4168, -3.7038, "es", "Madrid" },     { 41.9028, 12.4964, "it", "Rome" },
        { 38.7223, -9.1393, "pt", "Lisbon" },       { 59.3293, 18.0686, "se", "Stockholm" }, { 60.1699, 24.9384, "fi", "Helsinki" },  { 55.6761, 12.5683, "dk", "Copenhagen" }, { 52.2297, 21.0122, "pl", "Warsaw" },
        { 50.0755, 14.4378, "cz", "Prague" },       { 47.4979, 19.0402, "hu", "Budapest" },  { 44.4268, 26.1025, "ro", "Bucharest" }, { 37.9838, 23.7275, "gr", "Athens" },     { 39.9334, 32.8597, "tr", "Ankara" },
        { 55.7558, 37.6173, "ru", "Moscow" },       { 40.7128, -74.0060, "us", "New York" }, { 45.4215, -75.6972, "ca", "Ottawa" },   { -15.7975, -47.8919, "br", "Brasilia" }, { -34.6037, -58.3816, "ar", "Buenos Aires" },
        { 19.4326, -99.1332, "mx", "Mexico City" }, { 35.6762, 139.6503, "jp", "Tokyo" },    { 37.5665, 126.9780, "kr", "Seoul" },    { 39.9042, 116.4074, "cn", "Beijing" },   { 28.6139, 77.2090, "in", "New Delhi" },
        { -33.8688, 151.2093, "au", "Sydney" },     { 30.0444, 31.2357, "eg", "Cairo" },     { -1.2921, 36.8219, "ke", "Nairobi" },   { 1.3521, 103.8198, "sg", "Singapore" },  { 64.1466, -21.9426, "is", "Reykjavik" },
    };
    int numb = (int)(sizeof(tests) / sizeof(tests[0])), pass = 0;
    for (int i = 0; i < numb; i++) {
        char code[32];
        const int rc = codegrid_lookup(tests[i].lat, tests[i].lng, code, sizeof(code));
        const int ok = rc == 0 && strcmp(code, tests[i].expect) == 0;
        printf("[%s] %-14s (%8.4f,%9.4f) => %-8s (expect %s)\n", ok ? "OK" : "FAIL", tests[i].label, tests[i].lat, tests[i].lng, rc == 0 ? code : "ERROR", tests[i].expect);
        if (ok)
            pass++;
    }
    printf("\n%d total, %d passed, %d failed\n", numb, pass, numb - pass);
    return pass == numb ? EXIT_SUCCESS : EXIT_FAILURE;
}
#endif

// ----------------------------------------------------------------------------------------------------------------------------------------------------------------
