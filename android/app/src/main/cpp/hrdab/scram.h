// SCRAM-SHA-256 client for rtltcp_v2's login (docs: rtltcp.server
// docs/protocol-v2.md §4.2) plus the primitives it needs - self-contained so
// Android needs no crypto library in native code.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace hrdab::scram {

using Bytes = std::vector<uint8_t>;

Bytes sha256(const uint8_t* data, size_t len);
Bytes hmacSha256(const Bytes& key, const uint8_t* data, size_t len);
inline Bytes hmacSha256(const Bytes& key, const std::string& data)
{
    return hmacSha256(key, reinterpret_cast<const uint8_t*>(data.data()), data.size());
}
Bytes pbkdf2Sha256(const std::string& password, const Bytes& salt, int iterations, size_t length = 32);

std::string base64Encode(const Bytes& data);
// false on malformed input.
bool base64Decode(const std::string& text, Bytes& out);

// Random bytes for the client nonce (OS source).
Bytes randomBytes(size_t n);

// One login: [start] -> auth_start fields, [proof] answers the challenge,
// [verifyServer] checks auth_ok's signature.
class Client {
public:
    Client(std::string user, std::string password);

    const std::string& user() const { return user_; }
    const std::string& cnonce() const { return cnonce_; }

    // Returns the base64 proof, or an empty string when the challenge is
    // invalid (nonce not starting with our cnonce, bad base64, iterations).
    std::string proof(const std::string& nonce, const std::string& salt, int iterations);
    bool verifyServer(const std::string& signature) const;

private:
    std::string user_;
    std::string password_;
    std::string cnonce_;
    Bytes saltedPassword_;
    std::string authMessage_;
};

// Self-check against RFC 7677's test vector; true when it matches.
bool selfTest();

} // namespace hrdab::scram
