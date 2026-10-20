#pragma once

#include <cstdint>
#include <string>

namespace hrdab {

// Converts a DAB label/DLS text to UTF-8 (ETSI TS 101 756 character sets:
// 0 = complete EBU Latin, 4 = ISO 8859-1, 6 = UCS-2 big endian, 15 = UTF-8).
// Trailing spaces and NULs are trimmed.
std::string dabTextToUtf8(const uint8_t* data, int len, int charset);

} // namespace hrdab
