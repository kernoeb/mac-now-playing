import SwiftUI

/// The karaoke overlay: current line bright & sharp, neighbors smaller,
/// dimmer and blurrier as they recede; lines spring upward as the song plays.
struct LyricsView: View {
    @EnvironmentObject var model: PlayerModel

    // Tweak these to restyle. design: .default (SF Pro) reads cleaner than .rounded;
    // try .serif (New York) for a classier look or .monospaced for something techy.
    private let fontDesign: Font.Design = .default
    private let currentSize: CGFloat = 30
    private let neighborSize: CGFloat = 19

    // Fills the window height (see main.swift). The current line sits low — one row
    // up from the bottom — so the already-sung line shows above and the UPCOMING
    // line shows below it, with that lower line still clearing the Dock.
    private let windowHeight: CGFloat = 180
    private let rowHeight: CGFloat = 54
    // Centre of the current line, measured up from the bottom edge. MUST match
    // AppDelegate.currentLineFromBottom (the scroll band is placed there). One row
    // (54) + half a row leaves the upcoming line fully visible underneath.
    private let currentLineFromBottom: CGFloat = 78

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(model.isHovering ? 1.0 : 0.62)
            .animation(.easeInOut(duration: 0.25), value: model.isHovering)
            .overlay(alignment: .bottom) { if model.isHovering { syncReadout } }
    }

    /// Sync calibration HUD, shown only while hovering: scroll to adjust.
    private var syncReadout: some View {
        Text(String(format: "sync %+.2fs · scroll to adjust", model.syncOffset))
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(.black.opacity(0.45), in: Capsule())
            .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
            .padding(.bottom, 6)
    }

    @ViewBuilder
    private var content: some View {
        if !model.isPlaying {
            Color.clear            // paused / stopped / finished → overlay disappears
        } else if model.lines.isEmpty {
            if model.isFetching {
                loadingIndicator  // looking up lyrics (distinct from "no match found")
            } else {
                Color.clear        // playing but no synced lyrics exist → stay invisible
            }
        } else {
            // -1 before the first line starts: line 0 then sits just below the
            // bottom edge and springs up into place the moment it begins.
            let cur = model.currentIndex
            // Offset so the current line sits `currentLineFromBottom` up from the box
            // bottom; animating this translates the whole stack upward (real motion,
            // not a cross-fade). A fixed-size Color.clear sizes the box; the stack is
            // pinned to its TOP and shifted by `offset`, overflowing + clipped.
            let offset = (windowHeight - currentLineFromBottom)
                - (CGFloat(cur) * rowHeight + rowHeight / 2)

            Color.clear
                .frame(height: windowHeight)
                .overlay(alignment: .top) {
                    VStack(spacing: 0) {
                        ForEach(Array(model.lines.enumerated()), id: \.offset) { idx, line in
                            lineView(idx: idx, line: line).frame(height: rowHeight)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .offset(y: offset)
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.currentIndex)
                }
                .clipped()
                .mask(edgeFade)
        }
    }

    private func lineView(idx: Int, line: LyricLine) -> some View {
        let cur = model.currentIndex   // -1 = not started → no line is "current" yet
        let isCurrent = idx == cur
        let d = abs(idx - cur)

        // Current line + 1 neighbour each side; everything further is hidden.
        let opacity: Double = isCurrent ? 1 : (d == 1 ? 0.42 : 0)
        let blur: Double = isCurrent ? 0 : (d == 1 ? 1.5 : 0)
        // Size difference via scaleEffect (a smooth transform), NOT font size —
        // changing the font size re-lays-out and re-rasterises the text, which
        // pops instead of animating (very visible with CJK / Korean glyphs).
        let scale = isCurrent ? 1.0 : neighborSize / currentSize

        return Text(line.text.isEmpty ? "♪" : line.text)
            .font(.system(size: currentSize, weight: .bold, design: fontDesign))
            .foregroundStyle(.white)
            .lineLimit(1)                       // never wrap…
            .minimumScaleFactor(0.45)           // …shrink long lines to fit one line
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 34)
            .opacity(opacity)
            .blur(radius: blur)
            .scaleEffect(scale, anchor: .center)
            .shadow(color: .black.opacity(0.65), radius: 5, y: 1)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.currentIndex)
    }

    /// Subtle "looking up lyrics" hint — three faint dots, no text.
    private var loadingIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { _ in
                Circle()
                    .frame(width: 7, height: 7)
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
    }

    /// Fades both edges so lines dissolve in/out. The bottom fade is kept SHALLOW
    /// (starts at 0.92) so the upcoming line just below the current one stays
    /// clearly visible — the old 0.72 stop was swallowing it.
    private var edgeFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }
}
