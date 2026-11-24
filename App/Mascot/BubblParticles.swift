import SwiftUI

/// Every particle around Bubbl, drawn in one `Canvas`. Each particle's position comes from the
/// time and a fixed per-index seed, so nothing is stored between frames.
struct BubblParticles: View {
    let t: Double
    let pose: BubblPose
    /// Bubbl's resting center, before drift and float.
    let base: CGPoint
    /// Bubbl's center this frame.
    let center: CGPoint
    let radius: CGFloat
    /// Seconds since the last pop (M5) started, if any.
    let popElapsed: Double?
    /// M8: mini bubbles drift down toward the leftovers chip.
    let showsLeftovers: Bool

    private static let sparkleColors: [Color] = [.yellow, .pink, .mint, .cyan, .orange]

    var body: some View {
        Canvas { context, size in
            if pose.trail > 0.01 { drawTrail(in: &context) }
            if pose.dust > 0.01 { drawDust(in: &context) }
            if pose.zzz > 0.01 { drawZzz(in: &context) }
            if let popElapsed {
                let elapsed = popElapsed - BubblPopPhase.burstStart
                if elapsed >= 0, elapsed < 0.95 { drawBurst(in: &context, progress: elapsed / 0.95) }
            }
            if showsLeftovers { drawLeftovers(in: &context, size: size) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func hash(_ n: Int) -> Double { BubblMotion.hash(n) }

    /// M2: tiny bubbles left behind as Bubbl drifts, rising and fading.
    private func drawTrail(in context: inout GraphicsContext) {
        let count = 7
        let life = 1.4
        for index in 0..<count {
            let age = (t + Double(index) * life / Double(count)).truncatingRemainder(dividingBy: life)
            let born = t - age
            let generation = Int(floor((t + Double(index) * life / Double(count)) / life))
            let seed = index * 997 + generation
            // Where Bubbl was when this one was born, just behind its direction of travel.
            let heading: Double = cos(born * BubblMotion.driftSpeed) >= 0 ? 1 : -1
            let bornX = base.x + sin(born * BubblMotion.driftSpeed) * pose.driftAmp
            let bornY = base.y + sin(born * BubblMotion.floatSpeed) * pose.floatAmp
            let x = bornX - heading * radius * (0.85 + hash(seed) * 0.2) + sin(age * 4 + Double(index)) * 2
            let y = bornY + radius * (hash(seed + 1) - 0.3) * 0.7 - age * 14
            let r = 1.5 + hash(seed + 2) * 2.5
            let opacity = (1 - age / life) * pose.trail
            context.stroke(
                Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                with: .color(.cyan.opacity(0.8 * opacity)), lineWidth: 1
            )
        }
    }

    /// M4: dust specks spiral in and vanish inside Bubbl.
    private func drawDust(in context: inout GraphicsContext) {
        let count = 10
        let period = 1.5
        for index in 0..<count {
            let progress = (t / period + hash(index + 50)).truncatingRemainder(dividingBy: 1)
            let start = radius * 1.75
            let end = radius * 0.45
            let distance = start - (start - end) * BubblMotion.easeIn(progress)
            let angle = hash(index) * .pi * 2 + progress * 2.2
            let x = center.x + cos(angle) * distance
            let y = center.y + sin(angle) * distance
            let r = 1.2 + hash(index + 7) * 1.4
            context.fill(
                Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                with: .color(.gray.opacity(0.85 * sin(progress * .pi) * pose.dust))
            )
        }
    }

    /// M6: sleepy "z" mini bubbles rising from the top right.
    private func drawZzz(in context: inout GraphicsContext) {
        let count = 3
        let period = 3.0
        for index in 0..<count {
            let progress = (t / period + Double(index) / Double(count)).truncatingRemainder(dividingBy: 1)
            let x = center.x + radius * 0.6 + progress * 16 + sin(progress * 6) * 3
            let y = center.y - radius * 0.6 - progress * 30
            let r = 4.5 + progress * 4
            let opacity = sin(progress * .pi) * pose.zzz
            let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
            context.stroke(Path(ellipseIn: rect), with: .color(.cyan.opacity(0.6 * opacity)), lineWidth: 0.8)
            let letter = context.resolve(
                Text("z").font(.system(size: r * 1.3, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.secondary.opacity(opacity))
            )
            context.draw(letter, at: CGPoint(x: x, y: y - r * 0.1))
        }
    }

    /// M5: a ring and sparkles fly outward as Bubbl pops.
    private func drawBurst(in context: inout GraphicsContext, progress q: Double) {
        let ringRadius = radius * (1 + q * 0.35)
        context.stroke(
            Path(ellipseIn: CGRect(x: base.x - ringRadius, y: base.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2)),
            with: .color(.cyan.opacity(0.5 * (1 - q))), lineWidth: 1.5 * (1 - q) + 0.3
        )
        let count = 12
        for index in 0..<count {
            let angle = Double(index) / Double(count) * .pi * 2 + hash(index + 300) * 0.4
            let distance = radius * 0.5 + BubblMotion.easeOut(q) * (radius * 0.6 + hash(index + 400) * 10)
            let point = CGPoint(x: base.x + cos(angle) * distance, y: base.y + sin(angle) * distance)
            let size = (3 + hash(index + 500) * 3) * (1 - q * 0.6)
            let color = Self.sparkleColors[index % Self.sparkleColors.count]
            context.fill(Self.sparkle(at: point, size: size), with: .color(color.opacity(1 - q * q)))
        }
    }

    /// M8: a few mini bubbles drift from Bubbl down toward the leftovers chip below.
    private func drawLeftovers(in context: inout GraphicsContext, size: CGSize) {
        let count = 3
        let period = 2.4
        let start = CGPoint(x: center.x, y: center.y + radius * 0.85)
        let end = CGPoint(x: size.width / 2, y: size.height - 2)
        for index in 0..<count {
            let progress = (t / period + Double(index) / Double(count)).truncatingRemainder(dividingBy: 1)
            let x = start.x + (end.x - start.x) * progress + sin(progress * 5 + Double(index) * 2) * 6
            let y = start.y + (end.y - start.y) * progress
            let r = 2 + hash(index + 900) * 2
            context.stroke(
                Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                with: .color(.cyan.opacity(0.75 * sin(progress * .pi))), lineWidth: 0.9
            )
        }
    }

    /// A four-pointed sparkle.
    private static func sparkle(at c: CGPoint, size s: CGFloat) -> Path {
        let k = s * 0.22
        var path = Path()
        path.move(to: CGPoint(x: c.x, y: c.y - s))
        path.addQuadCurve(to: CGPoint(x: c.x + s, y: c.y), control: CGPoint(x: c.x + k, y: c.y - k))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + s), control: CGPoint(x: c.x + k, y: c.y + k))
        path.addQuadCurve(to: CGPoint(x: c.x - s, y: c.y), control: CGPoint(x: c.x - k, y: c.y + k))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - s), control: CGPoint(x: c.x - k, y: c.y - k))
        path.closeSubpath()
        return path
    }
}
