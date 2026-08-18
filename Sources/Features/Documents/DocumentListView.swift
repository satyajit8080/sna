import QuickLook
import SwiftData
import SwiftUI

struct DocumentListView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \MedicalDocument.importedAt, order: .reverse) private var allDocuments: [MedicalDocument]

    @State private var isScanning = false
    @State private var selected: MedicalDocument?

    private var mine: [MedicalDocument] {
        allDocuments.filter { $0.profileID == app.activeProfile.id }
    }

    var body: some View {
        Group {
            if mine.isEmpty {
                EmptyStateView(
                    symbol: "doc.text.magnifyingglass",
                    title: "No documents",
                    message: "Scan a blood test or doctor's letter and BP Coach will pull out the values for you to check.",
                    actionTitle: "Scan a report",
                    action: { isScanning = true }
                )
            } else {
                ScrollView {
                    VStack(spacing: Theme.Spacing.sm) {
                        ForEach(mine) { document in
                            Button { selected = document } label: {
                                DocumentRow(document: document)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(Theme.Spacing.lg)
                }
            }
        }
        .background(Theme.background)
        .navigationTitle("Documents")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isScanning = true } label: { Image(systemName: "doc.viewfinder") }
                    .accessibilityLabel("Scan a document")
            }
        }
        .sheet(isPresented: $isScanning) { DocumentScanView(kind: .bloodTest) }
        .navigationDestination(item: $selected) { DocumentDetailView(document: $0) }
    }
}

struct DocumentRow: View {
    let document: MedicalDocument

    var body: some View {
        CardView(padding: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: document.kind.symbol)
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(document.title).font(.subheadline.weight(.medium)).lineLimit(2)
                    HStack(spacing: 4) {
                        Text(document.kind.label)
                        Text("·")
                        Text((document.documentDate ?? document.importedAt)
                            .formatted(date: .abbreviated, time: .omitted))
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)

                    if !document.values.isEmpty {
                        Text("\(document.values.count) value\(document.values.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                    }
                }

                Spacer()

                if !document.valuesNeedingReview.isEmpty {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.statusElevated)
                        .accessibilityLabel("Some values need checking")
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

struct DocumentDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let document: MedicalDocument

    @State private var isConfirmingDelete = false
    @State private var previewURL: URL?

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                CardView {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(document.title).font(.headline)
                        Text("\(document.kind.label) · imported \(document.importedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }

                if !document.values.isEmpty { valuesCard }

                if document.fileURL != nil {
                    Button {
                        previewURL = document.fileURL
                    } label: {
                        CardView {
                            HStack {
                                Label("View original", systemImage: "doc.richtext")
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }
                            .foregroundStyle(Theme.textPrimary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                if let text = document.recognisedText, !text.isEmpty {
                    CardView {
                        DisclosureGroup("Recognised text") {
                            Text(text)
                                .font(.caption.monospaced())
                                .foregroundStyle(Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, Theme.Spacing.sm)
                        }
                    }
                }

                Button("Delete document", role: .destructive) { isConfirmingDelete = true }
                    .padding(.top, Theme.Spacing.md)
            }
            .padding(Theme.Spacing.lg)
        }
        .background(Theme.background)
        .navigationTitle("Document")
        .navigationBarTitleDisplayMode(.inline)
        .quickLookPreview($previewURL)
        .confirmationDialog(
            "Delete this document?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { delete() }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The file is removed from this device too.")
        }
    }

    private var valuesCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                SectionHeader(
                    title: "Values",
                    subtitle: "Read automatically — check against the original"
                )
                ForEach(document.values) { value in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(value.name).font(.subheadline.weight(.medium))
                            Spacer()
                            Text("\(value.value) \(value.unit ?? "")")
                                .font(Theme.number(16, weight: .semibold))
                        }
                        HStack(spacing: 6) {
                            if let range = value.referenceRange {
                                Text("Range \(range)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            if let within = value.isWithinRange {
                                Text(within ? "In range" : "Outside range")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background((within ? Theme.statusNormal : Theme.statusElevated).opacity(0.15))
                                    .foregroundStyle(within ? Theme.statusNormal : Theme.statusElevated)
                                    .clipShape(Capsule())
                            }
                            if value.confidence.needsReview {
                                Text(value.confidence.label)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.statusElevated)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                Text("""
                BP Coach reads these values but does not interpret them. Your doctor \
                is the right person to explain what they mean for you.
                """)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, Theme.Spacing.xs)
            }
        }
    }

    private func delete() {
        if let fileName = document.fileName { DocumentStore.delete(fileName: fileName) }
        context.delete(document)
        try? context.save()
        dismiss()
    }
}
