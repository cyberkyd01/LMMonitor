import SwiftUI

/// Minimal line chart drawn with Path. nil values break the line (gap).
struct Sparkline: View {
    var values: [Double?]
    var maxValue: Double? = nil
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { g in
            let n = values.count
            let top = max(maxValue ?? (values.compactMap { $0 }.max() ?? 1), 1e-9)
            let w = g.size.width, h = g.size.height
            let step = n > 1 ? w / CGFloat(n - 1) : 0
            let runs = Self.runs(values)
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h - 0.25)); p.addLine(to: CGPoint(x: w, y: h - 0.25))
                }.stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                ForEach(runs.indices, id: \.self) { i in
                    let run = runs[i]
                    Path { p in
                        guard let first = run.first else { return }
                        p.move(to: CGPoint(x: CGFloat(first.0) * step, y: h))
                        for (idx, v) in run { p.addLine(to: CGPoint(x: CGFloat(idx) * step, y: Self.y(v, top, h))) }
                        p.addLine(to: CGPoint(x: CGFloat(run.last!.0) * step, y: h))
                        p.closeSubpath()
                    }.fill(color.opacity(0.14))
                    Path { p in
                        for (k, e) in run.enumerated() {
                            let pt = CGPoint(x: CGFloat(e.0) * step, y: Self.y(e.1, top, h))
                            if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        }
                        if run.count == 1, let e = run.first {   // single point: draw a dot-like tick
                            p.move(to: CGPoint(x: CGFloat(e.0) * step - 1, y: Self.y(e.1, top, h)))
                            p.addLine(to: CGPoint(x: CGFloat(e.0) * step + 1, y: Self.y(e.1, top, h)))
                        }
                    }.stroke(color, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private static func y(_ v: Double, _ top: Double, _ h: CGFloat) -> CGFloat {
        let f = min(max(v / top, 0), 1)
        return h - 1 - CGFloat(f) * (h - 2)
    }
    private static func runs(_ vs: [Double?]) -> [[(Int, Double)]] {
        var out: [[(Int, Double)]] = []
        var cur: [(Int, Double)] = []
        for (i, v) in vs.enumerated() {
            if let v, v.isFinite { cur.append((i, v)) } else if !cur.isEmpty { out.append(cur); cur = [] }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}
