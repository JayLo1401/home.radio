// Minimal JSON for the desktop C API: parsing the method arguments Dart
// sends (flat objects, numbers, strings, bools, arrays) and writing the
// event objects that go back. Locale-independent on purpose - GTK sets
// LC_ALL from the environment, which would turn printf's "%.1f" into "1,5".
#pragma once

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace hrdab {

class Json {
public:
    enum class Type { Null, Bool, Number, String, Array, Object };

    // Parses `text`; a malformed document yields Null.
    static Json parse(const std::string& text);

    Type type() const { return type_; }
    bool isNull() const { return type_ == Type::Null; }

    // Object member access; a missing member is a Null value.
    const Json& operator[](const std::string& key) const;
    const std::vector<Json>& items() const { return array_; }

    // Typed reads with defaults, like MethodCall.argument<T>() ?: default.
    int asInt(int def = 0) const;
    double asDouble(double def = 0) const;
    bool asBool(bool def = false) const;
    std::string asString(const std::string& def = std::string()) const;
    bool isNumber() const { return type_ == Type::Number; }
    bool isString() const { return type_ == Type::String; }
    bool isBool() const { return type_ == Type::Bool; }

    int intOr(const std::string& key, int def) const { return (*this)[key].asInt(def); }
    bool boolOr(const std::string& key, bool def) const { return (*this)[key].asBool(def); }
    double doubleOr(const std::string& key, double def) const { return (*this)[key].asDouble(def); }
    std::string stringOr(const std::string& key, const std::string& def) const { return (*this)[key].asString(def); }

private:
    friend class JsonParser;
    Type type_ = Type::Null;
    bool bool_ = false;
    double number_ = 0;
    std::string string_;
    std::vector<Json> array_;
    std::map<std::string, Json> object_;
};

// Appends JSON text. Doubles are written with a decimal point always (so
// Dart's jsonDecode yields a double, like the Android method channel does
// for Kotlin floats); NaN/inf become null.
class JsonWriter {
public:
    // Top level or array element; members are written with the key-taking
    // calls below.
    JsonWriter& beginObject();
    JsonWriter& endObject();
    JsonWriter& beginArray(const char* key = nullptr);
    JsonWriter& endArray();

    JsonWriter& str(const char* key, const std::string& value);
    JsonWriter& strOrNull(const char* key, const std::string* value);
    JsonWriter& num(const char* key, int64_t value);
    JsonWriter& dbl(const char* key, double value, int decimals = 2);
    JsonWriter& boolean(const char* key, bool value);
    JsonWriter& null(const char* key);
    // Pre-formatted JSON value.
    JsonWriter& raw(const char* key, const std::string& json);

    // Array elements.
    JsonWriter& num(int64_t value) { return num(nullptr, value); }
    JsonWriter& dbl(double value, int decimals = 2) { return dbl(nullptr, value, decimals); }

    const std::string& text() const { return out_; }

    static std::string escape(const std::string& s);
    static std::string formatDouble(double value, int decimals);

private:
    void separator(const char* key);

    std::string out_;
    std::vector<bool> first_;
};

} // namespace hrdab
