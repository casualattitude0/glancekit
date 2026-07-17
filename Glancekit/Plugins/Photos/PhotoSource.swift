import AppKit
import Photos

/// Where the Photos glance pulls images from.
enum PhotoSourceKind: String, CaseIterable, Identifiable {
    case folder
    case photosLibrary

    var id: String { rawValue }

    var label: String {
        switch self {
        case .folder: return "Folder on disk"
        case .photosLibrary: return "Photos library"
        }
    }
}

/// A single loaded slide. `image` is already decoded and ready to draw;
/// `caption` is a filename or date to show under it.
struct PhotoSlide: Identifiable {
    let id: String
    let image: NSImage
    let caption: String
}

/// Loads slides from a security-scoped folder bookmark on disk.
enum FolderPhotoLoader {
    static let bookmarkKey = "glancekit.photos.bookmark"

    private static let extensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "gif", "tiff", "tif", "bmp", "webp"
    ]

    /// Resolves the persisted bookmark, starts security-scoped access, and
    /// returns the resolved folder URL. Caller is responsible for calling
    /// `stopAccessingSecurityScopedResource()` on the returned URL when done
    /// enumerating (see `loadSlides`, which handles this internally).
    static func resolveBookmarkedFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return url
    }

    /// Persists a new security-scoped bookmark for a folder chosen via NSOpenPanel.
    static func saveBookmark(for url: URL) {
        guard let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

    /// Forgets the persisted folder bookmark, dropping the app's security-scoped
    /// access to it. The folder itself is untouched.
    static func clearBookmark() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    /// Enumerates image files in the bookmarked folder and decodes them.
    /// Never throws; returns an empty array on any failure (missing folder,
    /// denied access, no bookmark yet, etc.). Safe to call off the main thread.
    static func loadSlides(limit: Int = 100) -> [PhotoSlide] {
        guard let url = resolveBookmarkedFolder() else { return [] }
        guard url.startAccessingSecurityScopedResource() else { return [] }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let files = entries
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .prefix(limit)

        return files.compactMap { fileURL in
            guard let image = NSImage(contentsOf: fileURL) else { return nil }
            return PhotoSlide(id: fileURL.path, image: image, caption: fileURL.lastPathComponent)
        }
    }
}

/// Loads slides from the user's Photos library via PhotoKit.
enum LibraryPhotoLoader {

    static var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    /// Requests read/write authorization (needed to read the library);
    /// resolves on whatever thread the system callback delivers, never throws.
    static func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// Fetches the most recent `limit` images and decodes thumbnails suitable
    /// for the popover slideshow. Safe to call off the main thread. Returns an
    /// empty array if unauthorized or the library is empty.
    static func loadSlides(limit: Int = 100) async -> [PhotoSlide] {
        let status = authorizationStatus
        guard status == .authorized || status == .limited else { return [] }

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.fetchLimit = limit
        let assets = PHAsset.fetchAssets(with: .image, options: fetchOptions)

        let manager = PHImageManager.default()
        let requestOptions = PHImageRequestOptions()
        requestOptions.isSynchronous = false
        requestOptions.deliveryMode = .highQualityFormat
        requestOptions.isNetworkAccessAllowed = true

        var slides: [PhotoSlide] = []
        var assetList: [PHAsset] = []
        assets.enumerateObjects { asset, _, _ in assetList.append(asset) }

        for asset in assetList {
            let image: NSImage? = await withCheckedContinuation { continuation in
                manager.requestImage(
                    for: asset,
                    targetSize: CGSize(width: 600, height: 400),
                    contentMode: .aspectFit,
                    options: requestOptions
                ) { image, _ in
                    continuation.resume(returning: image)
                }
            }
            guard let image else { continue }
            let caption: String
            if let date = asset.creationDate {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                caption = formatter.string(from: date)
            } else {
                caption = asset.localIdentifier
            }
            slides.append(PhotoSlide(id: asset.localIdentifier, image: image, caption: caption))
        }
        return slides
    }
}
