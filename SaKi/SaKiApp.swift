//
//  MyFirstARApp.swift
//  MyFirstAR
//
//  Created by Vincent Jiao on 13/12/2025.
//

import SwiftUI

@main
struct SaKiApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// 启动加载页：先渲染一个轻量 UI，再创建 ARView（ARKit/RealityKit 首次初始化很容易卡一小段）
private struct RootView: View {
    @State private var showMain: Bool = false
    // 启动页最短显示时间（标题页更“稳”，避免一闪而过）
    private let launchMinDurationNs: UInt64 = 4_000_000_000 // 2.0s

    var body: some View {
        ZStack {
            if showMain {
                ContentView()
            } else {
                LaunchLoadingView()
            }
        }
        .task {
            // 给 SwiftUI 一个机会先把“加载页”画出来，再进入 ARView 初始化（避免白屏/卡死观感）
            try? await Task.sleep(nanoseconds: launchMinDurationNs)
            withAnimation(.easeInOut(duration: 0.20)) {
                showMain = true
            }
        }
    }
}

private struct LaunchLoadingView: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [
                Color.black,
                // 稍微提亮一点点：仍然是“暗黑氛围”，但层次更明显
                Color(red: 0.10, green: 0.08, blue: 0.16)
            ], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()

            // 轻微的底部柔光（很克制）：让“标题页”更显眼但不破坏暗感
            RadialGradient(colors: [
                Color.white.opacity(0.08),
                Color.clear
            ], center: .bottom, startRadius: 0, endRadius: 420)
            .ignoresSafeArea()

            // 🎄 Low-key Christmas vibe:
            // - Warm golden bokeh (holiday lights)
            // - A little soft snow (winter air)
            WarmBokehOverlay()
                .ignoresSafeArea()
                .allowsHitTesting(false)
            SoftSnowOverlay()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 18) {
                Text("SaKi")
                    .font(.system(.largeTitle, design: .rounded).weight(.heavy))
                    .foregroundStyle(.white)

                ProgressView()
                    .tint(.white)

                Text("Loading AR session…")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))

                Text("Please be aware of your surroundings.")
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 24)
        }
    }
}

// MARK: - Subtle holiday atmosphere (no assets)
private struct WarmBokehOverlay: View {
    private struct Dot: Identifiable {
        let id = UUID()
        let x: CGFloat
        let y: CGFloat
        let r: CGFloat
        let phase: Double
        let speed: Double
        let base: Double
        let alpha: Double
    }

    @State private var dots: [Dot] = {
        // A bit more visible: still soft, but clearly "holiday lights"
        (0..<16).map { i in
            let t = Double(i) / 9.0
            let x = CGFloat.random(in: 0.05...0.95)
            let y = CGFloat.random(in: 0.55...0.98)
            let r = CGFloat.random(in: 56...128) * (0.75 + 0.45 * CGFloat(t))
            return Dot(
                x: x,
                y: y,
                r: r,
                phase: Double.random(in: 0...(2 * .pi)),
                speed: Double.random(in: 0.45...0.95),
                base: Double.random(in: 0.45...0.70),
                alpha: Double.random(in: 0.08...0.16)
            )
        }
    }()

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let w = geo.size.width
                let h = geo.size.height

                ZStack {
                    ForEach(dots) { d in
                        // Warm gold ↔ soft amber, very low saturation
                        let pulse = (sin(t * d.speed + d.phase) + 1) / 2
                        let glow = d.alpha * (d.base + 1.05 * pulse)
                        let driftX = CGFloat(sin(t * 0.18 + d.phase) * 18)

                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        Color(red: 1.00, green: 0.88, blue: 0.45).opacity(glow),
                                        Color(red: 1.00, green: 0.55, blue: 0.18).opacity(glow * 0.46),
                                        Color.clear
                                    ],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: d.r
                                )
                            )
                            .frame(width: d.r * 2, height: d.r * 2)
                            .position(x: d.x * w + driftX, y: d.y * h)
                            .blur(radius: 14)
                            .blendMode(.screen)
                    }
                }
                .compositingGroup()
            }
        }
    }
}

private struct SoftSnowOverlay: View {
    private struct Flake: Identifiable {
        let id = UUID()
        let x: CGFloat
        let y: CGFloat
        let size: CGFloat
        let speed: Double
        let drift: Double
        let phase: Double
        let alpha: Double
    }

    @State private var flakes: [Flake] = {
        // A bit more visible snow: still soft, but clearly "winter air"
        (0..<44).map { _ in
            Flake(
                x: CGFloat.random(in: 0...1),
                y: CGFloat.random(in: 0...1),
                size: CGFloat.random(in: 1.4...3.2),
                speed: Double.random(in: 22...46),     // px/s
                drift: Double.random(in: 14...34),     // px amplitude
                phase: Double.random(in: 0...(2 * .pi)),
                alpha: Double.random(in: 0.10...0.20)
            )
        }
    }()

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let w = geo.size.width
                let h = geo.size.height

                Canvas { ctx, _ in
                    for f in flakes {
                        let baseX = f.x * w
                        let driftX = CGFloat(sin(t * 0.9 + f.phase) * f.drift)
                        let yy = (f.y * h + CGFloat(t * f.speed)).truncatingRemainder(dividingBy: h + 40) - 20
                        let x = baseX + driftX

                        let rect = CGRect(x: x, y: yy, width: f.size, height: f.size)
                        ctx.fill(Path(ellipseIn: rect), with: .color(.white.opacity(f.alpha)))
                    }
                }
                .blur(radius: 0.85)
                .blendMode(.screen)
            }
        }
    }
}
