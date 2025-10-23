//
//  PersistentImageCache.swift
//  CoreUI
//
//  Created by Sergio Cardoso on 22/10/25.
//

import SwiftUI


/// A thread-safe (actor-isolated) image cache that persists items to disk and mirrors hot entries in memory.
///
/// Features
/// - In-memory caching via `NSCache` with cost-based eviction.
/// - On-disk caching in the app's caches directory, namespaced by `ImageCacheConfig.nameSpace`.
/// - Keys are derived from the absolute URL string and hashed with SHA-256 to create stable, filesystem-safe filenames.
/// - Time-to-live (TTL) expiration controlled by `ImageCacheConfig.timeToLive`.
/// - Disk usage bounded by `ImageCacheConfig.maxDiskBytes` with LRU eviction (by modification date).
///
/// Concurrency
/// - Declared as an `actor` to protect internal state and file-system operations.
/// - Public APIs are actor-isolated; call them with `await` from concurrent contexts.
public actor PersistentImageCache {
    
    /// Shared singleton instance suitable for simple, app-wide caching needs.
    public static let shared = PersistentImageCache()
    
    /// File manager used to access the caches directory and manage files on disk.
    private let fileManager: FileManager = .default
    /// In-memory cache for fast lookups of recently used images. Cost is set to the byte size of image data.
    private let memoryCache = NSCache<NSURL, UIImage>()
    /// Directory on disk where cached image files are stored.
    private let dirURL: URL
    /// Current configuration controlling namespace, TTL, and maximum disk usage.
    private var config: ImageCacheConfig
    
    /// Creates a new cache with the given configuration.
    /// - Parameter config: Configuration for namespace, TTL, and disk limits. Defaults to `ImageCacheConfig()`.
    ///
    /// The cache directory is created under the user's caches directory. The in-memory cache is initialized with
    /// a default total cost limit (~64 MB).
    public init(config: ImageCacheConfig = .init()) {
        self.config = config
        let documentDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        dirURL = documentDirectory.appendingPathComponent(config.nameSpace, isDirectory: true)
        try? fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)
        memoryCache.totalCostLimit = 64 * 1024 * 1024
    }
    
    /// Updates the cache configuration for subsequent operations.
    /// - Note: This does not retroactively rewrite existing files. TTL and size enforcement occur lazily
    ///         as items are accessed or when cleanup is triggered.
    public func configure(_ newConfig: ImageCacheConfig) {
        self.config = newConfig
    }
    
    /// Retrieves an image for the given URL from memory or disk.
    /// - Parameter url: The canonical URL used as the cache key (hashed for disk storage).
    /// - Returns: A decoded `UIImage` if present and not expired; otherwise `nil`.
    ///
    /// Lookup order:
    /// 1. Memory cache (NSCache)
    /// 2. Disk cache (validates TTL; refreshes modification date on access)
    public func image(for url: URL) -> UIImage? {
        if let image = memoryCache.object(forKey: url as NSURL) {
            print("💾 🟩 Fetched from memory cache")
            return image
        }
        guard let data = loadDataForKey(url) else { return nil }
        if let img = UIImage(data: data) {
            memoryCache.setObject(img, forKey: url as NSURL, cost: data.count)
            print("💾 🟩 Fetched from disk cache")
            return img
        }
        return nil
    }
    
    /// Stores an image in both the in-memory and on-disk caches.
    ///
    /// - Parameters:
    ///   - image: The `UIImage` to cache.
    ///   - url: The logical key for the image. The absolute string is hashed (SHA-256) to derive the on-disk filename.
    ///   - compression: Optional JPEG compression quality (0.0–1.0). If provided and JPEG data can be produced,
    ///                  the image is stored as JPEG; otherwise PNG data is used.
    ///
    /// Behavior
    /// - Updates the memory cache immediately with a cost equal to the encoded byte size.
    /// - Persists the encoded data to the cache directory atomically and updates the file's modification date.
    /// - Triggers cleanup to enforce TTL and maximum disk usage (LRU by modification date).
    ///
    /// - Note: Errors during disk writes are logged to the console and do not throw.
    public func save(_ image: UIImage, for url: URL, asJPEG compression: CGFloat? = nil) {
        // Memory
        let data: Data
        if let compression, let jpeg = image.jpegData(compressionQuality: compression) {
            data = jpeg
        } else {
            data = image.pngData() ?? Data()
        }
        memoryCache.setObject(image, forKey: url as NSURL, cost: data.count)
        
        // Disk
        let fileURL = fileURLForKey(url)
        do {
            try data.write(to: fileURL, options: .atomic)
            try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
            print("💾 🟩 Saved to disk cache")
        } catch {
            print(" 📁 🔴 ImageCache write error:", error)
        }
        cleanupIfNeeded()
    }

    
    /// Removes a specific cached image from both memory and disk.
    /// - Parameter url: The URL key whose cached entry should be removed.
    public func remove(for url: URL) {
        memoryCache.removeObject(forKey: url as NSURL)
        let fileURL = fileURLForKey(url)
        try? fileManager.removeItem(at: fileURL)
    }
    
    /// Clears the entire cache, removing all items from memory and disk.
    /// Recreates the cache directory after deletion.
    public func clearAll() {
        memoryCache.removeAllObjects()
        try? fileManager.removeItem(at: dirURL)
        try? fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)
    }
    
    /// Loads raw data for a URL key from disk, respecting TTL and touching the modification date on successful access.
    /// - Returns: The file data if it exists and is not expired; otherwise `nil`.
    private func loadDataForKey(_ url: URL) -> Data? {
        let fileURL = fileURLForKey(url)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        if isExpired(fileURL) {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
        
        return try? Data(contentsOf: fileURL)
    }
    
    /// Builds a filesystem-safe URL for storing a cached image associated with a logical URL key.
    ///
    /// This helper derives a filename from the provided URL by:
    /// - Taking the absolute string of the URL.
    /// - Percent-encoding it with a restricted character set (alphanumerics plus "-._@").
    /// - Truncating to a maximum length (200 characters) to avoid overly long filenames.
    /// - Appending an extension based on the original URL's path extension (or "img" if absent).
    ///
    /// The resulting filename is placed inside the cache namespace directory (`dirURL`). While this
    /// approach aims to be stable and safe for the filesystem, it is not cryptographically unique; two
    /// extremely long or similar URLs could theoretically collide after truncation. For stronger
    /// uniqueness guarantees, consider hashing the absolute string (e.g., SHA-256) and using the hash
    /// as the filename.
    ///
    /// - Parameter url: The canonical URL that acts as the cache key.
    /// - Returns: A `URL` pointing to the location on disk where the cached data should be stored.
    private func fileURLForKey(_ url: URL) -> URL {
        
        let original = url.absoluteString
        
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._@")
        let encoded = original.addingPercentEncoding(withAllowedCharacters: allowed) ?? UUID().uuidString

        let maxLength = 200
        let base: String
        if encoded.count > maxLength {
            base = String(encoded.suffix(maxLength))
        } else {
            base = encoded
        }

        let ext = (url.pathExtension.isEmpty ? "img" : url.pathExtension)
        let fileName = "\(base).\(ext)"
        let fileURL = dirURL.appendingPathComponent(fileName)
        return fileURL
    }
    
    /// Determines whether a file at the given URL has exceeded the configured TTL based on its modification date.
    private func isExpired(_ url: URL) -> Bool {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let mdate = attrs[.modificationDate] as? Date else { return true }
        return Date().timeIntervalSince(mdate) > TimeInterval(config.timeToLive)
    }
    
    /// Computes the total size in bytes of the cache directory (non-recursive, skips hidden files).
    private func directorySize() -> Int {
        guard let files = try? fileManager.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total = 0
        for url in files {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int(size)
            }
        }
        return total
    }
    
    /// Performs maintenance by removing expired files and enforcing the maximum disk size using LRU by modification date.
    private func cleanupIfNeeded() {
        removeExpiredFiles()
        
        // 2) Enforce max size (LRU by modification date)
        var size = directorySize()
        guard size > config.maxDiskBytes else { return }
        
        guard let files = try? fileManager.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        
        for url in sorted {
            if size <= config.maxDiskBytes { break }
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try? fileManager.removeItem(at: url)
            print(" 📁 🔴 deleted from disk cache:")
            size -= fileSize
        }
    }
    
    /// Removes any files in the cache directory that have expired according to the configured TTL.
    private func removeExpiredFiles() {
        guard let files = try? fileManager.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        for url in files {
            if isExpired(url) { try? fileManager.removeItem(at: url) }
        }
    }
}

