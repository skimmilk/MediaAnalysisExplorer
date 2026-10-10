# MediaAnalysis Explorer

A native macOS app for seeing what Apple's `mediaanalysisd` knows about your photos and videos—and the AI programs it keeps on disk.

`mediaanalysisd` does the background analysis behind features such as Photos search, generated captions, text recognition, scene classification, and Visual Look Up. Explorer brings its saved results, processing activity, and model caches into one browsable app.

## What you can explore

- **Media:** Browse your Photos library's analysis records alongside the original image or video. See captions, recognized text, scene and sensitivity scores, faces, poses, pets, and image characteristics. Detection boxes appear over the image; timed video and audio results follow playback.
- **Processing:** See recent analysis activity, background sessions, result changes, and the daemon's current CPU and memory use. Change the date range or open a recently analyzed item.
- **Models & Caches:** Browse model bundles and their files, see their purpose and compute stages, and inspect tensor inputs, outputs, and compiled operations. Explore the scene taxonomy and geographic scene atlas in dedicated browsers.

Everything is read locally. Explorer does not modify Apple's databases, caches, or media, and it does not run the cached AI programs. Geographic place search and the map use Apple Maps.

![Models & Caches showing a Visual Look Up program and its CPU and Neural Engine stages](docs/screenshots/models-and-caches.png)

## Getting started

Requires **macOS 14 or later** and **Xcode with a Swift 6 toolchain**. The app uses SwiftUI and Apple's system frameworks, with no third-party app dependencies.

From the project folder:

```sh
./launch.sh
```

This quits any running project copy, builds and signs the app, and opens it. To build a release configuration without launching:

```sh
./build-app.sh release
open "build/MediaAnalysis Explorer.app"
```

You can also open `Package.swift` in Xcode. The root-level `build-app.sh` creates a fresh signed app bundle at `build/MediaAnalysis Explorer.app`; omit `release` for a debug build.

On first launch, Explorer opens the standard Photos analysis store and scans the daemon's cache. If macOS blocks access, use **Authorize Library Access** or **Request Cache Access** to approve the folder. If access is still blocked, enable the app in **System Settings → Privacy & Security → Full Disk Access**, then reopen it. Rebuilding the app can require granting access again.

The app currently looks for the standard `~/Pictures/Photos Library.photoslibrary` location. Originals must be downloaded locally to preview them.

## Understanding the models and caches

A bundle is a prepared AI program with its supporting files. A single program can combine **Neural Engine** stages with **CPU** work: for example, a caption decoder uses CPU preprocessing, Neural Engine inference, and CPU probability calculations. Explorer shows these stages and lets you open their compiled files.

The following families have been identified in the inspected caches:

- **Image and video features:** `mubb_md8` extracts visual embeddings—numeric representations used by other analysis tasks. It has separate image and video functions.
- **Caption generation:** Caption decoders turn visual features and text tokens into word scores. Companion programs reshape image/video features for the decoder.
- **Text recognition:** Models detect text regions, determine orientation, and recognize Arabic, Devanagari, Latin, and Cyrillic text. Different width contexts let them process text regions of different sizes.
- **Visual Look Up:** `ObjectDetectionModel` finds objects; `NatureworldModel` scores plants, animals, and pet breeds; `UnifiedModel` supplies classification scores and visual embeddings.
- **Semantic search:** SystemSearch token and text encoders convert text into embeddings for searching by meaning.
- **Audio and combined features:** Programs extract features from spectrograms and combine audio with visual embeddings. Some of these programs expose their inputs and outputs without naming the original model.

Other caches provide reference data:

- **Scene taxonomy:** Categories, synonyms, parent/child relationships, detector links, and score thresholds for scene recognition.
- **Geographic atlas:** Geographic cells, popularity values, and scene-group associations, browsable on a map.
- **Caption vocabulary:** Token IDs and words used by a caption model.

### What the files do

- **`.e5`:** The program plan. It connects compute stages, names their compiled files, and describes the tensors passed between them.
- **`.bnnsir`:** Compiled CPU computation for Apple's BNNS library, including tensor interfaces and kernels.
- **`.espresso.net`:** Neural-network operations and connections for Apple's Espresso runtime.
- **`.espresso.shape`:** Tensor dimensions for the accompanying network.
- **`.espresso.weights`:** Learned model parameters.
- **`.anehash` / `.milhash`:** Identifiers associated with Neural Engine compilation and model intermediate representation.
- **`PFSceneTaxonomyData*.index` / `PFSceneGeographyData.index`:** Scene-category and geographic lookup data.

Cache contents vary with macOS, hardware, and the work the daemon has performed. A cached program describes available computation; it is not a log of which photo used it. Unsupported formats show an error or file details instead of a decoded view.

## Development

Run the core tests with:

```sh
swift test --disable-sandbox
```

`ExplorerCore` contains the database readers, cache inventory, and bounded binary decoders. `MediaAnalysisExplorer` contains the SwiftUI app. Native interface checks live in `scripts/`, and decoder fixtures live in `Fixtures/`.
