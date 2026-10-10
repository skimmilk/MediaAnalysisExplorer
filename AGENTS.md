# MediaAnalysis Explorer

This is a local native macOS application for exploring the records, processing history, and model caches stored by Apple's `mediaanalysisd`. It uses SwiftUI with system SQLite, compression, cryptography, image, and media frameworks. `Package.swift` defines the targets and requires macOS 14 or later; there are no third-party app dependencies.

The main areas are Media (stored results and original previews), Processing (activity and coverage), and Models & Caches (files, bundles, taxonomy, geography, and BNNS program metadata). The release app focuses on browsing and does not expose research exports, diagnostic imports, or a Photos importer.

## Important folders and files

- `README.md`: A short user introduction, feature overview, build instructions, and model/cache guide.
- `Package.swift`: Swift package targets and dependencies.
- `Sources/ExplorerCore/`: Database access, inventory, bounded binary decoders, and analysis interpretation. Keep this layer independent of SwiftUI.
  - `SQLite.swift`, `Library.swift`, and `StoredData.swift`: Read-only database access, Photos linkage, and stored records.
  - `AnalysisPayload.swift`, `VisualMetadata.swift`, `RegionTimeline.swift`, and `PlaybackTimeline.swift`: Stored analysis fields, geometry, and timed media results.
  - `ProcessingDashboard.swift`, `ProcessingHistory.swift`, and `PersistenceHistory.swift`: Processing summaries and historical records.
  - `Inventory.swift`: Cache discovery, file inspection, signatures, limits, and decoder integration.
  - `CacheBundle.swift`, `CacheExplanation.swift`, and `StaticGraphDecoder.swift`: Bundle relationships, evidence-based file descriptions, and static graph metadata.
  - `BNNSProgram.swift`: Bounded static `.bnnsir` interface and operation decoder. Reads metadata without executing models.
  - `E5Program.swift`: Bounded static E5 manifest reader, stored function/stage interfaces, and inventory-contained companion resolution. Uses declared source containers, never inferred model titles.
  - `SceneTaxonomy.swift`, `SceneGeography.swift`, `CaptionVocabulary.swift`, and `ImageFeatureDescriptor.swift`: Specialized readers for recovered cache/result formats.

- `Sources/MediaAnalysisExplorer/`: Native SwiftUI application and its presentation state.
  - `App.swift` and `AppLifecycle.swift`: Application entry point, menus, and lifecycle.
  - `ExplorerModel.swift`: Main state, background loading, cancellation, selection, and access authorization.
  - `ExplorerView.swift`: Main application layout and navigation.
  - `CachesView.swift`, `BNNSProgramView.swift`, and `E5ProgramView.swift`: Cache browsing, the E5 file filter, and selected program presentation. E5 stages can open inventoried compiled artifacts in the same Files browser.
  - `AssetVisualization.swift`, `RegionCanvas.swift`, and `RecordRelationshipsView.swift`: Asset/result inspection, overlays, and linked records.
  - `ProcessingView.swift`, `TaxonomyBrowserView.swift`, and `GeographyView.swift`: Specialized application screens.
  - `ImageAppearanceView.swift`, `AudioTimelineView.swift`, `LivePlaybackPanel.swift`, and `LocalVideoPlayer.swift`: Feature summaries and media playback.
  - `Resources/Geography/`: Bundled geography presentation resources.
- `Sources/CSQLite/` and `Sources/CBZip2/`: System-library module wrappers. `Sources/CAtlasSupport/` supplies the small C hashing helper used by archive decoding.
- `Tests/ExplorerCoreTests/`: Core regression tests, including decoder, read-only access, cancellation, provenance, and geometry checks. Developer-only test-media validation and schema reference helpers live here. `BNNSProgramTests.swift` and `E5ProgramTests.swift` cover the static program readers.
- `Fixtures/`: Test databases and metadata fixtures; read `PROVENANCE.md`. `Fixtures/BNNS/` contains metadata prefixes, compiler footers, and getter-derived expectations, without learned weights.
  - `Fixtures/E5/`: All 20 small E5 manifests and independent decoder expectations, with provenance and no learned weight arrays.
- `build-app.sh`: Root-level build script that creates a fresh app bundle, copies resources, and ad-hoc signs `build/MediaAnalysis Explorer.app`. `scripts/Info.plist` holds bundle metadata and version.
- `launch.sh` and `scripts/relaunch-app.swift`: The root-level launcher requests normal termination of existing project app instances, then builds and launches. A refusal to quit stops the rebuild.
- `scripts/check-*-interface.*`, `scripts/check-image-appearance.*`, and other `check-*` scripts: Native hosted checks and render artifacts for actual application views. `check-bnns-interface.sh` and `check-e5-interface.sh` check program scan/search/selection flows.
- `research-notes/`: Investigation reports, decoding scripts, evidence, and interactive `.canvas.tsx` reports. `research-notes/bnns/README.md` documents the nine inspected BNNS programs and independent verification.
  - `research-notes/e5/`: Static E5 manifest decoder, generated-reader evidence, BNNS interface comparisons, and the report template. Read its `README.md` for supported fields and remaining uncertainty.
- `research-captures/`: Local captured databases, logs, manifests, and observation results; excluded from version control.
- `test-media/` and `test-media-research-2/`: Local test batches, manifests, provenance, preparation scripts, and coverage evidence.
- `outputs/`: Generated checks, screenshots, and validation results. `.build/` is SwiftPM output; `build/` holds app bundles. Treat these as generated artifacts, not source.

## Working on this application

- Keep Apple's source databases, originals, and caches read-only. Never import media or substitute fixtures for an unavailable live source.
- Preserve the distinction between observed data and inference. A model filename, matching tensor interface, or coincident activity does not prove runtime routing or per-asset model use.
- Keep parsers bounded and cancellable. Unsupported or damaged data should retain raw evidence and show an explicit unavailable reason instead of fabricated interpretation.
- Protected-source access can differ between the shell and the authorized native app. Shell escalation does not grant macOS privacy access; use the existing native authorization path when appropriate.
- Build with `./build-app.sh` (or append `release`), launch with `./launch.sh`, and run core tests with `swift test --disable-sandbox`. Run the relevant native check for changes to a specialized screen. Optional capture/media tests require their documented local inputs.
- Native bitmap exports can omit text/vibrancy layers. Report that limitation and any unavailable live screen capture; do not equate a hosted render with complete visual verification.

## Displaying canvas reports — required

**A Markdown link to a `.canvas.tsx` file is not a rendered report in this environment. It opens the TSX source code. Never deliver a canvas report by linking to that file alone.**

- Read the available canvas/visualize skill instructions before creating or changing visual reports. Use the actual supported visualization renderer or tool to display the content, and verify that the user receives the rendered report rather than the editor.
- If no canvas renderer is available, adapt the report's content into an inline HTML visualization using the visualize skill. A TSX file cannot be passed directly to an HTML renderer.
- For the currently supported inline visualization mechanism, save an HTML fragment in an authorized durable output location and include this content reference in the final response, with the real absolute HTML path:

  ```text
  visualize{"path":"/absolute/path/report.html"}
  ```

- Keep `.canvas.tsx` files as editable research artifacts when useful, but a source link is only supplementary. If rendering is unavailable, put the useful findings directly in the chat and explain the rendering limitation. When the user asks for the report here, include the report here.
