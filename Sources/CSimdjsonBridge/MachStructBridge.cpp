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
// Recursive DOM walk.
//
// my_idx is the index of the current node's placeholder in `buf`; after all
// children are pushed, we update buf[my_idx].child_count in-place.
// ---------------------------------------------------------------------------
static void walk(dom::element el,
                 std::vector<FlatEntry>& buf,
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
                0,                          // byte_offset — TODO in P1-06
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
extern "C"
int64_t ms_build_structural_index(const char*   data,
                                   uint64_t      length,
                                   MSIndexEntry* out_entries,
                                   uint64_t      max_entries)
{
    // padded_string makes an internal copy with SIMDJSON_PADDING trailing bytes,
    // which is required by simdjson regardless of whether the input is already padded.
    simdjson::padded_string ps(data, static_cast<size_t>(length));

    dom::parser parser;
    dom::element doc;
    if (parser.parse(ps).get(doc)) {
        return MS_ERROR_PARSE_FAILED;
    }

    // Initial reserve — conservative estimate to avoid excessive reallocations.
    // Capped at 500 000 to avoid huge up-front allocations for large files.
    std::vector<FlatEntry> buf;
    buf.reserve(std::min(static_cast<size_t>(length / 8),
                         static_cast<size_t>(500'000)));

    walk(doc, buf, /*parent_index=*/-1, /*depth=*/0);

    if (static_cast<uint64_t>(buf.size()) > max_entries) {
        return MS_ERROR_BUFFER_SMALL;
    }

    const size_t n = buf.size();
    for (size_t i = 0; i < n; ++i) {
        out_entries[i].byte_offset   = buf[i].byte_offset;
        out_entries[i].byte_length   = buf[i].byte_length;
        out_entries[i].node_type     = buf[i].node_type;
        out_entries[i].depth         = buf[i].depth;
        out_entries[i].parent_index  = buf[i].parent_index;
        out_entries[i].child_count   = buf[i].child_count;
    }

    return static_cast<int64_t>(n);
}
