// MARK: - FormatMetadata

/// Optional format-specific info that doesn't fit the universal DocumentNode model.
public enum FormatMetadata: Sendable, Equatable {
    case json(JSONMetadata)
    case xml(XMLMetadata)
    case yaml(YAMLMetadata)
    case csv(CSVMetadata)
}

// MARK: - JSON

public struct JSONMetadata: Sendable, Equatable {
    public var hasTrailingComma: Bool
    public var hasComments: Bool

    public init(hasTrailingComma: Bool = false, hasComments: Bool = false) {
        self.hasTrailingComma = hasTrailingComma
        self.hasComments = hasComments
    }
}

// MARK: - XML

public struct XMLMetadata: Sendable, Equatable {
    public var namespace: String?
    /// Attributes in document order.
    public var attributes: [(key: String, value: String)]
    public var isSelfClosing: Bool

    public init(
        namespace: String? = nil,
        attributes: [(key: String, value: String)] = [],
        isSelfClosing: Bool = false
    ) {
        self.namespace = namespace
        self.attributes = attributes
        self.isSelfClosing = isSelfClosing
    }

    // Manual Equatable because Swift tuples can't synthesize protocol conformances.
    public static func == (lhs: XMLMetadata, rhs: XMLMetadata) -> Bool {
        lhs.namespace == rhs.namespace &&
        lhs.isSelfClosing == rhs.isSelfClosing &&
        lhs.attributes.count == rhs.attributes.count &&
        zip(lhs.attributes, rhs.attributes).allSatisfy { l, r in
            l.key == r.key && l.value == r.value
        }
    }
}

// MARK: - YAML

public enum YAMLScalarStyle: Sendable, Equatable {
    case plain
    case singleQuoted
    case doubleQuoted
    case literal    // | block
    case folded     // > block
}

public struct YAMLMetadata: Sendable, Equatable {
    public var anchor: String?      // &anchor
    public var alias: String?       // *alias
    public var tag: String?         // !tag
    public var scalarStyle: YAMLScalarStyle

    public init(
        anchor: String? = nil,
        alias: String? = nil,
        tag: String? = nil,
        scalarStyle: YAMLScalarStyle = .plain
    ) {
        self.anchor = anchor
        self.alias = alias
        self.tag = tag
        self.scalarStyle = scalarStyle
    }
}

// MARK: - CSV

public struct CSVMetadata: Sendable, Equatable {
    public var delimiter: Character
    public var hasHeader: Bool
    public var columnIndex: Int

    public init(delimiter: Character = ",", hasHeader: Bool = true, columnIndex: Int = 0) {
        self.delimiter = delimiter
        self.hasHeader = hasHeader
        self.columnIndex = columnIndex
    }
}
