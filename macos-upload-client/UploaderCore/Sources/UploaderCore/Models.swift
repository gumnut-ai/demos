import Foundation

/// Lifecycle of a discovered file, persisted in the `files` table.
public enum FileStatus: String, Codable, Sendable, CaseIterable {
    /// Not yet known to exist on the server; awaiting hash/check/upload.
    case pending
    /// Present on the server (matched by checksum, or uploaded).
    case synced
    /// Excluded by the user; never uploaded while excluded.
    case excluded
    /// RAW format — counted and skipped (the API does not accept RAW yet).
    case skippedRaw = "skipped_raw"
    /// Not a format the API accepts.
    case skippedUnsupported = "skipped_unsupported"
    /// Last attempt failed; will reappear in the next run's plan.
    case error
}

public enum MediaClassification: Sendable, Equatable {
    case image
    case video
    case raw
    case unsupported

    /// The status a freshly discovered, non-excluded file starts in.
    public var initialStatus: FileStatus {
        switch self {
        case .image, .video: .pending
        case .raw: .skippedRaw
        case .unsupported: .skippedUnsupported
        }
    }
}

public enum RunOutcome: String, Codable, Sendable {
    case running
    case completed
    case cancelled
    case failed
}

/// Per-run statistics, stored as JSON so fields can evolve freely.
public struct RunCounters: Codable, Equatable, Sendable {
    public var filesDiscovered: Int
    public var mediaFiles: Int
    public var alreadySynced: Int
    public var toUpload: Int
    public var uploaded: Int
    public var skippedRaw: Int
    public var skippedUnsupported: Int
    public var excluded: Int
    public var errors: Int
    public var duplicateLocalFiles: Int
    public var bytesUploaded: Int64
    /// Files skipped this run because they were modified moments before the
    /// scan (possibly still being copied); they are picked up next run.
    public var deferredRecentlyModified: Int

    public init(
        filesDiscovered: Int = 0,
        mediaFiles: Int = 0,
        alreadySynced: Int = 0,
        toUpload: Int = 0,
        uploaded: Int = 0,
        skippedRaw: Int = 0,
        skippedUnsupported: Int = 0,
        excluded: Int = 0,
        errors: Int = 0,
        duplicateLocalFiles: Int = 0,
        bytesUploaded: Int64 = 0,
        deferredRecentlyModified: Int = 0
    ) {
        self.filesDiscovered = filesDiscovered
        self.mediaFiles = mediaFiles
        self.alreadySynced = alreadySynced
        self.toUpload = toUpload
        self.uploaded = uploaded
        self.skippedRaw = skippedRaw
        self.skippedUnsupported = skippedUnsupported
        self.excluded = excluded
        self.errors = errors
        self.duplicateLocalFiles = duplicateLocalFiles
        self.bytesUploaded = bytesUploaded
        self.deferredRecentlyModified = deferredRecentlyModified
    }
}
