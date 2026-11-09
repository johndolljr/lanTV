import SwiftUI

/// Colours and surfaces shared by every lanTV screen.
enum LanTVDesignSystem {
    static let background = Color(red: 0.012, green: 0.025, blue: 0.10)
    static let panel = Color(red: 0.025, green: 0.055, blue: 0.16)
    static let accent = Color(red: 0.02, green: 0.70, blue: 1.0)
    static let mint = Color(red: 0.12, green: 0.94, blue: 0.79)
    static let violet = Color(red: 0.43, green: 0.19, blue: 0.94)
    static let panelBorder = Color(red: 0.20, green: 0.39, blue: 0.76)

    static let accentGradient = LinearGradient(
        colors: [Color(red: 0.0, green: 0.66, blue: 0.97), Color(red: 0.05, green: 0.42, blue: 0.96)],
        startPoint: .top, endPoint: .bottom
    )
    static let backgroundGradient = LinearGradient(
        colors: [Color(red: 0.008, green: 0.025, blue: 0.09), Color(red: 0.015, green: 0.018, blue: 0.10), Color(red: 0.065, green: 0.025, blue: 0.20)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let panelGradient = LinearGradient(
        colors: [Color(red: 0.055, green: 0.09, blue: 0.24), Color(red: 0.016, green: 0.04, blue: 0.15), Color(red: 0.035, green: 0.035, blue: 0.17)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let programmeGradient = LinearGradient(
        colors: [Color(red: 0.09, green: 0.14, blue: 0.27), Color(red: 0.035, green: 0.065, blue: 0.15)],
        startPoint: .top, endPoint: .bottom
    )
    static let liveProgrammeGradient = LinearGradient(
        colors: [Color(red: 0.025, green: 0.34, blue: 0.55), Color(red: 0.08, green: 0.25, blue: 0.61), Color(red: 0.22, green: 0.10, blue: 0.53)],
        startPoint: .leading, endPoint: .trailing
    )
}

/// One smooth signal ribbon with a soft bloom, used as a restrained background accent.
struct LanTVSignalWave: View {
    var guide = false

    var body: some View {
        Canvas { context, size in
            guard size.width > 80, size.height > 40 else { return }

            drawPanelLight(in: context, size: size)

            let start = CGPoint(x: size.width * 0.30, y: size.height * (guide ? 0.045 : 0.72))
            let end = CGPoint(x: size.width * (guide ? 0.78 : 0.70), y: size.height * (guide ? 0.07 : 0.40))
            let control1 = CGPoint(x: size.width * 0.44, y: size.height * (guide ? 0.00 : 0.22))
            let control2 = CGPoint(x: size.width * 0.62, y: size.height * (guide ? 0.14 : 0.98))
            var path = Path()
            path.move(to: start)
            path.addCurve(to: end, control1: control1, control2: control2)

            let gradient = Gradient(stops: [
                .init(color: LanTVDesignSystem.accent.opacity(0.04), location: 0),
                .init(color: LanTVDesignSystem.accent.opacity(0.48), location: 0.36),
                .init(color: LanTVDesignSystem.accent.opacity(0.62), location: 0.58),
                .init(color: LanTVDesignSystem.violet.opacity(0.56), location: 0.82),
                .init(color: LanTVDesignSystem.violet.opacity(0.04), location: 1)
            ])
            let stroke = GraphicsContext.Shading.linearGradient(
                gradient,
                startPoint: CGPoint(x: start.x, y: 0),
                endPoint: CGPoint(x: end.x, y: 0)
            )

            // A soft fold on one side of the ribbon catches the light at its bend.
            // Both ends taper to the original curve.
            let spread = min(size.width * 0.026, size.height * (guide ? 0.055 : 0.16))
            let offset = guide ? -spread : spread
            var fold = path
            fold.addCurve(
                to: start,
                control1: CGPoint(x: control2.x, y: control2.y + offset),
                control2: CGPoint(x: control1.x, y: control1.y + offset * 0.3)
            )
            fold.closeSubpath()
            context.drawLayer { reflectedLight in
                reflectedLight.opacity = 0.44
                reflectedLight.addFilter(.blur(radius: spread * 0.24))
                reflectedLight.fill(fold, with: stroke)
            }
            context.drawLayer { bloom in
                bloom.addFilter(.blur(radius: 15))
                bloom.opacity = 0.35
                bloom.stroke(path, with: stroke, style: StrokeStyle(lineWidth: 14, lineCap: .round))
            }
            context.drawLayer { highlight in
                highlight.opacity = 0.32
                highlight.addFilter(.blur(radius: 5))
                highlight.stroke(path, with: stroke, style: StrokeStyle(lineWidth: 7, lineCap: .round))
            }
            context.stroke(path, with: stroke, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drawPanelLight(in context: GraphicsContext, size: CGSize) {
        let bounds = Path(CGRect(origin: .zero, size: size))

        func fillBand(_ band: Gradient, in layer: inout GraphicsContext) {
            layer.fill(bounds, with: .linearGradient(band, startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
        }

        func feather(_ band: Gradient, from start: CGFloat, to end: CGFloat) {
            context.drawLayer { layer in
                fillBand(band, in: &layer)
                layer.blendMode = .destinationIn
                layer.fill(bounds, with: .linearGradient(
                    Gradient(colors: [.white, .white.opacity(0.42), .clear]),
                    startPoint: CGPoint(x: 0, y: size.height * start),
                    endPoint: CGPoint(x: 0, y: size.height * end)
                ))
            }
        }

        // These full-width color bands come from the unobstructed navy surfaces in the
        // reference. Cross-fading them vertically lets the sky light reach all four edges.
        var base = context
        fillBand(guide ? Self.guideMiddle : Self.headerMiddle, in: &base)
        feather(guide ? Self.guideTop : Self.headerTop, from: 0, to: guide ? 0.19 : 0.55)
        feather(guide ? Self.guideBottom : Self.headerBottom, from: 1, to: guide ? 0.15 : 0.43)

        // The violet reflected light is strongest near the right bend. Transforming the
        // shading itself keeps its outer edge fully transparent at every aspect ratio.
        var bend = context
        bend.translateBy(x: size.width * (guide ? 0.715 : 0.64), y: size.height * (guide ? 0.08 : 0.62))
        bend.scaleBy(x: size.width * (guide ? 0.23 : 0.22), y: size.height * (guide ? 0.22 : 0.92))
        bend.fill(Path(CGRect(x: -1, y: -1, width: 2, height: 2)), with: .radialGradient(
            Self.bendLight, center: .zero, startRadius: 0, endRadius: 1
        ))
    }

    private static func band(_ swatches: [UInt32]) -> Gradient {
        Gradient(colors: swatches.map { rgb in
            Color(.sRGB, red: Double(rgb >> 16) / 255,
                  green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
        })
    }

    private static let headerTop = band([0x0b2044, 0x0b1e3f, 0x171f51, 0x22205d, 0x10173d, 0x101739, 0x0b1b3e])
    private static let headerMiddle = band([0x081329, 0x0d1935, 0x101b3e, 0x0b1b3a, 0x101537, 0x101734, 0x0a142b])
    private static let headerBottom = band([0x091a34, 0x0e2247, 0x0c254d, 0x0a2347, 0x141a44, 0x111934, 0x0b1b37])
    private static let guideTop = band([0x09152c, 0x141b42, 0x161f54, 0x091e46, 0x0d1942, 0x0e1739, 0x09182f])
    private static let guideMiddle = band([0x091328, 0x0d1837, 0x0b1b3d, 0x081a3b, 0x0a1536, 0x0b1533, 0x091228])
    private static let guideBottom = band([0x0a1236, 0x080e27, 0x070d21, 0x080f28, 0x090e31, 0x080e2c, 0x07122e])
    private static let bendLight = Gradient(stops: [
        .init(color: Color(red: 0.25, green: 0.21, blue: 0.61).opacity(0.52), location: 0),
        .init(color: Color(red: 0.21, green: 0.17, blue: 0.55).opacity(0.34), location: 0.34),
        .init(color: Color(red: 0.16, green: 0.14, blue: 0.44).opacity(0.10), location: 0.70),
        .init(color: .clear, location: 1)
    ])
}
