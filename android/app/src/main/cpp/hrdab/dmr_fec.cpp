#include "dmr_fec.h"

#include <cstring>

namespace hrdab::dmr {

namespace {

// Parity parts of the generator matrices [I | P] of annex B (tables B.11,
// B.12, B.14 - B.17), one row per information bit, MSB first.
const uint16_t kGolay2087[8] = {0x3DA, 0xD99, 0x6CD, 0x367, 0xDC6, 0xA97, 0x93E, 0x8EB};
const uint16_t kQr1676[7] = {0x04F, 0x11E, 0x1B7, 0x1E2, 0x1C9, 0x0E5, 0x073};
const uint16_t kHamming743[4] = {0x5, 0x7, 0x6, 0x3};
const uint16_t kHamming139[9] = {0xF, 0xE, 0x7, 0xA, 0x5, 0xB, 0xC, 0x6, 0x3};
const uint16_t kHamming1511[11] = {0x9, 0xD, 0xF, 0xE, 0x7, 0xA, 0x5, 0xB, 0xC, 0x6, 0x3};
const uint16_t kHamming16114[11] = {0x13, 0x1A, 0x1F, 0x1C, 0x0E, 0x15, 0x0B, 0x16, 0x19, 0x0D, 0x07};

int popcount(uint32_t v)
{
    int n = 0;
    for (; v; v &= v - 1) n++;
    return n;
}

uint32_t systematic(int data, int k, int p, const uint16_t* rows)
{
    uint32_t parity = 0;
    for (int i = 0; i < k; i++) {
        if ((data >> (k - 1 - i)) & 1) parity ^= rows[i];
    }
    return (static_cast<uint32_t>(data) << p) | parity;
}

// Nearest codeword of a short code (2^k candidates), within maxErrors.
int nearest(uint32_t word, int k, int p, const uint16_t* rows, int maxErrors, int* errors)
{
    int best = -1, bestDist = 99;
    for (int d = 0; d < (1 << k); d++) {
        const int dist = popcount(word ^ systematic(d, k, p, rows));
        if (dist < bestDist) {
            bestDist = dist;
            best = d;
        }
    }
    if (errors) *errors = bestDist;
    return bestDist <= maxErrors ? best : -1;
}

uint32_t hammingSyndrome(const uint8_t* w, int k, int p, const uint16_t* rows)
{
    uint32_t syn = 0;
    for (int i = 0; i < k; i++) {
        if (w[i]) syn ^= rows[i];
    }
    for (int j = 0; j < p; j++) syn ^= static_cast<uint32_t>(w[k + j] & 1) << (p - 1 - j);
    return syn;
}

// The bit a single error at would give `syn`, -1 if none.
int hammingErrorAt(uint32_t syn, int k, int p, const uint16_t* rows)
{
    for (int i = 0; i < k; i++) {
        if (rows[i] == syn) return i;
    }
    for (int j = 0; j < p; j++) {
        if (syn == 1u << (p - 1 - j)) return k + j;
    }
    return -1;
}

// Hamming code word w[0..k+p-1] (data, then parity): corrects a single bit
// error in place. 0 = was fine, 1 = corrected, -1 = uncorrectable.
int hammingFix(uint8_t* w, int k, int p, const uint16_t* rows)
{
    const uint32_t syn = hammingSyndrome(w, k, p, rows);
    if (!syn) return 0;
    const int at = hammingErrorAt(syn, k, p, rows);
    if (at < 0) return -1;
    w[at] ^= 1;
    return 1;
}

void hammingParity(uint8_t* w, int k, int p, const uint16_t* rows)
{
    uint32_t parity = 0;
    for (int i = 0; i < k; i++) {
        if (w[i]) parity ^= rows[i];
    }
    for (int j = 0; j < p; j++) w[k + j] = static_cast<uint8_t>((parity >> (p - 1 - j)) & 1);
}

// GF(2^8) with x^8 + x^4 + x^3 + x^2 + 1 (B.3.6).
struct Gf256 {
    uint8_t exp[512];
    uint8_t log[256];
    Gf256()
    {
        int x = 1;
        for (int i = 0; i < 255; i++) {
            exp[i] = static_cast<uint8_t>(x);
            log[x] = static_cast<uint8_t>(i);
            x <<= 1;
            if (x & 0x100) x ^= 0x11D;
        }
        for (int i = 255; i < 512; i++) exp[i] = exp[i - 255];
        log[0] = 0;
    }
    uint8_t mul(uint8_t a, uint8_t b) const { return a && b ? exp[log[a] + log[b]] : 0; }
};

const Gf256& gf()
{
    static const Gf256 g;
    return g;
}

} // namespace

uint32_t golay2087Encode(int data8)
{
    return systematic(data8 & 0xFF, 8, 12, kGolay2087);
}

int golay2087Decode(uint32_t word20, int* errors)
{
    return nearest(word20 & 0xFFFFF, 8, 12, kGolay2087, 3, errors);
}

uint32_t qr1676Encode(int data7)
{
    return systematic(data7 & 0x7F, 7, 9, kQr1676);
}

int qr1676Decode(uint32_t word16, int* errors)
{
    return nearest(word16 & 0xFFFF, 7, 9, kQr1676, 2, errors);
}

uint32_t hamming743Encode(int data4)
{
    return systematic(data4 & 0xF, 4, 3, kHamming743);
}

int hamming743Decode(uint32_t word7, int* errors)
{
    return nearest(word7 & 0x7F, 4, 3, kHamming743, 1, errors);
}

bool bptc19696Decode(const uint8_t* rx196, uint8_t* info96, int* corrected)
{
    // Encoder matrix: index j = 1 + 15 * row + column (index 0 is R(3)),
    // sent at position j * 181 mod 196 (B.1.1).
    uint8_t m[13][15];
    for (int j = 1; j < 196; j++) m[(j - 1) / 15][(j - 1) % 15] = rx196[(j * 181) % 196] & 1;
    auto rowSyn = [&](int r) { return hammingSyndrome(m[r], 11, 4, kHamming1511); };
    auto colSyn = [&](int c) {
        uint8_t col[13];
        for (int r = 0; r < 13; r++) col[r] = m[r][c];
        return hammingSyndrome(col, 9, 4, kHamming139);
    };
    // Rows (Hamming 15,11) and columns (13,9) in turn. A correction is
    // only made where the crossing code agrees that something is wrong:
    // two errors in a row (or column) point at a third, innocent bit,
    // which the other code sees as fine - left alone, the columns fix the
    // two instead. Rows go first: rows 9-12 (the column parity) have no
    // row code, so a column's correction there cannot be cross-checked.
    int fixes = 0;
    for (int pass = 0; pass < 4; pass++) {
        bool changed = false;
        for (int r = 0; r < 9; r++) {
            const uint32_t syn = rowSyn(r);
            if (!syn) continue;
            const int c = hammingErrorAt(syn, 11, 4, kHamming1511);
            if (c < 0 || !colSyn(c)) continue;
            m[r][c] ^= 1;
            fixes++;
            changed = true;
        }
        for (int c = 0; c < 15; c++) {
            const uint32_t syn = colSyn(c);
            if (!syn) continue;
            const int r = hammingErrorAt(syn, 9, 4, kHamming139);
            if (r < 0 || (r < 9 && !rowSyn(r))) continue;
            m[r][c] ^= 1;
            fixes++;
            changed = true;
        }
        if (!changed) break;
    }
    if (corrected) *corrected = fixes;
    // All rows valid; one column may still fail - errors among its parity
    // bits alone (rows 9-12), which no row can see.
    for (int r = 0; r < 9; r++) {
        if (rowSyn(r)) return false;
    }
    int badColumns = 0;
    for (int c = 0; c < 15; c++) badColumns += colSyn(c) != 0;
    if (badColumns > 1) return false;
    int n = 0;
    for (int c = 3; c < 11; c++) info96[n++] = m[0][c];
    for (int r = 1; r < 9; r++) {
        for (int c = 0; c < 11; c++) info96[n++] = m[r][c];
    }
    return true;
}

void bptc19696Encode(const uint8_t* info96, uint8_t* tx196)
{
    uint8_t m[13][15] = {};
    int n = 0;
    for (int c = 3; c < 11; c++) m[0][c] = info96[n++] & 1;
    for (int r = 1; r < 9; r++) {
        for (int c = 0; c < 11; c++) m[r][c] = info96[n++] & 1;
    }
    for (int r = 0; r < 9; r++) hammingParity(m[r], 11, 4, kHamming1511);
    for (int c = 0; c < 15; c++) {
        uint8_t col[13];
        for (int r = 0; r < 9; r++) col[r] = m[r][c];
        hammingParity(col, 9, 4, kHamming139);
        for (int r = 9; r < 13; r++) m[r][c] = col[r];
    }
    tx196[0] = 0;  // R(3)
    for (int j = 1; j < 196; j++) tx196[(j * 181) % 196] = m[(j - 1) / 15][(j - 1) % 15];
}

int lcChecksum(const uint8_t* lc9)
{
    int sum = 0;
    for (int i = 0; i < 9; i++) sum += lc9[i];
    return sum % 31;
}

namespace {

void lcBytes(const uint8_t* lc72, uint8_t* lc9)
{
    for (int i = 0; i < 9; i++) lc9[i] = static_cast<uint8_t>(bitsToInt(lc72 + 8 * i, 8));
}

// Figure B.3: rows 0 and 1 carry 11 LC bits, rows 2-6 ten plus one
// checksum bit (CS(4) .. CS(0)), then the Hamming (16,11,4) parity.
void embeddedRows(uint8_t e[8][16], const uint8_t* lc72, int cs)
{
    int n = 0;
    for (int r = 0; r < 7; r++) {
        const int lcBits = r < 2 ? 11 : 10;
        for (int c = 0; c < lcBits; c++) e[r][c] = lc72[n++] & 1;
        if (r >= 2) e[r][10] = static_cast<uint8_t>((cs >> (6 - r)) & 1);
    }
}

} // namespace

bool embeddedLcDecode(const uint8_t* rx128, uint8_t* lc72)
{
    // Sent column by column: bit k is row k % 8, column k / 8.
    uint8_t e[8][16];
    for (int k = 0; k < 128; k++) e[k % 8][k / 8] = rx128[k] & 1;
    for (int r = 0; r < 7; r++) {
        if (hammingFix(e[r], 11, 5, kHamming16114) < 0) return false;
    }
    // The parity row is not protected itself; the checksum decides.
    int n = 0, cs = 0;
    for (int r = 0; r < 7; r++) {
        const int lcBits = r < 2 ? 11 : 10;
        for (int c = 0; c < lcBits; c++) lc72[n++] = e[r][c];
        if (r >= 2) cs = (cs << 1) | e[r][10];
    }
    uint8_t lc9[9];
    lcBytes(lc72, lc9);
    return lcChecksum(lc9) == cs;
}

void embeddedLcEncode(const uint8_t* lc72, uint8_t* tx128)
{
    uint8_t lc9[9];
    lcBytes(lc72, lc9);
    uint8_t e[8][16] = {};
    embeddedRows(e, lc72, lcChecksum(lc9));
    for (int r = 0; r < 7; r++) hammingParity(e[r], 11, 5, kHamming16114);
    for (int c = 0; c < 16; c++) {
        uint8_t p = 0;
        for (int r = 0; r < 7; r++) p ^= e[r][c];
        e[7][c] = p;
    }
    for (int k = 0; k < 128; k++) tx128[k] = e[k % 8][k / 8];
}

void rs129Parity(const uint8_t* lc9, uint8_t* parity3)
{
    // g(x) = x^3 + 0x0E x^2 + 0x38 x + 0x40 (B.10); the first octet is
    // the highest power.
    const Gf256& g = gf();
    uint8_t r0 = 0, r1 = 0, r2 = 0;
    for (int i = 0; i < 9; i++) {
        const uint8_t fb = lc9[i] ^ r0;
        r0 = r1 ^ g.mul(fb, 0x0E);
        r1 = r2 ^ g.mul(fb, 0x38);
        r2 = g.mul(fb, 0x40);
    }
    parity3[0] = r0;
    parity3[1] = r1;
    parity3[2] = r2;
}

void ambeDeinterleave(const uint8_t* tx72, char fr[4][24])
{
    uint8_t v[72];
    for (int m = 0; m < 18; m++) {
        for (int c = 0; c < 4; c++) v[18 * c + m] = tx72[4 * m + c] & 1;
    }
    std::memset(fr, 0, 4 * 24);
    for (int i = 0; i < 24; i++) fr[0][23 - i] = static_cast<char>(v[i]);
    for (int i = 0; i < 23; i++) fr[1][22 - i] = static_cast<char>(v[24 + i]);
    for (int i = 0; i < 11; i++) fr[2][10 - i] = static_cast<char>(v[47 + i]);
    for (int i = 0; i < 14; i++) fr[3][13 - i] = static_cast<char>(v[58 + i]);
}

void ambeInterleave(const char fr[4][24], uint8_t* tx72)
{
    uint8_t v[72];
    for (int i = 0; i < 24; i++) v[i] = static_cast<uint8_t>(fr[0][23 - i] & 1);
    for (int i = 0; i < 23; i++) v[24 + i] = static_cast<uint8_t>(fr[1][22 - i] & 1);
    for (int i = 0; i < 11; i++) v[47 + i] = static_cast<uint8_t>(fr[2][10 - i] & 1);
    for (int i = 0; i < 14; i++) v[58 + i] = static_cast<uint8_t>(fr[3][13 - i] & 1);
    for (int m = 0; m < 18; m++) {
        for (int c = 0; c < 4; c++) tx72[4 * m + c] = v[18 * c + m];
    }
}

} // namespace hrdab::dmr
