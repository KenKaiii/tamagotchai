import Foundation

/// Downloads a file using delegate-based URLSession so progress callbacks fire correctly.
/// The async `URLSession.download(from:)` convenience method bypasses didWriteData entirely.
func downloadFile(
    from url: URL,
    to destination: URL,
    onProgress: @Sendable @escaping (Double) -> Void
) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let delegate = DownloadSessionDelegate(
            destination: destination,
            onProgress: onProgress,
            onComplete: { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        )
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        task.resume()
    }
}

/// URLSession delegate that handles progress, file move, and completion for a single download.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: (Double) -> Void
    private let onComplete: (Error?) -> Void

    init(destination: URL, onProgress: @escaping (Double) -> Void, onComplete: @escaping (Error?) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(progress)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let httpStatus = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard httpStatus == 200 else {
            onComplete(URLError(.badServerResponse))
            session.invalidateAndCancel()
            return
        }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            onComplete(nil)
        } catch {
            onComplete(error)
        }
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            onComplete(error)
            session.invalidateAndCancel()
        }
    }
}
