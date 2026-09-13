# Media

Working with images, video, and audio in SwiftUI: loading, downsampling, playback,
recording, and previewing. Companion to **data/networking** (fetching remote assets),
**state/flow** (managing player lifecycles), and **view/effects** (shaders and
graphics).

## Three rules

1. **Downsample images off the main actor.** Never decode full-resolution camera or
   network images directly into `Image(uiImage:)` or `Image(nsImage:)` on the main
   thread; use `CGImageSource` with explicit pixel constraints in a background task.
2. **Tie media players strictly to view lifecycles.** `AVPlayer` instances keep
   streaming and decoding frames until paused or torn down. Pause on `.onDisappear` or
   manage playback within structured `.task(id:)` blocks.
3. **Use system viewers before hand-rolling modal viewers.** Leverage
   `.quickLookPreview(_:)` or `openWindow` (macOS) before implementing custom gestures,
   zoom matrices, and pan layers.

---

## Images

### Remote images with `AsyncImage`

Always handle phases explicitly to manage layout shifts, loading spinners, and error
fallbacks:

```swift
AsyncImage(url: imageURL, transaction: Transaction(animation: .easeInOut)) { phase in
    switch phase {
    case .empty:
        ProgressView()
            .frame(width: 120, height: 120)
    case .success(let image):
        image
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 120, height: 120)
            .clipped()
    case .failure:
        Image(systemName: "photo.badge.exclamationmark")
            .foregroundStyle(.secondary)
            .frame(width: 120, height: 120)
    @unknown default:
        EmptyView()
    }
}
```

- **Define explicit frames on placeholders and containers** to prevent layout thrashing
  while images load.
- **Cache considerations:** `AsyncImage` relies entirely on `URLCache.shared`. If you
  need custom disk caches or prefetching in high-velocity feeds, wrap your own async
  pipeline or loader service.

### Off-thread decoding & downsampling

Decoding high-resolution image data consumes substantial memory (width × height × 4
bytes). Downsample to display point sizes multiplied by screen scale:

```swift
import ImageIO

nonisolated func downsample(
    data: Data,
    to pointSize: CGSize,
    scale: CGFloat = 2.0
) -> CGImage? {
    let maxPixelSize = max(pointSize.width, pointSize.height) * scale
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
    ]

    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
        return nil
    }
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}
```

Render cross-platform via `Image(decorative: cgImage, scale: scale)`. This avoids
platform-specific `UIImage` / `NSImage` imports in domain or view code.

### SF Symbols & dynamic effects

- Use SF Symbols with `.symbolRenderingMode(.hierarchical)` or `.multicolor` for
  consistent platform iconography.
- Animate status transitions with `.symbolEffect`:
  ```swift
  Image(systemName: isPlaying ? "speaker.wave.3.fill" : "speaker.slash.fill")
      .contentTransition(.symbolEffect(.replace))
  ```

### View snapshots with `ImageRenderer`

On iOS 16+ and macOS 13+, use `@MainActor ImageRenderer` to render SwiftUI views into
raster images or PDFs without UIKit/AppKit view hierarchies:

```swift
@MainActor
func exportBadge(title: String) -> CGImage? {
    let renderer = ImageRenderer(content: BadgeView(title: title))
    renderer.scale = 2.0
    return renderer.cgImage
}
```

---

## Video

### Declarative playback with `VideoPlayer`

Use `AVKit.VideoPlayer` for native playback controls, picture-in-picture, and audio
routing:

```swift
import AVKit
import SwiftUI

struct MediaVideoView: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            let item = AVPlayerItem(url: url)
            player = AVPlayer(playerItem: item)
            player?.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}
```

- **Looping video:** Use `AVQueuePlayer` paired with `AVPlayerLooper` for gapless
  background loops (e.g., onboarding screens).
- **Audio mixing:** Set `player.isMuted = true` for autoplaying feed items so they do
  not interrupt system music.

### Async video thumbnail generation

Generate thumbnails asynchronously using modern Swift concurrency with
`AVAssetImageGenerator`:

```swift
import AVFoundation

func thumbnail(for videoURL: URL, at time: CMTime = .zero) async throws -> CGImage {
    let asset = AVURLAsset(url: videoURL)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    let (image, _) = try await generator.image(at: time)
    return image
}
```

---

## Audio

### Session configuration & routing

On iOS, configure `AVAudioSession` before initiating playback. macOS handles audio
routing at the system level and has no `AVAudioSession`:

```swift
#if os(iOS)
import AVFAudio

func configureAudioSession(category: AVAudioSession.Category = .playback) throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(category, mode: .default, options: [.mixWithOthers])
    try session.setActive(true)
}
#endif
```

- **Playback categories:**
  - `.playback`: Plays even when the silent switch is engaged (podcasts, videos).
  - `.ambient`: Respects the silent switch and mixes with background audio (game sound
    effects, UI clicks).
- **Interruption handling:** Listen to `AVAudioSession.interruptionNotification` to
  pause state when phone calls or alarms arrive.

### Sound effects vs. streaming audio

- **Short UI effects (< 5s):** Preload an `AVAudioPlayer` or use `AVAudioEngine` for
  low-latency triggers.
- **Longer audio / streams:** Use `AVPlayer` with remote URLs. Track progress and state
  changes using `AVPlayerItem.status` or `timeControlStatus` via Key-Value Observing
  (`observations` or `AsyncStream`).

---

## Media Previews & Fullscreen Viewers

### Inline previews with QuickLook

Present attachments and media files (images, PDFs, movies, audio) using system QuickLook
sheet or overlay:

```swift
import QuickLook
import SwiftUI

struct MediaGalleryView: View {
    /// Local file URLs. Quick Look previews files on disk — a remote `https://` URL
    /// renders a thumbnail via `AsyncImage` but fails to open in the preview.
    let fileURLs: [URL]
    @State private var selectedURL: URL?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(fileURLs, id: \.self) { url in
                    Button {
                        selectedURL = url
                    } label: {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Color.secondary.opacity(0.15)
                            }
                        }
                        .frame(width: 88, height: 88)
                        .clipShape(.rect(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .quickLookPreview($selectedURL)
    }
}
```

- **Quick Look needs a file URL.** `.quickLookPreview` resolves its binding against the
  file system; it cannot fetch. For remote media, download to a temporary or cached
  location first and bind the *local* URL:

  ```swift
  let (tmp, _) = try await URLSession.shared.download(from: remoteURL)
  let cached = URL.cachesDirectory.appending(path: remoteURL.lastPathComponent)
  try? FileManager.default.removeItem(at: cached)
  try FileManager.default.moveItem(at: tmp, to: cached)   // `tmp` is deleted on return
  selectedURL = cached
  ```

- **Cross-platform presentation:**
  - **iOS:** Use `.quickLookPreview($selectedURL)` or `.sheet` / `.fullScreenCover` for
    custom viewer chrome.
  - **macOS:** Use `.quickLookPreview($selectedURL)` for modal preview, or call
    `openWindow(id:value:)` to present media in independent multi-window instances.
