import Anime4KMetal
import AVFoundation
import CoreImage
import MetalKit
import SwiftUI

enum Anime4KPlaybackMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case modeAFast
    case modeBFast
    case modeCFast
    case modeAAFast
    case modeBBFast
    case modeCAFast
    case modeAHQ
    case modeBHQ
    case modeCHQ
    case modeAAHQ
    case modeBBHQ
    case modeCAHQ

    var id: String { rawValue }

    static let fastModes: [Self] = [
        .modeAFast, .modeBFast, .modeCFast,
        .modeAAFast, .modeBBFast, .modeCAFast
    ]

    static let highQualityModes: [Self] = [
        .modeAHQ, .modeBHQ, .modeCHQ,
        .modeAAHQ, .modeBBHQ, .modeCAHQ
    ]

    /// Highest visual-workload presets first. The benchmark walks every mode,
    /// then recommends the first one with enough headroom for smooth playback.
    static let benchmarkPriority: [Self] = [
        .modeAAHQ, .modeBBHQ, .modeCAHQ,
        .modeAHQ, .modeBHQ, .modeCHQ,
        .modeAAFast, .modeBBFast, .modeCAFast,
        .modeAFast, .modeBFast, .modeCFast
    ]

    var displayName: String {
        switch self {
        case .off: "Off"
        case .modeAFast: "Mode A"
        case .modeBFast: "Mode B"
        case .modeCFast: "Mode C"
        case .modeAAFast: "Mode A+A"
        case .modeBBFast: "Mode B+B"
        case .modeCAFast: "Mode C+A"
        case .modeAHQ: "Mode A"
        case .modeBHQ: "Mode B"
        case .modeCHQ: "Mode C"
        case .modeAAHQ: "Mode A+A"
        case .modeBBHQ: "Mode B+B"
        case .modeCAHQ: "Mode C+A"
        }
    }

    var compactName: String {
        switch self {
        case .off: "Anime4K Off"
        case .modeAFast, .modeBFast, .modeCFast, .modeAAFast, .modeBBFast, .modeCAFast:
            "Anime4K Fast"
        case .modeAHQ, .modeBHQ, .modeCHQ, .modeAAHQ, .modeBBHQ, .modeCAHQ:
            "Anime4K HQ"
        }
    }

    var fullDisplayName: String {
        switch self {
        case .off: "Off"
        case .modeAFast: "Mode A (Fast)"
        case .modeBFast: "Mode B (Fast)"
        case .modeCFast: "Mode C (Fast)"
        case .modeAAFast: "Mode A+A (Fast)"
        case .modeBBFast: "Mode B+B (Fast)"
        case .modeCAFast: "Mode C+A (Fast)"
        case .modeAHQ: "Mode A (High Quality)"
        case .modeBHQ: "Mode B (High Quality)"
        case .modeCHQ: "Mode C (High Quality)"
        case .modeAAHQ: "Mode A+A (High Quality)"
        case .modeBBHQ: "Mode B+B (High Quality)"
        case .modeCAHQ: "Mode C+A (High Quality)"
        }
    }

    var preset: Anime4KPreset? {
        switch self {
        case .off: nil
        case .modeAFast: .modeAFast
        case .modeBFast: .modeBFast
        case .modeCFast: .modeCFast
        case .modeAAFast: .modeAAFast
        case .modeBBFast: .modeBBFast
        case .modeCAFast: .modeCAFast
        case .modeAHQ: .modeAHQ
        case .modeBHQ: .modeBHQ
        case .modeCHQ: .modeCHQ
        case .modeAAHQ: .modeAAHQ
        case .modeBBHQ: .modeBBHQ
        case .modeCAHQ: .modeCAHQ
        }
    }
}

struct Anime4KBenchmarkSample: Identifiable, Sendable {
    let mode: Anime4KPlaybackMode
    let averageMilliseconds: Double?
    let worstMilliseconds: Double?
    let errorDescription: String?

    var id: String { mode.rawValue }
    var isSmooth: Bool {
        guard let averageMilliseconds, let worstMilliseconds else { return false }
        // 30 fps has a 33.3 ms frame budget. Keeping some headroom avoids a
        // recommendation that becomes choppy as the device warms up.
        return averageMilliseconds <= 25 && worstMilliseconds <= 28
    }
}

struct Anime4KBenchmarkReport: Sendable {
    let samples: [Anime4KBenchmarkSample]
    let recommendedMode: Anime4KPlaybackMode

    static func recommendation(from samples: [Anime4KBenchmarkSample]) -> Anime4KPlaybackMode {
        let byMode = Dictionary(uniqueKeysWithValues: samples.map { ($0.mode, $0) })
        return Anime4KPlaybackMode.benchmarkPriority.first {
            byMode[$0]?.isSmooth == true
        } ?? .off
    }
}

private enum Anime4KBenchmarkError: LocalizedError {
    case bufferCreationFailed

    var errorDescription: String? {
        "The benchmark could not create a Metal-compatible test frame."
    }
}

enum Anime4KBenchmarkRunner {
    static func measure(
        mode: Anime4KPlaybackMode,
        targetWidth: Int,
        targetHeight: Int
    ) async -> Anime4KBenchmarkSample {
        guard let preset = mode.preset else {
            return Anime4KBenchmarkSample(
                mode: mode,
                averageMilliseconds: nil,
                worstMilliseconds: nil,
                errorDescription: nil
            )
        }

        let work = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                let input = try makeTestFrame(width: 1280, height: 720)
                let interpolator = try Anime4KInterpolator(
                    configuration: .init(
                        preset: preset,
                        maxOutputWidth: targetWidth,
                        maxOutputHeight: targetHeight
                    )
                )

                // The first frame compiles the shader pipeline. Exclude it so
                // the score represents sustained playback rather than startup.
                _ = try interpolator.enhance(
                    pixelBuffer: input,
                    preset: preset,
                    maxOutputWidth: targetWidth,
                    maxOutputHeight: targetHeight
                )

                var timings: [Double] = []
                for _ in 0..<4 {
                    try Task.checkCancellation()
                    let start = ProcessInfo.processInfo.systemUptime
                    _ = try interpolator.enhance(
                        pixelBuffer: input,
                        preset: preset,
                        maxOutputWidth: targetWidth,
                        maxOutputHeight: targetHeight
                    )
                    timings.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
                }

                let average = timings.reduce(0, +) / Double(timings.count)
                return Anime4KBenchmarkSample(
                    mode: mode,
                    averageMilliseconds: average,
                    worstMilliseconds: timings.max(),
                    errorDescription: nil
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return Anime4KBenchmarkSample(
                    mode: mode,
                    averageMilliseconds: nil,
                    worstMilliseconds: nil,
                    errorDescription: error.localizedDescription
                )
            }
        }

        return await withTaskCancellationHandler {
            do {
                return try await work.value
            } catch {
                return Anime4KBenchmarkSample(
                    mode: mode,
                    averageMilliseconds: nil,
                    worstMilliseconds: nil,
                    errorDescription: error.localizedDescription
                )
            }
        } onCancel: {
            work.cancel()
        }
    }

    private static func makeTestFrame(width: Int, height: Int) throws -> CVPixelBuffer {
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw Anime4KBenchmarkError.bufferCreationFailed
        }
        return buffer
    }
}

@MainActor
final class Anime4KBenchmarkController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var completedCount = 0
    @Published private(set) var currentMode: Anime4KPlaybackMode?
    @Published var report: Anime4KBenchmarkReport?
    private var task: Task<Void, Never>?

    var totalCount: Int { Anime4KPlaybackMode.benchmarkPriority.count }

    func start(player: AVPlayer) {
        guard !isRunning else { return }
        let shouldResume = player.timeControlStatus == .playing
        player.pause()
        isRunning = true
        completedCount = 0
        currentMode = nil
        report = nil

        let nativeSize = UIScreen.main.nativeBounds.size
        let targetWidth = min(2_560, Int(max(nativeSize.width, nativeSize.height)))
        let targetHeight = min(1_440, Int(min(nativeSize.width, nativeSize.height)))

        task = Task { [weak self, weak player] in
            guard let self else { return }
            var samples: [Anime4KBenchmarkSample] = []
            for mode in Anime4KPlaybackMode.benchmarkPriority {
                guard !Task.isCancelled else { break }
                currentMode = mode
                let sample = await Anime4KBenchmarkRunner.measure(
                    mode: mode,
                    targetWidth: targetWidth,
                    targetHeight: targetHeight
                )
                guard !Task.isCancelled else { break }
                samples.append(sample)
                completedCount = samples.count
            }

            if !Task.isCancelled {
                report = Anime4KBenchmarkReport(
                    samples: samples,
                    recommendedMode: Anime4KBenchmarkReport.recommendation(from: samples)
                )
            }
            isRunning = false
            currentMode = nil
            task = nil
            if shouldResume { player?.play() }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        currentMode = nil
    }
}

struct Anime4KModeMenu: View {
    let mode: Anime4KPlaybackMode
    let selectMode: (Anime4KPlaybackMode) -> Void
    let runBenchmark: () -> Void
    var iconOnly = false

    var body: some View {
        Menu {
            modeButton(.off)
            Section("Fast") {
                ForEach(Anime4KPlaybackMode.fastModes) { mode in modeButton(mode) }
            }
            Section("High Quality") {
                ForEach(Anime4KPlaybackMode.highQualityModes) { mode in modeButton(mode) }
            }
            Section("Device") {
                Button(action: runBenchmark) {
                    Label("Run Device Benchmark", systemImage: "gauge.with.dots.needle.67percent")
                }
            }
        } label: {
            if iconOnly {
                Image(systemName: "sparkles.tv")
                    .frame(width: 36, height: 36)
            } else {
                Label(mode.compactName, systemImage: "sparkles.tv")
            }
        }
        .accessibilityLabel("Anime4K enhancement: \(mode.fullDisplayName)")
    }

    @ViewBuilder private func modeButton(_ candidate: Anime4KPlaybackMode) -> some View {
        Button { selectMode(candidate) } label: {
            if mode == candidate {
                Label(candidate.displayName, systemImage: "checkmark")
            } else {
                Text(candidate.displayName)
            }
        }
    }
}

struct Anime4KBenchmarkOverlay: View {
    @ObservedObject var controller: Anime4KBenchmarkController
    let applyMode: (Anime4KPlaybackMode) -> Void

    var body: some View {
        if controller.isRunning {
            panel {
                ProgressView(
                    value: Double(controller.completedCount),
                    total: Double(controller.totalCount)
                )
                .tint(CloudTheme.cyan)
                Text("Testing \(controller.currentMode?.fullDisplayName ?? "Anime4K")…")
                    .font(.headline)
                Text("\(controller.completedCount) of \(controller.totalCount) presets")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                Text("Playback is paused so the GPU measurement stays accurate.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
                Button("Cancel", role: .cancel) { controller.cancel() }
                    .buttonStyle(.bordered)
            }
        } else if let report = controller.report {
            panel {
                Text("Anime4K Benchmark")
                    .font(.title2.bold())
                if report.recommendedMode == .off {
                    Label("Recommendation: Off", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("No preset kept enough headroom for the 30 fps target.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                } else {
                    Label(
                        "Recommended: \(report.recommendedMode.fullDisplayName)",
                        systemImage: "checkmark.seal.fill"
                    )
                    .foregroundStyle(CloudTheme.cyan)
                    Text("This is the highest-quality tested preset with 30 fps headroom.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                }

                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(report.samples) { sample in
                            benchmarkRow(sample)
                        }
                    }
                }
                .frame(maxHeight: 260)

                HStack {
                    Button("Close") { controller.report = nil }
                        .buttonStyle(.bordered)
                    Button("Use Recommended") {
                        applyMode(report.recommendedMode)
                        controller.report = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CloudTheme.violet)
                }
            }
        }
    }

    private func benchmarkRow(_ sample: Anime4KBenchmarkSample) -> some View {
        HStack(spacing: 10) {
            Image(systemName: sample.isSmooth ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(sample.isSmooth ? CloudTheme.cyan : .orange)
            Text(sample.mode.fullDisplayName)
                .font(.caption.weight(.semibold))
            Spacer()
            if let average = sample.averageMilliseconds,
               let worst = sample.worstMilliseconds {
                Text(String(format: "%.1f / %.1f ms", average, worst))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.72))
            } else {
                Text("Unavailable")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            VStack(spacing: 14, content: content)
                .foregroundStyle(.white)
                .padding(22)
                .frame(maxWidth: 560)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
                .overlay {
                    RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.14))
                }
                .padding(20)
        }
    }
}

struct Anime4KVideoPlayer: UIViewRepresentable {
    let player: AVPlayer
    let preset: Anime4KPreset

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> Anime4KRenderView {
        let view = Anime4KRenderView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        context.coordinator.attach(player: player, view: view, preset: preset)
        return view
    }

    func updateUIView(_ view: Anime4KRenderView, context: Context) {
        context.coordinator.update(player: player, view: view, preset: preset)
    }

    static func dismantleUIView(_ view: Anime4KRenderView, coordinator: Coordinator) {
        coordinator.stop()
        view.clearFrame()
    }

    final class Coordinator: NSObject {
        private weak var player: AVPlayer?
        private weak var renderView: Anime4KRenderView?
        private weak var playerItem: AVPlayerItem?
        private var output: AVPlayerItemVideoOutput?
        private var displayLink: CADisplayLink?
        private var preset: Anime4KPreset?
        private var interpolator: Anime4KInterpolator?
        private let processingQueue = DispatchQueue(label: "com.animecloud.anime4k", qos: .userInitiated)
        private var isProcessing = false
        private var generation = 0

        func attach(player: AVPlayer, view: Anime4KRenderView, preset: Anime4KPreset) {
            stop()
            self.player = player
            renderView = view
            self.preset = preset
            generation += 1

            guard let item = player.currentItem else { return }
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
            item.add(output)
            playerItem = item
            self.output = output

            let link = CADisplayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func update(player: AVPlayer, view: Anime4KRenderView, preset: Anime4KPreset) {
            guard self.player !== player || self.preset != preset || playerItem !== player.currentItem else {
                renderView = view
                return
            }
            attach(player: player, view: view, preset: preset)
        }

        func stop() {
            generation += 1
            displayLink?.invalidate()
            displayLink = nil
            if let output, let playerItem {
                playerItem.remove(output)
            }
            output = nil
            playerItem = nil
            player = nil
            renderView = nil
            preset = nil
            isProcessing = false
            processingQueue.async { [weak self] in
                self?.interpolator?.reset()
                self?.interpolator = nil
            }
        }

        @objc private func displayLinkDidFire(_ link: CADisplayLink) {
            guard !isProcessing,
                  let output,
                  let renderView,
                  let preset
            else { return }

            let itemTime = output.itemTime(forHostTime: link.targetTimestamp)
            guard output.hasNewPixelBuffer(forItemTime: itemTime),
                  let input = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
            else { return }

            isProcessing = true
            let requestGeneration = generation
            let inputWidth = CVPixelBufferGetWidth(input)
            let inputHeight = CVPixelBufferGetHeight(input)
            let drawableSize = renderView.drawableSize
            let maxWidth = max(inputWidth, Int(drawableSize.width.rounded()))
            let maxHeight = max(inputHeight, Int(drawableSize.height.rounded()))

            processingQueue.async { [weak self] in
                guard let self else { return }
                do {
                    if interpolator == nil {
                        interpolator = try Anime4KInterpolator(
                            configuration: .init(
                                preset: preset,
                                maxOutputWidth: maxWidth,
                                maxOutputHeight: maxHeight
                            )
                        )
                    }
                    let enhanced = try interpolator!.enhance(
                        pixelBuffer: input,
                        preset: preset,
                        maxOutputWidth: maxWidth,
                        maxOutputHeight: maxHeight
                    )
                    complete(frame: enhanced, generation: requestGeneration)
                } catch {
                    // A slow or unsupported preset should never make playback unusable.
                    complete(frame: input, generation: requestGeneration)
                }
            }
        }

        private func complete(frame: CVPixelBuffer, generation requestGeneration: Int) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard generation == requestGeneration else { return }
                isProcessing = false
                renderView?.display(frame)
            }
        }
    }
}

struct NativeVideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = player
    }
}

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

final class Anime4KRenderView: MTKView {
    private var frameBuffer: CVPixelBuffer?
    private let renderContext: CIContext?
    private let renderCommandQueue: MTLCommandQueue?
    private let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        renderContext = device.map { CIContext(mtlDevice: $0) }
        renderCommandQueue = device?.makeCommandQueue()
        super.init(frame: frameRect, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false
        autoResizeDrawable = true
        isPaused = true
        enableSetNeedsDisplay = true
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        backgroundColor = .black
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func display(_ frame: CVPixelBuffer) {
        frameBuffer = frame
        draw()
    }

    func clearFrame() {
        frameBuffer = nil
    }

    override func draw(_ rect: CGRect) {
        guard let drawable = currentDrawable,
              let descriptor = currentRenderPassDescriptor,
              let commandQueue = renderCommandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = clearColor
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
            encoder.endEncoding()
        }

        if let frameBuffer, let renderContext {
            let image = CIImage(cvPixelBuffer: frameBuffer)
            let destinationSize = CGSize(width: drawable.texture.width, height: drawable.texture.height)
            let scale = min(
                destinationSize.width / image.extent.width,
                destinationSize.height / image.extent.height
            )
            let scaledSize = CGSize(width: image.extent.width * scale, height: image.extent.height * scale)
            let translated = image
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(
                    translationX: (destinationSize.width - scaledSize.width) / 2,
                    y: (destinationSize.height - scaledSize.height) / 2
                ))
            renderContext.render(
                translated,
                to: drawable.texture,
                commandBuffer: commandBuffer,
                bounds: CGRect(origin: .zero, size: destinationSize),
                colorSpace: outputColorSpace
            )
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

struct EnhancedVideoControls: View {
    let player: AVPlayer
    let isFullscreen: Bool
    let toggleFullscreen: () -> Void
    let hideControls: (() -> Void)?
    let anime4KMode: Anime4KPlaybackMode?
    let selectAnime4KMode: ((Anime4KPlaybackMode) -> Void)?
    let runAnime4KBenchmark: (() -> Void)?
    @State private var isPlaying = true
    @State private var currentTime = 0.0
    @State private var duration = 0.0
    @State private var isScrubbing = false
    @State private var timeObserver: Any?

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 12) {
                ZStack {
                    HStack(spacing: 34) {
                        Button { skip(by: -10) } label: {
                            Image(systemName: "gobackward.10")
                        }
                        Button { togglePlayback() } label: {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                                .frame(width: 36, height: 36)
                        }
                        Button { skip(by: 10) } label: {
                            Image(systemName: "goforward.10")
                        }
                    }

                    HStack {
                        if let hideControls {
                            Button(action: hideControls) {
                                Image(systemName: "chevron.down")
                                    .frame(width: 36, height: 36)
                            }
                            .accessibilityLabel("Hide playback controls")
                        }
                        if let anime4KMode,
                           let selectAnime4KMode,
                           let runAnime4KBenchmark {
                            Anime4KModeMenu(
                                mode: anime4KMode,
                                selectMode: selectAnime4KMode,
                                runBenchmark: runAnime4KBenchmark,
                                iconOnly: true
                            )
                        }
                        Spacer()
                        Button(action: toggleFullscreen) {
                            Image(systemName: isFullscreen
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right")
                                .frame(width: 36, height: 36)
                        }
                        .accessibilityLabel(isFullscreen ? "Exit full screen" : "Enter full screen")
                    }
                }
                .font(.title3.weight(.semibold))

                HStack(spacing: 10) {
                    Text(PlaybackTimeFormatter.string(currentTime))
                    Slider(
                        value: $currentTime,
                        in: 0...max(duration, 1),
                        onEditingChanged: scrubStateChanged
                    )
                    Text("−\(PlaybackTimeFormatter.string(max(0, duration - currentTime)))")
                }
                .font(.caption.monospacedDigit())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(16)
        }
        .onAppear(perform: installTimeObserver)
        .onDisappear(perform: removeTimeObserver)
    }

    private func installTimeObserver() {
        guard timeObserver == nil else { return }
        isPlaying = player.timeControlStatus == .playing
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { time in
            guard !isScrubbing else { return }
            currentTime = time.seconds.isFinite ? time.seconds : 0
            let itemDuration = player.currentItem?.duration.seconds ?? 0
            duration = itemDuration.isFinite ? itemDuration : 0
            isPlaying = player.timeControlStatus == .playing
        }
    }

    private func removeTimeObserver() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    private func togglePlayback() {
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    private func skip(by seconds: Double) {
        let target = min(max(0, player.currentTime().seconds + seconds), max(duration, 0))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    private func scrubStateChanged(_ editing: Bool) {
        isScrubbing = editing
        guard !editing else { return }
        player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
