#ifndef MACHSTRUCTBRIDGE_H
#define MACHSTRUCTBRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Node type codes (per PARSING-ENGINE.md §4)
// JSON-level types — JSONParser (P1-06) maps these to DocumentNode.NodeType.
// ---------------------------------------------------------------------------
#define MS_NODE_TYPE_OBJECT  0   // maps to NodeType.object
#define MS_NODE_TYPE_ARRAY   1   // maps to NodeType.array
#define MS_NODE_TYPE_STRING  2   // maps to NodeType.scalar(.string)
#define MS_NODE_TYPE_NUMBER  3   // maps to NodeType.scalar(.integer / .float)
#define MS_NODE_TYPE_BOOL    4   // maps to NodeType.scalar(.boolean)
#define MS_NODE_TYPE_NULL    5   // maps to NodeType.scalar(.null)

// ---------------------------------------------------------------------------
// Return / error codes
// ---------------------------------------------------------------------------
#define MS_ERROR_PARSE_FAILED  ((int64_t)-1)
#define MS_ERROR_BUFFER_SMALL  ((int64_t)-2)

// ---------------------------------------------------------------------------
// MSIndexEntry — one entry per JSON node in the structural index.
//
// Object-key strings are represented as STRING entries whose parent is the
// enclosing OBJECT and whose single child is the associated value entry.
// JSONParser (P1-06) converts these (key, value) pairs into .keyValue nodes.
// ---------------------------------------------------------------------------
typedef struct {
    uint64_t byte_offset;    ///< Start byte of this node in the original JSON (0 = unknown for Phase 1)
    uint32_t byte_length;    ///< Byte length of this node's raw JSON (0 = unknown for containers in Phase 1)
    uint8_t  node_type;      ///< One of MS_NODE_TYPE_*
    uint16_t depth;          ///< Nesting depth (root = 0)
    int64_t  parent_index;   ///< Index into this same flat array; -1 for root
    uint32_t child_count;    ///< Number of direct children (objects/arrays only)
} MSIndexEntry;

// ---------------------------------------------------------------------------
// ms_build_structural_index
//
// Parse `data` (length bytes of JSON) using simdjson and populate `out_entries`
// with a flat structural index.
//
// @param data         Pointer to JSON bytes. Need not be null-terminated.
//                     simdjson makes an internal padded copy if required.
// @param length       Byte count of `data`.
// @param out_entries  Caller-allocated output buffer.
// @param max_entries  Capacity of `out_entries`.
//
// @return  Number of entries written on success.
//          MS_ERROR_PARSE_FAILED  if the JSON is invalid.
//          MS_ERROR_BUFFER_SMALL  if the output buffer is too small.
// ---------------------------------------------------------------------------
int64_t ms_build_structural_index(
    const char*   data,
    uint64_t      length,
    MSIndexEntry* out_entries,
    uint64_t      max_entries
);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // MACHSTRUCTBRIDGE_H
