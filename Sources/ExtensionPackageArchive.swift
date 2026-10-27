import Foundation
import Compression
import CryptoKit
import Security

/// A failure from the package-archive or catalog layer with a user-presentable message.
struct ExtensionPackageError: Error, LocalizedError, CustomStringConvertible, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
    var description: String { message }
}

/// Whole-file and in-memory SHA-256 helpers (lowercase hex).
enum ExtensionPackageDigest {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Table-based CRC-32 (IEEE 802.3, as used by ZIP).
enum ExtensionCRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func update(_ crc: UInt32, with bytes: UnsafeRawBufferPointer) -> UInt32 {
        var value = ~crc
        for byte in bytes { value = table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8) }
        return ~value
    }

    static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { update(0, with: $0) }
    }
}

/// A dependency-free reader for the ZIP packages browser stores ship (XPI, CWS payloads,
/// plain ZIPs). Supports stored and deflate entries, verifies CRC-32 after decoding, and
/// extracts with strict path and size safety. Parsing validates every entry up front, so a
/// single hostile entry rejects the whole archive before anything is written.
struct ExtensionZipArchive: Sendable {
    struct Entry: Sendable, Equatable {
        let name: String
        let method: UInt16
        let flags: UInt16
        let crc32: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        let externalAttributes: UInt32
        /// Unix file type bits from the external attributes (0 when the creator did not record a mode).
        var unixFileType: UInt32 { (externalAttributes >> 16) & 0o170000 }
        var isDirectory: Bool { name.hasSuffix("/") || unixFileType == 0o040000 }
    }

    /// Wappalyzer 6.10 ships about 13,300 files (one icon per technology), so the cap sits well above that while staying
    /// below the classic ZIP limit of 65,535 entries.
    static let maximumEntries = 30_000
    /// Uncompressed bytes. Adblock Plus 4.x unpacks to about 330 MiB of bundled filter lists (a 77 MB download), so
    /// the cap is 512 MiB; the download itself stays capped at `maximumArchiveBytes`.
    static let maximumTotalBytes = 512 * 1_024 * 1_024
    static let maximumArchiveBytes = 128 * 1_024 * 1_024
    static let maximumManifestBytes = 1_048_576

    let data: Data
    let entries: [Entry]
    /// A single wrapping top-level folder that the store added around the package ("wrapper/"), or "".
    let packagePrefix: String

    static func looksLikeZip(_ data: Data) -> Bool {
        data.count >= 4 && data[data.startIndex] == 0x50 && data[data.startIndex + 1] == 0x4B &&
            data[data.startIndex + 2] == 0x03 && data[data.startIndex + 3] == 0x04
    }

    init(data input: Data) throws {
        let data = input.startIndex == 0 ? input : Data(input)
        self.data = data
        func u16(_ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
        }
        guard data.count >= 22 else { throw ExtensionPackageError("The package is not a ZIP archive.") }
        var eocd = -1
        var offset = data.count - 22
        let lowest = max(0, data.count - 22 - 65_535)
        while offset >= lowest {
            if data[offset] == 0x50, data[offset + 1] == 0x4B, data[offset + 2] == 0x05, data[offset + 3] == 0x06 { eocd = offset; break }
            offset -= 1
        }
        guard eocd >= 0 else { throw ExtensionPackageError("The package is not a ZIP archive (missing end-of-central-directory record).") }
        if eocd >= 20, u32(eocd - 20) == 0x0706_4B50 {
            throw ExtensionPackageError("ZIP64 archives are not supported.")
        }
        let diskNumber = u16(eocd + 4), directoryDisk = u16(eocd + 6)
        let entriesOnDisk = u16(eocd + 8), totalEntries = u16(eocd + 10)
        let directorySize = u32(eocd + 12), directoryOffset = u32(eocd + 16)
        guard totalEntries != 0xFFFF, directorySize != 0xFFFF_FFFF, directoryOffset != 0xFFFF_FFFF else {
            throw ExtensionPackageError("ZIP64 archives are not supported.")
        }
        guard diskNumber == 0, directoryDisk == 0, entriesOnDisk == totalEntries else {
            throw ExtensionPackageError("Multi-disk ZIP archives are not supported.")
        }
        guard totalEntries <= Self.maximumEntries else {
            throw ExtensionPackageError("The package has more than \(Self.maximumEntries) entries.")
        }
        guard Int(directoryOffset) + Int(directorySize) <= eocd else {
            throw ExtensionPackageError("The ZIP central directory is truncated.")
        }

        var entries: [Entry] = []
        entries.reserveCapacity(totalEntries)
        var cursor = Int(directoryOffset)
        let directoryEnd = Int(directoryOffset) + Int(directorySize)
        for _ in 0..<totalEntries {
            guard cursor + 46 <= directoryEnd, u32(cursor) == 0x0201_4B50 else {
                throw ExtensionPackageError("The ZIP central directory is corrupt.")
            }
            let flags = UInt16(u16(cursor + 8)), method = UInt16(u16(cursor + 10))
            let crc = u32(cursor + 16), compressed = u32(cursor + 20), uncompressed = u32(cursor + 24)
            let nameLength = u16(cursor + 28), extraLength = u16(cursor + 30), commentLength = u16(cursor + 32)
            let external = u32(cursor + 38), localOffset = u32(cursor + 42)
            let nameStart = cursor + 46
            let extraStart = nameStart + nameLength
            let next = extraStart + extraLength + commentLength
            guard next <= directoryEnd else { throw ExtensionPackageError("The ZIP central directory is corrupt.") }
            let nameBytes = data[nameStart..<extraStart]
            let name = String(data: nameBytes, encoding: .utf8) ?? String(data: nameBytes, encoding: .isoLatin1) ?? ""
            guard flags & 0x0001 == 0, flags & 0x0040 == 0, method != 99 else {
                throw ExtensionPackageError("Encrypted ZIP entries are not supported (\(name)).")
            }
            guard compressed != 0xFFFF_FFFF, uncompressed != 0xFFFF_FFFF, localOffset != 0xFFFF_FFFF,
                  !Self.extraFields(data, from: extraStart, length: extraLength).contains(0x0001) else {
                throw ExtensionPackageError("ZIP64 archives are not supported.")
            }
            guard method == 0 || method == 8 else {
                throw ExtensionPackageError("Unsupported ZIP compression method \(method) (\(name)).")
            }
            guard Int(localOffset) + 30 <= Int(directoryOffset), Int(localOffset) + 30 + Int(compressed) <= eocd else {
                throw ExtensionPackageError("A ZIP entry points outside the archive (\(name)).")
            }
            try Self.validateEntryName(name)
            let entry = Entry(name: name, method: method, flags: flags, crc32: crc, compressedSize: Int(compressed),
                              uncompressedSize: Int(uncompressed), localHeaderOffset: Int(localOffset), externalAttributes: external)
            let fileType = entry.unixFileType
            guard fileType == 0 || fileType == 0o100000 || fileType == 0o040000 else {
                throw ExtensionPackageError("The package contains a symbolic link or special file (\(name)).")
            }
            guard method != 0 || compressed == uncompressed else {
                throw ExtensionPackageError("A stored ZIP entry declares inconsistent sizes (\(name)).")
            }
            entries.append(entry)
            cursor = next
        }
        self.entries = entries

        let names = entries.map(\.name)
        if names.contains("manifest.json") {
            packagePrefix = ""
        } else {
            let tops = Set(names.map { String($0.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)[0]) })
            if tops.count == 1, let top = tops.first, !top.isEmpty, names.contains(top + "/manifest.json") {
                packagePrefix = top + "/"
            } else {
                throw ExtensionPackageError("The package has no manifest.json at its root.")
            }
        }
        var total = 0
        var seen = Set<String>()
        for entry in entries {
            let relative = packageRelativePath(for: entry)
            guard !relative.isEmpty else { continue }
            let key = relative.lowercased()
            guard seen.insert(key).inserted else {
                throw ExtensionPackageError("The package contains duplicate entries (\(entry.name)).")
            }
            total += entry.uncompressedSize
            guard total <= Self.maximumTotalBytes else {
                throw ExtensionPackageError("The package exceeds the 512 MiB uncompressed limit.")
            }
            if relative == "manifest.json", entry.uncompressedSize > Self.maximumManifestBytes {
                throw ExtensionPackageError("The extension manifest exceeds 1 MiB.")
            }
        }
    }

    /// The entry's path inside the package with any store wrapper folder removed; "" for the wrapper itself.
    func packageRelativePath(for entry: Entry) -> String {
        var name = entry.name
        if !packagePrefix.isEmpty, name.hasPrefix(packagePrefix) { name.removeFirst(packagePrefix.count) }
        if name.hasSuffix("/") { name.removeLast() }
        return name
    }

    func entry(forPackagePath path: String) -> Entry? {
        entries.first { !$0.isDirectory && packageRelativePath(for: $0) == path }
    }

    /// Decodes one entry, enforcing its declared size while inflating and verifying its CRC-32.
    func contents(of entry: Entry) throws -> Data {
        func u16(_ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 }
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, data[header] == 0x50, data[header + 1] == 0x4B, data[header + 2] == 0x03, data[header + 3] == 0x04 else {
            throw ExtensionPackageError("A ZIP local header is corrupt (\(entry.name)).")
        }
        let start = header + 30 + u16(header + 26) + u16(header + 28)
        guard start + entry.compressedSize <= data.count else {
            throw ExtensionPackageError("A ZIP entry is truncated (\(entry.name)).")
        }
        let compressed = data[start..<start + entry.compressedSize]
        let output: Data
        switch entry.method {
        case 0:
            guard compressed.count == entry.uncompressedSize else {
                throw ExtensionPackageError("A stored ZIP entry declares inconsistent sizes (\(entry.name)).")
            }
            output = Data(compressed)
        default:
            output = try Self.inflate(Data(compressed), expectedSize: entry.uncompressedSize, name: entry.name)
        }
        guard ExtensionCRC32.checksum(output) == entry.crc32 else {
            throw ExtensionPackageError("CRC-32 mismatch while extracting \(entry.name).")
        }
        return output
    }

    /// Extracts the package into `destination` (created as needed) and returns it. Any store
    /// wrapper folder is stripped so manifest.json lands at the destination root. Existing
    /// symbolic links in the destination are never followed; files are created exclusively.
    @discardableResult
    func extract(to destination: URL) throws -> URL {
        let fm = FileManager.default
        guard destination.isFileURL else { throw ExtensionPackageError("Extraction requires a local destination.") }
        let existedBefore = fm.fileExists(atPath: destination.path)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let destinationValues = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard destinationValues.isDirectory == true, destinationValues.isSymbolicLink != true else {
            throw ExtensionPackageError("The extraction destination must be a real directory.")
        }
        do {
            try writeEntries(into: destination)
        } catch {
            // A partial tree must never be mistaken for a package; remove what this call created.
            if !existedBefore { try? fm.removeItem(at: destination) }
            throw error
        }
        return destination
    }

    private func writeEntries(into destination: URL) throws {
        let fm = FileManager.default
        var total = 0
        for entry in entries {
            let relative = packageRelativePath(for: entry)
            guard !relative.isEmpty else { continue }
            let components = relative.split(separator: "/").map(String.init)
            var location = destination
            for (index, component) in components.enumerated() {
                location.appendPathComponent(component)
                let isLeafFile = index == components.count - 1 && !entry.isDirectory
                let existing = try? fm.attributesOfItem(atPath: location.path)[.type] as? FileAttributeType
                if isLeafFile {
                    guard existing == nil else { throw ExtensionPackageError("Extraction would overwrite an existing item (\(relative)).") }
                    let bytes = try contents(of: entry)
                    total += bytes.count
                    guard total <= Self.maximumTotalBytes else {
                        throw ExtensionPackageError("The package exceeds the 512 MiB uncompressed limit.")
                    }
                    if relative == "manifest.json", bytes.count > Self.maximumManifestBytes {
                        throw ExtensionPackageError("The extension manifest exceeds 1 MiB.")
                    }
                    try bytes.write(to: location, options: .withoutOverwriting)
                } else if let existing {
                    guard existing == .typeDirectory else {
                        throw ExtensionPackageError("Extraction refused to traverse a non-directory (\(relative)).")
                    }
                } else {
                    try fm.createDirectory(at: location, withIntermediateDirectories: false)
                }
            }
        }
    }

    private static func extraFields(_ data: Data, from start: Int, length: Int) -> Set<Int> {
        var ids = Set<Int>()
        var cursor = start
        let end = start + length
        while cursor + 4 <= end {
            let id = Int(data[cursor]) | Int(data[cursor + 1]) << 8
            let size = Int(data[cursor + 2]) | Int(data[cursor + 3]) << 8
            ids.insert(id)
            cursor += 4 + size
        }
        return ids
    }

    static func validateEntryName(_ name: String) throws {
        guard !name.isEmpty, name.utf8.count <= 4_096 else { throw ExtensionPackageError("The package contains an entry with an empty or overlong name.") }
        guard !name.hasPrefix("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw ExtensionPackageError("The package contains an entry with an unsafe path (\(name.debugDescription)).")
        }
        var components = name.split(separator: "/", omittingEmptySubsequences: false)
        if components.last == "" { components.removeLast() }
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ExtensionPackageError("The package contains an entry with an unsafe path (\(name.debugDescription)).")
        }
    }

    /// Raw-deflate decoding through the Compression framework (COMPRESSION_ZLIB is header-less
    /// DEFLATE, matching ZIP entries), bounded by the declared size as output is produced.
    static func inflate(_ input: Data, expectedSize: Int, name: String) throws -> Data {
        guard !input.isEmpty else {
            guard expectedSize == 0 else { throw ExtensionPackageError("A ZIP entry is truncated (\(name)).") }
            return Data()
        }
        var output = Data()
        output.reserveCapacity(expectedSize)
        let chunk = 64 * 1_024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ExtensionPackageError("The deflate decoder could not be initialized.")
        }
        defer { compression_stream_destroy(stream) }
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { throw ExtensionPackageError("A ZIP entry is truncated (\(name)).") }
            stream.pointee.src_ptr = base.assumingMemoryBound(to: UInt8.self)
            stream.pointee.src_size = raw.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.pointee.dst_size
                if produced > 0 {
                    guard output.count + produced <= expectedSize else {
                        throw ExtensionPackageError("A ZIP entry inflates beyond its declared size (\(name)).")
                    }
                    output.append(buffer, count: produced)
                }
                switch status {
                case COMPRESSION_STATUS_END:
                    return
                case COMPRESSION_STATUS_OK:
                    if produced == 0, stream.pointee.src_size == 0 {
                        throw ExtensionPackageError("A ZIP entry is truncated (\(name)).")
                    }
                default:
                    throw ExtensionPackageError("A ZIP entry contains corrupt deflate data (\(name)).")
                }
            }
        }
        guard output.count == expectedSize else {
            throw ExtensionPackageError("A ZIP entry's size does not match its declaration (\(name)).")
        }
        return output
    }
}

/// A minimal protobuf wire-format decoder: enough for `CrxFileHeader` without generated code.
struct ExtensionProtobufField: Sendable, Equatable {
    let number: Int
    let wireType: Int
    let varint: UInt64
    let bytes: Data

    static func decode(_ data: Data) throws -> [ExtensionProtobufField] {
        let bytes = [UInt8](data)
        var index = 0
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard index < bytes.count, shift < 64 else { throw ExtensionPackageError("The CRX header is corrupt.") }
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
        }
        var fields: [ExtensionProtobufField] = []
        while index < bytes.count {
            let tag = try varint()
            let number = Int(tag >> 3), wireType = Int(tag & 7)
            guard number > 0 else { throw ExtensionPackageError("The CRX header is corrupt.") }
            switch wireType {
            case 0:
                fields.append(ExtensionProtobufField(number: number, wireType: 0, varint: try varint(), bytes: Data()))
            case 1, 5:
                let width = wireType == 1 ? 8 : 4
                guard index + width <= bytes.count else { throw ExtensionPackageError("The CRX header is corrupt.") }
                fields.append(ExtensionProtobufField(number: number, wireType: wireType, varint: 0, bytes: Data(bytes[index..<index + width])))
                index += width
            case 2:
                let length = try varint()
                guard length <= UInt64(bytes.count - index) else { throw ExtensionPackageError("The CRX header is corrupt.") }
                fields.append(ExtensionProtobufField(number: number, wireType: 2, varint: 0, bytes: Data(bytes[index..<index + Int(length)])))
                index += Int(length)
            default:
                throw ExtensionPackageError("The CRX header uses an unsupported protobuf wire type.")
            }
        }
        return fields
    }
}

/// A CRX3 package: `Cr24`, version 3, a protobuf `CrxFileHeader`, then the ZIP payload.
/// Verification checks a publisher RSA proof over the signed header and the whole payload
/// and derives the extension ID from that proof's public key. Stripping the header alone
/// never counts as verification.
struct ExtensionCrxPackage: Sendable {
    struct Proof: Sendable, Equatable {
        let publicKey: Data
        let signature: Data
    }

    struct Verification: Sendable, Equatable {
        let verified: Bool
        /// The ID derived from the verified publisher key, or the declared `crx_id` when verification failed.
        let extensionID: String
        let declaredID: String?
        let rsaProofCount: Int
        let ecdsaProofCount: Int
        let verifiedRSAProofCount: Int
        /// Which check failed; nil when verified.
        let failure: String?
    }

    static let magic = Data([0x43, 0x72, 0x32, 0x34])
    static let maximumHeaderBytes = 1_048_576

    let headerData: Data
    let payloadZIP: Data
    let rsaProofs: [Proof]
    let ecdsaProofs: [Proof]
    let signedHeaderData: Data?
    let declaredCrxID: Data?

    static func looksLikeCRX(_ data: Data) -> Bool {
        data.count >= 4 && Data(data.prefix(4)) == magic
    }

    init(data input: Data) throws {
        let data = input.startIndex == 0 ? input : Data(input)
        func u32(_ offset: Int) -> Int {
            Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
        }
        guard data.count >= 12, Self.looksLikeCRX(data) else { throw ExtensionPackageError("The package is not a CRX file.") }
        let version = u32(4)
        guard version == 3 else { throw ExtensionPackageError("Only CRX3 packages are supported (found CRX version \(version)).") }
        let headerLength = u32(8)
        guard headerLength <= Self.maximumHeaderBytes, 12 + headerLength <= data.count else {
            throw ExtensionPackageError("The CRX header is truncated.")
        }
        headerData = Data(data[12..<12 + headerLength])
        payloadZIP = Data(data[(12 + headerLength)...])
        var rsa: [Proof] = [], ecdsa: [Proof] = []
        var signed: Data?, crxID: Data?
        for field in try ExtensionProtobufField.decode(headerData) where field.wireType == 2 {
            switch field.number {
            case 2, 3:
                var publicKey = Data(), signature = Data()
                for inner in try ExtensionProtobufField.decode(field.bytes) where inner.wireType == 2 {
                    if inner.number == 1 { publicKey = inner.bytes } else if inner.number == 2 { signature = inner.bytes }
                }
                if field.number == 2 { rsa.append(Proof(publicKey: publicKey, signature: signature)) }
                else { ecdsa.append(Proof(publicKey: publicKey, signature: signature)) }
            case 10000:
                signed = field.bytes
                for inner in try ExtensionProtobufField.decode(field.bytes) where inner.wireType == 2 && inner.number == 1 {
                    crxID = inner.bytes
                }
            default:
                continue
            }
        }
        rsaProofs = rsa
        ecdsaProofs = ecdsa
        signedHeaderData = signed
        declaredCrxID = crxID
    }

    /// Chrome's extension ID: the first 16 bytes of SHA-256 over the SPKI DER, each nibble as `a`–`p`.
    static func extensionID(forPublicKey spki: Data) -> String {
        extensionID(idBytes: Data(SHA256.hash(data: spki).prefix(16)))
    }

    static func extensionID(idBytes: Data) -> String {
        var result = ""
        for byte in idBytes {
            result.unicodeScalars.append(UnicodeScalar(UInt8(ascii: "a") + (byte >> 4)))
            result.unicodeScalars.append(UnicodeScalar(UInt8(ascii: "a") + (byte & 0x0F)))
        }
        return result
    }

    /// The bytes every proof signs: "CRX3 SignedData\0", little-endian length of the signed header, the signed header, the ZIP payload.
    func signedMessage() -> Data? {
        guard let signed = signedHeaderData else { return nil }
        var message = Data("CRX3 SignedData".utf8)
        message.append(0)
        let length = UInt32(signed.count)
        message.append(contentsOf: [UInt8(length & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 24 & 0xFF)])
        message.append(signed)
        message.append(payloadZIP)
        return message
    }

    /// Verifies the package. Every RSA proof must carry a valid PKCS#1 v1.5 SHA-256 signature
    /// (Chrome rejects any invalid proof), one RSA key must derive the declared `crx_id`, and
    /// that ID must equal `expectedID` when supplied. ECDSA proofs are counted but not required.
    func verify(expectedID: String? = nil) -> Verification {
        let declared = declaredCrxID.flatMap { $0.count == 16 ? Self.extensionID(idBytes: $0) : nil }
        func failure(_ message: String, verifiedCount: Int = 0) -> Verification {
            Verification(verified: false, extensionID: declared ?? "", declaredID: declared, rsaProofCount: rsaProofs.count,
                         ecdsaProofCount: ecdsaProofs.count, verifiedRSAProofCount: verifiedCount, failure: message)
        }
        guard !rsaProofs.isEmpty else { return failure("The package carries no RSA proof.") }
        guard let declared, let message = signedMessage() else {
            return failure("The package header lacks a 16-byte crx_id in its signed data.")
        }
        var publisherID: String?
        var verifiedCount = 0
        for proof in rsaProofs {
            guard let key = Self.importRSAPublicKey(proof.publicKey) else {
                return failure("An RSA public key in the package could not be read.", verifiedCount: verifiedCount)
            }
            var error: Unmanaged<CFError>?
            guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, proof.signature as CFData, &error) else {
                return failure("An RSA signature did not verify over the package contents.", verifiedCount: verifiedCount)
            }
            verifiedCount += 1
            let derived = Self.extensionID(forPublicKey: proof.publicKey)
            if derived == declared, publisherID == nil { publisherID = derived }
        }
        guard let publisherID else {
            return failure("No RSA proof's key derives the package's declared ID \(declared).", verifiedCount: verifiedCount)
        }
        if let expectedID, expectedID.lowercased() != publisherID {
            return failure("The package is signed for \(publisherID), not the expected \(expectedID.lowercased()).", verifiedCount: verifiedCount)
        }
        return Verification(verified: true, extensionID: publisherID, declaredID: declared, rsaProofCount: rsaProofs.count,
                            ecdsaProofCount: ecdsaProofs.count, verifiedRSAProofCount: verifiedCount, failure: nil)
    }

    /// Imports an SPKI DER public key; Security may want the inner PKCS#1 RSAPublicKey, so unwrap on rejection.
    static func importRSAPublicKey(_ spki: Data) -> SecKey? {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        if let key = SecKeyCreateWithData(spki as CFData, attributes as CFDictionary, nil) { return key }
        guard let pkcs1 = unwrapSubjectPublicKeyInfo(spki) else { return nil }
        return SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, nil)
    }

    /// Extracts the RSAPublicKey from `SEQUENCE { SEQUENCE { OID, NULL }, BIT STRING { 0x00, RSAPublicKey } }`.
    static func unwrapSubjectPublicKeyInfo(_ spki: Data) -> Data? {
        let bytes = [UInt8](spki)
        func element(at start: Int) -> (tag: UInt8, contentStart: Int, contentEnd: Int)? {
            guard start + 2 <= bytes.count else { return nil }
            let tag = bytes[start]
            var index = start + 1
            var length = Int(bytes[index])
            index += 1
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard count >= 1, count <= 4, index + count <= bytes.count else { return nil }
                length = 0
                for _ in 0..<count { length = length << 8 | Int(bytes[index]); index += 1 }
            }
            guard index + length <= bytes.count else { return nil }
            return (tag, index, index + length)
        }
        guard let outer = element(at: 0), outer.tag == 0x30,
              let algorithm = element(at: outer.contentStart), algorithm.tag == 0x30,
              let bitString = element(at: algorithm.contentEnd), bitString.tag == 0x03,
              bitString.contentEnd <= outer.contentEnd, bitString.contentEnd - bitString.contentStart >= 2,
              bytes[bitString.contentStart] == 0 else { return nil }
        return Data(bytes[(bitString.contentStart + 1)..<bitString.contentEnd])
    }
}
