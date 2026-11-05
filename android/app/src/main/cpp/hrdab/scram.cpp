#include "scram.h"

#include <algorithm>
#include <cstring>
#include <random>

namespace hrdab::scram {

namespace {

// --- SHA-256 (FIPS 180-4) ---

constexpr uint32_t kK[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

inline uint32_t rotr(uint32_t x, int n)
{
    return (x >> n) | (x << (32 - n));
}

class Sha256 {
public:
    void update(const uint8_t* data, size_t len)
    {
        total_ += len;
        while (len > 0) {
            const size_t take = std::min(len, sizeof(block_) - used_);
            std::memcpy(block_ + used_, data, take);
            used_ += take;
            data += take;
            len -= take;
            if (used_ == sizeof(block_)) {
                compress(block_);
                used_ = 0;
            }
        }
    }

    Bytes finish()
    {
        const uint64_t bits = total_ * 8;
        const uint8_t pad = 0x80;
        update(&pad, 1);
        const uint8_t zero = 0;
        while (used_ != 56) update(&zero, 1);
        uint8_t len[8];
        for (int i = 0; i < 8; i++) len[i] = static_cast<uint8_t>(bits >> (56 - 8 * i));
        update(len, 8);
        Bytes out(32);
        for (int i = 0; i < 8; i++) {
            out[4 * i] = static_cast<uint8_t>(h_[i] >> 24);
            out[4 * i + 1] = static_cast<uint8_t>(h_[i] >> 16);
            out[4 * i + 2] = static_cast<uint8_t>(h_[i] >> 8);
            out[4 * i + 3] = static_cast<uint8_t>(h_[i]);
        }
        return out;
    }

private:
    void compress(const uint8_t* p)
    {
        uint32_t w[64];
        for (int i = 0; i < 16; i++) {
            w[i] = (uint32_t(p[4 * i]) << 24) | (uint32_t(p[4 * i + 1]) << 16) | (uint32_t(p[4 * i + 2]) << 8) |
                   uint32_t(p[4 * i + 3]);
        }
        for (int i = 16; i < 64; i++) {
            const uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
            const uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16] + s0 + w[i - 7] + s1;
        }
        uint32_t a = h_[0], b = h_[1], c = h_[2], d = h_[3], e = h_[4], f = h_[5], g = h_[6], h = h_[7];
        for (int i = 0; i < 64; i++) {
            const uint32_t s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
            const uint32_t ch = (e & f) ^ (~e & g);
            const uint32_t t1 = h + s1 + ch + kK[i] + w[i];
            const uint32_t s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
            const uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
            const uint32_t t2 = s0 + maj;
            h = g;
            g = f;
            f = e;
            e = d + t1;
            d = c;
            c = b;
            b = a;
            a = t1 + t2;
        }
        h_[0] += a;
        h_[1] += b;
        h_[2] += c;
        h_[3] += d;
        h_[4] += e;
        h_[5] += f;
        h_[6] += g;
        h_[7] += h;
    }

    uint32_t h_[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    uint8_t block_[64] = {};
    size_t used_ = 0;
    uint64_t total_ = 0;
};

// HMAC with the key's inner/outer pads prepared once - PBKDF2 runs it
// 100 000 times with the same key.
class Hmac {
public:
    explicit Hmac(const Bytes& key)
    {
        uint8_t k[64] = {};
        if (key.size() > 64) {
            const Bytes hk = sha256(key.data(), key.size());
            std::memcpy(k, hk.data(), hk.size());
        } else if (!key.empty()) {
            std::memcpy(k, key.data(), key.size());
        }
        uint8_t ipad[64], opad[64];
        for (int i = 0; i < 64; i++) {
            ipad[i] = k[i] ^ 0x36;
            opad[i] = k[i] ^ 0x5c;
        }
        inner_.update(ipad, 64);
        outer_.update(opad, 64);
    }

    Bytes mac(const uint8_t* data, size_t len) const
    {
        Sha256 in = inner_;
        in.update(data, len);
        const Bytes ih = in.finish();
        Sha256 out = outer_;
        out.update(ih.data(), ih.size());
        return out.finish();
    }

private:
    Sha256 inner_;
    Sha256 outer_;
};

const char kB64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

Bytes xorBytes(const Bytes& a, const Bytes& b)
{
    Bytes out(a.size());
    for (size_t i = 0; i < a.size(); i++) out[i] = a[i] ^ b[i];
    return out;
}

// Constant-time compare (signature check).
bool equalBytes(const Bytes& a, const Bytes& b)
{
    if (a.size() != b.size()) return false;
    uint8_t diff = 0;
    for (size_t i = 0; i < a.size(); i++) diff |= a[i] ^ b[i];
    return diff == 0;
}

} // namespace

Bytes sha256(const uint8_t* data, size_t len)
{
    Sha256 s;
    s.update(data, len);
    return s.finish();
}

Bytes hmacSha256(const Bytes& key, const uint8_t* data, size_t len)
{
    return Hmac(key).mac(data, len);
}

Bytes pbkdf2Sha256(const std::string& password, const Bytes& salt, int iterations, size_t length)
{
    const Hmac prf(Bytes(password.begin(), password.end()));
    Bytes out;
    for (uint32_t block = 1; out.size() < length; block++) {
        Bytes s = salt;
        s.push_back(static_cast<uint8_t>(block >> 24));
        s.push_back(static_cast<uint8_t>(block >> 16));
        s.push_back(static_cast<uint8_t>(block >> 8));
        s.push_back(static_cast<uint8_t>(block));
        Bytes u = prf.mac(s.data(), s.size());
        Bytes t = u;
        for (int i = 1; i < iterations; i++) {
            u = prf.mac(u.data(), u.size());
            for (size_t j = 0; j < t.size(); j++) t[j] ^= u[j];
        }
        out.insert(out.end(), t.begin(), t.end());
    }
    out.resize(length);
    return out;
}

std::string base64Encode(const Bytes& data)
{
    std::string out;
    out.reserve((data.size() + 2) / 3 * 4);
    for (size_t i = 0; i < data.size(); i += 3) {
        const uint32_t n = (uint32_t(data[i]) << 16) | (i + 1 < data.size() ? uint32_t(data[i + 1]) << 8 : 0) |
                           (i + 2 < data.size() ? uint32_t(data[i + 2]) : 0);
        out += kB64[(n >> 18) & 63];
        out += kB64[(n >> 12) & 63];
        out += i + 1 < data.size() ? kB64[(n >> 6) & 63] : '=';
        out += i + 2 < data.size() ? kB64[n & 63] : '=';
    }
    return out;
}

bool base64Decode(const std::string& text, Bytes& out)
{
    out.clear();
    uint32_t acc = 0;
    int bits = 0;
    size_t pad = 0;
    for (const char c : text) {
        if (c == '=') {
            pad++;
            continue;
        }
        if (pad) return false; // data after padding
        const char* p = std::strchr(kB64, c);
        if (!p || c == '\0') return false;
        acc = (acc << 6) | static_cast<uint32_t>(p - kB64);
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out.push_back(static_cast<uint8_t>(acc >> bits));
        }
    }
    return pad <= 2;
}

Bytes randomBytes(size_t n)
{
    std::random_device rd;
    Bytes out(n);
    for (size_t i = 0; i < n; i += 4) {
        const uint32_t r = rd();
        for (size_t j = 0; j < 4 && i + j < n; j++) out[i + j] = static_cast<uint8_t>(r >> (8 * j));
    }
    return out;
}

Client::Client(std::string user, std::string password)
    : user_(std::move(user)), password_(std::move(password)), cnonce_(base64Encode(randomBytes(18)))
{
}

std::string Client::proof(const std::string& nonce, const std::string& salt, int iterations)
{
    Bytes nonceBytes, cnonceBytes, saltBytes;
    if (!base64Decode(nonce, nonceBytes) || !base64Decode(cnonce_, cnonceBytes) || !base64Decode(salt, saltBytes))
        return {};
    // The server's nonce must extend ours (replay protection).
    if (nonceBytes.size() <= cnonceBytes.size() ||
        std::memcmp(nonceBytes.data(), cnonceBytes.data(), cnonceBytes.size()) != 0)
        return {};
    if (iterations < 1 || iterations > 10000000) return {};
    saltedPassword_ = pbkdf2Sha256(password_, saltBytes, iterations);
    const Bytes clientKey = hmacSha256(saltedPassword_, "Client Key");
    const Bytes storedKey = sha256(clientKey.data(), clientKey.size());
    authMessage_ = user_ + "," + cnonce_ + "," + nonce + "," + salt + "," + std::to_string(iterations);
    return base64Encode(xorBytes(clientKey, hmacSha256(storedKey, authMessage_)));
}

bool Client::verifyServer(const std::string& signature) const
{
    Bytes sig;
    if (saltedPassword_.empty() || !base64Decode(signature, sig)) return false;
    const Bytes serverKey = hmacSha256(saltedPassword_, "Server Key");
    return equalBytes(sig, hmacSha256(serverKey, authMessage_));
}

bool selfTest()
{
    // RFC 7677 §3 (same math, different AuthMessage string).
    Bytes salt;
    if (!base64Decode("W22ZaJ0SNY7soEsUEjb6gQ==", salt)) return false;
    const Bytes salted = pbkdf2Sha256("pencil", salt, 4096);
    const std::string auth =
        "n=user,r=rOprNGfwEbeRWgbNEkqO,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,"
        "s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096,c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0";
    const Bytes clientKey = hmacSha256(salted, "Client Key");
    const Bytes storedKey = sha256(clientKey.data(), clientKey.size());
    const std::string proof = base64Encode(xorBytes(clientKey, hmacSha256(storedKey, auth)));
    const std::string sig = base64Encode(hmacSha256(hmacSha256(salted, "Server Key"), auth));
    return proof == "dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=" &&
           sig == "6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=";
}

} // namespace hrdab::scram
