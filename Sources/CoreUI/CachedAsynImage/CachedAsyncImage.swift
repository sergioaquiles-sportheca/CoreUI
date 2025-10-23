//
//  File.swift
//  CoreUI
//
//  Created by Sergio Cardoso on 23/10/25.
//

import SwiftUI

/// A SwiftUI view that asynchronously loads and displays an image from a URL with persistent disk caching.
///
/// `CachedAsyncImage` first attempts to retrieve an image from a persistent cache (`PersistentImageCache`).
/// If the image is not cached, it downloads it using `URLSession`, stores it in the cache, and then displays it.
/// While the image is loading (or when no URL is provided), the placeholder view is shown.
///
/// The view is driven by SwiftUI state and automatically reloads when the `url` changes.
///
/// Example usage:
/// ```swift
/// CachedAsyncImage(url: URL(string: "https://example.com/image.jpg")) { image in
///     image
///         .resizable()
///         .scaledToFill()
/// } placeholder: {
///     ProgressView()
/// }
/// .frame(width: 120, height: 120)
/// .clipShape(RoundedRectangle(cornerRadius: 12))
/// ```
///
/// - Note: Images are cached using `PersistentImageCache.shared`. The cache implementation is expected to be
///   thread-safe and persist images between app launches. Errors during download are printed to the console.

/// A SwiftUI view that asynchronously loads and displays an image from a URL with persistent disk caching.
///
/// `CachedAsyncImage` first attempts to retrieve an image from a persistent cache (`PersistentImageCache`).
/// If the image is not cached, it downloads it using `URLSession`, stores it in the cache, and then displays it.
/// While the image is loading (or when no URL is provided), the placeholder view is shown.
///
/// The view is driven by SwiftUI state and automatically reloads when the `url` changes.
///
/// Example usage:
/// ```swift
/// CachedAsyncImage(url: URL(string: "https://example.com/image.jpg")) { image in
///     image
///         .resizable()
///         .scaledToFill()
/// } placeholder: {
///     ProgressView()
/// }
/// .frame(width: 120, height: 120)
/// .clipShape(RoundedRectangle(cornerRadius: 12))
/// ```
///
/// - Note: Images are cached using `PersistentImageCache.shared`. The cache implementation is expected to be
///   thread-safe and persist images between app launches. Errors during download are printed to the console.
public struct CachedAsyncImage<Content> : View where Content: View {
    
    /// The remote image URL. When `nil`, only the placeholder is shown.
    private let url: URL?
    /// The scale factor to use when creating the `UIImage` from downloaded data.
    /// Defaults to `1`.
    private let scale: CGFloat
    /// Builder that produces the content given the loaded `Image`.
    private let contentBuilder: (Image) -> Content
    /// Builder that produces the placeholder while the image is not yet available.
    private let placeholderBuilder: () -> Content

    
    @State private var uiImage: UIImage?
    @State private var isLoading = false

    /// Creates a cached async image view.
    ///
    /// - Parameters:
    ///   - url: The remote image URL. If `nil`, the placeholder is shown and no loading occurs.
    ///   - scale: The scale factor to apply when constructing the `UIImage` from data. Defaults to `1`.
    ///   - content: A view builder that takes the loaded `Image` and returns the content to display.
    ///   - placeholder: A view builder that returns the placeholder to display while loading or when the image is unavailable.
    public init<I, P>(url: URL?,
                      scale: CGFloat = 1,
                      @ViewBuilder content: @escaping (Image) -> I,
                      @ViewBuilder placeholder: @escaping () -> P)
    where Content == _ConditionalContent<I, P>, I: View, P: View {
        self.url = url
        self.scale = scale
        self.contentBuilder = { image in
            ViewBuilder.buildEither(first: content(image))
        }
        self.placeholderBuilder = {
            ViewBuilder.buildEither(second: placeholder())
        }
    }

    /// The content and behavior of the view.
    public var body: some View {
        Group {
            if let uiImage {
                contentBuilder(Image(uiImage: uiImage))
            } else {
                placeholderBuilder()
            }
        }
        .task(id: url) {
            await loadImage()
        }
    }

    /// Loads the image for the current `url`.
    ///
    /// The method checks the persistent cache first. If no cached image is found, it downloads the data,
    /// constructs a `UIImage` using the configured `scale`, saves it to the cache, and updates view state on the main actor.
    /// Re-entrancy is prevented by the `isLoading` flag and the task is re-triggered when `url` changes.
    private func loadImage() async {
        guard let url else { return }
        if isLoading { return }
        isLoading = true
        defer { isLoading = false }
        if let cached = await PersistentImageCache.shared.image(for: url) {
            await MainActor.run { self.uiImage = cached }
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = UIImage(data: data, scale: scale) {
                await PersistentImageCache.shared.save(image, for: url, asJPEG: nil)
                await MainActor.run { self.uiImage = image }
            }
        } catch {
            print("💾 🔴 CachedAsyncImage load error:", error)
        }
    }
}

