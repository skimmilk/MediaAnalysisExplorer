import SwiftUI
import ExplorerCore

struct TaxonomyBrowserView: View {
    @ObservedObject var model: ExplorerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.taxonomyFromGeography {
                Button("Back to Geography", systemImage: "arrow.left") { model.cacheView = .geography }
            }
            sourceControls
            if let issue = model.taxonomyFailure {
                HStack(alignment: .top) { Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange); Spacer(); Button("Retry") { model.ensureTaxonomySources(); model.loadTaxonomy() } }
            }
            if let taxonomy = model.taxonomy {
                taxonomyIdentity(taxonomy)
                Divider()
                HSplitView {
                    conceptList.frame(minWidth: 290, idealWidth: 330, maxWidth: 420).padding(.trailing, 10)
                    ScrollView {
                        if let node = model.currentConcept { TaxonomyConceptInspector(model: model, taxonomy: taxonomy, node: node).padding(16) }
                        else { ContentUnavailableView("Select a concept", systemImage: "list.bullet.indent") }
                    }.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if model.busy.contains("taxonomy") || model.busy.contains("taxonomySources") || model.busy.contains("scan") {
                ProgressView("Reading taxonomy…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Taxonomy unavailable", systemImage: "list.bullet.indent", description: Text("Choose an installed archive or a readable cache index. Unsupported and damaged files are reported without a substitute dataset."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            model.ensureTaxonomySources()
            if model.taxonomy == nil, !model.busy.contains("taxonomy") { model.loadTaxonomy() }
        }
        .onChange(of: model.selectedTaxonomySource) { _, _ in model.loadTaxonomy() }
        .onChange(of: model.taxonomyLocale) { _, _ in model.loadTaxonomyLocale() }
    }
    private var sourceControls: some View {
        HStack(spacing: 12) {
            Picker("Source", selection: $model.selectedTaxonomySource) {
                ForEach(model.taxonomySources) { source in Text(source.title).tag(Optional(source.id)) }
            }.frame(maxWidth: 550)
            if let localization = model.taxonomyLocalization {
                Picker("Labels", selection: $model.taxonomyLocale) {
                    ForEach(localization.availableLocales, id: \.self) { locale in
                        Text((Locale(identifier: "en").localizedString(forIdentifier: locale) ?? locale) + " · " + locale).tag(locale)
                    }
                }.frame(maxWidth: 270)
            }
            Spacer()
            if model.taxonomy?.source.isCache == true {
                Button("Back to Cache File", systemImage: "doc.text") { model.revealTaxonomyFile() }
            }
            Button("Reload", systemImage: "arrow.clockwise") { model.loadTaxonomy() }.disabled(model.selectedTaxonomySource == nil || model.busy.contains("taxonomy"))
        }.controlSize(.small)
    }
    private func taxonomyIdentity(_ taxonomy: SceneTaxonomy) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 16) {
                Text("\(taxonomy.concepts.count) concepts · \(taxonomy.hierarchyEdges) hierarchy links · \(taxonomy.detectorLinks) detector links").font(.caption.monospacedDigit())
                if let version = taxonomy.indexVersion { Label("Index v\(version) · checksum verified", systemImage: "checkmark.shield").font(.caption).foregroundStyle(.teal) }
                InfoButton(title: "Taxonomy source", text: taxonomy.source.url.path)
                Spacer()
            }
            Text(taxonomy.source.url.path).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(taxonomy.source.url.path)
            if let reference = model.comparisonTaxonomy {
                let differences = taxonomy.differences(from: reference)
                if taxonomy.source.isCache {
                    Text(differences == 0
                         ? "Category contents match \(reference.source.title). \(taxonomy.declaredDigest == reference.declaredDigest ? "Declared digest also matches." : "Declared digest differs.")"
                         : "Compared with \(reference.source.title): \(differences) concepts differ or are absent.")
                        .font(.caption).foregroundStyle(differences == 0 ? Color.teal : Color.secondary)
                } else { Text("Comparison: \(reference.source.title) · changed cells use bold text.").font(.caption).foregroundStyle(.secondary) }
            } else if model.busy.contains("taxonomyComparison") { ProgressView("Reading comparison…").controlSize(.mini) }
            if let issue = model.taxonomyComparisonFailure { Text("Comparison unavailable: " + issue).font(.caption).foregroundStyle(.orange) }
        }
    }
    private var conceptList: some View {
        let concepts = model.visibleConcepts
        return VStack(alignment: .leading, spacing: 8) {
            TextField("Label, alias, scene ID or internal name", text: $model.taxonomyQuery).textFieldStyle(.roundedBorder)
            HStack {
                Picker("Network", selection: $model.taxonomyNetwork) {
                    Text("All networks").tag(UInt32(0)); Text("SceneNet · 1").tag(UInt32(1)); Text("EntityNet · 2").tag(UInt32(2))
                }.labelsHidden()
                Picker("Indexed", selection: $model.taxonomyIndexed) { Text("All flags").tag("all"); Text("Indexed").tag("yes"); Text("Not indexed").tag("no") }.labelsHidden()
            }.controlSize(.small)
            Text("\(concepts.count) matching concepts").font(.caption).foregroundStyle(.secondary)
            if concepts.isEmpty { ContentUnavailableView("No matching concepts", systemImage: "magnifyingglass") }
            else {
                List(concepts, selection: $model.selectedConcept) { node in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.taxonomyLocalization?.label(node.name) ?? node.name).lineLimit(2)
                        HStack { Text("ID \(node.sceneID)"); Text(node.networkName); if !node.indexed { Text("Not indexed") } }.font(.caption2).foregroundStyle(.secondary)
                        Text(node.name).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }.padding(.vertical, 3).tag(node.id)
                }.listStyle(.inset)
            }
        }
    }
}

struct TaxonomyConceptInspector: View {
    @ObservedObject var model: ExplorerModel
    let taxonomy: SceneTaxonomy
    let node: SceneConcept
    private var label: String { model.taxonomyLocalization?.label(node.name) ?? node.name }
    private var comparison: SceneConcept? { model.comparisonTaxonomy?.nodes[node.name] }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Text(label).font(.title2.weight(.semibold)).textSelection(.enabled)
                Spacer()
                InfoButton(title: "Concept interpretation", text: "A category Photos can recognize. Browse its parent categories, subcategories, and associated detectors.")
            }
            Text(node.name).font(.caption.monospaced()).textSelection(.enabled)
            HStack(spacing: 18) { Text("Scene ID \(node.sceneID)"); Text("\(node.networkName) · \(node.networkID)"); Text("Indexed: \(node.indexed ? "Yes" : "No")") }.font(.caption)
            if node.isSyntheticRoot { Text("Generated cache root · excluded from the source concept count.").font(.caption).foregroundStyle(.secondary) }
            if node.networkID == 1 {
                Button("Show Geography Group on Map", systemImage: "map") { model.openGeographyScene(node.sceneID) }
                    .disabled(model.geography.atlas != nil && model.geography.atlas?.group(forSceneID: node.sceneID) == nil)
            }
            if let localization = model.taxonomyLocalization {
                if localization.locale != "en", localization.usesEnglishFallback(node.name), !node.isSyntheticRoot { Text("English label fallback").font(.caption).foregroundStyle(.secondary) }
                let aliases = localization.synonyms(node.name)
                if !aliases.isEmpty { Text("Synonyms: " + aliases.joined(separator: " · ")).font(.caption).textSelection(.enabled) }
                if let searchable = localization.searchable[node.name], searchable != node.indexed {
                    Label("Resource difference: indexed \(node.indexed ? "true" : "false") · EntityNet searchable \(searchable ? "true" : "false")", systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
                }
            } else { Text("Companion labels unavailable; exact internal names are shown.").font(.caption).foregroundStyle(.orange) }
            if let other = comparison {
                Text("\(model.comparisonTaxonomy!.source.title): ID \(other.sceneID) · indexed \(other.indexed ? "true" : "false")").font(.caption).foregroundStyle(.secondary)
            } else if let reference = model.comparisonTaxonomy, !node.isSyntheticRoot { Text("This concept is absent from \(reference.source.title).").font(.caption).foregroundStyle(.secondary) }
            relationships("Parents", names: node.parents)
            relationships("Children", names: node.children, collapsed: true)
            relationships("Detector targets", names: node.detectors)
            thresholdTable
            if let reference = model.comparisonTaxonomy, let other = comparison {
                if node.parents.filter({ $0 != "|_ROOT_|" }) != other.parents.filter({ $0 != "|_ROOT_|" }) || node.children != other.children || node.detectors != other.detectors {
                    DisclosureGroup("Relationships in \(reference.source.title)") {
                        VStack(alignment: .leading, spacing: 8) {
                            comparisonNames("Parents", names: other.parents)
                            comparisonNames("Children", names: other.children)
                            comparisonNames("Detectors", names: other.detectors)
                        }.padding(.top, 6)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func relationships(_ title: String, names: [String], collapsed: Bool = false) -> some View {
        if !names.isEmpty {
            if collapsed {
                DisclosureGroup("\(title) · \(names.count)") { relationButtons(names).padding(.top, 6) }
            } else { VStack(alignment: .leading, spacing: 7) { Text("\(title) · \(names.count)").font(.headline); relationButtons(names) } }
        }
    }
    private func relationButtons(_ names: [String]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(names, id: \.self) { name in
                Button { model.selectTaxonomyConcept(name) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.taxonomyLocalization?.label(name) ?? name).font(.caption).multilineTextAlignment(.leading)
                        if let target = taxonomy.nodes[name] { Text("ID \(target.sceneID)").font(.caption2).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.borderless).help(name)
            }
        }
    }
    private func comparisonNames(_ title: String, names: [String]) -> some View {
        Text(title + ": " + (names.isEmpty ? "None" : names.map { model.taxonomyLocalization?.label($0) ?? $0 }.joined(separator: " · "))).font(.caption).textSelection(.enabled)
    }
    private var thresholdTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Threshold reference").font(.headline); InfoButton(title: "Threshold semantics", text: "Score cutoffs used by the scene taxonomy.") }
            HStack { Text("Apple getter").frame(maxWidth: .infinity, alignment: .leading); Text("Selected source").frame(width: 155, alignment: .trailing); if comparison != nil { Text("Comparison").frame(width: 155, alignment: .trailing) } }.font(.caption).foregroundStyle(.secondary)
            ForEach(Array(SceneTaxonomyReader.thresholdKeys.enumerated()), id: \.element) { i, key in
                let current = node.thresholds[key], other = comparison?.thresholds[key], changed = other != nil && current != other
                HStack(alignment: .top) {
                    Text(SceneTaxonomyReader.thresholdLabels[i]).frame(maxWidth: .infinity, alignment: .leading)
                    Text(current.map { String($0) } ?? "Unavailable").fontWeight(changed ? .semibold : .regular).frame(width: 155, alignment: .trailing)
                    if comparison != nil { Text(other.map { String($0) } ?? "Unavailable").fontWeight(changed ? .semibold : .regular).frame(width: 155, alignment: .trailing) }
                }.font(.caption.monospaced()).textSelection(.enabled)
                Divider()
            }
        }
    }
}
