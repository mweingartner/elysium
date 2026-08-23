/*
 * gen-explog-goldens.c — Elysium-authored (not upstream fdlibm).
 *
 * Drives the netlib fdlibm 5.3/2004 __ieee754_exp/__ieee754_log/__ieee754_pow kernels
 * (compiled from upstream/e_exp.c, upstream/e_log.c, upstream/e_pow.c plus their support
 * files) over a fixed, deterministic probe set and emits goldens/fmath-explog-goldens.json
 * in the existing fmath hex-word format ("hi-lo" per Double, minified JSON, no trailing
 * newline) — see goldens/fmath-goldens.json for the precedent this format follows.
 *
 * Determinism: every probe input is either a hard-coded special/boundary bit pattern or
 * derived from the LCG x_{n+1} = 6364136223846793005*x_n + 1442695040888963407 (mod 2^64),
 * seeded with 0x5EED, per design.md Decision 14. No time(), no rand(), single-threaded,
 * fixed iteration order — running this binary twice produces byte-identical output.
 *
 * Magnitude bands are constructed directly from IEEE-754 bit patterns (a uniform sweep of
 * the double's biased exponent field) rather than by calling a transcendental library
 * function to synthesize "1e-300..1e300"-shaped inputs: this needs no <math.h> (avoiding any
 * declaration clash with fdlibm.h's own extern math prototypes) and gives at least as wide a
 * magnitude sweep as the decimal band the design describes (decimal 1e-300 fdlib300 correspond
 * to binary exponents of about -996 and +996; the biased-exponent bounds below cover that
 * span and then some).
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* fdlibm's public entry points for the three kernels we port. Declared here (in addition to
 * fdlibm.h, which every upstream .c file includes on its own) only so this translation unit
 * does not need to include fdlibm.h itself — that header pulls in a large surface of extern
 * declarations for functions we do not define (acos, tan, ...), and skipping it here avoids
 * having to shim __LITTLE_ENDIAN/__P for a file that has no use for __HI/__LO. The three
 * upstream .c files get the endianness shim via the compiler command line instead (see
 * gen-explog-goldens.sh) — never by editing them.
 */
extern double __ieee754_exp(double);
extern double __ieee754_log(double);
extern double __ieee754_pow(double, double);

/* ---------------------------------------------------------------------------------------
 * Bit-level helpers (no libm calls; plain arithmetic and memcpy only)
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

/* Format matching the existing goldens/fmath-goldens.json convention exactly: lowercase hex,
 * no leading zeros, high word and low word joined by one '-'.
 */
static void hexWord(double x, char *out, size_t n) {
    uint64_t bits = bitsOf(x);
    unsigned long long hi = (unsigned long long)(uint32_t)(bits >> 32);
    unsigned long long lo = (unsigned long long)(uint32_t)(bits & 0xffffffffULL);
    snprintf(out, n, "%llx-%llx", hi, lo);
}

/* ---------------------------------------------------------------------------------------
 * Deterministic LCG (Decision 14): x_{n+1} = 6364136223846793005*x_n + 1442695040888963407
 * --------------------------------------------------------------------------------------- */

static uint64_t lcgNext(uint64_t *state) {
    *state = (*state) * 6364136223846793005ULL + 1442695040888963407ULL;
    return *state;
}

/* Builds a Double with a sign and 52-bit mantissa drawn from the LCG stream, and a biased
 * exponent field drawn uniformly from [expLoBiased, expHiBiased] (both inclusive, each in
 * 0...2046 so the result is always finite). Two LCG draws per call.
 */
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

/* Clamp to +-limit (limit > 0), preserving sign, without calling any library function. */
static double clampMagnitude(double x, double limit) {
    if (x > limit) return limit;
    if (x < -limit) return -limit;
    return x;
}

/* ---------------------------------------------------------------------------------------
 * Output buffer: a growable array of heap-allocated "row" strings.
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

static void addExpLogRow(RowList *list, double x) {
    char xs[40], es[40], ls[40], row[140];
    double e = __ieee754_exp(x);
    double l = __ieee754_log(x);
    hexWord(x, xs, sizeof(xs));
    hexWord(e, es, sizeof(es));
    hexWord(l, ls, sizeof(ls));
    snprintf(row, sizeof(row), "%s:%s,%s", xs, es, ls);
    rowListPush(list, row);
}

static void addPowRow(RowList *list, double x, double y) {
    char xs[40], ys[40], ps[40], row[140];
    double p = __ieee754_pow(x, y);
    hexWord(x, xs, sizeof(xs));
    hexWord(y, ys, sizeof(ys));
    hexWord(p, ps, sizeof(ps));
    snprintf(row, sizeof(row), "%s,%s:%s", xs, ys, ps);
    rowListPush(list, row);
}

/* ---------------------------------------------------------------------------------------
 * Probe set construction
 * --------------------------------------------------------------------------------------- */

/* Biased-exponent bounds: 1023 is the bias for exponent 0 (|x| in [1,2)). Decimal 1e-300 is
 * about binary 2^-996.6; decimal 1e300 is about binary 2^996.6 — biased fields 26 and 2020
 * bracket that span with room to spare, while staying inside the finite range (1..2046;
 * 2047 is reserved for Inf/NaN).
 */
#define WIDE_EXP_LO 26
#define WIDE_EXP_HI 2020

/* |x| < 2^10 = 1024 keeps every draw well inside detExp's primary reduction range before the
 * explicit clamp to +-750 below.
 */
#define NEAR_EXP_LO 970
#define NEAR_EXP_HI 1033

static void buildExpLogSpecials(RowList *list) {
    static const uint64_t specialBits[] = {
        0x0000000000000000ULL, /* +0 */
        0x8000000000000000ULL, /* -0 */
        0x3ff0000000000000ULL, /* 1.0 */
        0xbff0000000000000ULL, /* -1.0 */
        0x4000000000000000ULL, /* 2.0 */
        0x3fe62e42fefa39efULL, /* ln2 */
        0xbfe62e42fefa39efULL, /* -ln2 */
        0x7ff0000000000000ULL, /* +inf */
        0xfff0000000000000ULL, /* -inf */
        0x7ff8000000000000ULL, /* quiet NaN, canonical */
        0xfff8000000000000ULL, /* quiet NaN, sign set */
        0x7ff0000000000001ULL, /* signaling-style NaN payload 1 */
        0x7ff4000000000001ULL, /* NaN with a different payload */
        0x0000000000000001ULL, /* smallest positive subnormal */
        0x8000000000000001ULL, /* smallest negative subnormal (magnitude) */
        0x000fffffffffffffULL, /* largest subnormal */
        0x0010000000000000ULL, /* smallest positive normal */
        0x7fefffffffffffffULL, /* greatest finite magnitude */
        0xffefffffffffffffULL, /* most negative finite */
        0x40862e42fefa39efULL, /* o_threshold: 709.78... */
        0xc0862e42fefa39efULL, /* -o_threshold */
        0x4086300000000000ULL, /* just above o_threshold */
        0xc0874910d52d3051ULL, /* u_threshold: -745.13... */
        0x40874910d52d3051ULL, /* +745.13... (positive mirror, no overflow) */
        0xc0875000000000f0ULL, /* just below u_threshold */
        0x408637f36c8f9d7bULL, /* 710.0 slightly above overflow */
        0xc08637f36c8f9d7bULL, /* -710.0 slightly below underflow */
    };
    for (size_t i = 0; i < sizeof(specialBits) / sizeof(specialBits[0]); i++) {
        addExpLogRow(list, doubleFromBits(specialBits[i]));
    }
}

static void buildExpLogWideBand(RowList *list, uint64_t *rng, int count) {
    for (int i = 0; i < count; i++) {
        double x = lcgDoubleInExpRange(rng, WIDE_EXP_LO, WIDE_EXP_HI);
        addExpLogRow(list, x);
    }
}

static void buildExpLogNearBand(RowList *list, uint64_t *rng, int count) {
    for (int i = 0; i < count; i++) {
        double x = lcgDoubleInExpRange(rng, NEAR_EXP_LO, NEAR_EXP_HI);
        x = clampMagnitude(x, 750.0);
        addExpLogRow(list, x);
    }
}

static void buildPowSpecials(RowList *list) {
    /* Each pair below exercises one of the nineteen documented special cases in
     * upstream/e_pow.c's header comment, with sign/parity variants.
     */
    static const double one = 1.0, two = 2.0, half = 0.5, three = 3.0;
    static const double negOne = -1.0, negTwo = -2.0, negThree = -3.0;
    double posInf = doubleFromBits(0x7ff0000000000000ULL);
    double negInf = doubleFromBits(0xfff0000000000000ULL);
    double nan1 = doubleFromBits(0x7ff8000000000000ULL);
    double posZero = doubleFromBits(0x0000000000000000ULL);
    double negZero = doubleFromBits(0x8000000000000000ULL);

    double xs[] = {7.5, -7.5, 0.25, -0.25, 2.0, -2.0, 100.0, -100.0, 1e-10, -1e-10};
    for (size_t i = 0; i < sizeof(xs) / sizeof(xs[0]); i++) {
        addPowRow(list, xs[i], posZero);          /* case 1: anything ** 0 == 1 */
        addPowRow(list, xs[i], negZero);          /* anything ** -0 == 1 */
        addPowRow(list, xs[i], one);               /* case 2: anything ** 1 == itself */
        addPowRow(list, xs[i], nan1);              /* case 3: anything ** NaN == NaN */
        addPowRow(list, xs[i], two);
        addPowRow(list, xs[i], half);
        addPowRow(list, xs[i], negOne);
        addPowRow(list, xs[i], negTwo);
        addPowRow(list, xs[i], three);
        addPowRow(list, xs[i], negThree);
    }
    addPowRow(list, nan1, xs[0]);                  /* case 4: NaN ** (anything != 0) */
    addPowRow(list, nan1, posZero);                /* NaN ** 0 == 1 */
    addPowRow(list, nan1, negZero);

    addPowRow(list, two, posInf);                  /* case 5: |x|>1 ** +inf == +inf */
    addPowRow(list, negTwo, posInf);
    addPowRow(list, two, negInf);                  /* case 6: |x|>1 ** -inf == +0 */
    addPowRow(list, negTwo, negInf);
    addPowRow(list, half, posInf);                 /* case 7: |x|<1 ** +inf == +0 */
    addPowRow(list, doubleFromBits(0xbfe0000000000000ULL), posInf);
    addPowRow(list, half, negInf);                  /* case 8: |x|<1 ** -inf == +inf */
    addPowRow(list, doubleFromBits(0xbfe0000000000000ULL), negInf);
    addPowRow(list, one, posInf);                   /* case 9: +-1 ** +-inf == NaN */
    addPowRow(list, one, negInf);
    addPowRow(list, negOne, posInf);
    addPowRow(list, negOne, negInf);

    addPowRow(list, posZero, 3.0);                  /* case 10: +0 ** pos == +0 */
    addPowRow(list, posZero, 4.0);
    addPowRow(list, negZero, 4.0);                  /* case 11: -0 ** pos even == +0 */
    addPowRow(list, negZero, 3.0);                  /* case 14: -0 ** odd int == -(+0**odd) */
    addPowRow(list, negZero, 2.5);                  /* -0 ** non-integer positive */
    addPowRow(list, posZero, -3.0);                 /* case 12: +0 ** neg == +inf */
    addPowRow(list, posZero, -4.0);
    addPowRow(list, negZero, -4.0);                 /* case 13: -0 ** neg even == +inf */
    addPowRow(list, negZero, -3.0);                 /* -0 ** neg odd int == -inf */
    addPowRow(list, negZero, -2.5);

    addPowRow(list, posInf, 3.0);                   /* case 15: +inf ** pos == +inf */
    addPowRow(list, posInf, -3.0);                   /* case 16: +inf ** neg == +0 */
    addPowRow(list, negInf, 3.0);                    /* case 17: -inf ** anything */
    addPowRow(list, negInf, 4.0);
    addPowRow(list, negInf, -3.0);
    addPowRow(list, negInf, -4.0);
    addPowRow(list, negInf, 2.5);

    addPowRow(list, negTwo, 2.5);                    /* case 19: (-x, non-int) == NaN */
    addPowRow(list, negTwo, -2.5);
    addPowRow(list, negOne, 0.5);
    addPowRow(list, negThree, 1.0 / 3.0);

    addPowRow(list, negTwo, 3.0);                    /* case 18: (-x)**int, odd/even */
    addPowRow(list, negTwo, 4.0);
    addPowRow(list, negTwo, -3.0);
    addPowRow(list, negTwo, -4.0);

    addPowRow(list, doubleFromBits(0x4000000000000000ULL), half); /* 2 ** 0.5 (sqrt fast path) */
    addPowRow(list, 9.0, half);
    addPowRow(list, negOne, negOne);                  /* -1 ** -1 (odd int) */
}

static void buildPowIntegerExponents(RowList *list, uint64_t *rng, int basesPerExponent) {
    static const double exponents[] = {
        -20.0, -15.0, -10.0, -5.0, -3.0, -2.0, -1.0, 0.0,
        1.0, 2.0, 3.0, 5.0, 10.0, 15.0, 20.0,
    };
    for (size_t e = 0; e < sizeof(exponents) / sizeof(exponents[0]); e++) {
        for (int i = 0; i < basesPerExponent; i++) {
            double x = lcgDoubleInExpRange(rng, 1000, 1046); /* roughly 1.2e-7 .. 8.4e6 magnitude */
            addPowRow(list, x, exponents[e]);
        }
    }
}

static void buildPowHalfIntegerExponents(RowList *list, uint64_t *rng, int basesPerExponent) {
    static const double exponents[] = {
        -9.5, -7.5, -5.5, -3.5, -1.5, 0.5, 1.5, 3.5, 5.5, 7.5, 9.5,
    };
    for (size_t e = 0; e < sizeof(exponents) / sizeof(exponents[0]); e++) {
        for (int i = 0; i < basesPerExponent; i++) {
            /* Mostly non-negative bases (half-integer powers of negative numbers are NaN
             * regardless of magnitude), with a minority of negative bases to cover that path.
             */
            double x = lcgDoubleInExpRange(rng, 1000, 1046);
            if (i % 4 == 3) x = -x;
            addPowRow(list, x, exponents[e]);
        }
    }
}

static void buildPowGeneralPairs(RowList *list, uint64_t *rng, int count) {
    for (int i = 0; i < count; i++) {
        double x = lcgDoubleInExpRange(rng, WIDE_EXP_LO, WIDE_EXP_HI);
        /* Keep |y|'s binary exponent below 21 (|y| < ~2^21) — comfortably inside the domain
         * where upstream/e_pow.c's own yisint parity computation is well-defined (its k>20
         * branch depends on a C shift-by-negative-amount that is undefined behaviour in the
         * original fdlibm source for larger |y|; this generator never asks the reference
         * build to resolve that undefined case, so the golden it produces never depends on
         * it either). detPow's own no-trap sweep (Tests/ElysiumCoreTests/DetMathExpLogPowTests
         * .swift) still exercises huge |y| such as +-1e308 — for non-trapping only, not for a
         * bit-exact match against this golden.
         */
        double y = lcgDoubleInExpRange(rng, 1023 - 30, 1023 + 20);
        addPowRow(list, x, y);
    }
}

/* ---------------------------------------------------------------------------------------
 * JSON output — single line, minified, matching goldens/fmath-goldens.json exactly.
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
    RowList expLog, pow;
    rowListInit(&expLog);
    rowListInit(&pow);

    uint64_t rng = 0x5EEDULL;

    buildExpLogSpecials(&expLog);
    buildExpLogWideBand(&expLog, &rng, 450);
    buildExpLogNearBand(&expLog, &rng, 450);

    buildPowSpecials(&pow);
    buildPowIntegerExponents(&pow, &rng, 20);
    buildPowHalfIntegerExponents(&pow, &rng, 10);
    buildPowGeneralPairs(&pow, &rng, 100);

    FILE *out = stdout;
    if (argc > 1) {
        out = fopen(argv[1], "wb");
        if (!out) { fprintf(stderr, "cannot open %s for writing\n", argv[1]); return 1; }
    }

    fprintf(out, "{");
    writeArray(out, "expLog", &expLog, 1);
    writeArray(out, "pow", &pow, 0);
    fprintf(out, "}");

    if (out != stdout) fclose(out);

    fprintf(stderr, "expLog probes: %zu\npow probes: %zu\ntotal: %zu\n",
            expLog.count, pow.count, expLog.count + pow.count);
    return 0;
}
