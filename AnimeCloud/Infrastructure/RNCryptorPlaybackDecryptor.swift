import Foundation

struct RNCryptorPlaybackDecryptor: Sendable {
    private let password: String

    init(password: String) { self.password = password }

    func decryptServerPayload(_ serverData: Data) throws -> Data {
        let encoded = String(decoding: serverData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
        guard let encrypted = Data(base64Encoded: encoded), encrypted.count > 66 else {
            throw CryptoError.invalidPayload
        }
        return try decrypt(encrypted)
    }

    private func decrypt(_ payload: Data) throws -> Data {
        let bytes = [UInt8](payload)
        guard bytes[0] == 3, bytes.count > 66 else { throw CryptoError.unsupportedVersion }

        let encryptionSalt = Data(bytes[2..<10])
        let hmacSalt = Data(bytes[10..<18])
        let iv = Data(bytes[18..<34])
        let authenticated = Data(bytes.dropLast(32))
        let suppliedHMAC = Data(bytes.suffix(32))
        let ciphertext = Data(bytes[34..<(bytes.count - 32)])

        let encryptionKey = try deriveKey(salt: encryptionSalt)
        let hmacKey = try deriveKey(salt: hmacSalt)
        let calculatedHMAC = hmacSHA256(key: hmacKey, data: authenticated)
        guard constantTimeEqual(suppliedHMAC, calculatedHMAC) else { throw CryptoError.hmacMismatch }

        let outputCapacity = ciphertext.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            ciphertext.withUnsafeBytes { cipherBytes in
                encryptionKey.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, kCCKeySizeAES256, ivBytes.baseAddress,
                            cipherBytes.baseAddress, ciphertext.count,
                            outputBytes.baseAddress, outputCapacity, &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.decryptionFailed(status) }
        output.removeSubrange(moved..<output.count)
        return output
    }

    private func deriveKey(salt: Data) throws -> Data {
        let keyLength = kCCKeySizeAES256
        var key = Data(count: keyLength)
        let passwordBytes = Array(password.utf8)
        let status = key.withUnsafeMutableBytes { keyBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordBytes.withUnsafeBytes { passwordBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuffer.bindMemory(to: Int8.self).baseAddress,
                        passwordBytes.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        10_000,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyLength
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.keyDerivationFailed(status) }
        return key
    }

    private func hmacSHA256(key: Data, data: Data) -> Data {
        var digest = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        digest.withUnsafeMutableBytes { digestBytes in
            key.withUnsafeBytes { keyBytes in
                data.withUnsafeBytes { dataBytes in
                    CCHmac(
                        CCHmacAlgorithm(kCCHmacAlgSHA256),
                        keyBytes.baseAddress,
                        key.count,
                        dataBytes.baseAddress,
                        data.count,
                        digestBytes.baseAddress
                    )
                }
            }
        }
        return digest
    }

    private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

enum CryptoError: LocalizedError {
    case invalidPayload, unsupportedVersion, hmacMismatch
    case keyDerivationFailed(Int32), decryptionFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidPayload: "The playback response was not valid encrypted data."
        case .unsupportedVersion: "The playback encryption version is unsupported."
        case .hmacMismatch: "The playback response failed its integrity check."
        case .keyDerivationFailed: "The playback key could not be derived."
        case .decryptionFailed: "The playback response could not be decrypted."
        }
    }
}
