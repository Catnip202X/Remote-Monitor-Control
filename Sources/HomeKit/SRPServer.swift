//
//  SRPServer.swift
//  Remote Monitor Control
//
//  SRP-6a as HomeKit uses it for pair setup: the RFC 5054 3072-bit group,
//  generator 5, SHA-512, username "Pair-Setup", and the 8-digit setup code as the
//  password. A, B and S are padded to 384 bytes, as Apple's accessory kit does.
//

import BigInt
import Foundation

final class SRPServer {
    static let N = BigUInt(
        "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74" +
        "020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437" +
        "4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED" +
        "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05" +
        "98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB" +
        "9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B" +
        "E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718" +
        "3995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33" +
        "A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7" +
        "ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864" +
        "D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E2" +
        "08E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF",
        radix: 16)!
    static let g = BigUInt(5)
    static let length = 384
    static let username = "Pair-Setup"

    let salt: Data
    private let b: BigUInt
    private let v: BigUInt
    private let B: BigUInt
    private(set) var sessionKey: Data?

    init(password: String) {
        salt = HAPCrypto.random(16)
        let x = BigUInt(HAPCrypto.sha512(salt, HAPCrypto.sha512(Data("\(Self.username):\(password)".utf8))))
        v = Self.g.power(x, modulus: Self.N)
        b = BigUInt(HAPCrypto.random(32))
        let k = BigUInt(HAPCrypto.sha512(Self.pad(Self.N), Self.pad(Self.g)))
        B = (k * v + Self.g.power(b, modulus: Self.N)) % Self.N
    }

    /// B, 384 bytes.
    var publicKey: Data { Self.pad(B) }

    /// Checks the client's proof M1. Returns the server proof M2, or nil if the setup code was wrong.
    func verify(clientPublicKey: Data, clientProof: Data) -> Data? {
        let A = BigUInt(clientPublicKey)
        guard A % Self.N != 0 else { return nil }
        let aBytes = Self.pad(A)
        let bBytes = Self.pad(B)
        let u = BigUInt(HAPCrypto.sha512(aBytes, bBytes))
        let S = ((A * v.power(u, modulus: Self.N)) % Self.N).power(b, modulus: Self.N)
        let K = HAPCrypto.sha512(Self.pad(S))

        let hN = HAPCrypto.sha512(Self.N.serialize())
        let hg = HAPCrypto.sha512(Self.g.serialize())
        let hGroup = Data(zip(hN, hg).map { $0 ^ $1 })
        let hUser = HAPCrypto.sha512(Data(Self.username.utf8))
        let M1 = HAPCrypto.sha512(hGroup, hUser, salt, aBytes, bBytes, K)
        guard M1 == clientProof else { return nil }

        sessionKey = K
        return HAPCrypto.sha512(aBytes, M1, K)
    }

    static func pad(_ n: BigUInt) -> Data {
        let raw = n.serialize()
        if raw.count >= length { return raw }
        return Data(repeating: 0, count: length - raw.count) + raw
    }
}
