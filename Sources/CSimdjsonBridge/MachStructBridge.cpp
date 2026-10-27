// MachStructBridge.cpp
// Thin C-callable wrapper around the simdjson DOM parser.
//
// Phase 1 (P1-03): builds the structural index using simdjson DOM.
// Byte offsets are set to 0 for Phase 1 — JSONParser (P1-06) will extract
// precise offsets using simdjson's tape internals after integration.
//
// Note on memory safety:
//   We use index-based access (buf[my_idx]) rather than reference-based
//   (Entry& e = buf[...]) across recursive calls, because push_back may
//   reallocate the vector, invalidating references.

#include <cstdlib>
#include "MachStructBridge.h"
#include "simdjson.h"

#include <vector>
#include <algorithm>
#include <cstring>

using namespace simdjson;

// ---------------------------------------------------------------------------
// Internal flat entry buffer — same shape as MSIndexEntry but without the
// C-ABI requirement so we can use it freely inside C++.
// ---------------------------------------------------------------------------
struct FlatEntry {
    uint64_t byte_offset;
    uint32_t byte_length;
    uint8_t  node_type;
    uint16_t depth;
    int64_t  parent_index;
    uint32_t child_count;
};

// ---------------------------------------------------------------------------
// Output that `walk` writes straight into: a caller-sized array of exactly
// `count_nodes` entries, so nothing grows or is copied afterwards.
// ---------------------------------------------------------------------------
struct FixedBuffer {
    MSIndexEntry* entries;
    size_t        capacity;
    size_t        used = 0;
    bool          overflowed = false;

    size_t size() const { return used; }
    MSIndexEntry& operator[](int64_t i) { return entries[i]; }
    void push_back(const FlatEntry& e) {
        // Unreachable while count_nodes mirrors walk; checked so a mismatch
        // fails the parse rather than writing past the array.
        if (used == capacity) { overflowed = true; return; }
        entries[used++] = {e.byte_offset, e.byte_length, e.node_type,
                           e.depth, e.parent_index, e.child_count};
    }
};

// The number of entries `walk` produces for `el`, including its depth limit.
static size_t count_nodes(dom::element el, uint16_t depth)
{
    if (depth > 1000) return 0;
    size_t n = 1;
    dom::object obj;
    dom::array arr;
    if (el.type() == dom::element_type::OBJECT && !el.get(obj)) {
        for (auto field : obj) {
            n += 1 + count_nodes(field.value, static_cast<uint16_t>(depth + 2));
        }
    } else if (el.type() == dom::element_type::ARRAY && !el.get(arr)) {
        for (auto child : arr) {
            n += count_nodes(child, static_cast<uint16_t>(depth + 1));
        }
    }
    return n;
}

// ---------------------------------------------------------------------------
// Recursive DOM walk.
//
// my_idx is the index of the current node's placeholder in `buf`; after all
// children are pushed, we update buf[my_idx].child_count in-place.
// ---------------------------------------------------------------------------
template <typename Buffer>
static void walk(dom::element el,
                 Buffer& buf,
                 int64_t parent_idx,
                 uint16_t depth)
{
    // Guard against pathological nesting depth (stack overflow protection)
    if (depth > 1000) return;

    // Reserve this node's slot.
    int64_t my_idx = static_cast<int64_t>(buf.size());
    buf.push_back({0, 0, 0, depth, parent_idx, 0});
    // NOTE: do NOT hold a reference to buf[my_idx] past this point — any
    // subsequent push_back may reallocate.  Access via buf[my_idx] each time.

    switch (el.type()) {

    case dom::element_type::OBJECT: {
        buf[my_idx].node_type = MS_NODE_TYPE_OBJECT;
        dom::object obj;
        if (el.get(obj)) break;  // error_code != SUCCESS
        for (auto field : obj) {
            // Each JSON field becomes a STRING (key) entry whose child is the value.
            int64_t key_idx = static_cast<int64_t>(buf.size());
            std::string_view key = field.key;
            buf.push_back({
                // byte_offset/byte_length are placeholders: the DOM API has no
                // token positions. JSONParser.scanTokenRanges (Swift) assigns
                // real source ranges to every entry after this walk.
                0,
                static_cast<uint32_t>(key.size()),
                MS_NODE_TYPE_STRING,
                static_cast<uint16_t>(depth + 1),
                my_idx,                     // parent = enclosing object
                1                           // child_count = 1 (the value)
            });
            walk(field.value, buf, key_idx, static_cast<uint16_t>(depth + 2));
            buf[my_idx].child_count++;
        }
        break;
    }

    case dom::element_type::ARRAY: {
        buf[my_idx].node_type = MS_NODE_TYPE_ARRAY;
        dom::array arr;
        if (el.get(arr)) break;
        for (auto child : arr) {
            walk(child, buf, my_idx, static_cast<uint16_t>(depth + 1));
            buf[my_idx].child_count++;
        }
        break;
    }

    case dom::element_type::STRING: {
        buf[my_idx].node_type = MS_NODE_TYPE_STRING;
        std::string_view sv;
        if (!el.get(sv)) {
            buf[my_idx].byte_length = static_cast<uint32_t>(sv.size());
        }
        break;
    }

    case dom::element_type::INT64:
    case dom::element_type::UINT64:
    case dom::element_type::DOUBLE:
        buf[my_idx].node_type = MS_NODE_TYPE_NUMBER;
        break;

    case dom::element_type::BOOL:
        buf[my_idx].node_type = MS_NODE_TYPE_BOOL;
        break;

    case dom::element_type::NULL_VALUE:
        buf[my_idx].node_type = MS_NODE_TYPE_NULL;
        break;
    }
}

// ---------------------------------------------------------------------------
// Public C entry point
// ---------------------------------------------------------------------------
// Parses `data` and walks it with `emit(doc)`. Returns false if the JSON is
// invalid or `emit` fails.
template <typename Emit>
static bool with_document(const char* data, uint64_t length, Emit emit)
{
    // padded_string makes an internal copy with SIMDJSON_PADDING trailing bytes,
    // which is required by simdjson regardless of whether the input is already padded.
    simdjson::padded_string ps(data, static_cast<size_t>(length));

    dom::parser parser;
    dom::element doc;
    if (parser.parse(ps).get(doc)) {
        return false;
    }
    return emit(doc);
}

static void copy_entries(const std::vector<FlatEntry>& buf, MSIndexEntry* out_entries)
{
    const size_t n = buf.size();
    for (size_t i = 0; i < n; ++i) {
        out_entries[i].byte_offset   = buf[i].byte_offset;
        out_entries[i].byte_length   = buf[i].byte_length;
        out_entries[i].node_type     = buf[i].node_type;
        out_entries[i].depth         = buf[i].depth;
        out_entries[i].parent_index  = buf[i].parent_index;
        out_entries[i].child_count   = buf[i].child_count;
    }
}

extern "C"
int64_t ms_build_structural_index(const char*   data,
                                   uint64_t      length,
                                   MSIndexEntry* out_entries,
                                   uint64_t      max_entries)
{
    std::vector<FlatEntry> buf;
    bool fits = true;
    bool parsed = with_document(data, length, [&](dom::element doc) {
        // Initial reserve — conservative estimate to avoid excessive reallocations.
        // Capped at 500 000 to avoid huge up-front allocations for large files.
        buf.reserve(std::min(static_cast<size_t>(length / 8),
                             static_cast<size_t>(500'000)));
        walk(doc, buf, /*parent_index=*/-1, /*depth=*/0);
        fits = static_cast<uint64_t>(buf.size()) <= max_entries;
        return true;
    });
    if (!parsed) {
        return MS_ERROR_PARSE_FAILED;
    }
    if (!fits) {
        return MS_ERROR_BUFFER_SMALL;
    }
    copy_entries(buf, out_entries);
    return static_cast<int64_t>(buf.size());
}

extern "C"
int64_t ms_build_structural_index_alloc(const char*    data,
                                         uint64_t       length,
                                         MSIndexEntry** out_entries)
{
    *out_entries = nullptr;
    size_t count = 0;
    bool built = with_document(data, length, [&](dom::element doc) {
        // Counting first lets the walk write each entry once, into an array
        // of the final size, instead of growing a vector and copying it.
        count = count_nodes(doc, 0);
        // At least one entry, so the result is always a pointer to free.
        auto* out = static_cast<MSIndexEntry*>(
            std::malloc(std::max<size_t>(1, count) * sizeof(MSIndexEntry)));
        if (!out) {
            return false;
        }
        FixedBuffer buf{out, count};
        walk(doc, buf, /*parent_index=*/-1, /*depth=*/0);
        if (buf.overflowed || buf.used != count) {
            std::free(out);
            return false;
        }
        *out_entries = out;
        return true;
    });
    return built ? static_cast<int64_t>(count) : MS_ERROR_PARSE_FAILED;
}

extern "C"
void ms_free_entries(MSIndexEntry* entries)
{
    std::free(entries);
}
