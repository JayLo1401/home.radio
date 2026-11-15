// DMR coding blocks from the open standard ETSI TS 102 361-1 (annex B:
// FEC and CRC codes, annex E: transmit bit order): the small block codes
// of the burst fields, BPTC (196,96) of the data/control bursts, the
// embedded LC of the voice superframe and the Reed-Solomon (12,9) check of
// the full LC - each with its encoder, which the self test uses to build
// bursts. Plus the order of the 72 bits of an AMBE+2 voice frame as they
// go over the air, for the vocoder (mbelib).
//
// Bit vectors are uint8_t 0/1, the first transmitted (most significant)
// bit first.
#pragma once

#include <cstdint>

namespace hrdab::dmr {

// Golay (20,8): Slot Type (colour code << 4 | data type). Decoding corrects
// up to 3 bit errors; -1 if the word is further from every codeword.
uint32_t golay2087Encode(int data8);
int golay2087Decode(uint32_t word20, int* errors = nullptr);

// Quadratic residue (16,7,6): EMB (colour code << 3 | PI << 2 | LCSS).
// Corrects up to 2 bit errors.
uint32_t qr1676Encode(int data7);
int qr1676Decode(uint32_t word16, int* errors = nullptr);

// Hamming (7,4,3): CACH TACT (AT << 3 | TC << 2 | LCSS). Corrects 1.
uint32_t hamming743Encode(int data4);
int hamming743Decode(uint32_t word7, int* errors = nullptr);

// BPTC (196,96): the 196 info bits of a general data burst (transmit
// order) -> the 96 bits I(95)..I(0). False if a row or column still fails
// its Hamming check after the iterative correction.
bool bptc19696Decode(const uint8_t* rx196, uint8_t* info96, int* corrected = nullptr);
void bptc19696Encode(const uint8_t* info96, uint8_t* tx196);

// Embedded LC: the 4 x 32 embedded signalling bits of voice bursts B-E,
// in order -> the 72 LC bits. Checks the Hamming (16,11,4) rows (one error
// per row corrected), the column parity and the 5-bit checksum.
bool embeddedLcDecode(const uint8_t* rx128, uint8_t* lc72);
void embeddedLcEncode(const uint8_t* lc72, uint8_t* tx128);

// Reed-Solomon (12,9) parity of the 9 LC octets, before the CRC mask.
void rs129Parity(const uint8_t* lc9, uint8_t* parity3);

// Data Type CRC masks of the full LC's RS parity (table B.21).
constexpr uint32_t kMaskVoiceLcHeader = 0x969696;
constexpr uint32_t kMaskTerminatorLc = 0x999999;

// 5-bit checksum of the embedded full LC (B.3.11).
int lcChecksum(const uint8_t* lc9);

// An AMBE+2 voice frame: the 72 bits as transmitted <-> mbelib's
// ambe_fr[4][24] (C0: 24 bits [23..0], C1: 23, C2: 11, C3: 14, each with
// its most significant bit at the highest index). Over the air the four
// code words, MSB first and concatenated, are read out of an 18 x 4 block
// column by column: transmitted bit 4m + c is code bit 18c + m.
void ambeDeinterleave(const uint8_t* tx72, char fr[4][24]);
void ambeInterleave(const char fr[4][24], uint8_t* tx72);

// Bit helpers: `count` bits (MSB first) <-> integer.
inline uint32_t bitsToInt(const uint8_t* b, int count)
{
    uint32_t v = 0;
    for (int i = 0; i < count; i++) v = (v << 1) | (b[i] & 1u);
    return v;
}

inline void intToBits(uint32_t v, int count, uint8_t* b)
{
    for (int i = 0; i < count; i++) b[i] = static_cast<uint8_t>((v >> (count - 1 - i)) & 1u);
}

} // namespace hrdab::dmr
