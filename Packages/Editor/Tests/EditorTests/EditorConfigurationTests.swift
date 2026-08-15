import Editor
import Testing

@Suite("Editor configuration")
struct EditorConfigurationTests {
    @Test func defaultsAreHostNeutral() {
        let configuration = EditorConfiguration()

        #expect(configuration.theme.bodyFontFamily == nil)
        #expect(configuration.isAudioFeedbackEnabled == false)
        #expect(configuration.isHapticFeedbackEnabled == false)
        #expect(configuration.loggingSubsystem == nil)
    }

    @Test func inlineAttributeNamesAreEditorOwned() {
        #expect(InlineAttributes.BoldAttribute.name == "Editor.Inline.Bold")
        #expect(InlineAttributes.ItalicAttribute.name == "Editor.Inline.Italic")
        #expect(InlineAttributes.CodeAttribute.name == "Editor.Inline.Code")
        #expect(InlineAttributes.StrikethroughAttribute.name == "Editor.Inline.Strikethrough")
    }
}
