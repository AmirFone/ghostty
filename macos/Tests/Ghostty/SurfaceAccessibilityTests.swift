//
//  SurfaceAccessibilityTests.swift
//  GhosttyTests
//
//  Tests for the accessibility view of a terminal surface, which has to keep
//  the value, the length and the selected range describing one string in one
//  unit (UTF-16 offsets).
//

import Testing
import AppKit
@testable import Ghostty

private typealias Snapshot = Ghostty.SurfaceView.AccessibilitySnapshot

struct SurfaceAccessibilitySnapshotTests {
    /// The selected range must point at the selected text, because VoiceOver
    /// reads the value at that range rather than the selection string.
    @Test func testSelectedRangeLocatesSelection() async throws {
        let snapshot = Snapshot(
            string: "first line\nsecond line\nthird line",
            selectedText: "second"
        )

        #expect(snapshot.selectedRange == NSRange(location: 11, length: 6))
        #expect(snapshot.substring(for: snapshot.selectedRange) == "second")
    }

    /// A multi-line selection is still a contiguous substring of the value.
    @Test func testSelectedRangeSpanningLines() async throws {
        let snapshot = Snapshot(
            string: "alpha\nbravo\ncharlie",
            selectedText: "bravo\ncharlie"
        )

        #expect(snapshot.substring(for: snapshot.selectedRange) == "bravo\ncharlie")
    }

    /// With no selection the range must still be in bounds. An out-of-bounds
    /// range is what makes VoiceOver fall back to announcing the whole value.
    @Test func testNoSelectionGivesInBoundsEmptyRange() async throws {
        let snapshot = Snapshot(string: "some terminal output", selectedText: nil)

        #expect(snapshot.selectedRange.length == 0)
        #expect(snapshot.selectedRange.location >= 0)
        #expect(snapshot.selectedRange.location <= snapshot.length)
    }

    /// A selection that scrolled out of the viewport isn't in the value, so the
    /// range has to degrade to something in bounds rather than to garbage.
    @Test func testSelectionNotInViewportGivesInBoundsRange() async throws {
        let snapshot = Snapshot(string: "visible text", selectedText: "scrolled away")

        #expect(snapshot.selectedRange.length == 0)
        #expect(snapshot.selectedRange.location + snapshot.selectedRange.length <= snapshot.length)
    }

    /// The cell offset hint picks between repeated occurrences of the same text.
    @Test func testHintDisambiguatesRepeatedSelection() async throws {
        let string = "make\nmake\nmake"

        let first = Snapshot(string: string, selectedText: "make", selectionHint: 0)
        let last = Snapshot(string: string, selectedText: "make", selectionHint: 10)

        #expect(first.selectedRange.location == 0)
        #expect(last.selectedRange.location == 10)
    }

    /// Lengths are UTF-16 code units. Counting characters instead desynchronizes
    /// every offset as soon as the terminal shows an emoji or CJK text.
    @Test func testLengthCountsUTF16CodeUnits() async throws {
        let snapshot = Snapshot(string: "a👻b", selectedText: nil)

        #expect(snapshot.length == 4)
        #expect(snapshot.length == ("a👻b" as NSString).length)
    }

    /// Offsets stay consistent past a non-BMP character.
    @Test func testSelectionAfterEmojiUsesUTF16Offsets() async throws {
        let snapshot = Snapshot(string: "👻 ghostty", selectedText: "ghostty")

        #expect(snapshot.selectedRange == NSRange(location: 3, length: 7))
        #expect(snapshot.substring(for: snapshot.selectedRange) == "ghostty")
    }

    @Test func testLineForIndex() async throws {
        let snapshot = Snapshot(string: "one\ntwo\nthree", selectedText: nil)

        #expect(snapshot.lineCount == 3)
        #expect(snapshot.line(for: 0) == 0)
        #expect(snapshot.line(for: 3) == 0)
        #expect(snapshot.line(for: 4) == 1)
        #expect(snapshot.line(for: 8) == 2)
    }

    @Test func testRangeForLine() async throws {
        let snapshot = Snapshot(string: "one\ntwo\nthree", selectedText: nil)

        #expect(snapshot.substring(for: snapshot.range(forLine: 0)) == "one\n")
        #expect(snapshot.substring(for: snapshot.range(forLine: 1)) == "two\n")
        #expect(snapshot.substring(for: snapshot.range(forLine: 2)) == "three")
        #expect(snapshot.range(forLine: 3).location == NSNotFound)
    }

    /// A terminal viewport usually ends in a newline. That newline closes the
    /// last line, it doesn't open an extra empty one for VoiceOver to land on.
    @Test func testTrailingNewlineDoesNotAddLine() async throws {
        let snapshot = Snapshot(string: "one\ntwo\n", selectedText: nil)

        #expect(snapshot.lineCount == 2)
    }

    @Test func testSubstringRejectsOutOfBoundsRange() async throws {
        let snapshot = Snapshot(string: "short", selectedText: nil)

        #expect(snapshot.substring(for: NSRange(location: 0, length: 99)) == nil)
        #expect(snapshot.substring(for: NSRange(location: 99, length: 1)) == nil)
        #expect(snapshot.substring(for: NSRange(location: NSNotFound, length: 0)) == nil)
    }

    /// A selection can start above the viewport when the user scrolls. The core
    /// still reports the whole selection, so the visible tail is what VoiceOver
    /// should land on.
    @Test func testSelectionClippedAtTop() async throws {
        let snapshot = Snapshot(
            string: "line3\nline4\nline5",
            selectedText: "line1\nline2\nline3\nline4"
        )

        #expect(snapshot.substring(for: snapshot.selectedRange) == "line3\nline4")
    }

    /// The same in the other direction, where the selection continues below the
    /// bottom of the viewport.
    @Test func testSelectionClippedAtBottom() async throws {
        let snapshot = Snapshot(
            string: "line1\nline2\nline3",
            selectedText: "line2\nline3\nline4\nline5"
        )

        #expect(snapshot.substring(for: snapshot.selectedRange) == "line2\nline3")
    }

    /// When the selection is larger than the viewport in both directions every
    /// visible character really is selected.
    @Test func testSelectionCoversWholeViewport() async throws {
        let viewport = "line3\nline4"
        let snapshot = Snapshot(
            string: viewport,
            selectedText: "line1\nline2\nline3\nline4\nline5"
        )

        #expect(snapshot.selectedRange == NSRange(location: 0, length: (viewport as NSString).length))
    }

    @Test func testEmptySnapshot() async throws {
        let snapshot = Snapshot.empty

        #expect(snapshot.length == 0)
        #expect(snapshot.string.isEmpty)
        #expect(snapshot.selectedText == nil)
        #expect(snapshot.selectedRange == NSRange(location: 0, length: 0))
        #expect(snapshot.line(for: 0) == 0)
    }
}
