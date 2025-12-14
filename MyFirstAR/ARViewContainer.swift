//
//  ARViewContainer.swift
//  MyFirstAR
//
//  Created by Vincent Jiao on 13/12/2025.
//

import SwiftUI
import RealityKit
import ARKit
import Combine
import simd
import UIKit
import AVFoundation
import CoreGraphics

struct ARViewContainer: UIViewRepresentable {

    @Binding var mode: GameMode
    @Binding var pathStatus: PathStatus
    @Binding var totalCoinsThisRun: Int
    @Binding var collectedCoins: Int
    @Binding var isWarning: Bool
    @Binding var dangerLevel: Float
    @Binding var commands: ARCommands
    @Binding var arReadyFinished: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            mode: $mode,
            pathStatus: $pathStatus,
            totalCoinsThisRun: $totalCoinsThisRun,
            collectedCoins: $collectedCoins,
            isWarning: $isWarning,
            dangerLevel: $dangerLevel,
            commands: $commands,
            arReadyFinished: $arReadyFinished
        )
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        // MARK: - AR Config
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        arView.session.run(config)

        // Lighting & Occlusion
        // ⚠️ occlusion 在很多环境下会把“贴地的小物体”吃掉（你描述的“能收集但看不到”很像这个）
        // 先默认关闭，保证金币可见；如果你确实想要遮挡效果，可以再加开关打开。
        arView.environment.sceneUnderstanding.options.insert(.receivesLighting)
        arView.environment.lighting.intensityExponent = 1.2

        // Gesture (build: tap to place coin)
        context.coordinator.arView = arView
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        arView.addGestureRecognizer(tap)

        // Start update loop once
        context.coordinator.startUpdateLoop()

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.handleCommands(commands)
    }

    // MARK: - Coordinator
    final class Coordinator: NSObject {

        weak var arView: ARView?

        // Bindings
        private let mode: Binding<GameMode>
        private let pathStatus: Binding<PathStatus>
        private let totalCoinsThisRun: Binding<Int>
        private let collectedCoins: Binding<Int>
        private let isWarning: Binding<Bool>
        private let dangerLevel: Binding<Float>
        private let commands: Binding<ARCommands>
        private let arReadyFinished: Binding<Bool>

        init(mode: Binding<GameMode>,
             pathStatus: Binding<PathStatus>,
             totalCoinsThisRun: Binding<Int>,
             collectedCoins: Binding<Int>,
             isWarning: Binding<Bool>,
             dangerLevel: Binding<Float>,
             commands: Binding<ARCommands>,
             arReadyFinished: Binding<Bool>) {

            self.mode = mode
            self.pathStatus = pathStatus
            self.totalCoinsThisRun = totalCoinsThisRun
            self.collectedCoins = collectedCoins
            self.isWarning = isWarning
            self.dangerLevel = dangerLevel
            self.commands = commands
            self.arReadyFinished = arReadyFinished
            // ✅ 关键：避免第一次 updateUIView 时把所有 token 都当成“变化”
            // 因为 ARCommands() 默认是随机 UUID，如果 lastCommands 也用 ARCommands() 初始化，
            // 首帧会误触发 reset/prepare/startPlay 等逻辑，导致一启动就跳到 play。
            self.lastCommands = commands.wrappedValue

            super.init()
            setupAudioSession()
        }

        // MARK: - Audio
        private func setupAudioSession() {
            let s = AVAudioSession.sharedInstance()
            do {
                try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try s.setActive(true)
            } catch {
                print("❌ AudioSession error:", error)
            }
        }

        private let soundName = "coin"
        private let soundExt  = "wav"
        private var sfxPlayer: AVAudioPlayer?

        private func playCoinSound() {
            guard let url = Bundle.main.url(forResource: soundName, withExtension: soundExt) else {
                print("❌ sound not found:", soundName, soundExt)
                return
            }
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.volume = Float.random(in: 0.45...0.60)
                p.prepareToPlay()
                p.play()
                self.sfxPlayer = p
            } catch {
                print("❌ Sound error:", error)
            }
        }

        // MARK: - Commands token tracking
        private var lastCommands = ARCommands()
        private var playStartedAt: CFTimeInterval = 0
        // 入场保护：避免开局离路径远直接判死
        private let playGraceDuration: CFTimeInterval = 10.0

        func handleCommands(_ new: ARCommands) {

            if new.resetToken != lastCommands.resetToken {
                resetAll()
            }

            if new.startRecordingToken != lastCommands.startRecordingToken {
                startRecording()
            }

            if new.stopRecordingToken != lastCommands.stopRecordingToken {
                stopRecording()
            }

            if new.prepareLevelToken != lastCommands.prepareLevelToken {
                // Ready: 路径 → 金币投射 + 出现动画
                prepareLevel()
            }

            if new.startPlayToken != lastCommands.startPlayToken {
                // 开始游玩：一般 UI 已经把 collectedCoins 清了
                // 这里保持兼容：再保证一次
                collectedCoins.wrappedValue = 0
                playStartedAt = CACurrentMediaTime()

                // play 开始：如果有路径就显示“能量流”，否则清理
                if !recordedPath.isEmpty {
                    buildFlowGuideIfNeeded()
                } else {
                    clearFlowGuide()
                }
            }

            lastCommands = new
        }

        // MARK: - World / coin storage
        private var coins: [ModelEntity] = []
        // 只记录“路径生成”的金币（Ready/Prepare 时会清理它们，但不影响手点金币）
        private var pathCoins: [ModelEntity] = []
        private var coinBaseY: [ObjectIdentifier: Float] = [:]
        private var coinPhase: [ObjectIdentifier: Float] = [:]
        private var attracting: Set<ObjectIdentifier> = []
        // 出现动画期间：避免 idle 更新干扰（否则会“鬼畜”）
        private var appearing: Set<ObjectIdentifier> = []

        // MARK: - Path coin variants
        private enum PathCoinVariant: CaseIterable {
            case coin
            case giftBox
            case hamburger

            var modelName: String {
                switch self {
                case .coin: return "coin.usdz"
                case .giftBox: return "giftBox.usdz"
                case .hamburger: return "hamburger.usdz"
                }
            }
        }

        // templates (loaded once, cloned per spawn)
        private lazy var coinTemplate: ModelEntity = loadModelTemplate(named: "coin.usdz")
        private lazy var giftBoxTemplate: ModelEntity = loadModelTemplate(named: "giftBox.usdz")
        private lazy var hamburgerTemplate: ModelEntity = loadModelTemplate(named: "hamburger.usdz")

        private func template(for variant: PathCoinVariant) -> ModelEntity {
            switch variant {
            case .coin: return coinTemplate
            case .giftBox: return giftBoxTemplate
            case .hamburger: return hamburgerTemplate
            }
        }

        private func randomPathVariant() -> PathCoinVariant {
            PathCoinVariant.allCases.randomElement() ?? .coin
        }

        // 在场景内离屏校准：读取每个模板在 ARView 中的真实 bounds，再算缩放
        // 这比“离场景估算 visualBounds/mesh bounds”可靠，避免出现巨倍率导致遮屏。
        private var calibratedPathScale: [PathCoinVariant: Float] = [:]

        private func maxWorldExtent(_ e: Entity) -> Float {
            let b = e.visualBounds(relativeTo: nil)
            return max(b.extents.x, max(b.extents.y, b.extents.z))
        }

        private func calibratePathVariantScalesIfNeeded(in arView: ARView) {
            // 已经校准过就不重复做（避免每次生成都测）
            if calibratedPathScale.count == PathCoinVariant.allCases.count { return }

            // 离屏锚点：放到视野外
            let a = AnchorEntity(world: SIMD3<Float>(0, -10, 0))
            arView.scene.addAnchor(a)

            // 1) 测 coin 在 scale=1 的最大边
            let coinProbe = coinTemplate.clone(recursive: true)
            coinProbe.scale = SIMD3<Float>(repeating: 1)
            a.addChild(coinProbe)
            let coinE1 = maxWorldExtent(coinProbe)
            coinProbe.removeFromParent()

            // 防呆：如果 coin 尺寸都测不到，就直接回退不做校准
            guard coinE1 > 1e-6 else {
                a.removeFromParent()
                return
            }

            // 2) 计算每个变体：让其最大边 = coin 的最大边 * 相对倍率
            for v in PathCoinVariant.allCases {
                let probe = template(for: v).clone(recursive: true)
                probe.scale = SIMD3<Float>(repeating: 1)
                a.addChild(probe)
                let e1 = maxWorldExtent(probe)
                probe.removeFromParent()

                let ratio = extraScale(for: v) // coin=1，giftBox/hamburger 你设为 0.25
                if e1 > 1e-6 {
                    // scaleNeeded = (coinE1 * pathCoinScale * ratio) / e1
                    let s = (coinE1 * pathCoinScale * ratio) / e1
                    calibratedPathScale[v] = max(0.001, min(10, s))
                } else {
                    // 测不到就兜底：coin 用 pathCoinScale，其它按 ratio
                    calibratedPathScale[v] = max(0.001, min(10, pathCoinScale * ratio))
                }
            }

            a.removeFromParent()
        }

        private func loadModelTemplate(named name: String) -> ModelEntity {
            do {
                return try ModelEntity.loadModel(named: name)
            } catch {
                print("❌ Failed to load model:", name, "error:", error)
                return makeFallbackCoinTemplate()
            }
        }

        private func makeFallbackCoinTemplate() -> ModelEntity {
            // 一个简单的“金币”占位：薄圆柱体
            let mesh = MeshResource.generateCylinder(height: 0.006, radius: 0.04)
            let mat = SimpleMaterial(color: .yellow, isMetallic: true)
            return ModelEntity(mesh: mesh, materials: [mat])
        }

        // MARK: - Coin idle animation params
        private var updateSub: Cancellable?
        private var time: Float = 0

        private let spinSpeed: Float = 1.6
        private let bobAmp: Float = 0.015
        private let bobSpeed: Float = 2.2
        // coin 是 anchor 的 child，局部 y 正常应接近 0；异常时做限幅+重置兜底
        private let maxCoinLocalYAbs: Float = 0.20

        // MARK: - Collect params
        private let collectRadiusXZ: Float = 0.55
        private let maxVerticalDiff: Float = 1.6

        // Attract animation
        private let attractDuration: TimeInterval = 0.32
        private let attractHeight: Float = 0.15
        private let attractSide: Float = 0.08
        private let attractYOffset: Float = -0.10

        // MARK: - Path recording
        private var recordedPath: [SIMD3<Float>] = []
        private var lastRecordedPos: SIMD3<Float>?
        private let recordStep: Float = 0.12

        // debug small spheres anchors
        private var pathDebugAnchors: [AnchorEntity] = []
        // debug markers for path coins
        private var pathCoinDebugAnchors: [AnchorEntity] = []

        // MARK: - Path energy flow (sprite guide)
        private var flowAnchor: AnchorEntity?
        private var flowSprites: [ModelEntity] = []
        // swarm center cursor (single cluster moving along path)
        private var flowCenterCursor: Float = 0
        private var flowOffsets: [SIMD3<Float>] = []
        private var flowSamples: [SIMD3<Float>] = []
        private var flowBaseOpacity: [Float] = []
        private var flowPhaseA: [Float] = []
        private var flowPhaseB: [Float] = []
        private let flowSpacing: Float = 0.22
        // “萤火虫簇”：一团虫群沿路径飞行（更像活物，不像画线）
        private let flowCount: Int = 10
        private let flowSpeed: Float = 0.32            // 稍微快一点点
        private let flowHeightOffset: Float = 0.22     // 更高一些，避免像“地面提示”
        private let flowSpriteSize: Float = 0.020      // 更小一点更像萤火虫
        private let flowSpriteAlpha: Float = 0.95
        private let flowBobAmpY: Float = 0.055
        private let flowWobbleAmpXZ: Float = 0.055
        private let flowFlickerSpeed: Float = 2.8
        // 虫群形状：更“狭长”一些（沿路径方向更长，横向更窄）
        private let flowSwarmRadiusSide: Float = 0.12
        private let flowSwarmRadiusUp: Float = 0.10
        private let flowSwarmLengthForward: Float = 0.26
        private let flowSwarmForwardJitter: Float = 0.14
        private let flowSwarmCohesion: Float = 0.18    // 越大越聚（用于轻微拉回）

        // MARK: - Debug toggles
        private let debugShowPathCoinMarkers: Bool = false
        private let debugLogPathCoinSpawn: Bool = false

        // MARK: - Path gameplay params
        private let warningDistance: Float = 0.25
        private let deathDistance: Float = 0.5

        // MARK: - Spawn visibility guard
        // 避免把币生成在相机“脸上/脚下”导致近裁剪：看不见但能碰到/能收集
        private let minSpawnDistanceFromCameraXZ: Float = 0.35

        // MARK: - Ground estimation / Debug
        // 用于过滤“桌面/台阶”等高处水平面
        private let maxGroundAboveCamera: Float = -0.05 // 地面必须在相机 y 以下至少 5cm
        private let maxGroundJump: Float = 0.6          // 单次落地点高度跳变阈值（米）
        private var lastGoodGroundY: Float?

        // Debug: 把路径金币替换成非常显眼的几何体（用于确认“是不是 USDZ/材质问题”）
        private let debugPathCoinsUseVisiblePrimitive: Bool = false
        private let debugLogPlacedPathCoinEntity: Bool = false

        // MARK: - Ready params (关键：等距采样 + 出现动画)
        private let coinSpacing: Float = 0.9        // 路径上金币间距（米）
        private let coinGroundOffsetY: Float = 0.30 // 金币离地高度（你之前喜欢 0.30 左右）
        // 生成节奏：不要太密，否则体感像“一次性全刷出来”
        private let readySpawnInterval: TimeInterval = 0.13
        private let readyPopDuration: TimeInterval = 0.18
        private let readyBounceDuration: TimeInterval = 0.10
        private let readyRiseFromBelow: Float = 0.22
        private let readyOvershootY: Float = 0.07

        // MARK: - Coin scale tuning
        // 手点金币目前视觉大小 OK；路径金币之前看起来偏小（主要是出现动画初始状态+尺度差异）
        private let buildCoinScale: Float = 2.0
        private let pathCoinScale: Float = 2.0
        // ✅ giftBox/hamburger 相对 coin 的尺寸（1 = 和 coin 一样大；0.25 = coin 的 1/4）
        private let giftBoxExtraScale: Float = 0.25
        private let hamburgerExtraScale: Float = 0.25

        private func extraScale(for variant: PathCoinVariant) -> Float {
            switch variant {
            case .coin: return 1.0
            case .giftBox: return giftBoxExtraScale
            case .hamburger: return hamburgerExtraScale
            }
        }

        // Ready 期间避免重复触发
        private var isPreparingLevel: Bool = false
        private var spawnTask: Task<Void, Never>?

        // MARK: - Gesture: Tap to place coin (Build)
        @objc func handleTap(_ sender: UITapGestureRecognizer) {
            guard mode.wrappedValue == .build else { return }
            guard let arView = arView else { return }

            let loc = sender.location(in: arView)
            let results = arView.raycast(from: loc,
                                         allowing: .existingPlaneGeometry,
                                         alignment: .horizontal)
            guard let hit = results.first else { return }

            placeCoin(at: hit.worldTransform, withAppear: false, appearDelay: 0)
        }

        // MARK: - Update Loop
        func startUpdateLoop() {
            guard updateSub == nil, let arView = arView else { return }

            updateSub = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] e in
                guard let self else { return }

                self.time += Float(e.deltaTime)

                guard let frame = self.arView?.session.currentFrame else { return }
                let camT = frame.camera.transform
                let camPos = SIMD3<Float>(camT.columns.3.x, camT.columns.3.y, camT.columns.3.z)

                // Record tool (only when recording)
                self.updateRecording(camPos)

                // Idle animation for coins (skip attracting)
                self.updateCoinsIdle(deltaTime: e.deltaTime)

                // Play: collect + warning/death
                self.updateCollect(camPos: camPos)
                self.updatePathWarning(camPos: camPos)
                self.updateFlowGuide(deltaTime: e.deltaTime)
            }
        }

        // MARK: - Recording tool
        private func startRecording() {
            // 允许从 none 或 recorded 重新开始
            recordedPath.removeAll()
            lastRecordedPos = nil
            lastGoodGroundY = nil

            // 清掉旧 debug 球
            clearDebugPath()
            clearFlowGuide()

            pathStatus.wrappedValue = .recording
        }

        private func stopRecording() {
            pathStatus.wrappedValue = .recorded
        }

        private func updateRecording(_ camPos: SIMD3<Float>) {
            guard pathStatus.wrappedValue == .recording else { return }

            if let last = lastRecordedPos {
                let dx = camPos.x - last.x
                let dz = camPos.z - last.z
                let d = sqrt(dx*dx + dz*dz)
                guard d >= recordStep else { return }
            }

            recordedPath.append(camPos)
            lastRecordedPos = camPos
            placeDebugPathPoint(at: camPos)
        }

        private func placeDebugPathPoint(at pos: SIMD3<Float>) {
            guard let arView else { return }

            let mesh = MeshResource.generateSphere(radius: 0.02)
            let mat = SimpleMaterial(color: .cyan, isMetallic: false)
            let e = ModelEntity(mesh: mesh, materials: [mat])

            let a = AnchorEntity(world: pos)
            a.addChild(e)
            arView.scene.addAnchor(a)
            pathDebugAnchors.append(a)
        }

        private func clearDebugPath() {
            for a in pathDebugAnchors { a.removeFromParent() }
            pathDebugAnchors.removeAll()
        }

        private func clearPathCoinDebugMarkers() {
            for a in pathCoinDebugAnchors { a.removeFromParent() }
            pathCoinDebugAnchors.removeAll()
        }

        // MARK: - Flow guide (energy sprites)
        private static func makeRadialSpriteCGImage(size: Int, base: UIColor) -> CGImage? {
            let s = CGSize(width: size, height: size)
            let r = UIGraphicsImageRenderer(size: s)
            let img = r.image { ctx in
                let cg = ctx.cgContext
                cg.setFillColor(UIColor.clear.cgColor)
                cg.fill(CGRect(origin: .zero, size: s))

                // 先裁剪成圆形：这样无论怎么画渐变，都不会出现“方形边框”
                let circleRect = CGRect(origin: .zero, size: s)
                cg.addEllipse(in: circleRect.insetBy(dx: 1, dy: 1))
                cg.clip()

                // 中心白亮点更大一点，整体更明显
                let colors = [
                    UIColor.white.withAlphaComponent(1.0).cgColor,
                    base.withAlphaComponent(0.95).cgColor,
                    base.withAlphaComponent(0.05).cgColor,
                    base.withAlphaComponent(0.0).cgColor
                ]
                let locs: [CGFloat] = [0.0, 0.22, 0.62, 1.0]
                let space = CGColorSpaceCreateDeviceRGB()
                guard let grad = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locs) else { return }
                let center = CGPoint(x: s.width/2, y: s.height/2)
                cg.drawRadialGradient(grad,
                                      startCenter: center, startRadius: 0,
                                      endCenter: center, endRadius: s.width/2,
                                      // 允许渐变填充到圆形边缘，外部已被 clip 掉，不会出现方框
                                      options: [.drawsAfterEndLocation])
            }
            return img.cgImage
        }

        private func randomFireflyBaseColor() -> UIColor {
            // 青绿 ↔ 蓝青 之间轻微随机
            let a = UIColor(red: 0.20, green: 1.00, blue: 0.75, alpha: 1.0) // greener
            let b = UIColor(red: 0.35, green: 0.95, blue: 1.00, alpha: 1.0) // bluer
            let t = CGFloat.random(in: 0...1)

            var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
            var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
            a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
            b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)

            func lerp(_ x: CGFloat, _ y: CGFloat, _ t: CGFloat) -> CGFloat { x + (y - x) * t }
            return UIColor(red: lerp(ar, br, t),
                           green: lerp(ag, bg, t),
                           blue: lerp(ab, bb, t),
                           alpha: 1.0)
        }

        private func buildFlowGuideIfNeeded() {
            guard let arView else { return }
            guard mode.wrappedValue == .play else { return }
            guard flowAnchor == nil else { return }
            guard recordedPath.count >= 2 else { return }

            // 更密的采样让流动更平滑
            let samples = samplePathEqualSpacing(recordedPath, spacing: flowSpacing)
            guard samples.count >= 2 else { return }

            // 把 y 落到地面附近（一次性预计算）
            let camY = arView.session.currentFrame?.camera.transform.columns.3.y ?? samples[0].y
            flowSamples = samples.map { p in
                let gy = findGroundY(near: p, cameraY: camY, in: arView) ?? lastGoodGroundY ?? p.y
                return SIMD3<Float>(p.x, gy + flowHeightOffset, p.z)
            }

            // anchor 用世界原点即可（子节点用 world transform 更新）
            let a = AnchorEntity(world: .zero)
            arView.scene.addAnchor(a)
            flowAnchor = a

            // 改成“发光小球”来保证一定可见（不依赖 alpha/纹理混合）
            let mesh = MeshResource.generateSphere(radius: flowSpriteSize * 0.45)

            flowSprites.removeAll()
            flowCenterCursor = 0
            flowOffsets.removeAll()
            flowBaseOpacity.removeAll()
            flowPhaseA.removeAll()
            flowPhaseB.removeAll()
            flowSprites.reserveCapacity(flowCount)
            flowOffsets.reserveCapacity(flowCount)
            flowBaseOpacity.reserveCapacity(flowCount)
            flowPhaseA.reserveCapacity(flowCount)
            flowPhaseB.reserveCapacity(flowCount)

            // 让虫群从路径上的随机位置开始
            let maxIdx = Float(flowSamples.count - 1)
            flowCenterCursor = Float.random(in: 0..<max(1, maxIdx))

            for i in 0..<flowCount {
                // 每只萤火虫一个轻微不同的色相（只生成一次，不每帧改材质）
                let baseColor = randomFireflyBaseColor()
                var mat = UnlitMaterial()
                mat.color = .init(tint: baseColor.withAlphaComponent(1.0))

                let e = ModelEntity(mesh: mesh, materials: [mat])
                e.position = SIMD3<Float>(repeating: 0)
                a.addChild(e)
                flowSprites.append(e)

                // 初始随机分布在一个“椭球”内（狭长虫群）
                let ox = Float.random(in: -1...1) * flowSwarmRadiusSide
                let oy = abs(Float.random(in: -1...1)) * flowSwarmRadiusUp
                let oz = Float.random(in: -1...1) * flowSwarmLengthForward
                flowOffsets.append(SIMD3<Float>(ox, oy, oz))

                // “萤火虫”特征：前面更亮、后面更淡，再叠加随机闪烁
                let t = Float(i) / max(1, Float(flowCount - 1))
                let baseOpacity = (0.35 + 0.60 * (1 - t)) * flowSpriteAlpha
                flowBaseOpacity.append(baseOpacity)
                flowPhaseA.append(Float.random(in: 0..<(2 * .pi)))
                flowPhaseB.append(Float.random(in: 0..<(2 * .pi)))

                e.components.set(OpacityComponent(opacity: baseOpacity))
            }
        }

        private func clearFlowGuide() {
            flowSprites.forEach { $0.removeFromParent() }
            flowSprites.removeAll()
            flowCenterCursor = 0
            flowOffsets.removeAll()
            flowSamples.removeAll()
            flowBaseOpacity.removeAll()
            flowPhaseA.removeAll()
            flowPhaseB.removeAll()
            flowAnchor?.removeFromParent()
            flowAnchor = nil
        }

        private func updateFlowGuide(deltaTime: TimeInterval) {
            guard mode.wrappedValue == .play else { return }
            guard !recordedPath.isEmpty else { return }
            buildFlowGuideIfNeeded()
            guard let arView else { return }
            guard flowSamples.count >= 2, flowSprites.count == flowOffsets.count, !flowSprites.isEmpty else { return }

            guard let frame = arView.session.currentFrame else { return }
            let camT = frame.camera.transform
            let camPos = SIMD3<Float>(camT.columns.3.x, camT.columns.3.y, camT.columns.3.z)

            let dt = Float(deltaTime)
            let advancePoints = (flowSpeed * dt) / max(1e-6, flowSpacing)
            let maxIdx = Float(flowSamples.count - 1)

            // 让“虫群中心”沿路径循环移动
            flowCenterCursor += advancePoints
            if flowCenterCursor >= maxIdx { flowCenterCursor -= maxIdx }

            let c = flowCenterCursor
            let idx = Int(c)
            let frac = c - Float(idx)
            let p0 = flowSamples[idx]
            let p1 = flowSamples[min(idx + 1, flowSamples.count - 1)]
            let centerPos = p0 + (p1 - p0) * frac

            // 构建一个“沿路径方向”的局部坐标系：forward/right/up
            var forward = SIMD3<Float>(p1.x - p0.x, 0, p1.z - p0.z)
            if simd_length_squared(forward) < 1e-6 { forward = SIMD3<Float>(0, 0, -1) }
            forward = simd_normalize(forward)
            let up = SIMD3<Float>(0, 1, 0)
            var right = simd_cross(up, forward)
            if simd_length_squared(right) < 1e-6 { right = SIMD3<Float>(1, 0, 0) }
            right = simd_normalize(right)

            for i in 0..<flowSprites.count {
                // 轻微“群聚力”：把偏离的 offset 慢慢拉回
                var o = flowOffsets[i]
                o *= (1 - flowSwarmCohesion * dt)

                // 萤火虫自己的 flutter（局部随机游走）
                let pha = flowPhaseA[i] + time * 1.55
                let phb = flowPhaseB[i] + time * 1.05
                let flutter = SIMD3<Float>(
                    sin(phb) * flowWobbleAmpXZ,
                    sin(pha) * flowBobAmpY,
                    cos(phb) * flowWobbleAmpXZ
                )
                o += flutter * dt

                // 前后方向再给一点 jitter，让群更“活”
                let fJ = (sin(pha * 1.3) * 0.5 + 0.5) * flowSwarmForwardJitter
                let local = right * o.x + up * o.y + forward * (o.z + fJ)
                flowOffsets[i] = o

                var pos = centerPos + local

                // 让它更“飞”：离相机太近时略微抬高一点点，避免贴脸像 UI
                let dx = camPos.x - pos.x
                let dz = camPos.z - pos.z
                let distXZ = sqrt(dx*dx + dz*dz)
                if distXZ < 0.55 {
                    pos.y += (0.55 - distXZ) * 0.08
                }

                // 呼吸 + 闪烁
                let pulsePhase = (Float(i) * 0.55) + time * 2.0
                let pulse = (sin(pulsePhase) + 1) * 0.5
                let flicker = (sin(flowPhaseB[i] + time * flowFlickerSpeed) + 1) * 0.5
                let scale = 0.70 + 0.55 * pulse
                let alpha = min(1.0, max(0.04, flowBaseOpacity[i] * (0.30 + 0.80 * flicker)))

                let sprite = flowSprites[i]
                sprite.position = pos
                sprite.scale = SIMD3<Float>(repeating: scale)
                sprite.components.set(OpacityComponent(opacity: alpha))
            }
        }

        private func placePathCoinDebugMarker(at worldPos: SIMD3<Float>, index: Int) {
            guard debugShowPathCoinMarkers, let arView else { return }
            // 用 UnlitMaterial，确保在弱光/曝光变化下也非常显眼
            let mesh = MeshResource.generateSphere(radius: 0.035)
            var mat = UnlitMaterial()
            mat.color = .init(tint: .magenta)
            let e = ModelEntity(mesh: mesh, materials: [mat])
            e.position = .zero

            let a = AnchorEntity(world: worldPos)
            a.addChild(e)
            arView.scene.addAnchor(a)
            pathCoinDebugAnchors.append(a)

            if debugLogPathCoinSpawn {
                print("🟣 [PathCoinMarker #\(index)] worldPos =", worldPos)
            }
        }

        // MARK: - Coin placement helper
        private func configureCoinMaterial(_ coin: ModelEntity, forPathCoin: Bool) {
            // Debug：路径金币先用 Unlit 纯色材质（极易可见），排除“模型材质太暗/太反光”的可能
            if forPathCoin && debugPathCoinsUseVisiblePrimitive {
                // 这里不改 USDZ 的 mesh，只换材质
                var m = UnlitMaterial()
                m.color = .init(tint: .yellow)
                coin.model?.materials = [m]
                return
            }

            if var mat = coin.model?.materials.first as? PhysicallyBasedMaterial {
                mat.baseColor.tint = UIColor(red: 0.95, green: 0.82, blue: 0.35, alpha: 1.0)
                mat.metallic  = .init(floatLiteral: 0.85)
                mat.roughness = .init(floatLiteral: 0.45)
                coin.model?.materials = [mat]
            }
        }

        private func placeCoin(at worldTransform: simd_float4x4,
                               withAppear: Bool,
                               appearDelay: TimeInterval,
                               isPathCoin: Bool = false) {

            guard let arView else { return }

            // ✅ 1. 用 wt，并抬高
            var wt = worldTransform
            wt.columns.3.y += coinGroundOffsetY

            // ✅ 2. position 必须从 wt 取
            let pos = SIMD3<Float>(
                wt.columns.3.x,
                wt.columns.3.y,
                wt.columns.3.z
            )
            // 用 world anchor 更稳定（尤其是估算平面/户外环境）
            let anchor = AnchorEntity(world: pos)

            let coin: ModelEntity
            let targetScale: SIMD3<Float>
            if isPathCoin && debugPathCoinsUseVisiblePrimitive {
                // 尺寸刻意做大，确保肉眼一定能看到
                let mesh = MeshResource.generateBox(size: 0.28)
                var mat = UnlitMaterial()
                mat.color = .init(tint: .yellow)
                coin = ModelEntity(mesh: mesh, materials: [mat])
                targetScale = SIMD3<Float>(repeating: 1.0) // box 本身已够大
            } else {
                if isPathCoin {
                    let v = randomPathVariant()
                    coin = template(for: v).clone(recursive: true)
                    // 只有 coin 变体才改金色材质；giftBox/hamburger 保持原材质贴图
                    if v == .coin { configureCoinMaterial(coin, forPathCoin: true) }
                    calibratePathVariantScalesIfNeeded(in: arView)
                    let s = calibratedPathScale[v] ?? (pathCoinScale * extraScale(for: v))
                    targetScale = SIMD3<Float>(repeating: s)
                } else {
                    coin = coinTemplate.clone(recursive: true)
                    configureCoinMaterial(coin, forPathCoin: false)
                    targetScale = SIMD3<Float>(repeating: buildCoinScale)
                }
            }

            // ✅ 3. coin 局部坐标归零
            coin.position = .zero
            // 不依赖 collision 做收集判定（我们是距离判定），这里避免每次生成都做重计算导致卡顿
            // coin.generateCollisionShapes(recursive: true)

            // 出现动画：不要从“极小+下沉”开始（很容易肉眼看不到）
            // 改成从“较大缩放”弹到目标缩放，且不做 y 位移
            let effectiveWithAppear = (isPathCoin && debugPathCoinsUseVisiblePrimitive) ? false : withAppear
            if effectiveWithAppear {
                // 从下方冒出来
                coin.scale = targetScale * 0.55
                coin.position = SIMD3<Float>(0, -readyRiseFromBelow, 0)
            } else {
                coin.scale = targetScale
                coin.position = .zero
            }

            anchor.addChild(coin)
            arView.scene.addAnchor(anchor)

            // 记录 coin
            coins.append(coin)
            if isPathCoin { pathCoins.append(coin) }
            let id = ObjectIdentifier(coin)
            coinBaseY[id] = coin.position.y
            coinPhase[id] = Float.random(in: 0..<(2 * .pi))

            if isPathCoin && debugPathCoinsUseVisiblePrimitive && debugLogPlacedPathCoinEntity {
                let wm = coin.transformMatrix(relativeTo: nil)
                let wpos = SIMD3<Float>(wm.columns.3.x, wm.columns.3.y, wm.columns.3.z)
                let b = coin.visualBounds(relativeTo: nil)
                print("🟨 [PathCoinEntity] wpos =", wpos,
                      "extents =", b.extents,
                      "center =", b.center,
                      "scale =", coin.scale)
            }

            guard effectiveWithAppear else { return }

            let duration = readyPopDuration
            appearing.insert(id)
            DispatchQueue.main.asyncAfter(deadline: .now() + appearDelay) { [weak self] in
                guard let self else { return }

                // 1) 上冲 + 轻微过冲（更生动）
                let mid = Transform(
                    scale: targetScale * 1.06,
                    rotation: coin.transform.rotation,
                    translation: SIMD3<Float>(0, self.readyOvershootY, 0)
                )
                coin.move(to: mid,
                          relativeTo: coin.parent,
                          duration: duration,
                          timingFunction: .easeOut)

                // 2) 回弹落位
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                    guard let self else { return }
                    let final = Transform(
                        scale: targetScale,
                        rotation: coin.transform.rotation,
                        translation: .zero
                    )
                    coin.move(to: final,
                              relativeTo: coin.parent,
                              duration: self.readyBounceDuration,
                              timingFunction: .easeInOut)

                    DispatchQueue.main.asyncAfter(deadline: .now() + self.readyBounceDuration) {
                        // 兜底：确保最终尺寸正确
                        coin.scale = targetScale
                        coin.position = .zero
                        let oid = ObjectIdentifier(coin)
                        self.appearing.remove(oid)
                        self.coinBaseY[oid] = coin.position.y
                    }
                }
            }
        }

        // MARK: - READY (核心实现)
        private func prepareLevel() {
            guard !isPreparingLevel else { return }
            isPreparingLevel = true
            lastGoodGroundY = nil
            spawnTask?.cancel()
            spawnTask = nil

            // 1) mode 进入 ready（UI 已经先切了，这里保证一致）
            mode.wrappedValue = .ready
            isWarning.wrappedValue = false

            // 2) 录制中不允许准备（UI 已禁用；这里再兜底）
            if pathStatus.wrappedValue == .recording {
                isPreparingLevel = false
                return
            }

            // 3) 清掉 debug 路径球（你要求：debug 球不等于金币）
            clearDebugPath()
            // Ready 阶段不显示能量流（避免画面太吵）
            clearFlowGuide()

            // 3.5) 清掉旧“路径金币”，避免多次 Prepare 重复叠加
            clearPathCoins()
            clearPathCoinDebugMarkers()

            // 4) 生成路径金币点（等距采样 + 落地）
            let sampledXZ = samplePathEqualSpacing(recordedPath, spacing: coinSpacing)
            if debugLogPathCoinSpawn {
                print("🧭 [PrepareLevel] recordedPath =", recordedPath.count, "sampled =", sampledXZ.count)
            }

            // 5) 我们不会删除 build 阶段你手点放的金币（那是“设计工具”）
            //    这里只是把“路径金币”追加生成。
            //    如果你想 ready 时清掉手点金币，也能做（但你没要求）。

            // 6) 逐个生成：从近到远出现（从无到有）
            //    先把点做一次“按离当前相机距离排序”，视觉更合理
            var spawnPoints: [SIMD3<Float>] = []
            if let frame = arView?.session.currentFrame {
                let cam = frame.camera.transform
                let camPos = SIMD3<Float>(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
                if debugLogPathCoinSpawn {
                    print("📷 [PrepareLevel] camPos =", camPos)
                }
                // 先过滤掉离相机太近的点（XZ），否则可能被 near plane clip 掉
                let filtered = sampledXZ.filter { p in
                    let dx = p.x - camPos.x
                    let dz = p.z - camPos.z
                    return sqrt(dx*dx + dz*dz) >= minSpawnDistanceFromCameraXZ
                }

                spawnPoints = filtered.sorted { a, b in
                    let da = (a.x - camPos.x)*(a.x - camPos.x) + (a.z - camPos.z)*(a.z - camPos.z)
                    let db = (b.x - camPos.x)*(b.x - camPos.x) + (b.z - camPos.z)*(b.z - camPos.z)
                    return da < db
                }
            } else {
                spawnPoints = sampledXZ
            }
            if debugLogPathCoinSpawn {
                print("🪙 [PrepareLevel] spawnPoints =", spawnPoints.count)
                if let first = spawnPoints.first { print("🪙 [PrepareLevel] firstSpawnPoint =", first) }
            }

            // 7) 对每个 spawn 点做“向下落地”并生成 coin
            //    （户外没平面时 estimated plane 也能工作一部分；失败则回退用原 y）
            let totalToSpawn = spawnPoints.count
            if totalToSpawn == 0 {
                // 没有路径也可以 ready -> play（只靠手点金币）
                finalizeReadyAfter(delay: 0.25)
                return
            }

            // ✅ 用单个 Task 顺序生成：不会一次性创建很多 timer，体感更“一个接一个”
            spawnTask = Task { [weak self] in
                guard let self else { return }
                for (idx, p) in spawnPoints.enumerated() {
                    if Task.isCancelled { return }
                    // 稍微让出主线程，让 UI 有机会刷新（减少“点一下卡住”的感觉）
                    try? await Task.sleep(nanoseconds: UInt64(self.readySpawnInterval * 1_000_000_000))
                    guard let arView = self.arView else { return }

                    let camY = arView.session.currentFrame?.camera.transform.columns.3.y ?? p.y
                    let groundY = self.findGroundY(near: p, cameraY: camY, in: arView)
                    ?? self.lastGoodGroundY
                    ?? p.y

                    let worldPos = SIMD3<Float>(p.x, groundY, p.z)
                    var tt = matrix_identity_float4x4
                    tt.columns.3 = SIMD4<Float>(worldPos.x, worldPos.y, worldPos.z, 1)

                    self.placePathCoinDebugMarker(at: SIMD3<Float>(worldPos.x, worldPos.y + self.coinGroundOffsetY, worldPos.z),
                                                  index: idx)
                    self.placeCoin(at: tt, withAppear: true, appearDelay: 0, isPathCoin: true)
                }

                // 全部生成完 -> 结束 ready（把回弹时间也算进去）
                self.finalizeReadyAfter(delay: self.readyPopDuration + self.readyBounceDuration + 0.15)
                self.spawnTask = nil
            }
        }

        private func finalizeReadyAfter(delay: TimeInterval) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }

                // totalCoinsThisRun 由 AR 侧锁定（包含手点金币 + 路径金币）
                self.totalCoinsThisRun.wrappedValue = self.coins.count

                // 通知 ContentView：Ready 完成 -> 自动切 play
                self.arReadyFinished.wrappedValue = true

                self.isPreparingLevel = false
            }
        }

        // MARK: - Path sampling (Equal spacing in XZ)
        // 只按水平距离（XZ）采样，让“手机高度变化/手抖”不影响金币密度
        private func samplePathEqualSpacing(_ path: [SIMD3<Float>], spacing: Float) -> [SIMD3<Float>] {
            guard path.count >= 2 else { return [] }
            guard spacing > 0 else { return [] }

            var result: [SIMD3<Float>] = []
            result.reserveCapacity(max(8, Int(Float(path.count) * 0.6)))

            // 从起点开始
            var prev = path[0]
            result.append(prev)

            var acc: Float = 0

            for i in 1..<path.count {
                let cur = path[i]

                // 只看 XZ
                var seg = SIMD3<Float>(cur.x - prev.x, 0, cur.z - prev.z)
                var segLen = simd_length(seg)
                if segLen < 1e-5 {
                    prev = cur
                    continue
                }

                while acc + segLen >= spacing {
                    let remain = spacing - acc
                    let t = remain / segLen

                    // 线性插值（XZ）
                    let nx = prev.x + (cur.x - prev.x) * t
                    let nz = prev.z + (cur.z - prev.z) * t

                    // y 暂时保留 prev 的 y（后面会落地 raycast 纠正）
                    let ny = prev.y + (cur.y - prev.y) * t

                    let np = SIMD3<Float>(nx, ny, nz)
                    result.append(np)

                    // 下一段从 np 继续
                    prev = np
                    seg = SIMD3<Float>(cur.x - prev.x, 0, cur.z - prev.z)
                    segLen = simd_length(seg)
                    acc = 0
                }

                acc += segLen
                prev = cur
            }

            return result
        }

        // MARK: - Ground finding (downward raycast)
        // 在户外没有“已检测到的平面”时，estimatedPlane 比 existingPlaneGeometry 更可靠
        private func findGroundY(near p: SIMD3<Float>, cameraY: Float, in arView: ARView) -> Float? {
            // origin 用 cameraY 更稳：p.y 是“录制时相机高度插值”，可能抖动或不在真实地面附近
            let origin = SIMD3<Float>(p.x, cameraY + 2.0, p.z)
            let direction = SIMD3<Float>(0, -1, 0)

            let query = ARRaycastQuery(
                origin: origin,
                direction: direction,
                allowing: .estimatedPlane,
                alignment: .horizontal
            )

            let hits = arView.session.raycast(query)
            guard !hits.isEmpty else { return nil }

            let ys = hits.map { $0.worldTransform.columns.3.y }

            // 1) 优先只接受“在相机下方”的命中（避免桌面/高处平面）
            let belowCamera = ys.filter { $0 <= cameraY + maxGroundAboveCamera }

            // 2) 如果有历史地面高度，优先取“离上次地面最近”的那个（更稳定）
            func pickClosest(to target: Float, from candidates: [Float]) -> Float? {
                candidates.min(by: { abs($0 - target) < abs($1 - target) })
            }

            var candidate: Float?
            if let last = lastGoodGroundY, let c = pickClosest(to: last, from: belowCamera.isEmpty ? ys : belowCamera) {
                candidate = c
            } else {
                // 没有历史时：取最低的（尽量贴近“地面”）
                candidate = (belowCamera.isEmpty ? ys : belowCamera).min()
            }

            guard let chosen = candidate else { return nil }

            // 3) 再做一次“跳变”过滤：如果突然高很多，就回退到 lastGoodGroundY
            if let last = lastGoodGroundY, abs(chosen - last) > maxGroundJump {
                return last
            }

            lastGoodGroundY = chosen
            return chosen
        }

        // MARK: - Coin idle animation
        private func updateCoinsIdle(deltaTime: TimeInterval) {
            let dq = simd_quatf(angle: spinSpeed * Float(deltaTime), axis: [0, 1, 0])

            for coin in coins {
                let id = ObjectIdentifier(coin)
                if attracting.contains(id) { continue }
                if appearing.contains(id) { continue }

                coin.transform.rotation = dq * coin.transform.rotation

                var y0 = coinBaseY[id] ?? coin.position.y
                // 安全阀：局部 y 如果异常（突然变很高），先重置到 0，避免“集体升高后保持”
                if abs(y0) > maxCoinLocalYAbs {
                    y0 = 0
                    coinBaseY[id] = 0
                }
                let p = coinPhase[id] ?? 0
                let y = y0 + sin(time * bobSpeed + p) * bobAmp
                coin.position.y = max(-maxCoinLocalYAbs, min(maxCoinLocalYAbs, y))
            }
        }

        // MARK: - Collect
        private func updateCollect(camPos: SIMD3<Float>) {
            guard mode.wrappedValue == .play else { return }

            for i in stride(from: coins.count - 1, through: 0, by: -1) {
                let coin = coins[i]
                let id = ObjectIdentifier(coin)
                if attracting.contains(id) { continue }

                let m = coin.transformMatrix(relativeTo: nil)
                let pos = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)

                let dx = camPos.x - pos.x
                let dz = camPos.z - pos.z
                let dy = abs(camPos.y - pos.y)
                let distXZ = sqrt(dx*dx + dz*dz)

                guard distXZ < collectRadiusXZ, dy < maxVerticalDiff else { continue }

                attracting.insert(id)
                runAttract(coin: coin, camPos: camPos, index: i)
            }
        }

        private func runAttract(coin: ModelEntity, camPos: SIMD3<Float>, index: Int) {
            let duration = attractDuration
            let side: Float = Bool.random() ? attractSide : -attractSide

            let m = coin.transformMatrix(relativeTo: nil)
            let pos = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)

            let mid = Transform(
                scale: coin.transform.scale,
                rotation: coin.transform.rotation,
                translation: [pos.x + side, pos.y + attractHeight, pos.z]
            )

            let final = Transform(
                scale: coin.transform.scale,
                rotation: coin.transform.rotation,
                translation: [camPos.x, camPos.y + attractYOffset, camPos.z]
            )

            coin.move(to: mid,
                      relativeTo: nil,
                      duration: duration * 0.45,
                      timingFunction: .easeOut)

            DispatchQueue.main.asyncAfter(deadline: .now() + duration * 0.45) { [weak self] in
                guard let self else { return }
                coin.move(to: final,
                          relativeTo: nil,
                          duration: duration * 0.55,
                          timingFunction: .easeIn)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                guard let self else { return }

                let oid = ObjectIdentifier(coin)
                // ⚠️ 这里不能用 index 删除：异步期间 coins 可能已变化，导致误删
                self.removeCoinEverywhere(oid: oid)

                self.collectedCoins.wrappedValue += 1
                self.playCoinSound()

                // 通关判定：收集完 -> result
                if self.collectedCoins.wrappedValue >= self.totalCoinsThisRun.wrappedValue,
                   self.totalCoinsThisRun.wrappedValue > 0 {
                    DispatchQueue.main.async {
                        self.mode.wrappedValue = .result
                    }
                }
            }
        }

        // MARK: - Path warning / death
        private func updatePathWarning(camPos: SIMD3<Float>) {
            guard mode.wrappedValue == .play else {
                isWarning.wrappedValue = false
                dangerLevel.wrappedValue = 0
                return
            }
            guard !recordedPath.isEmpty else {
                // 没录路径，就不做“偏离死亡”（避免新手困惑）
                isWarning.wrappedValue = false
                dangerLevel.wrappedValue = 0
                return
            }

            var best: Float = .greatestFiniteMagnitude
            for p in recordedPath {
                let dx = camPos.x - p.x
                let dz = camPos.z - p.z
                let d = sqrt(dx*dx + dz*dz)
                if d < best { best = d }
            }

            let inGrace = (CACurrentMediaTime() - playStartedAt) < playGraceDuration

            if best > deathDistance {
                // 开局 grace：避免“刚开始就秒死”
                if !inGrace {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.mode.wrappedValue = .gameOver
                        self.isWarning.wrappedValue = false
                        self.dangerLevel.wrappedValue = 0
                    }
                }
            } else {
                // dangerLevel: 0..1 (warningDistance -> 0, deathDistance -> 1)
                let t = (best - warningDistance) / max(0.0001, (deathDistance - warningDistance))
                let clamped = max(0, min(1, t))
                // smoothstep，让变化更“游戏化”、不突兀
                let s = clamped * clamped * (3 - 2 * clamped)
                dangerLevel.wrappedValue = s
                isWarning.wrappedValue = (s > 0.001)
            }
        }

        // MARK: - Reset
        private func resetAll() {
            spawnTask?.cancel()
            spawnTask = nil
            // remove coins
            for c in coins { c.removeFromParent() }
            coins.removeAll()
            pathCoins.removeAll()
            coinBaseY.removeAll()
            coinPhase.removeAll()
            attracting.removeAll()
            appearing.removeAll()
            clearFlowGuide()

            // remove debug path
            clearDebugPath()
            clearPathCoinDebugMarkers()

            // clear path data
            recordedPath.removeAll()
            lastRecordedPos = nil
            lastGoodGroundY = nil
            pathStatus.wrappedValue = .none

            // clear anchors
            arView?.scene.anchors.removeAll()

            // ui state
            totalCoinsThisRun.wrappedValue = 0
            collectedCoins.wrappedValue = 0
            isWarning.wrappedValue = false
            dangerLevel.wrappedValue = 0
            arReadyFinished.wrappedValue = false

            // timers
            time = 0
            isPreparingLevel = false
        }

        // MARK: - Coin removal helpers
        private func clearPathCoins() {
            guard !pathCoins.isEmpty else { return }
            // ⚠️ 注意：不能边遍历 pathCoins 边修改它（removeCoinEverywhere 会 mutate）
            let toRemove = pathCoins
            pathCoins.removeAll()

            // 逐个按 oid 删除，确保字典/集合也同步清理
            for c in toRemove {
                removeCoinEverywhere(oid: ObjectIdentifier(c))
            }
        }

        private func removeCoinEverywhere(oid: ObjectIdentifier) {
            // 先从父节点移除（如果还在场景里）
            if let coin = coins.first(where: { ObjectIdentifier($0) == oid }) {
                coin.removeFromParent()
            }

            // 再从各容器移除引用
            coins.removeAll { ObjectIdentifier($0) == oid }
            pathCoins.removeAll { ObjectIdentifier($0) == oid }
            coinBaseY.removeValue(forKey: oid)
            coinPhase.removeValue(forKey: oid)
            attracting.remove(oid)
            appearing.remove(oid)
        }
    }
}
