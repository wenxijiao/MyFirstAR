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
    @Binding var warningDistance: Float
    @Binding var deathDistance: Float
    @Binding var deathEnabled: Bool
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
            warningDistance: $warningDistance,
            deathDistance: $deathDistance,
            deathEnabled: $deathEnabled,
            commands: $commands,
            arReadyFinished: $arReadyFinished
        )
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        // MARK: - AR Config
        // ✅ Build 阶段也需要更好的地形理解：启动时就启用 mesh（设备支持时）
        // 为了不让用户看到“黑屏卡死”，我们会在 App 启动时先显示加载页（MyFirstARApp.swift）。
        let config = makeSessionConfiguration(enableMesh: true)
        arView.session.run(config)

        // Lighting & Occlusion
        // ⚠️ occlusion 在很多环境下会把“贴地的小物体”吃掉（你描述的“能收集但看不到”很像这个）
        // 先默认关闭，保证金币可见；如果你确实想要遮挡效果，可以再加开关打开。
        arView.environment.sceneUnderstanding.options.insert(.receivesLighting)
        arView.environment.lighting.intensityExponent = 1.2

        // Gesture (build: tap to place coin)
        context.coordinator.arView = arView
        context.coordinator.onARViewReady()
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        arView.addGestureRecognizer(tap)

        // Start update loop once
        context.coordinator.startUpdateLoop()

        return arView
    }

    private func makeSessionConfiguration(enableMesh: Bool) -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        // 户外复杂地形（马路牙子/台阶）想要更可靠，需要 mesh（前提：设备支持 LiDAR）
        if enableMesh, ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        return config
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
        private let warningDistance: Binding<Float>
        private let deathDistance: Binding<Float>
        private let deathEnabled: Binding<Bool>
        private let commands: Binding<ARCommands>
        private let arReadyFinished: Binding<Bool>

        init(mode: Binding<GameMode>,
             pathStatus: Binding<PathStatus>,
             totalCoinsThisRun: Binding<Int>,
             collectedCoins: Binding<Int>,
             isWarning: Binding<Bool>,
             dangerLevel: Binding<Float>,
             warningDistance: Binding<Float>,
             deathDistance: Binding<Float>,
             deathEnabled: Binding<Bool>,
             commands: Binding<ARCommands>,
             arReadyFinished: Binding<Bool>) {

            self.mode = mode
            self.pathStatus = pathStatus
            self.totalCoinsThisRun = totalCoinsThisRun
            self.collectedCoins = collectedCoins
            self.isWarning = isWarning
            self.dangerLevel = dangerLevel
            self.warningDistance = warningDistance
            self.deathDistance = deathDistance
            self.deathEnabled = deathEnabled
            self.commands = commands
            self.arReadyFinished = arReadyFinished
            // ✅ 关键：避免第一次 updateUIView 时把所有 token 都当成“变化”
            // 因为 ARCommands() 默认是随机 UUID，如果 lastCommands 也用 ARCommands() 初始化，
            // 首帧会误触发 reset/prepare/startPlay 等逻辑，导致一启动就跳到 play。
            self.lastCommands = commands.wrappedValue

            super.init()
            setupAudioSession()
        }

        private var didPrewarm: Bool = false
        // mesh 已在启动 session 时启用（设备支持时），无需再在 play 阶段重复 session.run
        private var preloadCancellables: Set<AnyCancellable> = []
        private var preloadedTemplates: [PathCoinVariant: ModelEntity] = [:]

        // 典型“相机高度-地面高度”估计（raycast 全失败时兜底用）
        private let assumedCameraHeight: Float = 1.3

        func onARViewReady() {
            // 预热：避免第一次进 ready/play 时才加载资源导致卡顿
            prewarmOnce()
        }

        private func prewarmOnce() {
            guard !didPrewarm else { return }
            didPrewarm = true

            // 1) 预热音效池
            prepareSfxPoolIfNeeded()

            // 2) 模型异步并行预加载（避免在 init/首次访问时同步阻塞）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                self.preloadModelAsync(variant: .coin, name: "coin.usdz")
                self.preloadModelAsync(variant: .giftBox, name: "giftBox.usdz")
                self.preloadModelAsync(variant: .hamburger, name: "hamburger.usdz")
                self.preloadModelAsync(variant: .sakura, name: "sakura.usdz")
            }

            // 3) 预热缩放校准（需要 arView，稍后执行）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self, let arView = self.arView else { return }
                self.calibratePathVariantScalesIfNeeded(in: arView)
            }
        }

        private func preloadModelAsync(variant: PathCoinVariant, name: String) {
            // 已经有了就不重复
            if preloadedTemplates[variant] != nil { return }

            ModelEntity.loadModelAsync(named: name)
                .sink { completion in
                    if case let .failure(err) = completion {
                        print("❌ Async preload failed:", name, err)
                    }
                } receiveValue: { [weak self] entity in
                    self?.preloadedTemplates[variant] = entity
                }
                .store(in: &preloadCancellables)
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
        // 用 pool 避免频繁创建 player（减少卡顿/覆盖音效）
        private var sfxPlayers: [AVAudioPlayer] = []
        private var sfxIndex: Int = 0
        private let sfxPoolSize: Int = 8

        private lazy var coinSfxURL: URL? = {
            Bundle.main.url(forResource: soundName, withExtension: soundExt)
        }()

        private func prepareSfxPoolIfNeeded() {
            guard sfxPlayers.isEmpty else { return }
            guard let url = coinSfxURL else {
                print("❌ sound not found:", soundName, soundExt)
                return
            }
            do {
                sfxPlayers = try (0..<sfxPoolSize).map { _ in
                let p = try AVAudioPlayer(contentsOf: url)
                    p.volume = 0.55
                p.prepareToPlay()
                    return p
                }
                sfxIndex = 0
            } catch {
                print("❌ Sound pool error:", error)
                sfxPlayers.removeAll()
            }
        }

        private func playCoinSound() {
            prepareSfxPoolIfNeeded()
            guard !sfxPlayers.isEmpty else { return }

            let i = sfxIndex
            sfxIndex = (sfxIndex + 1) % sfxPlayers.count
            let p = sfxPlayers[i]
            p.currentTime = 0
            p.volume = Float.random(in: 0.45...0.65)
            p.play()
        }

        // MARK: - Commands token tracking
        private var lastCommands = ARCommands()
        private var playStartedAt: CFTimeInterval = 0
        // 入场保护：避免开局离路径远直接判死
        private let playGraceDuration: CFTimeInterval = 10.0

        // MARK: - Path distance perf
        private var lastNearestPathIndex: Int = 0
        private let nearestSearchWindow: Int = 80
        private var fullScanCooldown: Int = 0
        private let fullScanEveryNFrames: Int = 45

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
                // ✅ Play 切入时先不上惩罚：等玩家捡到第一个“路径生成物”再开启警告/死亡判定
                pathPenaltyArmed = false
                pathVisualDangerLevel = 0

                // mesh 已在启动时启用（设备支持时）

                // play 开始：如果有路径就显示“能量流”，否则清理
                if !recordedPath.isEmpty {
                    buildFlowGuideIfNeeded()
                } else {
                    clearFlowGuide()
                }
            }

            lastCommands = new
        }

        // ensureMeshEnabledIfNeeded 已移除（避免重复 session.run 引发额外卡顿）

        // MARK: - World / coin storage
        private var coins: [ModelEntity] = []
        // 只记录“路径生成”的金币（Ready/Prepare 时会清理它们，但不影响手点金币）
        private var pathCoins: [ModelEntity] = []
        // 追踪每个 coin 对应的 AnchorEntity，避免 reset 时全量 anchors.removeAll() 造成首轮大卡顿
        private var coinAnchorById: [ObjectIdentifier: AnchorEntity] = [:]
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
            case sakura

            var modelName: String {
                switch self {
                case .coin: return "coin.usdz"
                case .giftBox: return "giftBox.usdz"
                case .hamburger: return "hamburger.usdz"
                case .sakura: return "sakura.usdz"
                }
            }
        }

        // templates (loaded once, cloned per spawn)
        private lazy var coinTemplate: ModelEntity = loadModelTemplate(named: "coin.usdz")
        private lazy var giftBoxTemplate: ModelEntity = loadModelTemplate(named: "giftBox.usdz")
        private lazy var hamburgerTemplate: ModelEntity = loadModelTemplate(named: "hamburger.usdz")
        private lazy var sakuraTemplate: ModelEntity = loadModelTemplate(named: "sakura.usdz")

        private func template(for variant: PathCoinVariant) -> ModelEntity {
            if let t = preloadedTemplates[variant] { return t }
            switch variant {
            case .coin: return coinTemplate
            case .giftBox: return giftBoxTemplate
            case .hamburger: return hamburgerTemplate
            case .sakura: return sakuraTemplate
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

        // debug small spheres (single root anchor -> faster clear)
        private var pathDebugRoot: AnchorEntity?
        private var pathDebugPoints: [ModelEntity] = []
        // debug markers for path coins
        private var pathCoinDebugAnchors: [AnchorEntity] = []

        // MARK: - Path energy flow (sprite guide)
        private var flowAnchor: AnchorEntity?
        // iOS17+ 粒子版：只用一个 emitter 实体模拟虫群（更轻量、更“官方”）
        private var flowEmitterEntity: Entity?
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
        private let flowSpeed: Float = 0.50            // 虫群整体沿路径移动速度：恢复到原来（刚刚好）
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
        // ✅ 路径提示：固定一群“虫群实体”（像之前小球一样），不要持续发射新粒子
        private let flowUseParticleEmitter: Bool = false

        // MARK: - Coin pop sparkle (lightweight particles)
        private var sparkleAnchors: [AnchorEntity] = []
        private let sparkleBurstCount: Int = 10
        private let sparkleDuration: TimeInterval = 0.55

        // MARK: - Debug toggles
        private let debugShowPathCoinMarkers: Bool = false
        private let debugLogPathCoinSpawn: Bool = false

        // MARK: - Path gameplay params
        // warning/death 由 UI 传入（可调 + 可关闭 death）

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
        private let sakuraExtraScale: Float = 1.0

        private func extraScale(for variant: PathCoinVariant) -> Float {
            switch variant {
            case .coin: return 1.0
            case .giftBox: return giftBoxExtraScale
            case .hamburger: return hamburgerExtraScale
            case .sakura: return sakuraExtraScale
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

        deinit {
            // 兜底清理：避免 ARViewContainer 生命周期变化导致残留订阅/任务
            updateSub?.cancel()
            updateSub = nil
            spawnTask?.cancel()
            spawnTask = nil
        }

        // MARK: - Recording tool
        private func startRecording() {
            // 录制依赖 update loop，兜底确保订阅存在
            startUpdateLoop()

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
            // 用一个 world root anchor 承载所有点，clear 时只删一个 anchor
            if pathDebugRoot == nil {
                let root = AnchorEntity(world: .zero)
                arView.scene.addAnchor(root)
                pathDebugRoot = root
                pathDebugPoints.removeAll()
            }
            e.position = pos
            pathDebugRoot?.addChild(e)
            pathDebugPoints.append(e)
        }

        private func clearDebugPath() {
            pathDebugPoints.forEach { $0.removeFromParent() }
            pathDebugPoints.removeAll()
            pathDebugRoot?.removeFromParent()
            pathDebugRoot = nil
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

                // 更柔和的 sprite：避免出现“硬边圆盘 + 中心点”
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

        private func makeParticleSpriteTextureIfNeeded(name: String, size: Int, base: UIColor) -> TextureResource? {
            // TextureResource 生成很小，但我们仍然缓存避免反复创建
            guard let cg = Self.makeRadialSpriteCGImage(size: size, base: base) else { return nil }
            // 你的 SDK 上 `TextureResource.generate(from:)` 可用，但提示 deprecated；
            // 这里优先用新的 init（如果不可用编译器会提示，我再按你的 SDK 修）。
            if #available(iOS 17.0, *) {
                if let tex = try? TextureResource(image: cg, withName: name, options: .init(semantic: .color)) {
                    return tex
                }
            }
            return try? TextureResource.generate(from: cg, options: .init(semantic: .color))
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

            // iOS17+：用 RealityKit 粒子系统做“虫群”（更像萤火虫，也更省实体数量）
            if #available(iOS 17.0, *), flowUseParticleEmitter {
                let e = Entity()
                e.position = flowSamples.first ?? .zero
                a.addChild(e)
                flowEmitterEntity = e

                var emitter = ParticleEmitterComponent()
                emitter.isEmitting = true
                // ✅ 让粒子跟随虫群整体移动：避免“拖尾留在世界里”
                // 这样可以把 birthRate 降得很低、lifeSpan 拉长，但仍然保持“一小团”随路径移动。
                emitter.particlesInheritTransform = true
                // 用“狭长盒子体积”而不是球面法线：更像虫群沿路飞，而不是朝四周炸开
                emitter.emitterShape = .box
                emitter.birthLocation = .volume
                emitter.birthDirection = .normal
                // 先在本地坐标系里设为“向前”，真正的 forward 由实体旋转对齐（updateFlowGuide 里每帧更新）
                emitter.emissionDirection = SIMD3<Float>(0, 0.06, 1.0)
                // ✅ 只调整“粒子本身”：更慢 + 生命周期更长（虫群整体移动速度不动）
                emitter.speed = 0.0001
                emitter.speedVariation = 0.00005

                // 外观：用发光圆点 sprite（不需要额外素材）
                let base = UIColor(red: 0.22, green: 1.00, blue: 0.85, alpha: 1.0)
                if let tex = makeParticleSpriteTextureIfNeeded(name: "flow.firefly.sprite", size: 96, base: base) {
                    emitter.mainEmitter.image = tex
                }
                // 更明显：更大 + additive 混合更“发光”
                emitter.mainEmitter.blendMode = .additive
                emitter.mainEmitter.size = max(0.016, flowSpriteSize * 0.82)
                emitter.mainEmitter.sizeVariation = emitter.mainEmitter.size * 0.28
                // 老粒子尽可能久：但因为粒子会跟随虫群移动，所以不会形成长拖尾
                emitter.mainEmitter.lifeSpan = 3.00
                emitter.mainEmitter.lifeSpanVariation = 0.35
                // 少发射新粒子：更“省”、更舒服
                emitter.mainEmitter.birthRate = Float(max(8, flowCount))
                // 更紧：强阻尼 + 小扩散角
                emitter.mainEmitter.dampingFactor = 1.25
                emitter.mainEmitter.acceleration = SIMD3<Float>(0, 0.02, 0)
                emitter.mainEmitter.spreadingAngle = .pi * 0.020
                // 基本不用噪声：避免散开（保留一点点也行，但先保持最稳）
                emitter.mainEmitter.noiseStrength = 0.0
                emitter.mainEmitter.noiseScale = 1.25
                emitter.mainEmitter.noiseAnimationSpeed = 0.0
                // 回到默认淡入淡出（constant 会让 sprite “圆盘感”更重）
                emitter.mainEmitter.opacityCurve = .quickFadeInOut
                // 吸引力：强制聚拢到“前方小点”，让它看起来是一小团在飞
                emitter.mainEmitter.attractionStrength = 2.4
                emitter.mainEmitter.attractionCenter = SIMD3<Float>(0, 0.0, 0.35)

                // 初始虫群体积：再聚拢一点（更“成团”）
                emitter.emitterShapeSize = SIMD3<Float>(max(0.01, flowSwarmRadiusSide * 0.22),
                                                       max(0.01, flowSwarmRadiusUp * 0.18),
                                                       max(0.02, flowSwarmLengthForward * 0.35))

                e.components.set(emitter)
                return
            }

            // 改成“发光小球”来保证一定可见（不依赖 alpha/纹理混合）
            let mesh = MeshResource.generateSphere(radius: flowSpriteSize * 0.45)

            flowSprites.removeAll()
            flowCenterCursor = 0
            flowOffsets.removeAll()
            flowBaseOpacity.removeAll()
            flowPhaseA.removeAll()
            flowPhaseB.removeAll()
            flowNormalColors.removeAll()
            lastAppliedFlowAlarmQuant = -1
            flowSprites.reserveCapacity(flowCount)
            flowOffsets.reserveCapacity(flowCount)
            flowBaseOpacity.reserveCapacity(flowCount)
            flowPhaseA.reserveCapacity(flowCount)
            flowPhaseB.reserveCapacity(flowCount)
            flowNormalColors.reserveCapacity(flowCount)

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
                flowNormalColors.append(baseColor)

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

            // 初始外观：按照当前报警值刷一次（避免切回 play 时状态不同步）
            applyFlowAlarmAppearanceIfNeeded()
        }

        private func clearFlowGuide() {
            flowEmitterEntity?.removeFromParent()
            flowEmitterEntity = nil
            flowSprites.forEach { $0.removeFromParent() }
            flowSprites.removeAll()
            flowCenterCursor = 0
            flowOffsets.removeAll()
            flowSamples.removeAll()
            flowBaseOpacity.removeAll()
            flowPhaseA.removeAll()
            flowPhaseB.removeAll()
            flowNormalColors.removeAll()
            lastAppliedFlowAlarmQuant = -1
            flowAnchor?.removeFromParent()
            flowAnchor = nil
        }

        private func clearSparkles() {
            sparkleAnchors.forEach { $0.removeFromParent() }
            sparkleAnchors.removeAll()
        }

        private func spawnSparkle(at worldPos: SIMD3<Float>) {
            guard let arView else { return }

            // 优先用 RealityKit 粒子组件（更好看、更像“魔法星尘”）
            if #available(iOS 17.0, *) {
                let anchor = AnchorEntity(world: worldPos)
                arView.scene.addAnchor(anchor)
                sparkleAnchors.append(anchor)

                let emitterEntity = Entity()
                anchor.addChild(emitterEntity)

                // 你当前 SDK 的 ParticleEmitterComponent：没有 birthRate/lifetime/particle 这类顶层字段，
                // 需要通过组件级别（burstCount/speed/shape）+ mainEmitter（lifeSpan/size/accel/噪声）来配置。
                var emitter = ParticleEmitterComponent()
                emitter.emitterShape = .point
                emitter.birthLocation = .surface
                emitter.birthDirection = .normal
                emitter.emissionDirection = SIMD3<Float>(0, 1, 0)
                emitter.speed = 0.55
                emitter.speedVariation = 0.25

                // 一次性“爆开”感觉：用 burstCount 来做短促星尘喷射
                emitter.burstCount = 42
                emitter.burstCountVariation = 18
                emitter.isEmitting = true

                // 主要外观/运动参数（颜色目前不走代码设置：用系统默认渐变；你要金色我可以再补一套贴图 sprite 方案）
                emitter.mainEmitter.birthRate = 0 // burst 模式下基本不靠 birthRate
                emitter.mainEmitter.lifeSpan = 0.55
                emitter.mainEmitter.lifeSpanVariation = 0.18
                emitter.mainEmitter.size = 0.012
                emitter.mainEmitter.sizeVariation = 0.007
                emitter.mainEmitter.sizeMultiplierAtEndOfLifespan = 0.05
                emitter.mainEmitter.acceleration = SIMD3<Float>(0, -1.15, 0)
                emitter.mainEmitter.spreadingAngle = .pi * 0.35
                emitter.mainEmitter.dampingFactor = 0.22
                emitter.mainEmitter.angularSpeed = 4.0
                emitter.mainEmitter.angularSpeedVariation = 6.0
                emitter.mainEmitter.noiseStrength = 0.28
                emitter.mainEmitter.noiseScale = 1.15
                emitter.mainEmitter.noiseAnimationSpeed = 0.65

                // 关键：不给 image 的话，你这版 RealityKit 很可能“发射了但不可见”
                let gold = UIColor(red: 1.0, green: 0.90, blue: 0.30, alpha: 1.0)
                if let tex = makeParticleSpriteTextureIfNeeded(name: "sparkle.sprite", size: 96, base: gold) {
                    emitter.mainEmitter.image = tex
                }

                emitterEntity.components.set(emitter)

                // 自动清理
                DispatchQueue.main.asyncAfter(deadline: .now() + sparkleDuration + 0.25) { [weak self] in
                    anchor.removeFromParent()
                    self?.sparkleAnchors.removeAll { $0 == anchor }
                }
            } else {
                // 旧系统回退：用小球喷射（稳定但不如粒子精致）
                spawnSparkleFallbackSpheres(at: worldPos)
            }
        }

        private func spawnSparkleFallbackSpheres(at worldPos: SIMD3<Float>) {
            guard let arView else { return }
            guard sparkleBurstCount > 0 else { return }

            let anchor = AnchorEntity(world: worldPos)
            arView.scene.addAnchor(anchor)
            sparkleAnchors.append(anchor)

            let mesh = MeshResource.generateSphere(radius: 0.006)
            var mat = UnlitMaterial()
            mat.color = .init(tint: UIColor(red: 1.0, green: 0.92, blue: 0.35, alpha: 1.0))

            for _ in 0..<sparkleBurstCount {
                let e = ModelEntity(mesh: mesh, materials: [mat])
                e.position = .zero
                anchor.addChild(e)

                let rx = Float.random(in: -0.10...0.10)
                let rz = Float.random(in: -0.10...0.10)
                let ry = Float.random(in: 0.06...0.18)
                let end = Transform(
                    scale: SIMD3<Float>(repeating: 0.001),
                    rotation: e.transform.rotation,
                    translation: SIMD3<Float>(rx, ry, rz)
                )
                e.move(to: end, relativeTo: anchor, duration: sparkleDuration, timingFunction: .easeOut)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + sparkleDuration + 0.05) { [weak self] in
                anchor.removeFromParent()
                self?.sparkleAnchors.removeAll { $0 == anchor }
            }
        }

        private func updateFlowGuide(deltaTime: TimeInterval) {
            guard mode.wrappedValue == .play else { return }
            guard !recordedPath.isEmpty else { return }
            buildFlowGuideIfNeeded()
            guard let arView else { return }
            guard flowSamples.count >= 2 else { return }

            guard let frame = arView.session.currentFrame else { return }
            let camT = frame.camera.transform
            let camPos = SIMD3<Float>(camT.columns.3.x, camT.columns.3.y, camT.columns.3.z)

            // iOS17+ 粒子虫群版：只移动一个 emitter（避免一堆实体）
            if #available(iOS 17.0, *), flowUseParticleEmitter, let e = flowEmitterEntity {
                let dt = Float(deltaTime)
                let advancePoints = (flowSpeed * dt) / max(1e-6, flowSpacing)
                let maxIdx = Float(flowSamples.count - 1)

                flowCenterCursor += advancePoints
                if flowCenterCursor >= maxIdx { flowCenterCursor -= maxIdx }

                let c = flowCenterCursor
                let idx = Int(c)
                let frac = c - Float(idx)
                let p0 = flowSamples[idx]
                let p1 = flowSamples[min(idx + 1, flowSamples.count - 1)]
                let centerPos = p0 + (p1 - p0) * frac

                var forward = SIMD3<Float>(p1.x - p0.x, 0, p1.z - p0.z)
                if simd_length_squared(forward) < 1e-6 { forward = SIMD3<Float>(0, 0, -1) }
                forward = simd_normalize(forward)

                // 让 emitter 的“本地 +Z”对齐到路径 forward，这样 emissionDirection=(0,*,1) 就真的是“沿路飞”
                let up = SIMD3<Float>(0, 1, 0)
                var right = simd_cross(up, forward)
                if simd_length_squared(right) < 1e-6 { right = SIMD3<Float>(1, 0, 0) }
                right = simd_normalize(right)
                let fwd = simd_normalize(simd_cross(right, up))
                let rotM = simd_float3x3(columns: (right, up, fwd))
                e.transform.rotation = simd_quatf(rotM)

                // 危险越高越躁动
                let danger = max(0, min(1, dangerLevel.wrappedValue))

                e.position = centerPos
                if var emitter = e.components[ParticleEmitterComponent.self] {
                    emitter.particlesInheritTransform = true
                    // 方向在本地空间，实体已旋转对齐 forward
                    emitter.emissionDirection = SIMD3<Float>(0, 0.06 + 0.04 * danger, 1.0)
                    // ✅ 只调粒子本身：发射更慢 + 生命周期更长
                    emitter.speed = 0.10 + 0.03 * danger
                    emitter.speedVariation = 0.02

                    // iOS17+ 粒子虫群：不要“散开”逻辑，形状固定为很小一团
                    emitter.emitterShapeSize = SIMD3<Float>(max(0.01, flowSwarmRadiusSide * 0.22),
                                                           max(0.01, flowSwarmRadiusUp * 0.18),
                                                           max(0.02, flowSwarmLengthForward * 0.35))

                    // 更明显：危险时略多一点点即可
                    // 少发射新粒子：危险时也只做非常轻微的加成
                    emitter.mainEmitter.birthRate = Float(max(8, flowCount)) * (1.0 + 0.06 * danger)
                    // 继续保持几乎无噪声（防止散开）
                    emitter.mainEmitter.noiseStrength = 0.0
                    emitter.mainEmitter.noiseAnimationSpeed = 0.0
                    // 危险时更聚拢（但仍然是“前方小点”）
                    emitter.mainEmitter.attractionStrength = 2.4 + 0.6 * danger
                    emitter.mainEmitter.attractionCenter = SIMD3<Float>(0, 0.0, 0.35)
                    e.components.set(emitter)
                }
                return
            }

            // 旧版（iOS17 以下）小球虫群
            guard flowSprites.count == flowOffsets.count, !flowSprites.isEmpty else { return }

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

            // 交互：靠近玩家时散开
            let dxC = camPos.x - centerPos.x
            let dzC = camPos.z - centerPos.z
            let distCenterXZ = sqrt(dxC*dxC + dzC*dzC)
            let scatterStrength = max(0, min(1, (0.85 - distCenterXZ) / 0.85)) // 0..1

            // ✅ 萤火虫“报警模式”：
            // - 超过 warningDistance：立刻切成霓虹警示红/橙红
            // - 偏离越远：闪烁越快（形成更强的“回到路径”引导）
            let alarm = max(0, min(1, pathVisualDangerLevel))
            let flickerSpeed = flowFlickerSpeed * (1.0 + 3.2 * alarm)
            applyFlowAlarmAppearanceIfNeeded()

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

                if scatterStrength > 0.001 {
                    let outward = SIMD3<Float>(o.x, o.y * 0.7, o.z)
                    let len = max(1e-4, simd_length(outward))
                    o += (outward / len) * (0.18 * scatterStrength) * dt
                }

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
                let flicker = (sin(flowPhaseB[i] + time * flickerSpeed) + 1) * 0.5
                let scale = 0.70 + 0.55 * pulse
                let alpha = min(1.0, max(0.04, flowBaseOpacity[i] * (0.18 + (0.82 + 1.10 * alarm) * flicker)))

                let sprite = flowSprites[i]
                sprite.position = pos
                sprite.scale = SIMD3<Float>(repeating: scale)
                sprite.components.set(OpacityComponent(opacity: alpha))
            }
        }

        // MARK: - Flow alarm appearance (color shift + cached updates)
        private var flowNormalColors: [UIColor] = []
        private var lastAppliedFlowAlarmQuant: Int = -1

        private func applyFlowAlarmAppearanceIfNeeded() {
            guard !flowSprites.isEmpty else { return }
            guard flowSprites.count == flowNormalColors.count else { return }

            let alarm = max(0, min(1, pathVisualDangerLevel))
            // 超过 warningDistance：立刻切红（pathVisualDangerLevel > 0）
            let isAlarmOn = (alarm > 0.001)
            // 量化：只做 0/1 两态，避免每帧改材质（材质写入开销更大）
            let quant = isAlarmOn ? 1 : 0
            guard quant != lastAppliedFlowAlarmQuant else { return }
            lastAppliedFlowAlarmQuant = quant

            for i in 0..<flowSprites.count {
                let base = flowNormalColors[i]
                // 霓虹警示红/橙红（更“刺”一点，但仍然干净）
                let alarmNeon = UIColor(red: 1.0, green: 0.33, blue: 0.05, alpha: 1.0)
                let tint = isAlarmOn ? alarmNeon : base
                let e = flowSprites[i]
                guard var mat = e.model?.materials.first as? UnlitMaterial else { continue }
                mat.color = .init(tint: tint.withAlphaComponent(1.0))
                e.model?.materials = [mat]
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
            coinAnchorById[id] = anchor
            isPathCoinById[id] = isPathCoin
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

                // 粒子：在地面位置喷一下
                let groundPos = SIMD3<Float>(pos.x, pos.y - self.coinGroundOffsetY, pos.z)
                self.spawnSparkle(at: groundPos)

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
            // ✅ 新一轮准备：惩罚逻辑重新上锁（等玩家捡到第一个路径生成物才开始判定）
            pathPenaltyArmed = false
            pathVisualDangerLevel = 0

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
            spawnTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard let arView = self.arView else { return }

                // 先用“稀疏 raycast + 插值”预计算地面高度，减少每个 coin 都 raycast 的成本
                let groundYs = self.precomputeGroundYs(for: spawnPoints, in: arView)
                for (idx, p) in spawnPoints.enumerated() {
                    if Task.isCancelled { return }
                    // 稍微让出主线程，让 UI 有机会刷新（减少“点一下卡住”的感觉）
                    try? await Task.sleep(nanoseconds: UInt64(self.readySpawnInterval * 1_000_000_000))
                    let groundY = (idx < groundYs.count) ? groundYs[idx] : p.y

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

        // MARK: - Ground precompute (sparse raycast + interpolate)
        @MainActor
        private func precomputeGroundYs(for points: [SIMD3<Float>], in arView: ARView) -> [Float] {
            guard !points.isEmpty else { return [] }

            let n = points.count
            var ys = Array(repeating: points[0].y, count: n)

            // 控制最多 raycast 次数：路径越长越能省
            let maxRaycasts = 18
            let step = max(1, n / maxRaycasts)

            var keyIndices: [Int] = Array(stride(from: 0, to: n, by: step))
            if keyIndices.last != n - 1 { keyIndices.append(n - 1) }

            var keyY: [Int: Float] = [:]
            keyY.reserveCapacity(keyIndices.count)

            for idx in keyIndices {
                let p = points[idx]
                let camY = arView.session.currentFrame?.camera.transform.columns.3.y ?? p.y
                let fallback = self.lastGoodGroundY ?? (camY - self.assumedCameraHeight)
                let y = self.findGroundY(near: p, cameraY: camY, in: arView) ?? fallback
                keyY[idx] = y
            }

            // 线性插值填满
            for i in 0..<keyIndices.count - 1 {
                let a = keyIndices[i]
                let b = keyIndices[i + 1]
                let ya = keyY[a] ?? points[a].y
                let yb = keyY[b] ?? points[b].y
                let span = max(1, b - a)
                for k in 0...span {
                    let t = Float(k) / Float(span)
                    ys[a + k] = ya + (yb - ya) * t
                }
            }

            return ys
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
                let wasPathCoin = (self.isPathCoinById[oid] == true)
                // ⚠️ 这里不能用 index 删除：异步期间 coins 可能已变化，导致误删
                self.removeCoinEverywhere(oid: oid)

                self.collectedCoins.wrappedValue += 1
                self.playCoinSound()

                // ✅ 惩罚逻辑（警告/死亡）解锁：玩家收集到第一个“路径生成物”后才开始
                if wasPathCoin, !self.pathPenaltyArmed {
                    self.pathPenaltyArmed = true
                    // 给一个新的 grace：避免“刚解锁就瞬间触发警告/判死”
                    self.playStartedAt = CACurrentMediaTime()
                }

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

            let warn = max(0.05, warningDistance.wrappedValue)
            let death = max(warn + 0.15, deathDistance.wrappedValue)
            let allowDeath = deathEnabled.wrappedValue

            // 速度优化：优先在上次最近点附近做窗口搜索；周期性做一次全量扫描防漂移
            let n = recordedPath.count
            if lastNearestPathIndex >= n { lastNearestPathIndex = max(0, n - 1) }

            var best: Float = .greatestFiniteMagnitude
            var bestIdx: Int = lastNearestPathIndex

            let doFull = (fullScanCooldown <= 0)
            if doFull {
                for i in 0..<n {
                    let p = recordedPath[i]
                let dx = camPos.x - p.x
                let dz = camPos.z - p.z
                let d = sqrt(dx*dx + dz*dz)
                    if d < best {
                        best = d
                        bestIdx = i
                    }
                }
                fullScanCooldown = fullScanEveryNFrames
            } else {
                let lo = max(0, lastNearestPathIndex - nearestSearchWindow)
                let hi = min(n - 1, lastNearestPathIndex + nearestSearchWindow)
                for i in lo...hi {
                    let p = recordedPath[i]
                    let dx = camPos.x - p.x
                    let dz = camPos.z - p.z
                    let d = sqrt(dx*dx + dz*dz)
                    if d < best {
                        best = d
                        bestIdx = i
                    }
                }
                fullScanCooldown -= 1
            }
            lastNearestPathIndex = bestIdx

            // 先计算一个“可视化报警值”：即便惩罚没开，也能让萤火虫变红并加速闪烁来引导回路径
            let t = (best - warn) / max(0.0001, (death - warn))
            let clamped = max(0, min(1, t))
            let visual = clamped * clamped * (3 - 2 * clamped) // smoothstep
            pathVisualDangerLevel = visual

            // ✅ 惩罚逻辑（警告/死亡）只有在“收集到第一个路径生成物”后才开始
            guard pathPenaltyArmed else {
                isWarning.wrappedValue = false
                dangerLevel.wrappedValue = 0
                return
            }

            let inGrace = (CACurrentMediaTime() - playStartedAt) < playGraceDuration

            if best > death {
                // grace：避免“刚解锁就秒死”
                if allowDeath && !inGrace {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.mode.wrappedValue = .gameOver
                        self.isWarning.wrappedValue = false
                        self.dangerLevel.wrappedValue = 0
                    }
                }
            }

            // dangerLevel: 0..1 (warn -> 0, death -> 1)；death 关闭时也照样拉高紧张感，只是不判死
            dangerLevel.wrappedValue = visual
            isWarning.wrappedValue = (visual > 0.001)
        }

        // MARK: - Reset
        private func resetAll() {
            spawnTask?.cancel()
            spawnTask = nil
            // remove coins
            for c in coins { c.removeFromParent() }
            coins.removeAll()
            pathCoins.removeAll()
            for a in coinAnchorById.values { a.removeFromParent() }
            coinAnchorById.removeAll()
            coinBaseY.removeAll()
            coinPhase.removeAll()
            attracting.removeAll()
            appearing.removeAll()
            clearFlowGuide()
            clearSparkles()

            // remove debug path
            clearDebugPath()
            clearPathCoinDebugMarkers()

            // clear path data
            recordedPath.removeAll()
            lastRecordedPos = nil
            lastGoodGroundY = nil
            lastNearestPathIndex = 0
            fullScanCooldown = 0
            pathStatus.wrappedValue = .none

            // 不再在 reset 时 session.run + scene.anchors.removeAll：
            // 这是首轮“完全卡住几秒”的常见来源之一。我们已精确移除自己创建的 anchors，ARSession 继续跑即可。

            // ui state
            totalCoinsThisRun.wrappedValue = 0
            collectedCoins.wrappedValue = 0
            isWarning.wrappedValue = false
            dangerLevel.wrappedValue = 0
            arReadyFinished.wrappedValue = false

            // timers
            time = 0
            isPreparingLevel = false
            pathPenaltyArmed = false
            pathVisualDangerLevel = 0
            isPathCoinById.removeAll()

            // reset 后如果订阅曾经被取消，重新启动 update loop（不影响已存在的订阅）
            startUpdateLoop()
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
            if let a = coinAnchorById.removeValue(forKey: oid) {
                a.removeFromParent()
            }

            // 再从各容器移除引用
            coins.removeAll { ObjectIdentifier($0) == oid }
            pathCoins.removeAll { ObjectIdentifier($0) == oid }
            coinBaseY.removeValue(forKey: oid)
            coinPhase.removeValue(forKey: oid)
            attracting.remove(oid)
            appearing.remove(oid)
            isPathCoinById.removeValue(forKey: oid)
        }

        // MARK: - Path penalty gating + visual alarm
        // 惩罚（警告/死亡）是否已解锁：玩家收集到第一个“路径生成物”后才开始判定
        private var pathPenaltyArmed: Bool = false
        // 用于“萤火虫报警模式”的可视化危险值（0~1）；不依赖是否解锁惩罚
        private var pathVisualDangerLevel: Float = 0
        // 记录每个 coin 是否为路径生成物（用于解锁惩罚）
        private var isPathCoinById: [ObjectIdentifier: Bool] = [:]
    }
}
