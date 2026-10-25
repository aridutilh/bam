import Foundation
import NaturalLanguage

/// `tabs.detectLanguage`: the page's own text when it is long and clear enough to
/// recognize (as Chrome's detector prefers), else the language the document declares in
/// `<html lang>` or a `<meta http-equiv="content-language">` (not the HTTP response
/// header), else `und`. The user's interface language is never reported as the page's.
enum ExtensionLanguageDetection {
    static let undetermined = "und"
    static let sampleLength = 4000
    static let minimumLetters = 40
    static let minimumConfidence = 0.7
    /// Run in an isolated content world, so the page cannot redefine what Bam reads.
    static let sampleScript = """
    const meta = document.querySelector('meta[http-equiv="content-language" i]');
    return {url: location.href, declared: document.documentElement.lang || (meta && meta.content) || '',
            text: ((document.body && document.body.innerText) || '').slice(0, \(sampleLength))};
    """

    static func language(declared: String?, text: String?) -> String {
        if let text, let recognized = recognize(text) { return recognized }
        return normalize(declared) ?? undetermined
    }

    /// A BCP 47 tag from an attribute or header; a comma list uses its first entry.
    /// Chrome answers with a language and optional region, never a script or variant.
    static func normalize(_ declared: String?) -> String? {
        guard let first = declared?.split(separator: ",").first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !first.isEmpty, first.count <= 35 else { return nil }
        let subtags = first.replacingOccurrences(of: "_", with: "-").split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        func ascii(_ tag: String, _ allowed: (Character) -> Bool) -> Bool { tag.allSatisfy { $0.isASCII && allowed($0) } }
        guard let primary = subtags.first, (2...3).contains(primary.count), ascii(primary, \.isLetter),
              subtags.dropFirst().allSatisfy({ (1...8).contains($0.count) && ascii($0) { $0.isLetter || $0.isNumber } })
        else { return nil }
        let language = primary.lowercased()
        guard language != undetermined else { return nil }
        let region = subtags.dropFirst().first { ($0.count == 2 && ascii($0, \.isLetter)) || ($0.count == 3 && ascii($0, \.isNumber)) }
        return region.map { "\(language)-\($0.uppercased())" } ?? language
    }

    static func recognize(_ text: String) -> String? {
        let sample = String(text.prefix(sampleLength))
        guard sample.reduce(0, { $0 + ($1.isLetter ? 1 : 0) }) >= minimumLetters else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= minimumConfidence, language != .undetermined else { return nil }
        // Chrome names the two written forms of Chinese by region.
        switch language {
        case .simplifiedChinese: return "zh-CN"
        case .traditionalChinese: return "zh-TW"
        default: return language.rawValue
        }
    }
}
