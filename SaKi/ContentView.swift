//
//  ContentView.swift
//  MyFirstAR
//
//  Created by Vincent Jiao on 13/12/2025.


import SwiftUI
import AVFoundation
import UIKit
import Combine

// MARK: - Game Mode & Status
enum GameMode: Equatable {
    case build          // 建造/录制
    case ready          // 转化动画中
    case play           // 游玩/收集
    case gameOver       // 失败
    case result         // 通关
}

enum PathStatus: Equatable {
    case none           // 未录制
    case recording      // 录制中
    case recorded       // 已录制
}

// MARK: - Build spawn selection (what to place when tapping in Build mode)
enum BuildSpawnItem: String, CaseIterable, Identifiable, Equatable {
    case coin
    case giftBox
    case hamburger
    case sakura
    case christmasBall
    case christmasTree
    case gingerbreadWagon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .coin: return "Coin"
        case .giftBox: return "Gift Box"
        case .hamburger: return "Hamburger"
        case .sakura: return "Sakura"
        case .christmasBall: return "Christmas Ball"
        case .christmasTree: return "Christmas Tree"
        case .gingerbreadWagon: return "Gingerbread Wagon"
        }
    }

    var systemImage: String {
        switch self {
        case .coin: return "circle.hexagongrid.fill"
        case .giftBox: return "gift.fill"
        case .hamburger: return "fork.knife"
        case .sakura: return "leaf.fill"
        case .christmasBall: return "circle.fill"
        case .christmasTree: return "tree.fill"
        case .gingerbreadWagon: return "cart.fill"
        }
    }

    /// Must match the USDZ names in bundle
    var modelName: String {
        switch self {
        case .coin: return "coin.usdz"
        case .giftBox: return "giftBox.usdz"
        case .hamburger: return "hamburger.usdz"
        case .sakura: return "sakura.usdz"
        case .christmasBall: return "christmas_ball.usdz"
        case .christmasTree: return "christmas_tree.usdz"
        case .gingerbreadWagon: return "gingerbread_wagon.usdz"
        }
    }
}

struct ARCommands: Equatable {
    var resetToken: UUID = UUID()
    var startRecordingToken: UUID = UUID()
    var stopRecordingToken: UUID = UUID()
    var prepareLevelToken: UUID = UUID()
    var startPlayToken: UUID = UUID()
}

struct ContentView: View {
    @State private var mode: GameMode = .build
    @State private var pathStatus: PathStatus = .none
    @State private var totalCoinsThisRun: Int = 0
    @State private var collectedCoins: Int = 0
    @State private var commands = ARCommands()
    @State private var arReadyFinished: Bool = false

    // AR side: becomes true after collecting the first "projected path item"
    @State private var pathPenaltyArmed: Bool = false

    // First-run tips (only show once)
    @AppStorage("hasSeenOnboardingTips.v1") private var hasSeenOnboardingTips: Bool = false

    // Build placement selection (tap-to-place)
    @State private var buildSpawnItem: BuildSpawnItem = .coin
    
    // 💀 新增：死亡/警告状态
    @State private var isWarning: Bool = false
    // ✅ 新增：危险等级（0~1），用于更“游戏化”的紧张反馈
    @State private var dangerLevel: Float = 0

    // ✅ 可调节的“路径容错”（不同场景：白线/马路牙子 vs 大马路）
    @State private var warningDistance: Float = 0.20
    @State private var deathDistance: Float = 0.8
    @State private var deathEnabled: Bool = true
    // 默认折叠，避免一打开就占屏
    @State private var showPathTuning: Bool = false

    // Haptics task
    @State private var hapticTask: Task<Void, Never>?
    @StateObject private var heartbeat = HeartbeatController()
    @State private var showCelebration: Bool = false

    var body: some View {
        ZStack {
            // AR View Layer
            ARViewContainer(
                mode: $mode,
                pathStatus: $pathStatus,
                totalCoinsThisRun: $totalCoinsThisRun,
                collectedCoins: $collectedCoins,
                isWarning: $isWarning,
                dangerLevel: $dangerLevel,
                warningDistance: $warningDistance,
                deathDistance: $deathDistance,
                deathEnabled: $deathEnabled,
                pathPenaltyArmed: $pathPenaltyArmed,
                buildSpawnItem: $buildSpawnItem,
                commands: $commands,
                arReadyFinished: $arReadyFinished
            )
            .ignoresSafeArea()
            
            // 🟥 危险层：边缘呼吸光圈（不遮挡画面，更“干净”）
            if mode == .play && dangerLevel > 0.001 {
                DangerEdgePulseOverlay(level: CGFloat(dangerLevel))
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            
            // UI Overlay Layer
            VStack {
                // Top Bar
                if mode != .gameOver {
                    topBar
                }
                
                Spacer()
                
                // Bottom Controls
                VStack(spacing: 12) {
                    bottomControls
                    if mode == .build {
                        pathTuningPanel
                    }
                }
                .padding(.bottom, 30)
            }
            .padding(.horizontal)

            // ✅ Success celebration (subtle + gamey)
            if showCelebration && mode == .result {
                SuccessCelebrationOverlay()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

            // First-run contextual tip (English, dismissible)
            if !hasSeenOnboardingTips && mode != .gameOver {
                FirstRunTipOverlay(
                    message: onboardingMessage,
                    onDismiss: { hasSeenOnboardingTips = true }
                )
                .transition(.opacity)
            }
            
            // ☠️ Game Over Overlay
            if mode == .gameOver {
                Color.black.opacity(0.8).ignoresSafeArea()
                VStack(spacing: 20) {
                    Image(systemName: "xmark.octagon.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.red)
                    Text("YOU FELL!")
                        .font(.largeTitle.weight(.heavy))
                        .foregroundColor(.white)
                    Text("Stay on the path next time.")
                        .font(.body)
                        .foregroundColor(.white.opacity(0.8))
                    
                    Button {
                        retry()
                    } label: {
                        Text("Try Again")
                            .font(.headline)
                            .foregroundColor(.black)
                            .padding(.horizontal, 30)
                            .padding(.vertical, 14)
                            .background(Color.white, in: Capsule())
                    }
                    .padding(.top, 20)
                }
                .transition(.scale)
            }
        }
        .onAppear {
            // 启动时预热 heartbeat，避免第一次进入危险/结束时才创建 AVAudioPlayer 引发卡顿
            heartbeat.prewarm()
        }
        // 监听 AR 准备完成 (动画播放完毕)
        .onChange(of: arReadyFinished) { _, finished in
            if finished {
                arReadyFinished = false
                withAnimation { mode = .play }
                commands.startPlayToken = UUID()
            }
        }
        // 保证 deathDistance >= warningDistance + 最小间隔
        .onChange(of: warningDistance) { _, new in
            let minGap: Float = 0.15
            if deathDistance < new + minGap {
                deathDistance = new + minGap
            }
        }
        .onChange(of: deathDistance) { _, new in
            let minGap: Float = 0.15
            if new < warningDistance + minGap {
                deathDistance = warningDistance + minGap
            }
        }
        // Haptics：dangerLevel 越高，震动越频繁
        .onChange(of: mode) { _, newMode in
            if newMode != .play {
                stopDangerHaptics()
                heartbeat.stop()
            }
            if newMode == .result {
                triggerCelebration()
            }
        }
        .onChange(of: dangerLevel) { _, new in
            if mode != .play {
                stopDangerHaptics()
                heartbeat.stop()
                return
            }
            if new <= 0.001 {
                stopDangerHaptics()
                heartbeat.stop()
            } else {
                startDangerHapticsIfNeeded()
                heartbeat.apply(level: Double(new))
            }
        }
    }
    
    func retry() {
        // 重置回准备阶段，重新开始
        commands.resetToken = UUID() // 简单处理：完全重置
        withAnimation {
            mode = .build
            pathStatus = .none
            isWarning = false
            dangerLevel = 0
            pathPenaltyArmed = false
            // 不重置 warning/death：让玩家的偏好保留
            collectedCoins = 0
            totalCoinsThisRun = 0
            showCelebration = false
        }
    }

    // MARK: - First run tips
    private var onboardingMessage: String {
        switch mode {
        case .build:
            switch pathStatus {
            case .none:
                return "Tap the Walk button to start recording, then walk a few steps along your route."
            case .recording:
                return "Keep walking. Tap the Walk button again to stop recording."
            case .recorded:
                return "Tap the Checkmark to project the level: items + fireflies will appear along your path."
            }
        case .ready:
            return "Projecting your level…"
        case .play:
            if pathPenaltyArmed {
                return "Deviation penalty is now active. Stay close to the path."
            } else {
                return "Follow the fireflies. Neon orange-red means you're off the path."
            }
        case .gameOver:
            return "Stay close to the fireflies to avoid failing."
        case .result:
            return "Nice! You can start a new run anytime."
        }
    }

    private func startDangerHapticsIfNeeded() {
        guard hapticTask == nil else { return }
        hapticTask = Task { @MainActor in
            let generator = UIImpactFeedbackGenerator(style: .heavy)
            generator.prepare()
            while !Task.isCancelled && mode == .play {
                let d = Double(max(0, min(1, dangerLevel)))
                if d <= 0.001 {
                    break
                }

                // 强度和频率随危险上升
                let intensity = CGFloat(0.35 + 0.65 * d)
                generator.impactOccurred(intensity: intensity)

                // 间隔：0.95s -> 0.25s
                let interval = 0.95 - 0.70 * d
                try? await Task.sleep(nanoseconds: UInt64(max(0.20, interval) * 1_000_000_000))
            }
            hapticTask = nil
        }
    }

    private func stopDangerHaptics() {
        hapticTask?.cancel()
        hapticTask = nil
    }

    private func triggerCelebration() {
        heartbeat.stop()
        stopDangerHaptics()

        let gen = UINotificationFeedbackGenerator()
        gen.notificationOccurred(.success)

        withAnimation(.easeOut(duration: 0.15)) {
            showCelebration = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            withAnimation(.easeIn(duration: 0.5)) {
                showCelebration = false
            }
        }
    }
}

// MARK: - Danger UI
private struct DangerEdgePulseOverlay: View {
    let level: CGFloat   // 0~1

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let l = max(0, min(1, level))

            // 越危险：呼吸越快、线更粗、更亮、更“刺”
            let freq = 0.9 + 2.4 * l
            let pulse = (sin(t * freq * 2.0 * .pi) + 1) / 2 // 0..1

            let baseOpacity = 0.18 + 0.55 * l
            let opacity = baseOpacity + 0.22 * l * pulse

            let baseLine: CGFloat = 6 + 10 * l
            let lineWidth = baseLine + 6 * l * pulse

            let blur = 6 + 10 * l
            let inset: CGFloat = 8

            ZStack {
                // 外层光晕（更柔）
                ContainerRelativeShape()
                    .inset(by: inset)
                    .stroke(Color.red.opacity(opacity * 0.55),
                            style: StrokeStyle(lineWidth: lineWidth + 10,
                                               lineCap: .round,
                                               lineJoin: .round))
                    .blur(radius: blur)

                // 内层主边框（更清晰）
                ContainerRelativeShape()
                    .inset(by: inset)
                    .stroke(Color.red.opacity(opacity),
                            style: StrokeStyle(lineWidth: lineWidth,
                                               lineCap: .round,
                                               lineJoin: .round))
                    .shadow(color: Color.red.opacity(opacity), radius: 10 + 12 * l)
            }
            .compositingGroup()
            .blendMode(.screen)
        }
    }
}


// MARK: - Heartbeat Audio (gamey tension)
@MainActor
private final class HeartbeatController: ObservableObject {
    private var player: AVAudioPlayer?
    private var lastApplied: Double = -1

    func prewarm() {
        ensurePlayer()
        player?.prepareToPlay()
    }

    func apply(level: Double) {
        let l = max(0, min(1, level))

        // 轻微抖动/噪声不值得频繁调参：做个小阈值
        if abs(l - lastApplied) < 0.03, player != nil { return }
        lastApplied = l

        ensurePlayer()
        guard let player else { return }

        // 危险越高：音量越大、心跳越快
        player.enableRate = true
        player.rate = Float(1.0 + 0.9 * l)     // 1.0x ~ 1.9x
        player.volume = Float(0.05 + 0.85 * l) // 0.05 ~ 0.90

        if !player.isPlaying {
            player.play()
        }
    }

    func stop() {
        lastApplied = -1
        guard let player else { return }
        player.stop()
        player.currentTime = 0
    }

    private func ensurePlayer() {
        if player != nil { return }
        guard let url = Bundle.main.url(forResource: "heartbeat", withExtension: "mp3") else {
            print("❌ heartbeat.mp3 not found in bundle")
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1
            p.volume = 0
            p.prepareToPlay()
            player = p
        } catch {
            print("❌ Heartbeat player error:", error)
        }
    }
}

// MARK: - Success celebration (particles)
private struct SuccessCelebrationOverlay: View {
    var body: some View {
        ZStack {
            ConfettiEmitterView()
                .allowsHitTesting(false)
            // Place the message just below the top bar (status + counter)
            Text("Congrats! Merry Christmas!")
                .font(.system(.title3, design: .rounded).weight(.heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(radius: 12)
                .padding(.top, 126) // tuned to sit right below the top bar
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
        }
    }
}

private struct ConfettiEmitterView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let emitter = CAEmitterLayer()
        emitter.emitterShape = .line
        emitter.emitterPosition = CGPoint(x: UIScreen.main.bounds.midX, y: -10)
        emitter.emitterSize = CGSize(width: UIScreen.main.bounds.width, height: 1)

        func rectImage(color: UIColor) -> CGImage? {
            let r = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 14))
            return r.image { ctx in
                ctx.cgContext.setFillColor(color.cgColor)
                ctx.cgContext.fill(CGRect(x: 0, y: 0, width: 10, height: 14))
            }.cgImage
        }

        let colors: [UIColor] = [
            UIColor(red: 1.0, green: 0.84, blue: 0.25, alpha: 1.0), // gold
            UIColor.white,
            UIColor(red: 1.0, green: 0.45, blue: 0.35, alpha: 1.0)  // warm red
        ]

        let cells: [CAEmitterCell] = colors.compactMap { c in
            guard let img = rectImage(color: c) else { return nil }
            let cell = CAEmitterCell()
            cell.contents = img
            cell.birthRate = 14
            cell.lifetime = 3.6
            cell.velocity = 280
            cell.velocityRange = 140
            cell.emissionLongitude = .pi
            cell.emissionRange = .pi / 5
            cell.spin = 3.5
            cell.spinRange = 4.0
            cell.scale = 0.55
            cell.scaleRange = 0.25
            cell.alphaSpeed = -0.55
            cell.yAcceleration = 520
            return cell
        }
        emitter.emitterCells = cells

        view.layer.addSublayer(emitter)

        // 让粒子爆发更集中：短暂提高 birthRate，然后自动回落
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            emitter.birthRate = 0.0
        }

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - First run tip UI
private struct FirstRunTipOverlay: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Text("Quick Tip")
                    .font(.system(.headline, design: .rounded).weight(.heavy))
                    .foregroundStyle(.white)

                Text(message)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    Button("Got it") { onDismiss() }
                        .font(.system(.headline, design: .rounded).weight(.heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color.white, in: Capsule())
                }
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 16, y: 10)
            .padding(.horizontal, 16)
            .padding(.bottom, 22)
        }
    }
}

// MARK: - UI Components
extension ContentView {
    
    // 顶部状态栏
    var topBar: some View {
        HStack {
            // 左侧：状态指示
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusColor.opacity(0.6), radius: 4)
                
                Text(statusText.uppercased())
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            
            Spacer()
            
            // 右侧：计数器
            if mode == .play || mode == .result {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill")
                        .foregroundColor(.yellow)
                    Text("\(collectedCoins) / \(totalCoinsThisRun)")
                        .font(.system(.title3, design: .rounded).weight(.heavy))
                        .foregroundColor(.white)
                        .contentTransition(.numericText(value: Double(collectedCoins)))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .padding(.top, 10)
    }
    
    // 底部控制区
    @ViewBuilder
    var bottomControls: some View {
        HStack {
            switch mode {
            case .build:
                buildControls
            case .ready:
                Text("Preparing Level...")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
                    .padding(10)
                    .background(.ultraThinMaterial, in: Capsule())
            case .play:
                playControls
            case .result:
                resultControls
            case .gameOver:
                EmptyView()
            }
        }
    }
    
    // Build 模式控制组
    var buildControls: some View {
        HStack(spacing: 40) {
            
            // Spawn picker (Build): choose what tap-to-place will create
            Menu {
                ForEach(BuildSpawnItem.allCases) { item in
                    Button {
                        buildSpawnItem = item
                    } label: {
                        Label(item.title, systemImage: item.systemImage)
                    }
                }
            } label: {
                Image(systemName: buildSpawnItem.systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 50, height: 50)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Button {
                commands.resetToken = UUID()
                withAnimation { pathStatus = .none }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 50, height: 50)
                    .background(.ultraThinMaterial, in: Circle())
            }
            
            // 录制按钮
            ZStack {
                if pathStatus == .recording {
                    Circle()
                        .stroke(Color.red.opacity(0.5), lineWidth: 4)
                        .frame(width: 80, height: 80)
                        .scaleEffect(1.1)
                        .opacity(0.8)
                        .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pathStatus)
                }
                
                Button {
                    if pathStatus == .none || pathStatus == .recorded {
                        commands.startRecordingToken = UUID()
                        withAnimation { pathStatus = .recording }
                    } else {
                        commands.stopRecordingToken = UUID()
                        withAnimation { pathStatus = .recorded }
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(pathStatus == .recording ? Color.red : Color.white)
                            .frame(width: 72, height: 72)
                        
                        if pathStatus == .recording {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.white)
                                .frame(width: 24, height: 24)
                        } else {
                            Image(systemName: "figure.walk")
                                .font(.title2)
                                .foregroundColor(.black)
                        }
                    }
                }
            }
            
            Button {
                withAnimation { mode = .ready }
                commands.prepareLevelToken = UUID()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 60, height: 60)
                    .background(Color.blue, in: Circle())
                    .shadow(color: .blue.opacity(0.5), radius: 8, y: 4)
            }
            .disabled(pathStatus == .recording)
            .opacity(pathStatus == .recording ? 0.3 : 1.0)
        }
    }

    // MARK: - Path tuning panel (Build)
    var pathTuningPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Path Tuning")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showPathTuning.toggle()
                    }
                } label: {
                    Image(systemName: showPathTuning ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.white.opacity(0.9))
                }
            }

            if showPathTuning {
                Toggle(isOn: $deathEnabled) {
                    Text("Enable Death")
                        .foregroundStyle(.white.opacity(0.95))
                }
                .toggleStyle(SwitchToggleStyle(tint: .red))

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Warning")
                            .foregroundStyle(.white.opacity(0.95))
                        Spacer()
                        Text(String(format: "%.2fm", warningDistance))
                            .foregroundStyle(.white.opacity(0.8))
                            .font(.caption.monospacedDigit())
                    }
                    Slider(value: Binding(
                        get: { Double(warningDistance) },
                        set: { warningDistance = Float($0) }
                    ), in: 0.2...2.0)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Death")
                            .foregroundStyle(.white.opacity(0.95))
                        Spacer()
                        Text(String(format: "%.2fm", deathDistance))
                            .foregroundStyle(.white.opacity(0.8))
                            .font(.caption.monospacedDigit())
                    }
                    Slider(value: Binding(
                        get: { Double(deathDistance) },
                        set: { deathDistance = Float($0) }
                    ), in: 0.3...3.5)
                    Text(deathEnabled ? "Go out too far and you fail." : "No instant fail — just warning & tension.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
    
    var playControls: some View {
        Button {
            withAnimation { mode = .result }
        } label: {
            Text("Finish")
                .font(.headline)
                .foregroundColor(.black)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.white, in: Capsule())
        }
    }
    
    var resultControls: some View {
        HStack(spacing: 20) {
            Button {
                retry()
            } label: {
                Label("New Game", systemImage: "arrow.clockwise")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }
    
    // 辅助属性
    var statusColor: Color {
        switch mode {
        case .build: return pathStatus == .recording ? .red : .blue
        case .ready: return .purple
        case .play: return dangerLevel > 0.001 ? .red : .green
        case .result: return .orange
        case .gameOver: return .red
        }
    }
    
    var statusText: String {
        switch mode {
        case .build: return pathStatus == .recording ? "Recording Path" : "Build Map"
        case .ready: return "Projecting..."
        case .play: return dangerLevel > 0.001 ? "DANGER!" : "Stay on Path"
        case .result: return "Success"
        case .gameOver: return "Failed"
        }
    }
}
