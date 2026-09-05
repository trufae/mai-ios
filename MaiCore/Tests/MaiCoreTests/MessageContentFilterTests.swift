import Testing

@testable import MaiCore

@Test("Markdown notification text uses the portable plain-text fallback")
func markdownPlainTextUsesPortableFallback() {
  let markdown = "# Heading\n- **Bold** [link](https://example.com)\n`code` and ~~old~~"

  #expect(MessageContentFilter.markdownPlainText(from: markdown) == "Heading\nBold link\ncode and old")
}
