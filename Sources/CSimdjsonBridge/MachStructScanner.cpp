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
    uint64_t from = start, to = end;
    unsigned char first = d[start];
    if (first == '"') {
        ++from; --to;
        for (uint64_t i = from; i < to; ++i) {
            if (d[i] == '\\' || d[i] >= 0x80) return false;
        }
    } else if (first == '-' || is_digit(first)) {
        if (to - from > 18) return false;              // may not fit Int64
        if (first == '-' && to - from > 1 && d[from + 1] == '0') return false;   // -0
        for (uint64_t i = from; i < to; ++i) {
            if (!is_digit(d[i]) && !(i == from && d[i] == '-')) return false;  // float
        }
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
