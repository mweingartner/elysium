/*
 * gen-trig-goldens.c — Elysium-authored (not upstream fdlibm).
 *
 * Drives the netlib fdlibm 5.3/2004 tan/asin/acos/log10 kernels (compiled from
 * upstream/s_tan.c, upstream/k_tan.c, upstream/e_rem_pio2.c, upstream/k_rem_pio2.c,
 * upstream/e_asin.c, upstream/e_acos.c, upstream/e_log10.c plus their support files) over a
 * fixed, deterministic probe set and emits goldens/fmath-trig-goldens.json in the existing
 * fmath hex-word format ("hi-lo" per Double, minified JSON, no trailing newline) — see
 * gen-explog-goldens.c for the precedent this generator follows line-for-line.
 *
 * log2 has no netlib upstream (classic fdlibm never shipped an e_log2.c — verified 2026-08-23:
 * https://www.netlib.org/fdlibm/e_log2.c returns HTTP 404 while every file this generator
 * needs returned 200 from the same host). `elysium_log2` below is this programme's own
 * derivation, documented in full on `detLog2` in Sources/ElysiumCore/Core/DetMath.swift: the
 * same reduction detLog already uses (ported from upstream/e_log.c), recombined in
 * extra-precision hi/lo form the way netlib's own e_log10.c recombines log10 from log, with
 * log2(2)==1 exactly taking the place of log10's irrational log10(2). It calls the pinned
 * `__ieee754_log` — nothing in this function is invented independently of upstream fdlibm
 * except the recombination arithmetic, which is elementary and documented inline.
 *
 * Determinism: every probe input is either a hard-coded special/boundary bit pattern or
 * derived from the LCG x_{n+1} = 6364136223846793005*x_n + 1442695040888963407 (mod 2^64),
 * seeded with 0x5EED (same seed and recurrence as gen-explog-goldens.c, run independently so
 * this generator's stream is entirely its own — probes here do not need to line up with that
 * file's probes). No time(), no rand(), single-threaded, fixed iteration order — running this
 * binary twice produces byte-identical output.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern double tan(double);
extern double __ieee754_asin(double);
extern double __ieee754_acos(double);
extern double __ieee754_log(double);
extern double __ieee754_log10(double);

/* ---------------------------------------------------------------------------------------
 * Bit-level helpers (no libm calls beyond the externs above; plain arithmetic and memcpy)
 * --------------------------------------------------------------------------------------- */

static uint64_t bitsOf(double x) {
    uint64_t bits;
    memcpy(&bits, &x, sizeof(bits));
    return bits;
}

static double doubleFromBits(uint64_t bits) {
    double x;
    memcpy(&x, &bits, sizeof(x));
    return x;
}

static void hexWord(double x, char *out, size_t n) {
    uint64_t bits = bitsOf(x);
    unsigned long long hi = (unsigned long long)(uint32_t)(bits >> 32);
    unsigned long long lo = (unsigned long long)(uint32_t)(bits & 0xffffffffULL);
    snprintf(out, n, "%llx-%llx", hi, lo);
}

/*
 * elysium_log2(x) — see the file header and DetMath.swift's `detLog2` doc comment for the
 * full provenance decision. Structurally this is upstream/e_log10.c's own reduction
 * (`hx`/`lx` extraction, subnormal scale-up, exponent split into `k`+`i`, __HI rewrite,
 * call into __ieee754_log on the reduced mantissa) with log10's {ivln10, log10_2hi,
 * log10_2lo} swapped for log2's {ivln2, 1.0, 0.0} — log2(2) is exactly 1, so unlike log10(2)
 * there is no "lo" correction term to carry.
 */
static double elysium_log2(double x) {
    double y;
    int32_t k, i;
    uint64_t bits = bitsOf(x);
    int32_t hx = (int32_t)(uint32_t)(bits >> 32);
    uint32_t lx = (uint32_t)(bits & 0xffffffffULL);

    k = 0;
    if (hx < 0x00100000) {                     /* x < 2**-1022 */
        if (((hx & 0x7fffffff) | (int32_t)lx) == 0) {
            return doubleFromBits(0xfff0000000000000ULL);  /* log2(+-0) = -inf */
        }
        if (hx < 0) {
            return doubleFromBits(0x7ff8000000000000ULL);  /* log2(-#) = NaN */
        }
        k -= 54;
        x *= 1.80143985094819840000e+16;        /* two54: subnormal number, scale up x */
        bits = bitsOf(x);
        hx = (int32_t)(uint32_t)(bits >> 32);
    }
    if (hx >= 0x7ff00000) return x + x;          /* +inf stays +inf; NaN stays NaN */
    k += (hx >> 20) - 1023;
    i = (k < 0) ? 1 : 0;
    hx = (hx & 0x000fffff) | ((0x3ff - i) << 20);
    y = (double)(k + i);
    {
        uint64_t newBits = ((uint64_t)(uint32_t)hx << 32) | (bitsOf(x) & 0xffffffffULL);
        x = doubleFromBits(newBits);
    }
    {
        /* ivln2 = 1/ln2, log2 hi/lo = {1.0, 0.0} (log2(2) is exact) */
        double z = 0.0 * y + 1.44269504088896338700e+00 * __ieee754_log(x);
        return z + y * 1.0;
    }
}

/* ---------------------------------------------------------------------------------------
 * Deterministic LCG (same recurrence as gen-explog-goldens.c, independent stream/seed use)
 * --------------------------------------------------------------------------------------- */

static uint64_t lcgNext(uint64_t *state) {
    *state = (*state) * 6364136223846793005ULL + 1442695040888963407ULL;
    return *state;
}

static double lcgDoubleInExpRange(uint64_t *state, int expLoBiased, int expHiBiased) {
    uint64_t s1 = lcgNext(state);
    uint64_t s2 = lcgNext(state);
    uint64_t sign = (s1 >> 63) & 1ULL;
    uint64_t span = (uint64_t)(expHiBiased - expLoBiased + 1);
    uint64_t biased = (uint64_t)expLoBiased + ((s1 >> 20) % span);
    uint64_t mantissa = s2 & 0xfffffffffffffULL;
    uint64_t bits = (sign << 63) | (biased << 52) | mantissa;
    return doubleFromBits(bits);
}

/* ---------------------------------------------------------------------------------------
 * Output buffer: a growable array of heap-allocated "row" strings (same as gen-explog-goldens.c)
 * --------------------------------------------------------------------------------------- */

typedef struct {
    char **rows;
    size_t count;
    size_t capacity;
} RowList;

static void rowListInit(RowList *list) {
    list->rows = NULL;
    list->count = 0;
    list->capacity = 0;
}

static void rowListPush(RowList *list, const char *row) {
    if (list->count == list->capacity) {
        size_t newCapacity = list->capacity == 0 ? 64 : list->capacity * 2;
        char **grown = (char **)realloc(list->rows, newCapacity * sizeof(char *));
        if (!grown) { fprintf(stderr, "out of memory\n"); exit(1); }
        list->rows = grown;
        list->capacity = newCapacity;
    }
    size_t len = strlen(row);
    char *copy = (char *)malloc(len + 1);
    if (!copy) { fprintf(stderr, "out of memory\n"); exit(1); }
    memcpy(copy, row, len + 1);
    list->rows[list->count++] = copy;
}

static void addTanRow(RowList *list, double x) {
    char xs[40], ts[40], row[90];
    double t = tan(x);
    hexWord(x, xs, sizeof(xs));
    hexWord(t, ts, sizeof(ts));
    snprintf(row, sizeof(row), "%s:%s", xs, ts);
    rowListPush(list, row);
}

static void addAsinAcosRow(RowList *list, double x) {
    char xs[40], as[40], cs[40], row[130];
    double a = __ieee754_asin(x);
    double c = __ieee754_acos(x);
    hexWord(x, xs, sizeof(xs));
    hexWord(a, as, sizeof(as));
    hexWord(c, cs, sizeof(cs));
    snprintf(row, sizeof(row), "%s:%s,%s", xs, as, cs);
    rowListPush(list, row);
}

static void addLog2Log10Row(RowList *list, double x) {
    char xs[40], l2s[40], l10s[40], row[130];
    double l2 = elysium_log2(x);
    double l10 = __ieee754_log10(x);
    hexWord(x, xs, sizeof(xs));
    hexWord(l2, l2s, sizeof(l2s));
    hexWord(l10, l10s, sizeof(l10s));
    snprintf(row, sizeof(row), "%s:%s,%s", xs, l2s, l10s);
    rowListPush(list, row);
}

/* ---------------------------------------------------------------------------------------
 * Probe set construction
 * --------------------------------------------------------------------------------------- */

/* Biased-exponent bounds (1023 = bias for exponent 0, |x| in [1,2)). */
#define TAN_DENSE_LO 990          /* ~roughly |x| in [9.3e-5, 33.5] */
#define TAN_DENSE_HI 1028
#define TAN_HUGE_LO 1044          /* strictly above ix>0x413921fb: full rem_pio2 guaranteed */
#define TAN_HUGE_HI 2020
#define TAN_SUBNORMAL_LO 1        /* subnormal..very small normal */
#define TAN_SUBNORMAL_HI 200

#define UNIT_DENSE_LO 900         /* |x| < 1, dense across the whole [0,1) magnitude range */
#define UNIT_DENSE_HI 1022
#define UNIT_SUBNORMAL_LO 1
#define UNIT_SUBNORMAL_HI 200
#define OUT_OF_DOMAIN_LO 1023     /* |x| >= 1: exercises the |x|>1 NaN path (except |x|==1) */
#define OUT_OF_DOMAIN_HI 1200

#define WIDE_LO 26                /* matches gen-explog-goldens.c's WIDE_EXP band */
#define WIDE_HI 2020
#define LOG_SUBNORMAL_LO 1
#define LOG_SUBNORMAL_HI 100

static void buildTanSpecials(RowList *list) {
    static const uint64_t specialBits[] = {
        0x0000000000000000ULL, /* +0 */
        0x8000000000000000ULL, /* -0 */
        0x3ff0000000000000ULL, /* 1.0 */
        0xbff0000000000000ULL, /* -1.0 */
        0x3fe921fb54442d18ULL, /* pi/4: exact quick-path boundary (ix<=0x3fe921fb) */
        0x3fe921fb54442d19ULL, /* just above pi/4 */
        0x4002d97c00000000ULL, /* exactly at the 3pi/4 boundary (ix==0x4002d97c): falls into
                                 * the general medium-range branch, not the n=+-1 special case,
                                 * since that branch tests strict ix<0x4002d97c */
        0x400921fb54442d18ULL, /* pi */
        0xc00921fb54442d18ULL, /* -pi */
        0x401921fb54442d18ULL, /* 2*pi */
        0x3ff921fb54442d18ULL, /* pi/2: the tangent near-singularity */
        0xbff921fb54442d18ULL, /* -pi/2 */
        0x413921fb54442d18ULL, /* just at/below the medium/huge rem_pio2 boundary */
        0x413921fc00000000ULL, /* just above it: forces the huge (Payne-Hanek) branch */
        0x7ff0000000000000ULL, /* +inf */
        0xfff0000000000000ULL, /* -inf */
        0x7ff8000000000000ULL, /* quiet NaN */
        0xfff8000000000000ULL, /* quiet NaN, sign set */
        0x7ff0000000000001ULL, /* NaN payload variant */
        0x0000000000000001ULL, /* smallest positive subnormal */
        0x8000000000000001ULL, /* smallest negative subnormal (magnitude) */
        0x7fefffffffffffffULL, /* greatest finite magnitude */
        0xffefffffffffffffULL, /* most negative finite */
    };
    for (size_t i = 0; i < sizeof(specialBits) / sizeof(specialBits[0]); i++) {
        addTanRow(list, doubleFromBits(specialBits[i]));
    }
}

static void buildTanDense(RowList *list, uint64_t *rng, int count) {
    for (int i = 0; i < count; i++) {
        addTanRow(list, lcgDoubleInExpRange(rng, TAN_DENSE_LO, TAN_DENSE_HI));
    }
}

static void buildTanHuge(RowList *list, uint64_t *rng, int count) {
    for (int i = 0; i < count; i++) {
        addTanRow(list, lcgDoubleInExpRange(rng, TAN_HUGE_LO, TAN_HUGE_HI));
    }
}

static void buildTanSubnormal(RowList *list, uint64_t *rng, int count) {
    for (int i = 0; i < count; i++) {
        addTanRow(list, lcgDoubleInExpRange(rng, TAN_SUBNORMAL_LO, TAN_SUBNORMAL_HI));
    }
}

static void buildAsinAcosSpecials(RowList *list) {
    static const uint64_t specialBits[] = {
        0x0000000000000000ULL, /* +0 */
        0x8000000000000000ULL, /* -0 */
        0x3ff0000000000000ULL, /* 1.0 */
        0xbff0000000000000ULL, /* -1.0 */
        0x3fe0000000000000ULL, /* 0.5: internal branch boundary */
        0x3fef333333333333ULL, /* just below the 0.975 branch boundary (ix>=0x3FEF3333) */
        0x3fef333333333334ULL, /* just above it */
        0x3e3fffffffffffffULL, /* just below |x|<2**-27 boundary */
        0x3e40000000000000ULL, /* exactly the |x|<2**-27 boundary */
        0x3c5fffffffffffffULL, /* just below acos's |x|<=2**-57 boundary */
        0x3c60000000000000ULL, /* exactly acos's |x|<=2**-57 boundary */
        0x3ff0000000000001ULL, /* just above 1.0: out of domain, NaN */
        0xbff0000000000001ULL, /* just below -1.0: out of domain, NaN */
        0x4000000000000000ULL, /* 2.0: out of domain, NaN */
        0xc000000000000000ULL, /* -2.0: out of domain, NaN */
        0x7ff0000000000000ULL, /* +inf: out of domain, NaN */
        0xfff0000000000000ULL, /* -inf: out of domain, NaN */
        0x7ff8000000000000ULL, /* quiet NaN */
        0xfff8000000000000ULL, /* quiet NaN, sign set */
        0x0000000000000001ULL, /* smallest positive subnormal */
        0x8000000000000001ULL, /* smallest negative subnormal (magnitude) */
    };
    for (size_t i = 0; i < sizeof(specialBits) / sizeof(specialBits[0]); i++) {
        addAsinAcosRow(list, doubleFromBits(specialBits[i]));
    }
}

static void buildAsinAcosDense(RowList *list, uint64_t *rng, int count) {
    for (int i = 0; i < count; i++) {
        addAsinAcosRow(list, lcgDoubleInExpRange(rng, UNIT_DENSE_LO, UNIT_DENSE_HI));
    }
}

static void buildAsinAcosSubnormal(RowList *list, uint64_t *rng, int count) {
    for (int i = 0; i < count; i++) {
        addAsinAcosRow(list, lcgDoubleInExpRange(rng, UNIT_SUBNORMAL_LO, UNIT_SUBNORMAL_HI));
    }
}

static void buildAsinAcosOutOfDomain(RowList *list, uint64_t *rng, int count) {
    for (int i = 0; i < count; i++) {
        addAsinAcosRow(list, lcgDoubleInExpRange(rng, OUT_OF_DOMAIN_LO, OUT_OF_DOMAIN_HI));
    }
}

static void buildLogSpecials(RowList *list) {
    static const uint64_t specialBits[] = {
        0x0000000000000000ULL, /* +0 */
        0x8000000000000000ULL, /* -0 */
        0xbff0000000000000ULL, /* -1.0: negative, NaN */
        0xc000000000000000ULL, /* -2.0: negative, NaN */
        0x7ff0000000000000ULL, /* +inf */
        0xfff0000000000000ULL, /* -inf */
        0x7ff8000000000000ULL, /* quiet NaN */
        0xfff8000000000000ULL, /* quiet NaN, sign set */
        0x3ff0000000000000ULL, /* 1.0 */
        0x4000000000000000ULL, /* 2.0 */
        0x4024000000000000ULL, /* 10.0 */
        0x4059000000000000ULL, /* 100.0 */
        0x408f400000000000ULL, /* 1000.0 */
        0x0000000000000001ULL, /* smallest positive subnormal */
        0x000fffffffffffffULL, /* largest subnormal */
        0x0010000000000000ULL, /* smallest positive normal */
        0x7fefffffffffffffULL, /* greatest finite magnitude */
    };
    for (size_t i = 0; i < sizeof(specialBits) / sizeof(specialBits[0]); i++) {
        addLog2Log10Row(list, doubleFromBits(specialBits[i]));
    }
}

static void buildLogDense(RowList *list, uint64_t *rng, int count) {
    for (int i = 0; i < count; i++) {
        double x = lcgDoubleInExpRange(rng, WIDE_LO, WIDE_HI);
        if (x < 0) x = -x;
        addLog2Log10Row(list, x);
    }
}

static void buildLogSubnormal(RowList *list, uint64_t *rng, int count) {
    for (int i = 0; i < count; i++) {
        double x = lcgDoubleInExpRange(rng, LOG_SUBNORMAL_LO, LOG_SUBNORMAL_HI);
        if (x < 0) x = -x;
        addLog2Log10Row(list, x);
    }
}

/* Exact powers of two, spanning the whole subnormal+normal double range — the "powers of 2"
 * probe band the task calls for, direct evidence of detLog2(2**n)==n.
 */
static void buildLogPowersOfTwo(RowList *list) {
    for (int e = -1074; e <= 1023; e += 7) {
        double x;
        if (e < -1022) {
            x = doubleFromBits(1ULL << (uint64_t)(e + 1074));   /* subnormal power of two */
        } else {
            x = doubleFromBits((uint64_t)(e + 1023) << 52);      /* normal power of two */
        }
        addLog2Log10Row(list, x);
    }
}

/* Exact powers of ten (as far as a double can represent one), direct evidence of
 * detLog10(10**n)==n for small n and of correct behaviour generally beyond that.
 */
static void buildLogPowersOfTen(RowList *list) {
    double x = 1.0;
    for (int p = 0; p <= 22; p++) {
        addLog2Log10Row(list, x);
        x *= 10.0;
    }
}

/* ---------------------------------------------------------------------------------------
 * JSON output — single line, minified, matching goldens/fmath-explog-goldens.json exactly.
 * --------------------------------------------------------------------------------------- */

static void writeArray(FILE *f, const char *key, RowList *list, int isFirst) {
    if (!isFirst) fprintf(f, ",");
    fprintf(f, "\"%s\":[", key);
    for (size_t i = 0; i < list->count; i++) {
        if (i > 0) fprintf(f, ",");
        fprintf(f, "\"%s\"", list->rows[i]);
    }
    fprintf(f, "]");
}

int main(int argc, char **argv) {
    RowList tanList, asinAcos, log2Log10;
    rowListInit(&tanList);
    rowListInit(&asinAcos);
    rowListInit(&log2Log10);

    uint64_t rng = 0x5EEDULL;

    buildTanSpecials(&tanList);
    buildTanDense(&tanList, &rng, 500);
    buildTanHuge(&tanList, &rng, 350);
    buildTanSubnormal(&tanList, &rng, 100);

    buildAsinAcosSpecials(&asinAcos);
    buildAsinAcosDense(&asinAcos, &rng, 600);
    buildAsinAcosSubnormal(&asinAcos, &rng, 150);
    buildAsinAcosOutOfDomain(&asinAcos, &rng, 150);

    buildLogSpecials(&log2Log10);
    buildLogDense(&log2Log10, &rng, 400);
    buildLogSubnormal(&log2Log10, &rng, 100);
    buildLogPowersOfTwo(&log2Log10);
    buildLogPowersOfTen(&log2Log10);

    FILE *out = stdout;
    if (argc > 1) {
        out = fopen(argv[1], "wb");
        if (!out) { fprintf(stderr, "cannot open %s for writing\n", argv[1]); return 1; }
    }

    fprintf(out, "{");
    writeArray(out, "tan", &tanList, 1);
    writeArray(out, "asinAcos", &asinAcos, 0);
    writeArray(out, "log2Log10", &log2Log10, 0);
    fprintf(out, "}");

    if (out != stdout) fclose(out);

    fprintf(stderr, "tan probes: %zu\nasinAcos probes: %zu\nlog2Log10 probes: %zu\ntotal: %zu\n",
            tanList.count, asinAcos.count, log2Log10.count,
            tanList.count + asinAcos.count + log2Log10.count);
    return 0;
}
