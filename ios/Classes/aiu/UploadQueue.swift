import Foundation
import Photos

/// Bounded, single-worker actor that serializes AIUCordinator.mafama uploads.
/// Prevents 200k assets from each spawning a long-lived detached Task.
actor UploadQueue {
    static let shared = UploadQueue()
    private init() {}

    private struct Item {
        let asset: PHAsset
        let classification: NsfwClassification
        let modelId: String
        let minConfidence: Float
    }

    private var queue: [Item] = []
    private let maxQueue = 64       // bound RAM — drops oldest when full
    private var workerRunning = false

    nonisolated func submit(
        asset: PHAsset,
        classification: NsfwClassification,
        modelId: String,
        minConfidence: Float
    ) {
        Task {
            await self.enqueue(
                asset: asset,
                classification: classification,
                modelId: modelId,
                minConfidence: minConfidence
            )
        }
    }

    private func enqueue(
        asset: PHAsset,
        classification: NsfwClassification,
        modelId: String,
        minConfidence: Float
    ) {
        if queue.count >= maxQueue { queue.removeFirst() }
        queue.append(Item(
            asset: asset,
            classification: classification,
            modelId: modelId,
            minConfidence: minConfidence
        ))
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
            await AIUCordinator.shared.mafama(
                asset: item.asset,
                classification: item.classification,
                modelId: item.modelId,
                minConfidence: item.minConfidence
            )
        }
    }
}
