import XCTest
@testable import MacNowPlaying

/// Pure-helper tests for the iTunes cover resolver. The network call (`coverURL`) is
/// not exercised here — only the deterministic matching/normalization logic.
final class ArtworkTests: XCTestCase {

    // MARK: - normalizeSearchTerm

    func testNormalizeStripsDiacriticsAndPunctuation() {
        XCTAssertEqual(Artwork.normalizeSearchTerm("Café del Mar!"), "cafe del mar")
        XCTAssertEqual(Artwork.normalizeSearchTerm("Beyoncé"), "beyonce")
    }

    func testNormalizeCollapsesWhitespaceAndLowercases() {
        XCTAssertEqual(Artwork.normalizeSearchTerm("  Hello   WORLD  "), "hello world")
    }

    func testNormalizeTurnsPunctuationIntoSpaces() {
        // Punctuation becomes a separator, not a deletion — words stay split.
        XCTAssertEqual(Artwork.normalizeSearchTerm("Up&Down"), "up down")
    }

    // MARK: - primaryArtist (consolidated lead-artist extractor, shared with lyrics)

    func testGetFirstArtistSplitsOnFeat() {
        XCTAssertEqual(LRCLIB.primaryArtist("A feat. B"), "A")
        XCTAssertEqual(LRCLIB.primaryArtist("A ft. B"), "A")
        XCTAssertEqual(LRCLIB.primaryArtist("A featuring B"), "A")
    }

    func testGetFirstArtistSplitsOnSeparators() {
        XCTAssertEqual(LRCLIB.primaryArtist("A, B"), "A")
        XCTAssertEqual(LRCLIB.primaryArtist("A & B"), "A")
        XCTAssertEqual(LRCLIB.primaryArtist("A x B"), "A")
    }

    func testGetFirstArtistKeepsSoloName() {
        XCTAssertEqual(LRCLIB.primaryArtist("Florence"), "Florence")
    }

    // MARK: - matchesResult

    func testMatchesExactArtistAndTitle() {
        XCTAssertTrue(Artwork.matchesResult(
            artist: "YOUHA", title: "Last Dance",
            resultArtist: "YOUHA", resultTitle: "Last Dance"))
    }

    func testMatchesWhenResultArtistContainsOurs() {
        // Our credit is the lead act; the result lists the full collaboration.
        XCTAssertTrue(Artwork.matchesResult(
            artist: "YOUHA", title: "Last Dance",
            resultArtist: "YOUHA feat. Someone", resultTitle: "Last Dance"))
    }

    func testMatchesOnSharedLongWord() {
        XCTAssertTrue(Artwork.matchesResult(
            artist: "The Beatles", title: "Hey Jude",
            resultArtist: "Beatles", resultTitle: "Hey Jude (Remastered)"))
    }

    func testRejectsWrongArtist() {
        XCTAssertFalse(Artwork.matchesResult(
            artist: "Adele", title: "Hello",
            resultArtist: "Lionel Richie", resultTitle: "Hello"))
    }

    func testRejectsWrongTitle() {
        XCTAssertFalse(Artwork.matchesResult(
            artist: "Adele", title: "Hello",
            resultArtist: "Adele", resultTitle: "Skyfall"))
    }

    // MARK: - firstYouTubeVideoID (pure helper)

    func testFirstYouTubeVideoIDExtractsKnownID() {
        let html = #"...{"videoRenderer":{"videoId":"dQw4w9WgXcQ","thumbnail":...}}..."#
        XCTAssertEqual(Artwork.firstYouTubeVideoID(inResultsHTML: html), "dQw4w9WgXcQ")
    }

    func testFirstYouTubeVideoIDReturnsFirstOfMany() {
        let html = #""videoId":"aaaaaaaaaaa" then later "videoId":"bbbbbbbbbbb""#
        XCTAssertEqual(Artwork.firstYouTubeVideoID(inResultsHTML: html), "aaaaaaaaaaa")
    }

    func testFirstYouTubeVideoIDReturnsNilWhenAbsent() {
        XCTAssertNil(Artwork.firstYouTubeVideoID(inResultsHTML: "<html>no ids here</html>"))
        // A wrong-length token (10 chars) must not match the 11-char id pattern.
        XCTAssertNil(Artwork.firstYouTubeVideoID(inResultsHTML: #""videoId":"shorttoken""#))
    }
}
