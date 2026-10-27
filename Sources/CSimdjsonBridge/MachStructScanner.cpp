// Byte-level JSON scanning for large files. See MachStructScanner.h and
// docs/ADR-002-lazy-source-index.md.

#include "MachStructScanner.h"
#include <cstring>
#include <vector>

namespace {

// ---------------------------------------------------------------------------
// Byte classes
// ---------------------------------------------------------------------------

struct Tables {
    bool plain_string[256];   // stays inside a string without checks
    bool structural[256];     // a byte a container skip has to look at
    bool scalar_end[256];     // ends an unquoted scalar
    constexpr Tables() : plain_string(), structural(), scalar_end() {
        for (int c = 0x20; c < 0x80; ++c) plain_string[c] = true;
        plain_string[static_cast<int>('"')] = false;
        plain_string[static_cast<int>('\\')] = false;
        for (unsigned char c : {'"', '{', '}', '[', ']'}) structural[c] = true;
        for (unsigned char c : {',', '}', ']', ' ', '\t', '\n', '\r'}) scalar_end[c] = true;
    }
};
constexpr Tables tables;

inline bool is_ws(unsigned char c) {
    return c == ' ' || c == '\n' || c == '\r' || c == '\t';
}

inline bool is_digit(unsigned char c) { return c >= '0' && c <= '9'; }

inline bool is_ascii(const unsigned char* s, uint64_t n) {
    for (uint64_t i = 0; i < n; ++i) if (s[i] >= 0x80) return false;
    return true;
}

// True when [s, e) is a number whose displayed text (ScalarValue's
// searchableText) is exactly these bytes: an Int64 written without a plus
// sign or leading zero, or a decimal Swift prints back unchanged, i.e. at most 15
// digits, no trailing zero unless it is a lone ".0", at least 1e-4, and no
// exponent.
bool displays_as_written(const unsigned char* d, uint64_t s, uint64_t e) {
    uint64_t i = s;
    if (i < e && d[i] == '-') ++i;
    uint64_t int_start = i;
    while (i < e && is_digit(d[i])) ++i;
    uint64_t int_digits = i - int_start;
    if (int_digits == 0 || (d[int_start] == '0' && int_digits > 1)) return false;
    if (i == e) {
        // An integer: displayed as Int64 prints it, which drops the sign of -0.
        if (d[s] == '-' && int_digits == 1 && d[int_start] == '0') return false;
        return int_digits <= 18;
    }
    if (d[i] != '.') return false;
    uint64_t frac_start = ++i;
    while (i < e && is_digit(d[i])) ++i;
    uint64_t frac_digits = i - frac_start;
    if (i != e || frac_digits == 0 || int_digits + frac_digits > 15) return false;
    bool lone_zero = frac_digits == 1 && d[frac_start] == '0';
    if (!lone_zero && d[e - 1] == '0') return false;
    if (d[int_start] == '0' && !lone_zero) {
        uint64_t zeros = 0;
        while (zeros < frac_digits && d[frac_start + zeros] == '0') ++zeros;
        if (zeros >= 4) return false;   // below 1e-4: printed with an exponent
    }
    return true;
}

inline int hex_value(unsigned char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// ---------------------------------------------------------------------------
// Validating scanner
// ---------------------------------------------------------------------------

struct Validator {
    const unsigned char* d;
    uint64_t n;
    uint64_t pos = 0;
    MSJSONError* error;

    bool fail(const char* message, uint64_t at) {
        error->offset = at;
        error->message = message;
        return false;
    }

    void skip_ws() { while (pos < n && is_ws(d[pos])) ++pos; }

    // `pos` is at a backslash.
    bool escape() {
        uint64_t start = pos;
        if (pos + 1 >= n) return fail("The string is not terminated.", start);
        unsigned char c = d[pos + 1];
        if (c != 'u') {
            if (c == '"' || c == '\\' || c == '/' || c == 'b' || c == 'f' ||
                c == 'n' || c == 'r' || c == 't') {
                pos += 2;
                return true;
            }
            return fail("Invalid escape sequence in a string.", start);
        }
        int unit = hex4(pos + 2);
        if (unit < 0) return fail("Invalid \\u escape in a string.", start);
        pos += 6;
        if (unit >= 0xDC00 && unit <= 0xDFFF) {
            return fail("Unpaired surrogate in a \\u escape.", start);
        }
        if (unit >= 0xD800 && unit <= 0xDBFF) {
            int low = (pos + 1 < n && d[pos] == '\\' && d[pos + 1] == 'u') ? hex4(pos + 2) : -1;
            if (low < 0xDC00 || low > 0xDFFF) {
                return fail("Unpaired surrogate in a \\u escape.", start);
            }
            pos += 6;
        }
        return true;
    }

    int hex4(uint64_t at) const {
        if (at + 4 > n) return -1;
        int v = 0;
        for (int i = 0; i < 4; ++i) {
            int h = hex_value(d[at + i]);
            if (h < 0) return -1;
            v = v * 16 + h;
        }
        return v;
    }

    // One UTF-8 sequence starting with a byte ≥ 0x80 (RFC 3629).
    bool utf8() {
        uint64_t start = pos;
        unsigned char c = d[pos];
        int extra;
        unsigned char lo = 0x80, hi = 0xBF;
        if (c >= 0xC2 && c <= 0xDF) { extra = 1; }
        else if (c == 0xE0)         { extra = 2; lo = 0xA0; }
        else if (c >= 0xE1 && c <= 0xEC) { extra = 2; }
        else if (c == 0xED)         { extra = 2; hi = 0x9F; }
        else if (c >= 0xEE && c <= 0xEF) { extra = 2; }
        else if (c == 0xF0)         { extra = 3; lo = 0x90; }
        else if (c >= 0xF1 && c <= 0xF3) { extra = 3; }
        else if (c == 0xF4)         { extra = 3; hi = 0x8F; }
        else return fail("The text is not valid UTF-8.", start);
        if (pos + extra >= n) return fail("The text is not valid UTF-8.", start);
        unsigned char b = d[pos + 1];
        if (b < lo || b > hi) return fail("The text is not valid UTF-8.", start);
        for (int i = 2; i <= extra; ++i) {
            b = d[pos + i];
            if (b < 0x80 || b > 0xBF) return fail("The text is not valid UTF-8.", start);
        }
        pos += extra + 1;
        return true;
    }

    // `pos` is at the opening quote.
    bool string() {
        uint64_t start = pos;
        ++pos;
        for (;;) {
            while (pos < n && tables.plain_string[d[pos]]) ++pos;
            if (pos >= n) return fail("The string is not terminated.", start);
            unsigned char c = d[pos];
            if (c == '"') { ++pos; return true; }
            if (c == '\\') { if (!escape()) return false; continue; }
            if (c < 0x20) return fail("Unescaped control character in a string.", pos);
            if (!utf8()) return false;
        }
    }

    bool digits() {
        if (pos >= n || !is_digit(d[pos])) return false;
        while (pos < n && is_digit(d[pos])) ++pos;
        return true;
    }

    bool number() {
        uint64_t start = pos;
        if (d[pos] == '-') ++pos;
        if (pos >= n) return fail("Invalid number.", start);
        if (d[pos] == '0') {
            ++pos;
        } else if (!digits()) {
            return fail("Invalid number.", start);
        }
        if (pos < n && d[pos] == '.') {
            ++pos;
            if (!digits()) return fail("Invalid number.", start);
        }
        if (pos < n && (d[pos] == 'e' || d[pos] == 'E')) {
            ++pos;
            if (pos < n && (d[pos] == '+' || d[pos] == '-')) ++pos;
            if (!digits()) return fail("Invalid number.", start);
        }
        return true;
    }

    bool literal(const char* word, size_t len) {
        if (pos + len > n || std::memcmp(d + pos, word, len) != 0) {
            return fail("Unexpected character.", pos);
        }
        pos += len;
        return true;
    }

    bool run(MSJSONInfo* info) {
        if (n >= 3 && d[0] == 0xEF && d[1] == 0xBB && d[2] == 0xBF) pos = 3;
        skip_ws();
        if (pos >= n) return fail("The document is empty.", pos);

        enum State { VALUE, OBJECT_FIRST, ARRAY_FIRST, KEY, AFTER };
        State state = VALUE;
        std::vector<unsigned char> stack;   // '{' or '[' per open container
        uint64_t nodes = 0, root_children = 0;
        info->root_offset = pos;

        for (;;) {
            skip_ws();
            switch (state) {
            case OBJECT_FIRST:
                if (pos < n && d[pos] == '}') { ++pos; stack.pop_back(); if (stack.empty()) info->root_end = pos; state = AFTER; break; }
                [[fallthrough]];
            case KEY:
                if (pos >= n) return fail("Unexpected end of the document.", pos);
                if (d[pos] != '"') return fail("Expected a key in quotes.", pos);
                ++nodes;
                if (stack.size() == 1) ++root_children;
                if (!string()) return false;
                skip_ws();
                if (pos >= n || d[pos] != ':') return fail("Expected ':' after a key.", pos);
                ++pos;
                state = VALUE;
                break;

            case ARRAY_FIRST:
                if (pos < n && d[pos] == ']') { ++pos; stack.pop_back(); if (stack.empty()) info->root_end = pos; state = AFTER; break; }
                if (stack.size() == 1) ++root_children;
                state = VALUE;
                break;

            case VALUE: {
                if (pos >= n) return fail("Unexpected end of the document.", pos);
                ++nodes;
                unsigned char c = d[pos];
                if (stack.empty()) {
                    info->root_type = c == '{' ? MS_NODE_TYPE_OBJECT
                                    : c == '[' ? MS_NODE_TYPE_ARRAY
                                    : c == '"' ? MS_NODE_TYPE_STRING
                                    : (c == 't' || c == 'f') ? MS_NODE_TYPE_BOOL
                                    : c == 'n' ? MS_NODE_TYPE_NULL
                                    : MS_NODE_TYPE_NUMBER;
                }
                if (c == '{') { stack.push_back('{'); ++pos; state = OBJECT_FIRST; break; }
                if (c == '[') { stack.push_back('['); ++pos; state = ARRAY_FIRST; break; }
                bool ok;
                if (c == '"') ok = string();
                else if (c == '-' || is_digit(c)) ok = number();
                else if (c == 't') ok = literal("true", 4);
                else if (c == 'f') ok = literal("false", 5);
                else if (c == 'n') ok = literal("null", 4);
                else ok = fail(c == ']' || c == '}' ? "Expected a value." : "Unexpected character.", pos);
                if (!ok) return false;
                if (stack.empty()) info->root_end = pos;
                state = AFTER;
                break;
            }

            case AFTER:
                if (stack.empty()) {
                    if (pos < n) return fail("Unexpected data after the root value.", pos);
                    info->root_child_count = root_children;
                    info->node_count = nodes;
                    return true;
                }
                if (pos >= n) return fail("Unexpected end of the document.", pos);
                if (stack.back() == '[') {
                    if (d[pos] == ',') {
                        ++pos;
                        if (stack.size() == 1) ++root_children;
                        state = VALUE;
                    } else if (d[pos] == ']') {
                        ++pos; stack.pop_back(); if (stack.empty()) info->root_end = pos;
                    } else {
                        return fail("Expected ',' or ']'.", pos);
                    }
                } else {
                    if (d[pos] == ',') { ++pos; state = KEY; }
                    else if (d[pos] == '}') { ++pos; stack.pop_back(); if (stack.empty()) info->root_end = pos; }
                    else return fail("Expected ',' or '}'.", pos);
                }
                break;
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Non-validating helpers (input already validated)
// ---------------------------------------------------------------------------

inline uint64_t skip_ws(const unsigned char* d, uint64_t n, uint64_t pos) {
    while (pos < n && is_ws(d[pos])) ++pos;
    return pos;
}

// `pos` at the opening quote; returns one past the closing quote.
inline uint64_t skip_string(const unsigned char* d, uint64_t n, uint64_t pos) {
    ++pos;
    while (pos < n) {
        unsigned char c = d[pos];
        if (c == '"') return pos + 1;
        pos += (c == '\\') ? 2 : 1;
    }
    return n;
}

// `pos` at `{` or `[`; returns one past the matching bracket.
uint64_t skip_container(const unsigned char* d, uint64_t n, uint64_t pos) {
    uint64_t depth = 0;
    while (pos < n) {
        while (pos < n && !tables.structural[d[pos]]) ++pos;
        if (pos >= n) break;
        unsigned char c = d[pos];
        if (c == '"') { pos = skip_string(d, n, pos); continue; }
        if (c == '{' || c == '[') { ++depth; }
        else if (--depth == 0) { return pos + 1; }
        ++pos;
    }
    return n;
}

uint64_t skip_value(const unsigned char* d, uint64_t n, uint64_t pos) {
    if (pos >= n) return n;
    unsigned char c = d[pos];
    if (c == '{' || c == '[') return skip_container(d, n, pos);
    if (c == '"') return skip_string(d, n, pos);
    while (pos < n && !tables.scalar_end[d[pos]]) ++pos;
    return pos;
}

// Walks the children of the container at `offset`, reporting each start.
// Returns one past the closing bracket.
template <typename Visit>
uint64_t each_child(const unsigned char* d, uint64_t n, uint64_t offset, Visit visit) {
    bool object = d[offset] == '{';
    uint64_t pos = skip_ws(d, n, offset + 1);
    if (pos < n && (d[pos] == '}' || d[pos] == ']')) return pos + 1;
    while (pos < n) {
        visit(pos);
        if (object) {
            pos = skip_string(d, n, pos);
            pos = skip_ws(d, n, pos);
            pos = skip_ws(d, n, pos + 1);   // ':'
        }
        pos = skip_value(d, n, pos);
        pos = skip_ws(d, n, pos);
        if (pos < n && d[pos] == ',') {
            pos = skip_ws(d, n, pos + 1);
            continue;
        }
        return pos + 1;
    }
    return n;
}

uint8_t type_at(const unsigned char* d, uint64_t offset) {
    switch (d[offset]) {
    case '{': return MS_NODE_TYPE_OBJECT;
    case '[': return MS_NODE_TYPE_ARRAY;
    case '"': return MS_NODE_TYPE_STRING;
    case 't': case 'f': return MS_NODE_TYPE_BOOL;
    case 'n': return MS_NODE_TYPE_NULL;
    default:  return MS_NODE_TYPE_NUMBER;
    }
}

// True when the token's text as searched (decoded and lowercased) can't
// contain `needle`. Only tokens whose text is exactly their bytes are judged:
// strings without escapes or non-ASCII bytes, plain integers and literals.
bool cannot_contain(const unsigned char* d, uint64_t start, uint64_t end,
                    const unsigned char* needle, uint64_t needle_length) {
    if (needle_length == 0) return false;
    if (!is_ascii(needle, needle_length)) {
        // ASCII text can't hold a non-ASCII needle; only \u escapes and
        // non-ASCII bytes make non-ASCII text.
        for (uint64_t i = start; i < end; ++i) {
            if (d[i] >= 0x80 || d[i] == '\\') return false;
        }
        return true;
    }
    uint64_t from = start, to = end;
    unsigned char first = d[start];
    if (first == '"') {
        ++from; --to;
        for (uint64_t i = from; i < to; ++i) {
            if (d[i] == '\\' || d[i] >= 0x80) return false;
        }
    } else if (first == '-' || is_digit(first)) {
        if (!displays_as_written(d, from, to)) return false;
    }
    if (to - from < needle_length) return true;
    for (uint64_t i = from; i + needle_length <= to; ++i) {
        uint64_t j = 0;
        while (j < needle_length) {
            unsigned char c = d[i + j];
            if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
            if (c != needle[j]) break;
            ++j;
        }
        if (j == needle_length) return false;
    }
    return true;
}

// --- CSV --------------------------------------------------------------------

// One past the end of the field starting at `pos`. A quoted field ends after
// its closing quote ("" is an escaped quote); an unquoted one at the
// delimiter or a line break.
uint64_t csv_field_end(const unsigned char* d, uint64_t n, uint64_t pos, unsigned char delim) {
    if (pos < n && d[pos] == '"') {
        ++pos;
        while (pos < n) {
            if (d[pos] == '"') {
                if (pos + 1 < n && d[pos + 1] == '"') { pos += 2; continue; }
                return pos + 1;
            }
            ++pos;
        }
        return n;
    }
    while (pos < n && d[pos] != delim && d[pos] != '\n' && d[pos] != '\r') ++pos;
    return pos;
}

// Reads the row at `pos` the way CSVParser's tokenizer does, calling
// `field(start, end)` for each field. Returns where the next row starts and
// sets `row_end` to one past the last field.
template <typename Field>
uint64_t csv_row(const unsigned char* d, uint64_t n, uint64_t pos, unsigned char delim,
                 uint64_t* row_end, Field field) {
    for (;;) {
        uint64_t end = csv_field_end(d, n, pos, delim);
        field(pos, end);
        pos = end;
        if (pos >= n) { *row_end = pos; return pos; }
        if (d[pos] == delim) { ++pos; continue; }
        *row_end = pos;
        // A line ending ends the row; anything else after a closing quote
        // starts the next one.
        if (d[pos] == '\r') {
            ++pos;
            if (pos < n && d[pos] == '\n') ++pos;
        } else if (d[pos] == '\n') {
            ++pos;
        }
        return pos;
    }
}

// True when the field's text is empty: nothing, `""`, or a lone `"` that
// opens a quoted field the file ends in.
inline bool csv_field_is_empty(const unsigned char* d, uint64_t start, uint64_t end) {
    if (end == start) return true;
    if (d[start] != '"') return false;
    return end - start == 1 || (end - start == 2 && d[start + 1] == '"');
}

bool utf8_valid(const unsigned char* d, uint64_t n) {
    uint64_t pos = 0;
    while (pos < n) {
        if (d[pos] < 0x80) { ++pos; continue; }
        unsigned char c = d[pos];
        int extra;
        unsigned char lo = 0x80, hi = 0xBF;
        if (c >= 0xC2 && c <= 0xDF) { extra = 1; }
        else if (c == 0xE0)         { extra = 2; lo = 0xA0; }
        else if (c >= 0xE1 && c <= 0xEC) { extra = 2; }
        else if (c == 0xED)         { extra = 2; hi = 0x9F; }
        else if (c >= 0xEE && c <= 0xEF) { extra = 2; }
        else if (c == 0xF0)         { extra = 3; lo = 0x90; }
        else if (c >= 0xF1 && c <= 0xF3) { extra = 3; }
        else if (c == 0xF4)         { extra = 3; hi = 0x8F; }
        else return false;
        if (pos + extra >= n) return false;
        if (d[pos + 1] < lo || d[pos + 1] > hi) return false;
        for (int i = 2; i <= extra; ++i) {
            if (d[pos + i] < 0x80 || d[pos + i] > 0xBF) return false;
        }
        pos += extra + 1;
    }
    return true;
}

// True when a CSV field's text, as CSVParser reads and displays it, can't
// contain `needle`. Judged only for unquoted ASCII fields whose displayed
// text is exactly their bytes up to case: anything Swift's `Double` might
// parse (digits other than a plain integer, inf, nan) is reformatted, and a
// quoted field is unescaped, so those are left to the caller.
bool csv_cannot_contain(const unsigned char* d, uint64_t start, uint64_t end,
                        const unsigned char* needle, uint64_t needle_length) {
    if (needle_length == 0) return false;
    if (!is_ascii(needle, needle_length)) {
        // ASCII text, quoted or not, can't hold a non-ASCII needle.
        for (uint64_t i = start; i < end; ++i) {
            if (d[i] >= 0x80) return false;
        }
        return true;
    }
    for (uint64_t i = start; i < end; ++i) {
        if (d[i] == '"' || d[i] >= 0x80) return false;
    }
    uint64_t s = start, e = end;
    while (s < e && (d[s] == ' ' || d[s] == '\t')) ++s;
    while (e > s && (d[e - 1] == ' ' || d[e - 1] == '\t')) --e;
    // Anything Swift could read as a number is displayed as that number. A
    // number needs a digit and only number characters (decimal, exponent,
    // hex float); plain Int64 digits without a leading zero display as is.
    bool has_digit = false, all_digits = s < e, number_chars = true;
    for (uint64_t i = s; i < e; ++i) {
        unsigned char c = d[i];
        if (is_digit(c)) { has_digit = true; continue; }
        all_digits = false;
        if (!std::strchr("+-.eExXpPaAbBcCdDfF", c)) number_chars = false;
    }
    if (has_digit && number_chars) {
        (void)all_digits;
        if (s != start || e != end || !displays_as_written(d, s, e)) return false;
    }
    // inf, infinity and nan, with sign and spaces, parse as floats.
    if (s < e && (d[s] == '+' || d[s] == '-')) ++s;
    for (const char* word : {"inf", "infinity", "nan", "snan"}) {
        size_t len = std::strlen(word);
        if (e - s != len) continue;
        size_t k = 0;
        while (k < len && (d[s + k] | 0x20) == static_cast<unsigned char>(word[k])) ++k;
        if (k == len) return false;
    }
    if (end - start < needle_length) return true;
    for (uint64_t i = start; i + needle_length <= end; ++i) {
        uint64_t j = 0;
        while (j < needle_length) {
            unsigned char c = d[i + j];
            if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
            if (c != needle[j]) break;
            ++j;
        }
        if (j == needle_length) return false;
    }
    return true;
}

} // namespace

// ---------------------------------------------------------------------------
// Public C entry points
// ---------------------------------------------------------------------------

extern "C" int ms_json_validate(const char* data, uint64_t length,
                                MSJSONInfo* info, MSJSONError* error)
{
    Validator v{reinterpret_cast<const unsigned char*>(data), length, 0, error};
    *info = MSJSONInfo{};
    return v.run(info) ? 1 : 0;
}

extern "C" uint64_t ms_json_child_offsets(const char* data, uint64_t length, uint64_t offset,
                                          uint64_t* out, uint64_t max, uint64_t* end)
{
    auto d = reinterpret_cast<const unsigned char*>(data);
    if (offset >= length || (d[offset] != '{' && d[offset] != '[')) {
        if (end) *end = offset;
        return 0;
    }
    uint64_t count = 0;
    uint64_t stop = each_child(d, length, offset, [&](uint64_t start) {
        if (count < max) out[count] = start;
        ++count;
    });
    if (end) *end = stop;
    return count;
}

extern "C" void ms_json_value_info(const char* data, uint64_t length, uint64_t offset,
                                   MSJSONValue* out)
{
    auto d = reinterpret_cast<const unsigned char*>(data);
    *out = MSJSONValue{};
    if (offset >= length) return;
    out->type = type_at(d, offset);
    if (out->type == MS_NODE_TYPE_OBJECT || out->type == MS_NODE_TYPE_ARRAY) {
        uint64_t count = 0;
        out->end = each_child(d, length, offset, [&](uint64_t) { ++count; });
        out->child_count = count;
    } else {
        out->end = skip_value(d, length, offset);
    }
}

extern "C" uint64_t ms_json_value_end(const char* data, uint64_t length, uint64_t offset)
{
    return skip_value(reinterpret_cast<const unsigned char*>(data), length, offset);
}

extern "C" void ms_json_member(const char* data, uint64_t length, uint64_t key_offset,
                               uint64_t* key_end, uint64_t* value_offset)
{
    auto d = reinterpret_cast<const unsigned char*>(data);
    uint64_t end = skip_string(d, length, key_offset);
    *key_end = end;
    uint64_t pos = skip_ws(d, length, end);
    *value_offset = skip_ws(d, length, pos + 1);   // past ':'
}

extern "C" void ms_json_search(const char* data, uint64_t length, uint64_t offset, int is_member,
                               const char* needle, uint64_t needle_length,
                               MSJSONVisitor visit, void* context)
{
    auto d = reinterpret_cast<const unsigned char*>(data);
    auto nd = reinterpret_cast<const unsigned char*>(needle);
    const uint64_t none = UINT64_MAX;
    std::vector<unsigned char> stack;   // '{' or '[' per open container
    uint64_t member = none;             // the member owning the value at `pos`
    uint64_t pos = offset;

    // Reports the key at `pos` and moves to its value. Returns false to stop.
    auto key = [&]() {
        uint64_t key_end = skip_string(d, length, pos);
        if (!cannot_contain(d, pos, key_end, nd, needle_length)) {
            MSJSONToken t{1, pos, key_end, pos, 1};
            if (!visit(context, &t)) return false;
        }
        member = pos;
        pos = skip_ws(d, length, key_end);
        pos = skip_ws(d, length, pos + 1);   // past ':'
        return true;
    };

    if (is_member && !key()) return;
    for (;;) {
        // `pos` is at a value.
        unsigned char c = d[pos];
        if (c == '{' || c == '[') {
            stack.push_back(c);
            pos = skip_ws(d, length, pos + 1);
            if (d[pos] == '}' || d[pos] == ']') {
                ++pos;
                stack.pop_back();
            } else if (c == '{') {
                if (!key()) return;
                continue;
            } else {
                member = none;
                continue;
            }
        } else {
            uint64_t end = skip_value(d, length, pos);
            if (!cannot_contain(d, pos, end, nd, needle_length)) {
                MSJSONToken t{0, pos, end, member != none ? member : pos,
                              static_cast<uint8_t>(member != none)};
                if (!visit(context, &t)) return;
            }
            pos = end;
        }
        // After a value: move to the next one, closing containers on the way.
        for (;;) {
            if (stack.empty()) return;
            pos = skip_ws(d, length, pos);
            if (pos >= length) return;
            if (d[pos] == ',') {
                pos = skip_ws(d, length, pos + 1);
                if (stack.back() == '{') {
                    if (!key()) return;
                } else {
                    member = none;
                }
                break;
            }
            ++pos;   // '}' or ']'
            stack.pop_back();
        }
    }
}

extern "C" void ms_csv_scan(const char* data, uint64_t length, char delimiter,
                            uint64_t* row_offsets, uint64_t max, MSCSVInfo* info)
{
    auto d = reinterpret_cast<const unsigned char*>(data);
    auto delim = static_cast<unsigned char>(delimiter);
    *info = MSCSVInfo{};
    info->is_utf8 = utf8_valid(d, length) ? 1 : 0;
    uint64_t pos = 0;
    while (pos < length) {
        uint64_t start = pos, row_end = 0, count = 0;
        bool empty = true;
        pos = csv_row(d, length, pos, delim, &row_end, [&](uint64_t s, uint64_t e) {
            ++count;
            empty = empty && csv_field_is_empty(d, s, e);
        });
        if (count == 1 && empty) continue;   // a blank line
        if (info->rows < max) row_offsets[info->rows] = start;
        ++info->rows;
        info->fields += count;
        if (count > info->widest) info->widest = count;
    }
}

extern "C" uint64_t ms_csv_fields(const char* data, uint64_t length, char delimiter,
                                  uint64_t row_offset, uint64_t* starts, uint64_t* ends,
                                  uint64_t max, uint64_t* row_end)
{
    auto d = reinterpret_cast<const unsigned char*>(data);
    uint64_t count = 0, end = 0;
    csv_row(d, length, row_offset, static_cast<unsigned char>(delimiter), &end,
            [&](uint64_t s, uint64_t e) {
        if (count < max) { starts[count] = s; ends[count] = e; }
        ++count;
    });
    if (row_end) *row_end = end;
    return count;
}

extern "C" void ms_csv_search_rows(const char* data, uint64_t length, char delimiter,
                                   uint64_t row_offset, uint64_t row_count,
                                   const char* needle, uint64_t needle_length,
                                   const uint8_t* columns, uint64_t column_count,
                                   MSCSVVisitor visit, void* context)
{
    auto d = reinterpret_cast<const unsigned char*>(data);
    auto nd = reinterpret_cast<const unsigned char*>(needle);
    auto delim = static_cast<unsigned char>(delimiter);
    uint64_t pos = row_offset, done = 0;
    bool stopped = false;
    while (pos < length && done < row_count && !stopped) {
        // A blank line isn't a row: check before visiting anything in it.
        uint64_t row_end = 0, count = 0;
        bool empty = true;
        uint64_t next = csv_row(d, length, pos, delim, &row_end, [&](uint64_t s, uint64_t e) {
            ++count;
            empty = empty && csv_field_is_empty(d, s, e);
        });
        if (count == 1 && empty) { pos = next; continue; }
        uint64_t row = pos, column = 0;
        csv_row(d, length, pos, delim, &row_end, [&](uint64_t s, uint64_t e) {
            if (!stopped) {
                bool marked = column < column_count && columns[column];
                if (marked || !csv_cannot_contain(d, s, e, nd, needle_length)) {
                    MSCSVField f{row, s, e, column};
                    if (!visit(context, &f)) stopped = true;
                }
            }
            ++column;
        });
        pos = next;
        ++done;
    }
}
