import Quagmire
import Testing

@Suite("Quagmire configuration")
struct EditorConfigurationTests {
    @Test func defaultsAreHostNeutral() {
        let configuration = EditorConfiguration()

        #expect(configuration.theme.bodyFontFamily == nil)
        #expect(configuration.isAudioFeedbackEnabled == false)
        #expect(configuration.isHapticFeedbackEnabled == false)
        #expect(configuration.loggingSubsystem == nil)
    }

    @Test func inlineAttributeNamesArePackageOwned() {
        #expect(InlineAttributes.BoldAttribute.name == "Quagmire.Inline.Bold")
        #expect(InlineAttributes.ItalicAttribute.name == "Quagmire.Inline.Italic")
        #expect(InlineAttributes.CodeAttribute.name == "Quagmire.Inline.Code")
        #expect(InlineAttributes.StrikethroughAttribute.name == "Quagmire.Inline.Strikethrough")
    }
}
