//
//  File.swift
//  CoreUI
//
//  Created by Sergio Cardoso on 22/10/25.
//

import SwiftUI

/// A SwiftUI view that asynchronously loads an image from a URL and displays
/// a placeholder while loading, caching the result using `PersistentImageCache`.
///
/// This view first attempts to retrieve a previously cached image for the given URL.
/// If a cached image is found, it is displayed immediately. Otherwise, the view
/// downloads the image, optionally compresses and persists it via `PersistentImageCache`,
/// and then updates the UI when the image becomes available.
///
/// The loading task is tied to the `url` using `.task(id:)` so changing the URL will
/// trigger a new load. State updates to `@State uiimage` are performed on the main actor.
///
/// Usage:
/// ```swift
/// CachedAsyncImage(
///     url: imageURL,
///     placeholder: { ProgressView() },
///     contentMode: .fill
/// )
/// .frame(width: 100, height: 100)
/// .clipped()
/// ```
public struct CachedAsyncImage<Content: View>: View {
    
    /// The remote URL of the image to load and cache.
    let url: URL?
    
    /// A placeholder view shown while the image is being loaded or when no image is yet available.
    @ViewBuilder private var placeholder: () -> Content
    
    /// How the loaded image should fit its available space when displayed.
    var contentMode: ContentMode
    
    /// Optional JPEG compression quality to use when persisting the image to cache.
    /// If `nil`, the image is stored without forcing JPEG compression, allowing the cache
    /// implementation to choose the best strategy.
    var jpegCompression: CGFloat? = nil

    /// The in-memory image loaded from cache or network. When set, the view renders this image.
    @State private var uiimage: UIImage?
    
    /// Creates a cached async image view.
    ///
    /// - Parameters:
    ///   - url: The remote image URL.
    ///   - placeholder: A placeholder view builder displayed while the image is loading.
    ///   - contentMode: The content mode applied to the loaded image. Defaults to `.fill`.
    ///   - jpegCompression: Optional JPEG compression quality to apply when saving to cache.
    ///   - uiimage: An optional preloaded image to display immediately.
    ///
    /// The view first tries to load a cached image for the given URL. If none is found,
    /// it downloads the image and saves it to the persistent cache before updating the UI.
    public init(
        url: URL?,
        @ViewBuilder placeholder: @escaping () -> Content,
        contentMode: ContentMode = .fill,
        jpegCompression: CGFloat? = nil,
        uiimage: UIImage? = nil
    ) {
        self.url = url
        self.placeholder = placeholder
        self.contentMode = contentMode
        self.jpegCompression = jpegCompression
        self.uiimage = uiimage
    }
    
    /// The view hierarchy for the cached image. Shows the loaded image when available,
    /// otherwise displays the provided placeholder and starts the loading task.
    public var body: some View {
        if let uiimage {
            Image(uiImage: uiimage)
                .resizable()
                .aspectRatio(contentMode: contentMode)
        } else {
            placeholder()
                .task(id: url) {
                    await load()
                }
        }
    }
    
    
    /// Loads the image for the current `url`.
    ///
    /// The method first queries `PersistentImageCache` for a cached image. If not found,
    /// it downloads the image using `URLSession`, persists it (optionally applying JPEG
    /// compression), and then updates the UI on the main actor.
    ///
    /// Errors are logged to the console.
    private func load() async {
        guard let url else { return }
        if let cached = await PersistentImageCache.shared.image(for: url) {
            await MainActor.run { self.uiimage = cached }
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = UIImage(data: data) {
                await PersistentImageCache.shared.save(image, for: url, asJPEG: jpegCompression)
                await MainActor.run { self.uiimage = image }
            }
        } catch {
            print("💾 🔴 CachedAsyncImage load error:", error)
        }
    }
}

