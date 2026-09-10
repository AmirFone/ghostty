import AppKit
import GhosttyKit

extension Ghostty.SurfaceView {
    /// One coherent view of the terminal text for accessibility clients.
    ///
    /// AppKit expects `AXValue`, `AXNumberOfCharacters`, `AXSelectedTextRange`,
    /// `AXLineForIndex` and friends to describe the same string in the same
    /// units (UTF-16 offsets). When they disagree, VoiceOver cannot resolve the
    /// selection against the value it was handed and falls back to announcing
    /// the entire value, so the whole terminal is read aloud instead of the
    /// selection.
    ///
    /// Every accessibility answer is therefore derived here from a single
    /// capture. Taking the value and the selection together also removes the
    /// race where the selection moves between the two reads.
    struct AccessibilitySnapshot {
        /// The text a screen reader reads. This is the visible viewport rather
        /// than the whole scrollback: a screen reader should describe what is
        /// on screen, and announcing thousands of scrollback lines is what made
        /// the terminal unusable with VoiceOver.
        let string: String

        /// The selection as it existed when `string` was captured.
        let selectedText: String?

        /// The location of `selectedText` within `string`, in UTF-16 offsets.
        /// Empty (but always in bounds) when nothing is selected.
        let selectedRange: NSRange

        /// UTF-16 offset at which each line begins.
        private let lineStarts: [Int]

        /// Length in UTF-16 code units, the unit AppKit accessibility uses.
        /// Swift's `String.count` counts grapheme clusters instead, which
        /// desynchronizes every offset as soon as the terminal shows an emoji,
        /// CJK text or a combining mark.
        let length: Int

        static let empty = AccessibilitySnapshot(string: "", selectedText: nil)

        init(string: String, selectedText: String?, selectionHint: Int? = nil) {
            self.string = string
            self.length = string.utf16.count
            self.selectedText = selectedText

            var starts: [Int] = [0]
            var offset = 0
            for unit in string.utf16 {
                offset += 1
                if unit == 0x0A { starts.append(offset) }
            }
            // A trailing newline ends the last line, it does not begin a new
            // one that anything can navigate to.
            if starts.count > 1 && starts[starts.count - 1] == self.length {
                starts.removeLast()
            }
            self.lineStarts = starts

            self.selectedRange = Self.range(
                ofSelection: selectedText,
                in: string,
                near: selectionHint
            ) ?? NSRange(location: 0, length: 0)
        }

        var lineCount: Int { lineStarts.count }

        /// The line containing a UTF-16 offset.
        func line(for index: Int) -> Int {
            guard index > 0 else { return 0 }
            var low = 0
            var high = lineStarts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if lineStarts[mid] <= index {
                    low = mid
                } else {
                    high = mid - 1
                }
            }
            return low
        }

        func range(forLine line: Int) -> NSRange {
            guard line >= 0, line < lineStarts.count else {
                return NSRange(location: NSNotFound, length: 0)
            }
            let start = lineStarts[line]
            let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : length
            return NSRange(location: start, length: end - start)
        }

        func substring(for range: NSRange) -> String? {
            guard range.location != NSNotFound,
                  range.location >= 0,
                  range.length >= 0,
                  range.location + range.length <= length,
                  let swiftRange = Range(range, in: string)
            else { return nil }
            return String(string[swiftRange])
        }

        /// Locate the selection within the accessibility text.
        ///
        /// Ghostty core reports a selection as a cell offset into the padded
        /// viewport grid (`row * columns + column`). That is a different
        /// coordinate space than this string, where soft-wrapped rows are
        /// joined without a newline and a row is therefore not a fixed number
        /// of characters. Inverting it would mean reimplementing the core's
        /// wrapping rules here and keeping them in sync.
        ///
        /// Instead we search for the selection text itself. The core produces
        /// the selection and the viewport with the same formatter settings, so
        /// a visible selection is always an exact substring, and the cell
        /// offset is only needed to choose between repeated occurrences.
        private static func range(
            ofSelection selection: String?,
            in string: String,
            near hint: Int?
        ) -> NSRange? {
            guard let selection, !selection.isEmpty else { return nil }

            if let exact = search(for: selection, in: string, near: hint) {
                return exact
            }

            // The selection isn't on screen in one piece. The core hands us the
            // whole selection even when the viewport shows only part of it, so
            // fall back to the largest piece that is actually visible.
            return visiblePortion(of: selection, in: string, near: hint)
        }

        /// The visible part of a selection that runs past the edge of the viewport.
        private static func visiblePortion(
            of selection: String,
            in string: String,
            near hint: Int?
        ) -> NSRange? {
            // The selection swallows the viewport whole, so all of it is selected.
            if !string.isEmpty, selection.contains(string) {
                return NSRange(location: 0, length: (string as NSString).length)
            }

            let lines = selection.components(separatedBy: "\n")
            guard lines.count > 1 else { return nil }

            // At most a viewport's worth of the selection can be showing, which
            // bounds how much we have to try trimming.
            let viewportLines = string.components(separatedBy: "\n").count
            let maxDrop = min(lines.count - 1, viewportLines)

            // Clipped at the top: the end of the selection is what's on screen.
            for drop in 1...maxDrop {
                let candidate = lines[drop...].joined(separator: "\n")
                if !candidate.isEmpty,
                   let found = search(for: candidate, in: string, near: hint) {
                    return found
                }
            }

            // Clipped at the bottom: the start of the selection is what's on screen.
            for drop in 1...maxDrop {
                let candidate = lines[..<(lines.count - drop)].joined(separator: "\n")
                if !candidate.isEmpty,
                   let found = search(for: candidate, in: string, near: hint) {
                    return found
                }
            }

            return nil
        }

        /// The occurrence of `needle` closest to `hint`, or the first one when
        /// there is no hint.
        private static func search(
            for needle: String,
            in string: String,
            near hint: Int?
        ) -> NSRange? {
            let haystack = string as NSString
            var searchRange = NSRange(location: 0, length: haystack.length)
            var best: NSRange?
            var bestDistance = Int.max

            while searchRange.length > 0 {
                let found = haystack.range(of: needle, options: .literal, range: searchRange)
                guard found.location != NSNotFound else { break }

                guard let hint else { return found }

                let distance = abs(found.location - hint)
                if distance < bestDistance {
                    bestDistance = distance
                    best = found
                }

                let next = found.location + 1
                guard next < haystack.length else { break }
                searchRange = NSRange(location: next, length: haystack.length - next)
            }

            return best
        }
    }
}

// MARK: Snapshot Capture

extension Ghostty.SurfaceView {
    /// Read the viewport and the selection from the surface as one unit.
    func captureAccessibilitySnapshot() -> AccessibilitySnapshot {
        guard let surface = self.surface else { return .empty }

        // The viewport, not the full screen. `GHOSTTY_POINT_SCREEN` spans the
        // scrollback, and handing a screen reader thousands of lines of history
        // as the value of the terminal is what caused it to read the entire
        // buffer aloud.
        var viewport = ghostty_text_s()
        let viewportSelection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, viewportSelection, &viewport) else {
            return .empty
        }
        defer { ghostty_surface_free_text(surface, &viewport) }
        let string = String(cString: viewport.text)

        // The selection, if any. Read from the same surface without releasing
        // control in between, so it describes the same viewport we just read.
        var selection = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &selection) else {
            return .init(string: string, selectedText: nil)
        }
        defer { ghostty_surface_free_text(surface, &selection) }

        let selectedText = String(cString: selection.text)
        guard !selectedText.isEmpty else {
            return .init(string: string, selectedText: nil)
        }

        return .init(
            string: string,
            selectedText: selectedText,
            selectionHint: accessibilityOffsetHint(forCell: Int(selection.offset_start))
        )
    }

    /// Approximate where a viewport cell offset lands in the accessibility text.
    ///
    /// The core reports `row * columns + column`, counting every row as exactly
    /// `columns` cells. The accessibility text instead separates rows with a
    /// newline and joins soft-wrapped rows with nothing at all, so the two only
    /// line up when no row wraps. That is close enough for its one job: telling
    /// repeated occurrences of the same selected text apart.
    private func accessibilityOffsetHint(forCell offset: Int) -> Int? {
        guard let surface = self.surface else { return nil }
        let columns = Int(ghostty_surface_size(surface).columns)
        guard columns > 0 else { return nil }
        return offset + (offset / columns)
    }
}

// MARK: Accessibility

extension Ghostty.SurfaceView {
    /// Indicates that this view should be exposed to accessibility tools like VoiceOver.
    override func isAccessibilityElement() -> Bool {
        return true
    }

    /// Defines the accessibility role for this view, which helps assistive technologies
    /// understand what kind of content this view contains and how users can interact with it.
    override func accessibilityRole() -> NSAccessibility.Role? {
        /// We use .textArea because the terminal surface is essentially an editable text area
        /// where users can input commands and view output.
        return .textArea
    }

    override func accessibilityHelp() -> String? {
        return "Terminal content area"
    }

    override func accessibilityValue() -> Any? {
        return accessibilitySnapshot.get().string
    }

    override func accessibilityNumberOfCharacters() -> Int {
        return accessibilitySnapshot.get().length
    }

    /// The terminal shows its whole viewport at once, so every character of the
    /// accessibility value is visible.
    override func accessibilityVisibleCharacterRange() -> NSRange {
        return NSRange(location: 0, length: accessibilitySnapshot.get().length)
    }

    /// Returns the currently selected text as a string.
    override func accessibilitySelectedText() -> String? {
        return accessibilitySnapshot.get().selectedText
    }

    /// Returns the range of text that is currently selected, as an offset into
    /// the accessibility value.
    ///
    /// This must stay in bounds even with no selection. An out-of-bounds or
    /// unresolvable range is what makes VoiceOver give up and read the entire
    /// terminal instead of the selection.
    override func accessibilitySelectedTextRange() -> NSRange {
        return accessibilitySnapshot.get().selectedRange
    }

    override func accessibilityInsertionPointLineNumber() -> Int {
        let snapshot = accessibilitySnapshot.get()
        return snapshot.line(for: snapshot.selectedRange.location)
    }

    override func accessibilityLine(for index: Int) -> Int {
        return accessibilitySnapshot.get().line(for: index)
    }

    override func accessibilityRange(forLine line: Int) -> NSRange {
        return accessibilitySnapshot.get().range(forLine: line)
    }

    override func accessibilityString(for range: NSRange) -> String? {
        return accessibilitySnapshot.get().substring(for: range)
    }

    /// Returns an attributed string for the given range.
    ///
    /// Note: right now this only applies font information. One day it'd be nice to extend
    /// this to copy styling information as well but we need to augment Ghostty core to
    /// expose that.
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let surface = self.surface else { return nil }
        guard let plainString = accessibilityString(for: range) else { return nil }

        var attributes: [NSAttributedString.Key: Any] = [:]

        // Try to get the font from the surface
        if let fontRaw = ghostty_surface_quicklook_font(surface) {
            let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
            attributes[.font] = font.takeUnretainedValue()
            font.release()
        }

        return NSAttributedString(string: plainString, attributes: attributes)
    }
}
