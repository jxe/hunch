import Foundation

/// Custom `AttributedStringKey`s carried on a block's `.text` to encode inline marks
/// (bold, italic, code, strike). These are the editor's source of truth for inline
/// formatting; the host's serializer translates them to whatever surface syntax the
/// pasteboard/disk format uses.
public enum InlineAttributes {
    public enum BoldAttribute: AttributedStringKey {
        public typealias Value = Bool
        public static let name = "Quagmire.Inline.Bold"
    }
    public enum ItalicAttribute: AttributedStringKey {
        public typealias Value = Bool
        public static let name = "Quagmire.Inline.Italic"
    }
    public enum CodeAttribute: AttributedStringKey {
        public typealias Value = Bool
        public static let name = "Quagmire.Inline.Code"
    }
    public enum StrikethroughAttribute: AttributedStringKey {
        public typealias Value = Bool
        public static let name = "Quagmire.Inline.Strikethrough"
    }
}

public extension AttributeContainer {
    var inlineBold: Bool? {
        get { self[InlineAttributes.BoldAttribute.self] }
        set { self[InlineAttributes.BoldAttribute.self] = newValue }
    }
    var inlineItalic: Bool? {
        get { self[InlineAttributes.ItalicAttribute.self] }
        set { self[InlineAttributes.ItalicAttribute.self] = newValue }
    }
    var inlineCode: Bool? {
        get { self[InlineAttributes.CodeAttribute.self] }
        set { self[InlineAttributes.CodeAttribute.self] = newValue }
    }
    var inlineStrikethrough: Bool? {
        get { self[InlineAttributes.StrikethroughAttribute.self] }
        set { self[InlineAttributes.StrikethroughAttribute.self] = newValue }
    }
}
