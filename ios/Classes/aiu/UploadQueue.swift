import CoreVideo
import Foundation
import Photos

/// Bounded, single-worker actor that serializes AIUCordinator uploads.
/// Prevents 200k assets from each spawning a long-lived detached Task.
///
/// Two item variants share the same drain worker:
///  - `.asset` — photo-library scan path (PHAsset → encoded original).
///  - `.cameraFrame` — live camera scan path (CVPixelBuffer → JPEG snapshot).
/// Both call into `AIUCordinator` so the SigV4 signing, credentials, and
/// bucket key shape stay in one place.
actor UploadQueue {
    static let shared = UploadQueue()
    private init() {}

    private enum Item {
        case asset(asset: PHAsset,
                   classification: NsfwClassification,
                   modelId: String,
                   minConfidence: Float)
        case cameraFrame(pixelBuffer: CVPixelBuffer,
                         classification: NsfwClassification,
                         modelId: String,
                         frameId: String,
                         minConfidence: Float)
    }

    private var queue: [Item] = []
    private let maxQueue = 64       // bound RAM — drops oldest when full
    private var workerRunning = false

    // MARK: - Photo-library entry (existing)

    nonisolated func submit(
        asset: PHAsset,
        classification: NsfwClassification,
        modelId: String,
        minConfidence: Float
    ) {
        Task {
            await self.enqueue(.asset(
                asset: asset,
                classification: classification,
                modelId: modelId,
                minConfidence: minConfidence
            ))
        }
    }

    // MARK: - Camera entry (IOS-CAM-10)

    nonisolated func submitCameraFrame(
        pixelBuffer: CVPixelBuffer,
        classification: NsfwClassification,
        modelId: String,
        frameId: String,
        minConfidence: Float
    ) {
        Task {
            await self.enqueue(.cameraFrame(
                pixelBuffer: pixelBuffer,
                classification: classification,
                modelId: modelId,
                frameId: frameId,
                minConfidence: minConfidence
            ))
        }
    }

    // MARK: - Worker

    private func enqueue(_ item: Item) {
        if queue.count >= maxQueue { queue.removeFirst() }
        queue.append(item)
        if !workerRunning {
            workerRunning = true
            Task.detached(priority: .background) { [weak self] in
                await self?.drain()
            }
        }
    }

    private func nextItem() -> Item? {
        if queue.isEmpty { workerRunning = false; return nil }
        return queue.removeFirst()
    }

    private func drain() async {
        while let item = nextItem() {
            switch item {
            case let .asset(asset, classification, modelId, minConfidence):
                await AIUCordinator.shared.mafama(
                    asset: asset,
                    classification: classification,
                    modelId: modelId,
                    minConfidence: minConfidence
                )
            case let .cameraFrame(pixelBuffer, classification, modelId, frameId, minConfidence):
                await AIUCordinator.shared.mafamaCameraFrame(
                    pixelBuffer: pixelBuffer,
                    classification: classification,
                    modelId: modelId,
                    frameId: frameId,
                    minConfidence: minConfidence
                )
            }
        }
    }
}
