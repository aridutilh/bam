import Foundation

@main struct ExtensionLanguageDetectionTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func main() {
        do { print("Extension language detection: \(try run()) checks passed") }
        catch { fputs("FAIL: Extension language detection: \(error)\n", stderr); exit(1) }
    }
    static func run() throws -> Int {
        var checks = 0
        func expect(_ actual: String?, _ expected: String?, _ message: String) throws {
            guard actual == expected else { throw Failure(description: "\(message): expected \(expected ?? "nil"), got \(actual ?? "nil")") }
            checks += 1
        }
        let french = "Le petit chat dort tranquillement sur le canapé du salon pendant que la pluie tombe doucement dehors et que les enfants lisent leurs livres préférés."
        let german = "Die Kinder spielen am Nachmittag im großen Garten hinter dem Haus, während ihre Eltern in der Küche gemeinsam das Abendessen für die ganze Familie vorbereiten."
        let japanese = "今日は朝から雨が降っていたので、私たちは家の中で本を読んだり、お茶を飲んだりしながら、ゆっくりと静かな一日を過ごしました。明日は晴れるといいですね。"

        // Clear page text wins over a wrong or missing declaration, as Chrome's detector does.
        try expect(ExtensionLanguageDetection.language(declared: "en", text: french), "fr", "Text did not override a wrong declaration")
        try expect(ExtensionLanguageDetection.language(declared: "", text: german), "de", "Undeclared German page was not recognized")
        try expect(ExtensionLanguageDetection.language(declared: nil, text: japanese), "ja", "Japanese page was not recognized")
        // Too little text falls back to the declaration, then to `und`, never to the user's locale.
        try expect(ExtensionLanguageDetection.language(declared: "pt-br", text: "Olá"), "pt-BR", "Short page lost its declared language")
        try expect(ExtensionLanguageDetection.language(declared: nil, text: "OK"), "und", "Short undeclared page did not report und")
        try expect(ExtensionLanguageDetection.language(declared: nil, text: nil), "und", "Missing sample did not report und")
        try expect(ExtensionLanguageDetection.language(declared: "", text: String(repeating: "1234 ", count: 200)), "und", "Digits were treated as language")

        // Declarations are normalized to Chrome's language-region form and malformed ones ignored.
        try expect(ExtensionLanguageDetection.normalize("EN_us"), "en-US", "Underscore tag was not normalized")
        try expect(ExtensionLanguageDetection.normalize("zh-Hant-TW"), "zh-TW", "Script subtag leaked into the answer")
        try expect(ExtensionLanguageDetection.normalize("es-419"), "es-419", "Numeric region was dropped")
        try expect(ExtensionLanguageDetection.normalize("de, en"), "de", "Comma list did not use its first language")
        try expect(ExtensionLanguageDetection.normalize("sr-Latn"), "sr", "Script-only tag was not reduced to its language")
        for bad in ["", "  ", "x", "english", "e1", "en-", "und", "en-US-<script>", "fr-toolongsubtag"] {
            try expect(ExtensionLanguageDetection.normalize(bad), nil, "Malformed declaration \(bad.debugDescription) was accepted")
        }

        // The recognizer itself refuses low-information samples.
        try expect(ExtensionLanguageDetection.recognize(String(repeating: "a", count: 20)), nil, "Twenty letters were enough to recognize")
        try expect(ExtensionLanguageDetection.recognize(french), "fr", "French sample was not recognized directly")
        return checks
    }
}
