#ifndef MACHSTRUCTSCANNER_H
#define MACHSTRUCTSCANNER_H

#include <stdint.h>
#include "MachStructBridge.h"   // MS_NODE_TYPE_*

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Byte-level JSON scanning for large files (ADR-002).
//
// Large documents are not indexed node by node: the bytes are the index. One
// validating pass checks the document and finds the root; after that, the
// functions below read a node's children, extent and key straight from the
// bytes. None of them allocates memory in proportion to the document.
//
// Offsets are byte offsets into `data`. Every function except
// ms_json_validate assumes `data` has passed ms_json_validate.
// ---------------------------------------------------------------------------

typedef struct {
    uint64_t root_offset;        ///< First byte of the root value.
    uint64_t root_end;           ///< One past the last byte of the root value.
    uint8_t  root_type;          ///< MS_NODE_TYPE_*
    uint64_t root_child_count;   ///< Members or elements of the root, if a container.
    uint64_t node_count;         ///< Values plus object members in the document.
} MSJSONInfo;

typedef struct {
    uint64_t    offset;          ///< Byte where the problem was found.
    const char* message;         ///< Static English description.
} MSJSONError;

/// Validate `data` as one JSON document (RFC 8259, UTF-8; a leading BOM is
/// skipped). Returns 1 and fills `info` when valid, otherwise 0 and fills
/// `error`. Iterative: any nesting depth is accepted.
int ms_json_validate(const char* data, uint64_t length,
                     MSJSONInfo* info, MSJSONError* error);

/// The children of the object or array whose opening bracket is at `offset`.
/// Writes the start of up to `max` children to `out`: for an object, the
/// offset of each member's key; for an array, of each element. Returns the
/// number of children, which may exceed `max`, and sets `end` (if not NULL)
/// to one past the closing bracket.
uint64_t ms_json_child_offsets(const char* data, uint64_t length, uint64_t offset,
                               uint64_t* out, uint64_t max, uint64_t* end);

typedef struct {
    uint8_t  type;               ///< MS_NODE_TYPE_*
    uint64_t end;                ///< One past the last byte of the value.
    uint64_t child_count;        ///< Members or elements, for a container.
} MSJSONValue;

/// The type, extent and (for a container) child count of the value at
/// `offset`. Counting children reads the whole container.
void ms_json_value_info(const char* data, uint64_t length, uint64_t offset,
                        MSJSONValue* out);

/// One past the last byte of the value at `offset`, without counting.
uint64_t ms_json_value_end(const char* data, uint64_t length, uint64_t offset);

/// For the object member whose key starts at `key_offset`: one past the key's
/// closing quote, and the offset of its value.
void ms_json_member(const char* data, uint64_t length, uint64_t key_offset,
                    uint64_t* key_end, uint64_t* value_offset);

/// A key or scalar the search scan found.
typedef struct {
    uint8_t  is_key;             ///< 1 for an object key, 0 for a scalar value.
    uint64_t offset;             ///< First byte of the token.
    uint64_t end;                ///< One past its last byte.
    uint64_t row_offset;         ///< Where the row showing it starts.
    uint8_t  row_is_member;      ///< 1 when that row is an object member.
} MSJSONToken;

/// Return 0 to stop the scan.
typedef int (*MSJSONVisitor)(void* context, const MSJSONToken* token);

/// Scan the subtree at `offset` (an object member's key when `is_member`,
/// else a value) in document order, calling `visit` for each key and scalar
/// that may contain `needle`. A scalar under an object member is shown on the
/// member's row; any other is its own row.
///
/// `needle` is the lowercased query in UTF-8; a token is skipped only when
/// its bytes show for certain that its text doesn't contain it. Pass a zero
/// length to visit every token.
void ms_json_search(const char* data, uint64_t length, uint64_t offset, int is_member,
                    const char* needle, uint64_t needle_length,
                    MSJSONVisitor visit, void* context);

// ---------------------------------------------------------------------------
// CSV (RFC 4180, as CSVParser reads it)
// ---------------------------------------------------------------------------

typedef struct {
    uint64_t rows;       ///< Rows, not counting blank lines.
    uint64_t fields;     ///< Fields in those rows.
    uint64_t widest;     ///< Most fields in one row.
    int      is_utf8;    ///< 1 when the whole file is valid UTF-8.
} MSCSVInfo;

/// Scan `data` for rows separated by `delimiter`. Writes the start of up to
/// `max` rows to `row_offsets`, skipping lines that hold a single empty
/// field, and fills `info`.
void ms_csv_scan(const char* data, uint64_t length, char delimiter,
                 uint64_t* row_offsets, uint64_t max, MSCSVInfo* info);

/// The fields of the row starting at `row_offset`: writes the raw extent of
/// up to `max` fields (a quoted field includes its quotes) and returns how
/// many there are. `row_end`, if not NULL, is set to one past the row's last
/// field, before its line ending.
uint64_t ms_csv_fields(const char* data, uint64_t length, char delimiter, uint64_t row_offset,
                       uint64_t* starts, uint64_t* ends, uint64_t max, uint64_t* row_end);

/// A field the CSV search scan found.
typedef struct {
    uint64_t row;        ///< Where its row starts.
    uint64_t start;      ///< First byte of the field (its opening quote, if quoted).
    uint64_t end;        ///< One past its last byte.
    uint64_t column;     ///< Its position in the row.
} MSCSVField;

/// Return 0 to stop the scan.
typedef int (*MSCSVVisitor)(void* context, const MSCSVField* field);

/// Visit each field of the rows from `row_offset` that may contain `needle`
/// (the lowercased query in UTF-8) once read as CSVParser reads it, and every field in a
/// column marked in `columns` (one byte per column, nonzero to visit). A
/// field is skipped only when its bytes are its text for certain: unquoted
/// ASCII that isn't a number needing reformatting. Pass a zero-length needle
/// to visit every field.
///
/// Scans `row_count` rows from the one at `row_offset`, skipping blank lines
/// as ms_csv_scan does.
void ms_csv_search_rows(const char* data, uint64_t length, char delimiter,
                        uint64_t row_offset, uint64_t row_count,
                        const char* needle, uint64_t needle_length,
                        const uint8_t* columns, uint64_t column_count,
                        MSCSVVisitor visit, void* context);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // MACHSTRUCTSCANNER_H
