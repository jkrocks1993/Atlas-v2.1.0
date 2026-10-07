import Foundation

struct AnalysisBundle {
    var exactHash: String?
    var image: ImageSignature?
    var video: VideoSignature?
    var pdf: PDFSignature?
    var text: TextSignature?
    var archive: ArchiveSignature?
    var audioKey: String?
    var failed: Bool
}

private struct CrossFormatBridge {
    var textHash: String?
    var textLength: Int
    var image: ImageSignature?
    var imageOnlyPDFPages: [ImageSignature]
}

enum DuplicateEngine {
    static func classify(
        files: inout [UUID: FileRecord],
        control: ScanControl,
        onProgress: (String) -> Void,
        onCategoryProgress: (FileCategory, Double) -> Void = { _, _ in },
        onCategoryFinished: (FileCategory, [UUID: FileRecord], [UUID: DuplicateGroup]) -> Void = { _, _, _ in }
    ) -> [UUID: DuplicateGroup] {
        // IMPORTANT: bundles are deliberately scoped to one category.  The old implementation
        // retained an AnalysisBundle for every scanned file simultaneously.  A large image/video
        // corpus could therefore keep a very large object graph alive for the entire scan.
        // Only the small cross-format bridge signatures survive category processing.
        var groups: [UUID: DuplicateGroup] = [:]
        var assigned = Set<UUID>()
        var exactBuckets: [String: [UUID]] = [:]
        var bridge: [UUID: CrossFormatBridge] = [:]
        var comparisonReady: [UUID: Bool] = [:]

        let categories = FileCategory.allCases
        let idsByCategory: [[UUID]] = categories.map { category in
            files.values.filter { $0.category == category }.map(\.id)
        }

        func attach(groupMembers: [UUID], category: FileCategory) {
            var existing = groupMembers.filter { files[$0] != nil }
            var inherited: [UUID] = []
            for mid in existing {
                if let gid = files[mid]?.groupID, let g = groups[gid] {
                    inherited.append(contentsOf: g.memberIDs)
                    groups.removeValue(forKey: gid)
                }
            }
            existing.append(contentsOf: inherited)
            let uniqueMembers = existing.uniqued()
            guard uniqueMembers.count >= 2 else { return }

            // User feedback is a hard local veto. Build groups only when every pair
            // inside the proposed group is still allowed. This is intentionally stricter
            // than a connected-component graph because A~C and B~C must not reintroduce
            // the explicitly rejected A-B relationship.
            var remaining = uniqueMembers
            while !remaining.isEmpty {
                let seed = remaining.removeFirst()
                var component: [UUID] = [seed]
                var deferred: [UUID] = []
                for candidate in remaining {
                    guard let candidateRecord = files[candidate] else { continue }
                    let compatible = component.allSatisfy { member in
                        guard let memberRecord = files[member] else { return false }
                        return !FeedbackStore.shared.isNotDuplicate(candidateRecord, memberRecord)
                    }
                    if compatible {
                        component.append(candidate)
                    } else {
                        deferred.append(candidate)
                    }
                }
                remaining = deferred
                guard component.count >= 2 else {
                    if var rec = files[component[0]] {
                        rec.comparisonStatus = .unique
                        rec.groupID = nil
                        rec.isBest = false
                        files[component[0]] = rec
                    }
                    continue
                }
                let best = pickBest(component, files: files)
                let gid = UUID()
                groups[gid] = DuplicateGroup(id: gid, category: category, memberIDs: component, bestID: best)
                for mid in component {
                    guard var rec = files[mid] else { continue }
                    rec.comparisonStatus = .duplicate
                    rec.groupID = gid
                    rec.isBest = (mid == best)
                    files[mid] = rec
                    assigned.insert(mid)
                }
            }
        }

        for (categoryIndex, category) in categories.enumerated() {
            if control.isStopped { break }
            onCategoryProgress(category, 0)
            onProgress("Starting \(category.displayName) comparison…")
            let categoryIDs = idsByCategory[categoryIndex]
            guard !categoryIDs.isEmpty else {
                onCategoryProgress(category, 1)
                onCategoryFinished(category, [:], [:])
                continue
            }
            var bundles: [UUID: AnalysisBundle] = [:]
            bundles.reserveCapacity(min(categoryIDs.count, 50_000))

            // Analyze one category at a time. Each individual analysis is wrapped in an
            // autorelease pool so ImageIO/PDFKit/AVFoundation temporary native objects are
            // returned promptly rather than accumulating until the entire scan finishes.
            for (analysisIndex, id) in categoryIDs.enumerated() {
                if control.isStopped { break }
                control.waitIfPaused()
                onCategoryProgress(category, 0.60 * Double(analysisIndex + 1) / Double(max(categoryIDs.count, 1)))
                guard let rec = files[id] else { continue }
                onProgress("Analyzing: \(rec.path)")
                autoreleasepool {
                    let bundle = analyze(rec)
                    bundles[id] = bundle
                    if var updated = files[id] {
                        updated.decodeFailed = bundle.failed
                        updated.contentFingerprint = bundle.exactHash
                        updated.perceptualSignature = perceptualKey(bundle)
                        updated.contentKind = ContentKindDetector.kind(url: updated.url, category: updated.category)
                        files[id] = updated
                        comparisonReady[id] = !bundle.failed && !insufficient(updated.category, bundle)
                    }
                    if let hash = bundle.exactHash {
                        exactBuckets[hash, default: []].append(id)
                    }

                    // Only retain signatures needed by the pre-existing cross-format rules.
                    // Everything else dies with this category's local bundle dictionary.
                    if category == .images || category == .pdfs || category == .word {
                        bridge[id] = crossFormatBundle(bundle, category: category)
                    }
                }
            }

            if control.isStopped {
                bundles.removeAll(keepingCapacity: false)
                break
            }

            // Preserve the existing category-specific comparison logic, but execute it while
            // this category is the only full AnalysisBundle set resident in memory.
            switch category {
            case .images:
                let remaining = categoryIDs.filter { !assigned.contains($0) }
                for cluster in classifyImages(remaining: remaining, files: files, bundles: bundles) {
                    attach(groupMembers: cluster, category: .images)
                }
            case .videos:
                var videoBuckets: [Int: [UUID]] = [:]
                for id in categoryIDs where !assigned.contains(id) {
                    guard let sig = bundles[id]?.video else { continue }
                    videoBuckets[Int((sig.duration * 2).rounded()), default: []].append(id)
                }
                for (_, bucket) in videoBuckets {
                    for cluster in pairwiseCluster(bucket, same: { a, b in
                        guard let sa = bundles[a]?.video, let sb = bundles[b]?.video else { return false }
                        return VideoAnalyzer.areDuplicates(sa, sb)
                    }) {
                        attach(groupMembers: cluster, category: .videos)
                    }
                }
            case .pdfs:
                var pdfText: [String: [UUID]] = [:]
                var pdfVisual: [UUID] = []
                for id in categoryIDs where !assigned.contains(id) {
                    guard let sig = bundles[id]?.pdf else { continue }
                    if let th = sig.textHash {
                        pdfText[th, default: []].append(id)
                    } else {
                        pdfVisual.append(id)
                    }
                }
                for (_, members) in pdfText where members.count >= 2 {
                    attach(groupMembers: members, category: .pdfs)
                }
                for cluster in pairwiseCluster(pdfVisual, same: { a, b in
                    guard let sa = bundles[a]?.pdf, let sb = bundles[b]?.pdf else { return false }
                    return PDFAnalyzer.areDuplicates(sa, sb)
                }) {
                    attach(groupMembers: cluster, category: .pdfs)
                }

                // Cross-link image-only PDFs with the already-processed image signatures.
                // This avoids retaining every PDF bundle until the entire scan finishes.
                let imageBridge = bridge
                for id in categoryIDs where !assigned.contains(id) {
                    guard let pdf = bundles[id]?.pdf, pdf.isImageOnly else { continue }
                    var match: [UUID] = [id]
                    let pages = pdf.imageSignatures
                    if !pages.isEmpty {
                        for (imageID, b) in imageBridge {
                            guard files[imageID]?.category == .images, let image = b.image else { continue }
                            if pages.contains(where: { ImageAnalyzer.areDuplicates($0, image) }) {
                                match.append(imageID)
                            }
                        }
                    }
                    if match.count >= 2 {
                        attach(groupMembers: match, category: .images)
                    }
                }
            case .word, .powerpoint, .excel:
                var textBuckets: [String: [UUID]] = [:]
                for id in categoryIDs where !assigned.contains(id) {
                    guard let sig = bundles[id]?.text else { continue }
                    textBuckets[sig.contentHash, default: []].append(id)
                }
                for (_, members) in textBuckets where members.count >= 2 {
                    attach(groupMembers: members, category: category)
                }
            case .zip, .rar:
                var man: [String: [UUID]] = [:]
                for id in categoryIDs where !assigned.contains(id) {
                    guard let sig = bundles[id]?.archive else { continue }
                    man[sig.manifestHash, default: []].append(id)
                }
                for (_, members) in man where members.count >= 2 {
                    attach(groupMembers: members, category: category)
                }
            case .audio:
                var audioBuckets: [String: [UUID]] = [:]
                for id in categoryIDs where !assigned.contains(id) {
                    guard let key = bundles[id]?.audioKey else { continue }
                    audioBuckets[key, default: []].append(id)
                }
                for (_, members) in audioBuckets where members.count >= 2 {
                    attach(groupMembers: members, category: .audio)
                }
            case .other, .unknown:
                break
            }

            // Publish this category immediately. The callback receives only this category's
            // FileRecords plus groups touching it; the large AnalysisBundle graph is still local.
            onCategoryProgress(category, 0.95)
            let categoryFiles = files.filter { $0.value.category == category }
            let categoryGroups = groups.filter { _, group in
                group.memberIDs.contains { files[$0]?.category == category }
            }
            onCategoryFinished(category, categoryFiles, categoryGroups)
            onCategoryProgress(category, 1.0)

            // The large per-category bundle graph is explicitly destroyed before the next
            // category starts. This is the key memory bound.
            bundles.removeAll(keepingCapacity: false)
            onProgress("Finished \(category.displayName) comparison")
        }

        // Exact groups are global, so an identical byte sequence can still be grouped across
        // category tabs exactly as before.
        for (_, members) in exactBuckets where members.count >= 2 {
            if control.isStopped { break }
            let category = files[members[0]]?.category ?? .other
            // Exact equality is normally authoritative, but an explicit user override
            // is stronger because the user may intentionally keep identical files.
            attach(groupMembers: members, category: category)
        }
        exactBuckets.removeAll(keepingCapacity: false)

        // A persistent NOT UNIQUE decision survives a future scan as a user-asserted
        // duplicate classification. It is represented as a singleton manual group until
        // another matching file is found; it is never silently paired with an unrelated file.
        for id in Array(files.keys) {
            guard !control.isStopped, let rec = files[id], FeedbackStore.shared.isForceDuplicate(rec) else { continue }
            if rec.groupID == nil {
                let gid = UUID()
                groups[gid] = DuplicateGroup(id: gid, category: rec.category, memberIDs: [id], bestID: id)
                var updated = rec
                updated.comparisonStatus = .duplicate
                updated.groupID = gid
                updated.isBest = true
                files[id] = updated
                assigned.insert(id)
            }
        }

        if !control.isStopped {
            // Existing cross-format Word ↔ PDF text rule. Only hashes are retained here.
            var docText: [String: [UUID]] = [:]
            for (id, b) in bridge {
                let cat = files[id]?.category
                guard cat == .pdfs || cat == .word else { continue }
                if let h = b.textHash, b.textLength > 0 {
                    docText[h, default: []].append(id)
                }
            }
            for (_, members) in docText where members.count >= 2 {
                attach(groupMembers: members, category: files[members[0]]?.category ?? .pdfs)
            }
            docText.removeAll(keepingCapacity: false)
        }
        bridge.removeAll(keepingCapacity: false)

        // Final status pass uses the one-bit readiness result captured during analysis.
        // No file is decoded or read again here.
        for id in Array(files.keys) {
            guard var rec = files[id], rec.comparisonStatus != .duplicate else { continue }
            if control.isStopped && rec.comparisonStatus == .pending {
                // STOP RELEASE MODE: the file has not been proven duplicate. It is surfaced in
                // Unique as a provisional result so the user can work with the released set.
                // This is intentionally different from a completed-scan uniqueness guarantee.
                rec.comparisonStatus = .unique
            } else {
                rec.comparisonStatus = (comparisonReady[id] == true) ? .unique : .uncompared
            }
            rec.isBest = false
            rec.groupID = nil
            files[id] = rec
        }
        comparisonReady.removeAll(keepingCapacity: false)

        return groups
    }

    // Keep only the small signatures needed by the existing cross-format rules.
    private static func crossFormatBundle(_ bundle: AnalysisBundle, category: FileCategory) -> CrossFormatBridge {
        switch category {
        case .images:
            return CrossFormatBridge(textHash: nil, textLength: 0, image: bundle.image, imageOnlyPDFPages: [])
        case .pdfs:
            if let pdf = bundle.pdf {
                return CrossFormatBridge(
                    textHash: pdf.textHash,
                    textLength: pdf.textLength,
                    image: nil,
                    imageOnlyPDFPages: pdf.isImageOnly ? pdf.imageSignatures : []
                )
            }
            return CrossFormatBridge(textHash: bundle.text?.contentHash, textLength: bundle.text?.length ?? 0, image: nil, imageOnlyPDFPages: [])
        case .word:
            return CrossFormatBridge(textHash: bundle.text?.contentHash, textLength: bundle.text?.length ?? 0, image: nil, imageOnlyPDFPages: [])
        default:
            return CrossFormatBridge(textHash: nil, textLength: 0, image: nil, imageOnlyPDFPages: [])
        }
    }

    static func classifyImages(
        remaining: [UUID],
        files: [UUID: FileRecord],
        bundles: [UUID: AnalysisBundle]
    ) -> [[UUID]] {
        var exactPix: [String: [UUID]] = [:]
        for id in remaining {
            guard let sig = bundles[id]?.image, let pix = sig.pixelIdentity else { continue }
            exactPix[pix, default: []].append(id)
        }
        var result: [[UUID]] = []
        var consumed = Set<UUID>()
        for members in exactPix.values where members.count >= 2 {
            result.append(members)
            consumed.formUnion(members)
        }
        var buckets: [UInt16: [UUID]] = [:]
        for id in remaining {
            guard let sig = bundles[id]?.image, !consumed.contains(id) else { continue }
            let key = UInt16(truncatingIfNeeded: sig.pHash >> 52)
            buckets[key, default: []].append(id)
        }
        for (_, bucket) in buckets {
            result.append(contentsOf: pairwiseCluster(bucket, same: { a, b in
                guard let sa = bundles[a]?.image, let sb = bundles[b]?.image,
                      let ra = files[a], let rb = files[b] else { return false }

                if FeedbackStore.shared.isNotDuplicate(ra, rb) { return false }

                if ImageAnalyzer.areDuplicates(sa, sb) {
                    let f = imageFeatures(sa, sb)
                    OfflinePairModel.shared.learn(phashDistance: f.0, dhashDistance: f.1, mad: f.2, visionScore: nil, label: true)
                    return true
                }

                // ML is intentionally restricted to perceptually plausible candidates.
                // It never turns an arbitrary pair of images into duplicates.
                let f = imageFeatures(sa, sb)
                guard f.0 <= 18, f.1 <= 18, f.2 <= 42 else { return false }
                let vision = OfflineMLVerifier.compare(ra.url, rb.url)
                let visionScore = vision?.probability
                let learned = OfflinePairModel.shared.probability(
                    phashDistance: f.0,
                    dhashDistance: f.1,
                    mad: f.2,
                    visionScore: visionScore
                )
                let accepted = (vision.map { OfflineMLVerifier.likelyDuplicate($0, minimumScore: 0.90) } ?? false)
                    || (learned >= 0.94 && (visionScore ?? 0) >= 0.78)
                if accepted {
                    OfflinePairModel.shared.learn(phashDistance: f.0, dhashDistance: f.1, mad: f.2, visionScore: visionScore, label: true)
                }
                return accepted
            }))
        }
        return result
    }

    private static func imageFeatures(_ a: ImageSignature, _ b: ImageSignature) -> (Int, Int, Double) {
        let ph = Hamming.distance(a.pHash, b.pHash)
        let dh = Hamming.distance(a.dHash, b.dHash)
        guard a.grid.count == b.grid.count, !a.grid.isEmpty else { return (ph, dh, 255) }
        var acc = 0
        for i in a.grid.indices { acc += abs(Int(a.grid[i]) - Int(b.grid[i])) }
        return (ph, dh, Double(acc) / Double(a.grid.count))
    }

    private static func analyze(_ rec: FileRecord) -> AnalysisBundle {
        autoreleasepool {
            var bundle = AnalysisBundle(failed: false)
            bundle.exactHash = ContentHashing.fullSHA256(url: rec.url, size: rec.size)
            switch rec.category {
            case .images:
                bundle.image = ImageAnalyzer.signature(url: rec.url)
                bundle.failed = bundle.image == nil
            case .videos:
                bundle.video = VideoAnalyzer.signature(url: rec.url)
                bundle.failed = bundle.video == nil && bundle.exactHash == nil
            case .pdfs:
                let ext = rec.ext
                if ext == "epub" {
                    bundle.text = OfficeAnalyzer.epubSignature(url: rec.url)
                    bundle.failed = bundle.text == nil && bundle.exactHash == nil
                } else if ["doc", "docx", "rtf", "pages"].contains(ext) {
                    bundle.text = OfficeAnalyzer.signature(url: rec.url, category: .word)
                    bundle.failed = bundle.text == nil && bundle.exactHash == nil
                } else {
                    bundle.pdf = PDFAnalyzer.signature(url: rec.url)
                    if let th = bundle.pdf?.textHash {
                        bundle.text = TextSignature(contentHash: th, length: bundle.pdf?.textLength ?? 0)
                    }
                    bundle.failed = bundle.pdf == nil
                }
            case .word, .powerpoint, .excel:
                bundle.text = OfficeAnalyzer.signature(url: rec.url, category: rec.category)
                bundle.failed = bundle.text == nil && bundle.exactHash == nil
            case .zip:
                bundle.archive = ArchiveAnalyzer.zipSignature(url: rec.url)
                bundle.failed = bundle.archive == nil && bundle.exactHash == nil
            case .rar:
                bundle.archive = ArchiveAnalyzer.rarSignature(url: rec.url)
                bundle.failed = bundle.archive == nil && bundle.exactHash == nil
            case .audio:
                bundle.audioKey = AudioAnalyzer.key(url: rec.url, size: rec.size)
                bundle.failed = bundle.audioKey == nil && bundle.exactHash == nil
            case .other, .unknown:
                bundle.failed = bundle.exactHash == nil
            }
            return bundle
        }
    }

    private static func insufficient(_ category: FileCategory, _ bundle: AnalysisBundle) -> Bool {
        switch category {
        case .images: return bundle.image == nil
        case .videos: return bundle.video == nil && bundle.exactHash == nil
        case .pdfs: return bundle.pdf == nil && bundle.text == nil
        case .word, .powerpoint, .excel: return bundle.text == nil && bundle.exactHash == nil
        case .zip, .rar: return bundle.archive == nil && bundle.exactHash == nil
        case .audio: return bundle.audioKey == nil && bundle.exactHash == nil
        case .other, .unknown: return bundle.exactHash == nil
        }
    }

    private static func perceptualKey(_ bundle: AnalysisBundle) -> String? {
        if let img = bundle.image { return String(img.pHash, radix: 16) }
        if let vid = bundle.video { return vid.frameHashes.map { String($0, radix: 16) }.joined(separator: "-") }
        if let pdf = bundle.pdf { return pdf.textHash ?? pdf.pageHashes.map { String($0, radix: 16) }.joined() }
        if let text = bundle.text { return text.contentHash }
        if let arch = bundle.archive { return arch.manifestHash }
        return bundle.exactHash
    }

    static func pickBest(_ ids: [UUID], files: [UUID: FileRecord]) -> UUID {
        let sorted = ids.compactMap { files[$0] }.sorted { a, b in
            if a.size != b.size { return a.size > b.size }
            let ac = a.created ?? .distantFuture
            let bc = b.created ?? .distantFuture
            if ac != bc { return ac < bc }
            if a.path.count != b.path.count { return a.path.count < b.path.count }
            return a.path < b.path
        }
        return sorted.first?.id ?? ids[0]
    }

    static func pairwiseCluster(_ ids: [UUID], same: (UUID, UUID) -> Bool) -> [[UUID]] {
        guard ids.count >= 2 else { return [] }
        let uniqueIDs = ids.uniqued()
        guard uniqueIDs.count >= 2 else { return [] }
        var parent: [UUID: UUID] = [:]
        parent.reserveCapacity(uniqueIDs.count)
        for id in uniqueIDs { parent[id] = id }
        func find(_ x: UUID) -> UUID {
            var cur = x
            while let p = parent[cur], p != cur { cur = p }
            return cur
        }
        func union(_ a: UUID, _ b: UUID) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        if uniqueIDs.count > 1 {
            for i in 0..<(uniqueIDs.count - 1) {
                for j in (i + 1)..<uniqueIDs.count {
                    if same(uniqueIDs[i], uniqueIDs[j]) { union(uniqueIDs[i], uniqueIDs[j]) }
                }
            }
        }
        var buckets: [UUID: [UUID]] = [:]
        for id in uniqueIDs { buckets[find(id), default: []].append(id) }
        return buckets.values.filter { $0.count >= 2 }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        seen.reserveCapacity(count)
        return filter { seen.insert($0).inserted }
    }
}
