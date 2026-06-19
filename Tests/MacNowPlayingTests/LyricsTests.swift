import XCTest
@testable import MacNowPlaying

final class LyricsTests: XCTestCase {

    // MARK: - parseLRC

    func testParsesBasicTimestamps() {
        let lines = LRCLIB.parseLRC("[00:12.33] Hello\n[01:05.50] World")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].time, 12.33, accuracy: 0.001)
        XCTAssertEqual(lines[0].text, "Hello")
        XCTAssertEqual(lines[1].time, 65.50, accuracy: 0.001)   // 1:05.50 → 65.5s
        XCTAssertEqual(lines[1].text, "World")
    }

    func testExpandsMultipleTimestampsOnOneLine() {
        // A line can carry several timestamps; each becomes its own entry.
        let lines = LRCLIB.parseLRC("[00:01.00][00:05.00] yo")
        XCTAssertEqual(lines.map(\.time), [1.0, 5.0])
        XCTAssertEqual(Set(lines.map(\.text)), ["yo"])
    }

    func testSortsByTime() {
        let lines = LRCLIB.parseLRC("[00:30.00] late\n[00:05.00] early")
        XCTAssertEqual(lines.map(\.text), ["early", "late"])
    }

    func testTimestampWithNoTextYieldsEmptyLine() {
        // Instrumental break: a bare timestamp → empty text (rendered as ♪), no crash.
        let lines = LRCLIB.parseLRC("[00:10.00]")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].time, 10.0, accuracy: 0.001)
        XCTAssertEqual(lines[0].text, "")
    }

    func testSkipsLinesWithoutTimestamps() {
        // Metadata / untimed lines are ignored.
        let lines = LRCLIB.parseLRC("[ar: Some Artist]\nplain text\n[00:03.00] kept")
        XCTAssertEqual(lines.map(\.text), ["kept"])
    }

    func testEmptyInputYieldsNoLines() {
        XCTAssertTrue(LRCLIB.parseLRC("").isEmpty)
    }

    // MARK: - normalizedArtist

    func testStripsTrailingKoreanParenthetical() {
        XCTAssertEqual(LRCLIB.normalizedArtist("EVERGLOW (에버글로우)"), "EVERGLOW")
        XCTAssertEqual(LRCLIB.normalizedArtist("IZ*ONE (아이즈원)"), "IZ*ONE")
    }

    func testLeavesPlainArtistUntouched() {
        XCTAssertEqual(LRCLIB.normalizedArtist("BTS"), "BTS")
        XCTAssertEqual(LRCLIB.normalizedArtist("Daft Punk"), "Daft Punk")
    }

    func testDoesNotReduceToEmpty() {
        // If stripping would leave nothing, keep the original.
        XCTAssertEqual(LRCLIB.normalizedArtist("(에버글로우)"), "(에버글로우)")
    }

    // MARK: - simplifiedTitle

    func testSimplifiedTitleStripsKoreanSubtitle() {
        XCTAssertEqual(LRCLIB.simplifiedTitle("하늘 위로 Up"), "Up")
        XCTAssertEqual(LRCLIB.simplifiedTitle("사랑 (Love)"), "Love")
    }

    func testSimplifiedTitleLeavesEnglishUntouched() {
        XCTAssertEqual(LRCLIB.simplifiedTitle("DUN DUN"), "DUN DUN")
    }

    func testSimplifiedTitleEmptyForPureHangul() {
        XCTAssertEqual(LRCLIB.simplifiedTitle("안녕"), "")
    }

    // MARK: - containsHangul

    func testDetectsHangul() {
        XCTAssertTrue(LRCLIB.containsHangul([LyricLine(time: 0, text: "안녕하세요")]))
    }

    func testRomanizedIsNotHangul() {
        XCTAssertFalse(LRCLIB.containsHangul([LyricLine(time: 0, text: "annyeong haseyo")]))
        XCTAssertFalse(LRCLIB.containsHangul([LyricLine(time: 0, text: "Yeah, EVERGLOW (whoo)")]))
    }

    // MARK: - NowPlaying

    func testTrackKeyExcludesDuration() {
        let a = NowPlaying(title: "Song", artist: "Band", album: "X",
                           duration: 180, elapsed: 0, timestamp: 0, isPlaying: true, rate: 1)
        let b = NowPlaying(title: "Song", artist: "Band", album: "X",
                           duration: 999, elapsed: 0, timestamp: 0, isPlaying: true, rate: 1)
        XCTAssertEqual(a.trackKey, b.trackKey)   // duration must not affect identity
        XCTAssertEqual(a.trackKey, "Band|Song")
    }

    func testIsValidRequiresArtistAndTitle() {
        func np(_ artist: String, _ title: String) -> NowPlaying {
            NowPlaying(title: title, artist: artist, album: "", duration: 0,
                       elapsed: 0, timestamp: 0, isPlaying: true, rate: 1)
        }
        XCTAssertTrue(np("Band", "Song").isValid)
        XCTAssertFalse(np("", "Song").isValid)
        XCTAssertFalse(np("Band", "").isValid)
    }
}
