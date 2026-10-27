import Foundation
import Compression
import CryptoKit
import Security

@main struct ExtensionPackageArchiveTests {
    static var checks = 0
    struct CheckFailure: Error, CustomStringConvertible { let description: String }
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CheckFailure(description: message) }
        checks += 1
    }

    static func main() {
        do {
            guard CommandLine.arguments.count == 2 else {
                throw CheckFailure(description: "Usage: archive-tests <scoped temporary directory>")
            }
            try run(in: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
            print("Extension package archive: \(checks) checks passed")
        } catch {
            fputs("FAIL: Extension package archive: \(error)\n", stderr)
            exit(1)
        }
    }

    // MARK: ZIP fixture builder

    struct ZipSpec {
        var name: String
        var data: Data = Data()
        var deflate = false
        var externalAttributes: UInt32 = 0
        var crcOverride: UInt32? = nil
        var uncompressedSizeOverride: UInt32? = nil
        var flags: UInt16 = 0
        var methodOverride: UInt16? = nil
    }

    static func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
    static func le32(_ value: UInt32) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)] }

    static func deflate(_ input: Data) -> Data {
        guard !input.isEmpty else { return Data([0x03, 0x00]) }
        let capacity = input.count + 1_024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        let written = input.withUnsafeBytes { raw in
            compression_encode_buffer(destination, capacity, raw.baseAddress!.assumingMemoryBound(to: UInt8.self), raw.count, nil, COMPRESSION_ZLIB)
        }
        precondition(written > 0, "deflate failed")
        return Data(bytes: destination, count: written)
    }

    static func buildZip(_ specs: [ZipSpec], zip64Marker: Bool = false, zip64Locator: Bool = false) -> Data {
        var body = Data()
        var central = Data()
        for spec in specs {
            let nameBytes = Array(spec.name.utf8)
            let payload = spec.deflate ? deflate(spec.data) : spec.data
            let method = spec.methodOverride ?? (spec.deflate ? 8 : 0)
            let crc = spec.crcOverride ?? ExtensionCRC32.checksum(spec.data)
            let uncompressed = spec.uncompressedSizeOverride ?? UInt32(spec.data.count)
            let offset = UInt32(body.count)
            body.append(contentsOf: le32(0x0403_4B50) + le16(20) + le16(Int(spec.flags)) + le16(Int(method)) + le16(0) + le16(0))
            body.append(contentsOf: le32(crc) + le32(UInt32(payload.count)) + le32(uncompressed) + le16(nameBytes.count) + le16(0))
            body.append(contentsOf: nameBytes)
            body.append(payload)
            central.append(contentsOf: le32(0x0201_4B50) + le16(0x031E) + le16(20) + le16(Int(spec.flags)) + le16(Int(method)) + le16(0) + le16(0))
            central.append(contentsOf: le32(crc) + le32(UInt32(payload.count)) + le32(uncompressed) + le16(nameBytes.count) + le16(0) + le16(0))
            central.append(contentsOf: le16(0) + le16(0) + le32(spec.externalAttributes) + le32(offset))
            central.append(contentsOf: nameBytes)
        }
        var archive = body
        archive.append(central)
        if zip64Locator { archive.append(contentsOf: le32(0x0706_4B50) + le32(0) + [UInt8](repeating: 0, count: 8) + le32(1)) }
        let count = zip64Marker ? 0xFFFF : specs.count
        archive.append(contentsOf: le32(0x0605_4B50) + le16(0) + le16(0) + le16(count) + le16(count))
        archive.append(contentsOf: le32(UInt32(central.count)) + le32(UInt32(body.count)) + le16(0))
        return archive
    }

    // MARK: CRX3 fixture builder

    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }

    static func field(_ number: UInt64, _ bytes: Data) -> Data {
        Data(varint(number << 3 | 2) + varint(UInt64(bytes.count))) + bytes
    }

    static func derLength(_ length: Int) -> [UInt8] {
        if length < 0x80 { return [UInt8(length)] }
        if length <= 0xFF { return [0x81, UInt8(length)] }
        return [0x82, UInt8(length >> 8), UInt8(length & 0xFF)]
    }

    /// Wraps a PKCS#1 RSAPublicKey in an X.509 SubjectPublicKeyInfo (what CRX3 proofs carry).
    static func spki(wrapping pkcs1: Data) -> Data {
        let algorithm: [UInt8] = [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]
        let bitString = [0x03] + derLength(pkcs1.count + 1) + [0x00] + [UInt8](pkcs1)
        let content = algorithm + bitString
        return Data([0x30] + derLength(content.count) + content)
    }

    struct TestKey {
        let privateKey: SecKey
        let spki: Data
        let pkcs1: Data
        var id: String { ExtensionPackageArchiveTests.expectedID(forSPKI: spki) }
        func sign(_ message: Data) throws -> Data {
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, &error) else {
                throw CheckFailure(description: "signing failed: \(String(describing: error?.takeRetainedValue()))")
            }
            return signature as Data
        }
    }

    static func makeKey() throws -> TestKey {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048, kSecAttrIsPermanent: false]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw CheckFailure(description: "key generation failed: \(String(describing: error?.takeRetainedValue()))")
        }
        return TestKey(privateKey: privateKey, spki: spki(wrapping: pkcs1), pkcs1: pkcs1)
    }

    /// Independent ID derivation: hex of SHA-256 prefix with 0-9a-f mapped to a-p.
    static func expectedID(forSPKI spki: Data) -> String {
        let hex = SHA256.hash(data: spki).prefix(16).map { String(format: "%02x", $0) }.joined()
        let alphabet = Array("abcdefghijklmnop")
        return String(hex.map { alphabet[Int(String($0), radix: 16)!] })
    }

    static func buildCRX(payload: Data, keys: [TestKey], crxID: Data? = nil, version: UInt32 = 3,
                         includeRSA: Bool = true, ecdsaDummy: Bool = false) throws -> Data {
        let id = crxID ?? Data(SHA256.hash(data: keys[0].spki).prefix(16))
        let signedData = field(1, id)
        var message = Data("CRX3 SignedData".utf8)
        message.append(0)
        message.append(contentsOf: le32(UInt32(signedData.count)))
        message.append(signedData)
        message.append(payload)
        var header = Data()
        if includeRSA {
            for key in keys { header.append(field(2, field(1, key.spki) + field(2, try key.sign(message)))) }
        }
        if ecdsaDummy { header.append(field(3, field(1, Data(repeating: 1, count: 91)) + field(2, Data(repeating: 2, count: 70)))) }
        header.append(field(10000, signedData))
        var crx = Data("Cr24".utf8)
        crx.append(contentsOf: le32(version) + le32(UInt32(header.count)))
        crx.append(header)
        crx.append(payload)
        return crx
    }

    // MARK: Suite

    static func run(in parent: URL) throws {
        let fm = FileManager.default
        let root = parent.appendingPathComponent("archive-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func reject(_ label: String, _ body: () throws -> Void, containing fragment: String? = nil) throws {
            do { try body() } catch {
                let text = "\(error)"
                try check(fragment == nil || text.contains(fragment!), "\(label): error mentions \(fragment ?? "") (got \(text))")
                return
            }
            throw CheckFailure(description: "\(label): expected a rejection")
        }

        try check(ExtensionCRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926, "CRC-32 matches the standard check value")
        try check(ExtensionCRC32.checksum(Data()) == 0, "CRC-32 of empty data is zero")
        try check(ExtensionPackageDigest.sha256(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                  "SHA-256 helper matches the known vector")
        let digestFile = root.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: digestFile)
        try check(try ExtensionPackageDigest.sha256(ofFileAt: digestFile) == ExtensionPackageDigest.sha256(Data("abc".utf8)), "File digest matches in-memory digest")

        let manifest = Data(#"{"manifest_version":3,"name":"Fixture","version":"1.0"}"#.utf8)
        let script = Data(String(repeating: "const café = '日本語';\n", count: 2_000).utf8)
        let valid = buildZip([
            ZipSpec(name: "manifest.json", data: manifest),
            ZipSpec(name: "background.js", data: script, deflate: true),
            ZipSpec(name: "lib/", externalAttributes: 0o040755 << 16),
            ZipSpec(name: "lib/util.js", data: Data("export const x = 1;".utf8), deflate: true, externalAttributes: 0o100644 << 16),
            ZipSpec(name: "_locales/en/messages.json", data: Data("{}".utf8), deflate: true),
            ZipSpec(name: "empty.txt", data: Data(), deflate: true)
        ])
        try check(ExtensionZipArchive.looksLikeZip(valid) && !ExtensionCrxPackage.looksLikeCRX(valid), "ZIP sniffing recognizes the local header")
        let archive = try ExtensionZipArchive(data: valid)
        try check(archive.entries.count == 6 && archive.packagePrefix == "", "Central directory lists every entry at the root")
        try check(try archive.contents(of: archive.entry(forPackagePath: "background.js")!) == script, "Deflate entries inflate to the original bytes")
        try check(try archive.contents(of: archive.entry(forPackagePath: "manifest.json")!) == manifest, "Stored entries return their bytes")
        let out = root.appendingPathComponent("valid", isDirectory: true)
        let extracted = try archive.extract(to: out)
        try check(extracted == out, "Extraction returns the destination as the package URL")
        try check(try Data(contentsOf: out.appendingPathComponent("background.js")) == script &&
                  Data(contentsOf: out.appendingPathComponent("lib/util.js")) == Data("export const x = 1;".utf8) &&
                  Data(contentsOf: out.appendingPathComponent("empty.txt")).isEmpty &&
                  Data(contentsOf: out.appendingPathComponent("_locales/en/messages.json")) == Data("{}".utf8),
                  "Extracted files match, including nested and empty entries")
        try reject("extract-into-existing", { _ = try archive.extract(to: out) }, containing: "overwrite")

        let wrapped = try ExtensionZipArchive(data: buildZip([
            ZipSpec(name: "pkg-1.0/"), ZipSpec(name: "pkg-1.0/manifest.json", data: manifest),
            ZipSpec(name: "pkg-1.0/src/a.js", data: Data("a".utf8), deflate: true)
        ]))
        try check(wrapped.packagePrefix == "pkg-1.0/", "A single wrapping folder is detected")
        let wrappedOut = root.appendingPathComponent("wrapped", isDirectory: true)
        try wrapped.extract(to: wrappedOut)
        try check(try Data(contentsOf: wrappedOut.appendingPathComponent("manifest.json")) == manifest &&
                  fm.fileExists(atPath: wrappedOut.appendingPathComponent("src/a.js").path) &&
                  !fm.fileExists(atPath: wrappedOut.appendingPathComponent("pkg-1.0").path),
                  "The wrapper folder is stripped so manifest.json sits at the root")

        try reject("no-manifest", { _ = try ExtensionZipArchive(data: buildZip([ZipSpec(name: "a.js", data: Data("a".utf8))])) }, containing: "manifest.json")
        try reject("two-top-folders", { _ = try ExtensionZipArchive(data: buildZip([
            ZipSpec(name: "one/manifest.json", data: manifest), ZipSpec(name: "two/b.js", data: Data("b".utf8))])) }, containing: "manifest.json")
        try reject("nested-manifest-only", { _ = try ExtensionZipArchive(data: buildZip([
            ZipSpec(name: "a/b/manifest.json", data: manifest)])) }, containing: "manifest.json")

        for (index, name) in ["../evil.js", "/abs.js", "a\\b.js", "lib/../x.js", "bad\u{01}name.js", "./x.js", "lib//x.js", "", "..", "x/../../y"].enumerated() {
            try reject("unsafe-name-\(index)", { _ = try ExtensionZipArchive(data: buildZip([
                ZipSpec(name: "manifest.json", data: manifest), ZipSpec(name: name, data: Data("x".utf8))])) }, containing: name.isEmpty ? "empty" : "unsafe")
        }
        try check(!fm.fileExists(atPath: root.appendingPathComponent("../evil.js").path), "No zip-slip file was written anywhere")

        try reject("symlink-mode", { _ = try ExtensionZipArchive(data: buildZip([
            ZipSpec(name: "manifest.json", data: manifest),
            ZipSpec(name: "link.js", data: Data("background.js".utf8), externalAttributes: 0o120777 << 16)])) }, containing: "symbolic link")
        try reject("fifo-mode", { _ = try ExtensionZipArchive(data: buildZip([
            ZipSpec(name: "manifest.json", data: manifest),
            ZipSpec(name: "pipe", externalAttributes: 0o010644 << 16)])) }, containing: "special")

        let badCRC = try ExtensionZipArchive(data: buildZip([
            ZipSpec(name: "manifest.json", data: manifest), ZipSpec(name: "bg.js", data: script, deflate: true, crcOverride: 0xDEAD_BEEF)]))
        try reject("crc-mismatch-read", { _ = try badCRC.contents(of: badCRC.entry(forPackagePath: "bg.js")!) }, containing: "CRC-32")
        let crcOut = root.appendingPathComponent("crc", isDirectory: true)
        try reject("crc-mismatch-extract", { try badCRC.extract(to: crcOut) }, containing: "CRC-32")
        try check(!fm.fileExists(atPath: crcOut.path), "A failed extraction removes the directory it created")

        try reject("declared-total-too-large", { _ = try ExtensionZipArchive(data: buildZip([
            ZipSpec(name: "manifest.json", data: manifest),
            ZipSpec(name: "big.bin", data: Data("x".utf8), deflate: true, uncompressedSizeOverride: 512 * 1_024 * 1_024 + 1)])) }, containing: "512 MiB")
        try reject("declared-manifest-too-large", { _ = try ExtensionZipArchive(data: buildZip([
            ZipSpec(name: "manifest.json", data: manifest, deflate: true, uncompressedSizeOverride: 1_048_577)])) }, containing: "1 MiB")
        let underDeclared = try ExtensionZipArchive(data: buildZip([
            ZipSpec(name: "manifest.json", data: manifest),
            ZipSpec(name: "bg.js", data: script, deflate: true, uncompressedSizeOverride: 10)]))
        try reject("inflates-beyond-declaration", { _ = try underDeclared.contents(of: underDeclared.entry(forPackagePath: "bg.js")!) }, containing: "beyond")
        let overDeclared = try ExtensionZipArchive(data: buildZip([
            ZipSpec(name: "manifest.json", data: manifest),
            ZipSpec(name: "bg.js", data: script, deflate: true, uncompressedSizeOverride: UInt32(script.count) + 5)]))
        try reject("inflates-short-of-declaration", { _ = try overDeclared.contents(of: overDeclared.entry(forPackagePath: "bg.js")!) }, containing: "size")
        try reject("stored-size-mismatch", { _ = try ExtensionZipArchive(data: buildZip([
            ZipSpec(name: "manifest.json", data: manifest, uncompressedSizeOverride: 5)])) }, containing: "inconsistent")
        try reject("corrupt-deflate", {
            let archive = try ExtensionZipArchive(data: buildZip([
                ZipSpec(name: "manifest.json", data: manifest),
                ZipSpec(name: "bg.js", data: Data(repeating: 0xFF, count: 40), methodOverride: 8)]))
            _ = try archive.contents(of: archive.entry(forPackagePath: "bg.js")!)
        })

        try reject("zip64-count", { _ = try ExtensionZipArchive(data: buildZip([ZipSpec(name: "manifest.json", data: manifest)], zip64Marker: true)) }, containing: "ZIP64")
        try reject("zip64-locator", { _ = try ExtensionZipArchive(data: buildZip([ZipSpec(name: "manifest.json", data: manifest)], zip64Locator: true)) }, containing: "ZIP64")
        try reject("encrypted", { _ = try ExtensionZipArchive(data: buildZip([ZipSpec(name: "manifest.json", data: manifest, flags: 0x0001)])) }, containing: "Encrypted")
        try reject("bzip2-method", { _ = try ExtensionZipArchive(data: buildZip([ZipSpec(name: "manifest.json", data: manifest, methodOverride: 12)])) }, containing: "method")
        try reject("not-a-zip", { _ = try ExtensionZipArchive(data: Data(repeating: 0x41, count: 100)) }, containing: "ZIP")
        try reject("duplicate-case-insensitive", { _ = try ExtensionZipArchive(data: buildZip([
            ZipSpec(name: "manifest.json", data: manifest), ZipSpec(name: "A.js", data: Data("1".utf8)), ZipSpec(name: "a.js", data: Data("2".utf8))])) }, containing: "duplicate")
        var many = [ZipSpec(name: "manifest.json", data: manifest)]
        for index in 0..<30_000 { many.append(ZipSpec(name: "f\(index)")) }
        try reject("too-many-entries", { _ = try ExtensionZipArchive(data: buildZip(many)) }, containing: "30000")
        try check(try ExtensionZipArchive(data: buildZip(Array(many.prefix(30_000)))).entries.count == 30_000, "Exactly 30,000 entries are accepted")

        // Existing symlinks inside the destination are never followed.
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let trap = root.appendingPathComponent("trap", isDirectory: true)
        try fm.createDirectory(at: trap, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: trap.appendingPathComponent("lib"), withDestinationURL: outside)
        let viaLink = try ExtensionZipArchive(data: buildZip([
            ZipSpec(name: "manifest.json", data: manifest), ZipSpec(name: "lib/payload.js", data: Data("p".utf8))]))
        try reject("destination-symlink-dir", { try viaLink.extract(to: trap) }, containing: "non-directory")
        try check(!fm.fileExists(atPath: outside.appendingPathComponent("payload.js").path), "Nothing is written through a destination symlink")
        let fileLinkTrap = root.appendingPathComponent("file-trap", isDirectory: true)
        try fm.createDirectory(at: fileLinkTrap, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target.txt")
        try Data("keep".utf8).write(to: target)
        try fm.createSymbolicLink(at: fileLinkTrap.appendingPathComponent("manifest.json"), withDestinationURL: target)
        try reject("destination-symlink-file", { try archive.extract(to: fileLinkTrap) }, containing: "overwrite")
        try check(try Data(contentsOf: target) == Data("keep".utf8), "A symlinked destination file is left untouched")
        let linkedDestination = root.appendingPathComponent("linked-destination")
        try fm.createSymbolicLink(at: linkedDestination, withDestinationURL: outside)
        try reject("symlinked-destination", { try archive.extract(to: linkedDestination) }, containing: "real directory")

        // CRX3
        let key = try makeKey()
        try check(ExtensionCrxPackage.unwrapSubjectPublicKeyInfo(key.spki) == key.pkcs1, "The DER unwrapper recovers the PKCS#1 key from SPKI")
        try check(ExtensionCrxPackage.importRSAPublicKey(key.spki) != nil, "The SPKI public key imports through Security")
        try check(ExtensionCrxPackage.extensionID(forPublicKey: key.spki) == key.id && key.id.count == 32 &&
                  key.id.allSatisfy { ("a"..."p").contains($0) }, "Extension IDs derive from the SPKI hash as a-p letters")
        let crx = try buildCRX(payload: valid, keys: [key])
        try check(ExtensionCrxPackage.looksLikeCRX(crx) && !ExtensionZipArchive.looksLikeZip(crx), "CRX sniffing recognizes the magic")
        let package = try ExtensionCrxPackage(data: crx)
        try check(package.payloadZIP == valid && package.rsaProofs.count == 1 && package.ecdsaProofs.isEmpty, "CRX3 header and payload parse")
        let verification = package.verify(expectedID: key.id)
        try check(verification.verified && verification.failure == nil && verification.extensionID == key.id &&
                  verification.declaredID == key.id && verification.rsaProofCount == 1 && verification.verifiedRSAProofCount == 1,
                  "A correctly signed CRX3 verifies with the derived ID")
        try check(package.verify().verified && package.verify(expectedID: key.id.uppercased()).verified, "Verification works without an expected ID and ignores ID case")
        let crxOut = root.appendingPathComponent("crx-package", isDirectory: true)
        try ExtensionZipArchive(data: package.payloadZIP).extract(to: crxOut)
        try check(try Data(contentsOf: crxOut.appendingPathComponent("manifest.json")) == manifest, "The CRX payload extracts as a ZIP package")

        var flipped = crx
        flipped[flipped.count - 30] ^= 0x01
        let flippedResult = try ExtensionCrxPackage(data: flipped).verify(expectedID: key.id)
        try check(!flippedResult.verified && flippedResult.failure?.contains("signature") == true && flippedResult.verifiedRSAProofCount == 0,
                  "A flipped payload byte fails signature verification")
        var flippedHeader = crx
        flippedHeader[20] ^= 0x01
        try check(!(try ExtensionCrxPackage(data: flippedHeader).verify().verified), "A corrupted header proof fails verification")

        let otherKey = try makeKey()
        let wrongID = try ExtensionCrxPackage(data: buildCRX(payload: valid, keys: [key], crxID: Data(SHA256.hash(data: otherKey.spki).prefix(16)))).verify()
        try check(!wrongID.verified && wrongID.failure?.contains("declared ID") == true && wrongID.extensionID == otherKey.id,
                  "A crx_id that no proof key derives is rejected")
        let mismatch = package.verify(expectedID: otherKey.id)
        try check(!mismatch.verified && mismatch.failure?.contains("expected") == true && mismatch.extensionID == key.id,
                  "An expected store ID that differs from the signed ID is rejected")
        let noRSA = try ExtensionCrxPackage(data: buildCRX(payload: valid, keys: [key], includeRSA: false, ecdsaDummy: true))
        let noRSAResult = noRSA.verify()
        try check(!noRSAResult.verified && noRSAResult.failure?.contains("RSA") == true && noRSAResult.ecdsaProofCount == 1 && noRSAResult.rsaProofCount == 0,
                  "A package without an RSA proof never verifies, even with ECDSA proofs")
        try check(!(try ExtensionCrxPackage(data: buildCRX(payload: valid, keys: [key], crxID: Data(repeating: 7, count: 15))).verify().verified),
                  "A crx_id that is not 16 bytes is rejected")
        let twoKeys = try ExtensionCrxPackage(data: buildCRX(payload: valid, keys: [key, otherKey]))
        let twoResult = twoKeys.verify(expectedID: key.id)
        try check(twoResult.verified && twoResult.rsaProofCount == 2 && twoResult.verifiedRSAProofCount == 2 && twoResult.extensionID == key.id,
                  "Additional valid RSA proofs (store key) are accepted and counted")
        var stolenProof = try buildCRX(payload: valid, keys: [key, otherKey])
        stolenProof[stolenProof.count - 1] ^= 0x01
        try check(!(try ExtensionCrxPackage(data: stolenProof).verify().verified), "Every RSA proof must verify, not only the publisher's")
        try reject("crx2", { _ = try ExtensionCrxPackage(data: buildCRX(payload: valid, keys: [key], version: 2)) }, containing: "CRX3")
        try reject("crx-truncated-header", { _ = try ExtensionCrxPackage(data: Data("Cr24".utf8) + Data(le32(3) + le32(99_999)) + Data(repeating: 0, count: 10)) }, containing: "truncated")
        try reject("crx-not-crx", { _ = try ExtensionCrxPackage(data: valid) }, containing: "CRX")
        try reject("header-only-is-not-verification", {
            let headerless = try ExtensionCrxPackage(data: Data("Cr24".utf8) + Data(le32(3) + le32(0)) + valid)
            guard headerless.verify().verified else { throw ExtensionPackageError("unverified as required") }
        }, containing: "unverified")
    }
}
