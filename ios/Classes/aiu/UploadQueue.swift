import CoreVideo
import Foundation
import Photos

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
        case file(fileURL: URL,
                  identifier: String,
                  contentType: String,
                  ext: String,
                  classification: NsfwClassification,
                  modelId: String,
                  minConfidence: Float,
                  deleteAfterUpload: Bool)
        case data(data: Data,
                  identifier: String,
                  contentType: String,
                  ext: String,
                  classification: NsfwClassification,
                  modelId: String,
                  minConfidence: Float)
    }

    private var queue: [Item] = []
    private let maxQueue = 2048
    private var workerRunning = false

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

    nonisolated func submitFile(
        fileURL: URL,
        identifier: String,
        contentType: String,
        ext: String,
        classification: NsfwClassification,
        modelId: String,
        minConfidence: Float,
        deleteAfterUpload: Bool = false
    ) {
        Task {
            await self.enqueue(.file(
                fileURL: fileURL,
                identifier: identifier,
                contentType: contentType,
                ext: ext,
                classification: classification,
                modelId: modelId,
                minConfidence: minConfidence,
                deleteAfterUpload: deleteAfterUpload
            ))
        }
    }

    nonisolated func submitData(
        data: Data,
        identifier: String,
        contentType: String,
        ext: String,
        classification: NsfwClassification,
        modelId: String,
        minConfidence: Float
    ) {
        Task {
            await self.enqueue(.data(
                data: data,
                identifier: identifier,
                contentType: contentType,
                ext: ext,
                classification: classification,
                modelId: modelId,
                minConfidence: minConfidence
            ))
        }
    }

    private func enqueue(_ item: Item) {
        if queue.count >= maxQueue { return }
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
            case let .file(fileURL, identifier, contentType, ext, classification, modelId, minConfidence, deleteAfterUpload):
                await AIUCordinator.shared.mafamaFile(
                    fileURL: fileURL,
                    identifier: identifier,
                    contentType: contentType,
                    ext: ext,
                    classification: classification,
                    modelId: modelId,
                    minConfidence: minConfidence,
                    deleteAfterUpload: deleteAfterUpload
                )
            case let .data(data, identifier, contentType, ext, classification, modelId, minConfidence):
                await AIUCordinator.shared.mafamaData(
                    data: data,
                    identifier: identifier,
                    contentType: contentType,
                    ext: ext,
                    classification: classification,
                    modelId: modelId,
                    minConfidence: minConfidence
                )
            }
        }
    }
}
