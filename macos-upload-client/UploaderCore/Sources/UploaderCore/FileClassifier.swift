import Foundation

/// Classifies files by extension. The image/video allowlists mirror what the
/// API accepts today (anything else is rejected server-side with 422); the RAW
/// list covers common camera formats so they are counted rather than silently
/// ignored.
public enum FileClassifier {
    public static let imageExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp",
    ]

    public static let videoExtensions: Set<String> = [
        "3gp", "avi", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "webm", "wmv",
    ]

    public static let rawExtensions: Set<String> = [
        "3fr", "ari", "arw", "cap", "cin", "cr2", "cr3", "crw", "dcr", "dng",
        "erf", "fff", "iiq", "k25", "kdc", "mrw", "nef", "nrw", "orf", "ori",
        "pef", "raf", "raw", "rw2", "rwl", "sr2", "srf", "srw", "x3f",
    ]

    public static func classify(fileName: String) -> MediaClassification {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        if rawExtensions.contains(ext) { return .raw }
        return .unsupported
    }
}
