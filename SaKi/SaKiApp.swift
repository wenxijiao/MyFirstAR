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
    private let launchMinDurationNs: UInt64 = 1_500_000_000 // 1.5s

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
                Color(red: 0.06, green: 0.04, blue: 0.10)
            ], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()

            VStack(spacing: 18) {
                Text("SaKi")
                    .font(.system(.largeTitle, design: .rounded).weight(.heavy))
                    .foregroundStyle(.white)

                ProgressView()
                    .tint(.white)

                Text("Loading AR session…")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 24)
        }
    }
}
