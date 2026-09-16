import Foundation
import NaturalLanguage

/// The vetted texts bundled with the app. One Markdown file each, split into
/// passages at `##` headings.
nonisolated enum Guide: String, CaseIterable, Codable, Sendable {
    case firstAid = "first-aid"
    case roadside
    case outdoors

    var title: String {
        switch self {
        case .firstAid: "First aid"
        case .roadside: "Roadside"
        case .outdoors: "Outdoors"
        }
    }
}

/// One section of a guide: the unit of retrieval and the unit of citation.
nonisolated struct Passage: Identifiable, Hashable, Sendable {
    let guide: Guide
    let title: String
    let text: String

    var id: String { "\(guide.rawValue)/\(title)" }
}

nonisolated struct RetrievedPassage: Hashable, Sendable {
    let passage: Passage
    let score: Double
}

/// Retrieval over the bundled guides, so the safety personas answer from
/// reviewed text instead of a 1B model's memory.
///
/// Two signals are combined. BM25 over stemmed words does the heavy lifting: a
/// question about a "deep cut that will not stop bleeding" shares words with
/// the passage that answers it. Apple's on-device sentence embedding from the
/// NaturalLanguage framework adds meaning when the words differ, and needs no
/// download. If the embedding is unavailable, BM25 alone still works, which is
/// what the unit tests rely on. The corpus is under a hundred passages, so
/// everything is computed once at launch and searched by brute force.
nonisolated final class GuideLibrary: Sendable {
    let passages: [Passage]

    private struct Document {
        let termFrequency: [String: Int]
        let length: Int
    }

    private let documents: [Document]
    private let documentFrequency: [String: Int]
    private let averageLength: Double
    private let vectors: [[Double]?]

    init(passages: [Passage]) {
        self.passages = passages
        var documents: [Document] = []
        var documentFrequency: [String: Int] = [:]
        for passage in passages {
            // Heading words are the passage's own summary of itself, so they
            // count three times.
            let titleTerms = Self.terms(in: passage.title)
            let terms = titleTerms + titleTerms + titleTerms + Self.terms(in: passage.text)
            var frequency: [String: Int] = [:]
            for term in terms { frequency[term, default: 0] += 1 }
            for term in frequency.keys { documentFrequency[term, default: 0] += 1 }
            documents.append(Document(termFrequency: frequency, length: terms.count))
        }
        self.documents = documents
        self.documentFrequency = documentFrequency
        self.averageLength = documents.isEmpty ? 1 : Double(documents.map(\.length).reduce(0, +)) / Double(documents.count)
        let embedding = NLEmbedding.sentenceEmbedding(for: .english)
        self.vectors = passages.map { passage in
            embedding?.vector(for: passage.title + ". " + Self.firstSentence(of: passage.text))
        }
    }

    /// Load every guide from the bundle. Missing files are skipped, so a build
    /// without the guides still runs; the personas then answer ungrounded.
    convenience init(bundle: Bundle = .main) {
        var passages: [Passage] = []
        for guide in Guide.allCases {
            guard let url = bundle.url(forResource: guide.rawValue, withExtension: "md"),
                  let markdown = try? String(contentsOf: url, encoding: .utf8) else { continue }
            passages += Self.chunk(markdown, guide: guide)
        }
        self.init(passages: passages)
    }

    var isEmpty: Bool { passages.isEmpty }

    func passages(in guide: Guide) -> [Passage] {
        passages.filter { $0.guide == guide }
    }

    // MARK: Chunking

    /// Split at `##` headings. The `#` title line and anything before the first
    /// heading are dropped.
    static func chunk(_ markdown: String, guide: Guide) -> [Passage] {
        var result: [Passage] = []
        var title: String?
        var body: [String] = []
        func flush() {
            if let title {
                let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { result.append(Passage(guide: guide, title: title, text: text)) }
            }
            body.removeAll()
        }
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                flush()
                title = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("# ") {
                continue
            } else if title != nil {
                body.append(String(line))
            }
        }
        flush()
        return result
    }

    // MARK: Retrieval

    /// The best passages for a question within one guide, best first. Empty
    /// when nothing in the guide is relevant, which the caller should treat as
    /// "the guide does not cover this".
    func retrieve(_ query: String, in guide: Guide, limit: Int = 3) -> [RetrievedPassage] {
        let queryTerms = Self.terms(in: query)
        let indices = passages.indices.filter { passages[$0].guide == guide }
        guard !indices.isEmpty else { return [] }

        let lexical = indices.map { bm25(queryTerms, document: documents[$0]) }
        let maxLexical = lexical.max() ?? 0

        let embedding = NLEmbedding.sentenceEmbedding(for: .english)
        let queryVector = embedding?.vector(for: query)

        var scored: [RetrievedPassage] = []
        for (offset, index) in indices.enumerated() {
            let lexicalScore = maxLexical > 0 ? lexical[offset] / maxLexical : 0
            var semanticScore = 0.0
            if let queryVector, let vector = vectors[index] {
                semanticScore = max(0, Self.cosine(queryVector, vector))
            }
            let score = 0.7 * lexicalScore + 0.3 * semanticScore
            if score >= 0.15 {
                scored.append(RetrievedPassage(passage: passages[index], score: score))
            }
        }
        return Array(scored.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// The prompt the model actually sees for a grounded persona: the passages,
    /// then the question. The instruction to stay inside the passages is here
    /// rather than in the persona so it sits next to the text it refers to.
    static func groundedPrompt(question: String, passages: [RetrievedPassage]) -> String {
        guard !passages.isEmpty else { return question }
        var lines: [String] = []
        lines.append("Answer using only the guide passages below. If they do not cover the situation, say so and tell the person to call emergency services.")
        lines.append("")
        for retrieved in passages {
            lines.append("[Guide: \(retrieved.passage.title)]")
            lines.append(retrieved.passage.text)
            lines.append("")
        }
        lines.append("Question: \(question)")
        return lines.joined(separator: "\n")
    }

    // MARK: Scoring

    private func bm25(_ query: [String], document: Document) -> Double {
        // Passages are all a paragraph long, so length normalisation is kept
        // gentle; otherwise the shortest passage wins ties it should not.
        let k1 = 1.2
        let b = 0.4
        let total = Double(documents.count)
        var score = 0.0
        for term in Set(query) {
            guard let tf = document.termFrequency[term] else { continue }
            let df = Double(documentFrequency[term] ?? 0)
            let idf = log(1 + (total - df + 0.5) / (df + 0.5))
            let norm = Double(tf) * (k1 + 1) / (Double(tf) + k1 * (1 - b + b * Double(document.length) / averageLength))
            score += idf * norm
        }
        return score
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for index in a.indices {
            dot += a[index] * b[index]
            na += a[index] * a[index]
            nb += b[index] * b[index]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    private static func firstSentence(of text: String) -> String {
        if let end = text.firstIndex(where: { $0 == "." || $0 == "\n" }) {
            return String(text[..<end])
        }
        return String(text.prefix(200))
    }

    // MARK: Terms

    static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "of", "to", "in", "on", "at", "for", "with",
        "is", "are", "was", "were", "be", "been", "it", "its", "this", "that", "these", "those",
        "i", "me", "my", "we", "our", "you", "your", "he", "she", "they", "them", "his", "her",
        "do", "does", "did", "not", "no", "so", "as", "by", "from", "up", "down", "out", "into",
        "what", "when", "where", "how", "why", "which", "who", "can", "could", "should", "would",
        "will", "just", "now", "then", "than", "there", "here", "have", "has", "had", "am", "get",
    ]

    /// Lowercased words minus stopwords, lightly stemmed so "bleeding" meets
    /// "bleed" and "tyres" meets "tyre".
    static func terms(in text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 1 && !stopwords.contains($0) }
            .map(stem)
    }

    static func stem(_ word: String) -> String {
        var word = word
        if word.hasSuffix("ies"), word.count > 4 { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("sses") { return String(word.dropLast(2)) }
        if word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us"), word.count > 3 {
            word = String(word.dropLast())
        }
        if word.hasSuffix("ing"), word.count > 5 { word = String(word.dropLast(3)) }
        else if word.hasSuffix("ed"), word.count > 4 { word = String(word.dropLast(2)) }
        return word
    }
}
