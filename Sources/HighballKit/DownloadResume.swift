import Foundation

/// The resumable-download decisions, kept pure so they are testable without a server.
/// (Touching this file exercises the pull-request funnel gate.)
public enum DownloadResume {
    public enum Decision: Equatable, Sendable { case append, restart, failed }

    /// Headers for a retry: a byte range from what is already on disk, conditional on the ETag
    /// the first response carried so a changed asset restarts instead of splicing two files.
    /// Nothing on disk means a plain request.
    public static func rangeHeaders(partialBytes: Int64, etag: String?) -> [String: String]? {
        guard partialBytes > 0 else { return nil }
        var h = ["Range": "bytes=\(partialBytes)-"]
        if let etag { h["If-Range"] = etag }
        return h
    }

    /// 206 with a partial on disk means append; 200 means the server sent the whole thing (no
    /// range support, or the ETag changed), so start over; 416 means the range was past the end
    /// (a partial that is already complete, or an asset that shrank), so start over rather than
    /// asking for the same impossible range on every retry; anything else is a failure. A 206
    /// without a partial cannot happen with our request and is treated as a restart.
    public static func decide(status: Int, partialBytes: Int64) -> Decision {
        switch status {
        case 206: return partialBytes > 0 ? .append : .restart
        case 200..<300: return .restart
        case 416: return .restart
        default: return .failed
        }
    }
}
