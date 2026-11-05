#include "json.h"

#include <charconv>
#include <cmath>
#include <cstdio>

namespace hrdab {

class JsonParser {
public:
    explicit JsonParser(const std::string& s) : s_(s) {}

    bool parseValue(Json& out, int depth)
    {
        if (depth > 32) return false;
        skipWs();
        if (pos_ >= s_.size()) return false;
        const char c = s_[pos_];
        if (c == '{') return parseObject(out, depth);
        if (c == '[') return parseArray(out, depth);
        if (c == '"') {
            out.type_ = Json::Type::String;
            return parseString(out.string_);
        }
        if (literal("true")) {
            out.type_ = Json::Type::Bool;
            out.bool_ = true;
            return true;
        }
        if (literal("false")) {
            out.type_ = Json::Type::Bool;
            out.bool_ = false;
            return true;
        }
        if (literal("null")) {
            out.type_ = Json::Type::Null;
            return true;
        }
        return parseNumber(out);
    }

    bool atEnd()
    {
        skipWs();
        return pos_ == s_.size();
    }

private:
    void skipWs()
    {
        while (pos_ < s_.size() && (s_[pos_] == ' ' || s_[pos_] == '\t' || s_[pos_] == '\n' || s_[pos_] == '\r')) {
            pos_++;
        }
    }

    bool literal(const char* word)
    {
        const size_t n = std::char_traits<char>::length(word);
        if (s_.compare(pos_, n, word) != 0) return false;
        pos_ += n;
        return true;
    }

    bool parseNumber(Json& out)
    {
        const char* begin = s_.data() + pos_;
        const char* end = s_.data() + s_.size();
        double v = 0;
        const auto r = std::from_chars(begin, end, v);
        if (r.ec != std::errc() || r.ptr == begin) return false;
        pos_ += static_cast<size_t>(r.ptr - begin);
        out.type_ = Json::Type::Number;
        out.number_ = v;
        return true;
    }

    static void appendUtf8(std::string& out, uint32_t cp)
    {
        if (cp < 0x80) {
            out += static_cast<char>(cp);
        } else if (cp < 0x800) {
            out += static_cast<char>(0xC0 | (cp >> 6));
            out += static_cast<char>(0x80 | (cp & 0x3F));
        } else if (cp < 0x10000) {
            out += static_cast<char>(0xE0 | (cp >> 12));
            out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (cp & 0x3F));
        } else {
            out += static_cast<char>(0xF0 | (cp >> 18));
            out += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
            out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (cp & 0x3F));
        }
    }

    bool hex4(uint32_t& v)
    {
        if (pos_ + 4 > s_.size()) return false;
        v = 0;
        for (int i = 0; i < 4; i++) {
            const char c = s_[pos_++];
            v <<= 4;
            if (c >= '0' && c <= '9') v |= static_cast<uint32_t>(c - '0');
            else if (c >= 'a' && c <= 'f') v |= static_cast<uint32_t>(c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') v |= static_cast<uint32_t>(c - 'A' + 10);
            else return false;
        }
        return true;
    }

    bool parseString(std::string& out)
    {
        pos_++; // opening quote
        while (pos_ < s_.size()) {
            const char c = s_[pos_++];
            if (c == '"') return true;
            if (c != '\\') {
                out += c;
                continue;
            }
            if (pos_ >= s_.size()) return false;
            const char e = s_[pos_++];
            switch (e) {
                case '"': out += '"'; break;
                case '\\': out += '\\'; break;
                case '/': out += '/'; break;
                case 'b': out += '\b'; break;
                case 'f': out += '\f'; break;
                case 'n': out += '\n'; break;
                case 'r': out += '\r'; break;
                case 't': out += '\t'; break;
                case 'u': {
                    uint32_t cp;
                    if (!hex4(cp)) return false;
                    if (cp >= 0xD800 && cp < 0xDC00 && s_.compare(pos_, 2, "\\u") == 0) {
                        pos_ += 2;
                        uint32_t lo;
                        if (!hex4(lo)) return false;
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    }
                    appendUtf8(out, cp);
                    break;
                }
                default: return false;
            }
        }
        return false;
    }

    bool parseArray(Json& out, int depth)
    {
        out.type_ = Json::Type::Array;
        pos_++;
        skipWs();
        if (pos_ < s_.size() && s_[pos_] == ']') {
            pos_++;
            return true;
        }
        while (true) {
            Json item;
            if (!parseValue(item, depth + 1)) return false;
            out.array_.push_back(std::move(item));
            skipWs();
            if (pos_ >= s_.size()) return false;
            if (s_[pos_] == ',') {
                pos_++;
                continue;
            }
            if (s_[pos_] == ']') {
                pos_++;
                return true;
            }
            return false;
        }
    }

    bool parseObject(Json& out, int depth)
    {
        out.type_ = Json::Type::Object;
        pos_++;
        skipWs();
        if (pos_ < s_.size() && s_[pos_] == '}') {
            pos_++;
            return true;
        }
        while (true) {
            skipWs();
            if (pos_ >= s_.size() || s_[pos_] != '"') return false;
            std::string key;
            if (!parseString(key)) return false;
            skipWs();
            if (pos_ >= s_.size() || s_[pos_] != ':') return false;
            pos_++;
            Json value;
            if (!parseValue(value, depth + 1)) return false;
            out.object_[key] = std::move(value);
            skipWs();
            if (pos_ >= s_.size()) return false;
            if (s_[pos_] == ',') {
                pos_++;
                continue;
            }
            if (s_[pos_] == '}') {
                pos_++;
                return true;
            }
            return false;
        }
    }

    const std::string& s_;
    size_t pos_ = 0;
};

Json Json::parse(const std::string& text)
{
    Json out;
    JsonParser p(text);
    if (!p.parseValue(out, 0) || !p.atEnd()) return Json();
    return out;
}

const Json& Json::operator[](const std::string& key) const
{
    static const Json kNull;
    if (type_ != Type::Object) return kNull;
    auto it = object_.find(key);
    return it == object_.end() ? kNull : it->second;
}

int Json::asInt(int def) const
{
    return type_ == Type::Number ? static_cast<int>(std::llround(number_)) : def;
}

double Json::asDouble(double def) const
{
    return type_ == Type::Number ? number_ : def;
}

bool Json::asBool(bool def) const
{
    return type_ == Type::Bool ? bool_ : def;
}

std::string Json::asString(const std::string& def) const
{
    return type_ == Type::String ? string_ : def;
}

// --- writer ---

std::string JsonWriter::escape(const std::string& s)
{
    std::string out;
    out.reserve(s.size() + 2);
    for (unsigned char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    out += static_cast<char>(c);
                }
        }
    }
    return out;
}

std::string JsonWriter::formatDouble(double value, int decimals)
{
    if (!std::isfinite(value)) return "null";
    if (decimals < 1) decimals = 1;
    char buf[64];
    const auto r = std::to_chars(buf, buf + sizeof(buf), value, std::chars_format::fixed, decimals);
    if (r.ec != std::errc()) return "null";
    return std::string(buf, r.ptr);
}

void JsonWriter::separator(const char* key)
{
    if (!first_.empty()) {
        if (!first_.back()) out_ += ',';
        first_.back() = false;
    }
    if (key) {
        out_ += '"';
        out_ += escape(key);
        out_ += "\":";
    }
}

JsonWriter& JsonWriter::beginObject()
{
    separator(nullptr);
    out_ += '{';
    first_.push_back(true);
    return *this;
}

JsonWriter& JsonWriter::endObject()
{
    out_ += '}';
    first_.pop_back();
    return *this;
}

JsonWriter& JsonWriter::beginArray(const char* k)
{
    separator(k);
    out_ += '[';
    first_.push_back(true);
    return *this;
}

JsonWriter& JsonWriter::endArray()
{
    out_ += ']';
    first_.pop_back();
    return *this;
}

JsonWriter& JsonWriter::str(const char* k, const std::string& value)
{
    separator(k);
    out_ += '"';
    out_ += escape(value);
    out_ += '"';
    return *this;
}

JsonWriter& JsonWriter::strOrNull(const char* k, const std::string* value)
{
    if (!value) return null(k);
    return str(k, *value);
}

JsonWriter& JsonWriter::num(const char* k, int64_t value)
{
    separator(k);
    out_ += std::to_string(value);
    return *this;
}

JsonWriter& JsonWriter::dbl(const char* k, double value, int decimals)
{
    separator(k);
    out_ += formatDouble(value, decimals);
    return *this;
}

JsonWriter& JsonWriter::boolean(const char* k, bool value)
{
    separator(k);
    out_ += value ? "true" : "false";
    return *this;
}

JsonWriter& JsonWriter::null(const char* k)
{
    separator(k);
    out_ += "null";
    return *this;
}

JsonWriter& JsonWriter::raw(const char* k, const std::string& json)
{
    separator(k);
    out_ += json;
    return *this;
}

} // namespace hrdab
