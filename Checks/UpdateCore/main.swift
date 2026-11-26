import Foundation
import CryptoKit

var count = 0
func check(_ condition: Bool, _ name: String) {
    guard condition else { print("FAIL \(name)"); exit(1) }
    count += 1
}
func hex(_ s: String) -> Data {
    let bytes = Array(s.utf8)
    return Data(stride(from: 0, to: bytes.count, by: 2).map {
        UInt8(String(decoding: bytes[$0..<$0 + 2], as: UTF8.self), radix: 16)!
    })
}

// All five Ed25519 vectors, including the 1023-byte message and SHA(abc).
// Source: https://www.rfc-editor.org/rfc/rfc8032#section-7.1
let vectors: [(String, String, String, String, String)] = [
    ("TEST 1", "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
     "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
     "",
     "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46b" +
                "d25bf5f0595bbe24655141438e7a100b"),
    ("TEST 2", "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
     "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
     "72",
     "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c" +
                "387b2eaeb4302aeeb00d291612bb0c00"),
    ("TEST 3", "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
     "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
     "af82",
     "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc659" +
                "4a7c15e9716ed28dc027beceea1ec40a"),
    ("TEST 1024", "f5e5767cf153319517630f226876b86c8160cc583bc013744c6bf255f5cc0ee5",
     "278117fc144c72340f67d0f2316e8386ceffbf2b2428c9c51fef7c597f1d426e",
     "08b8b2b733424243760fe426a4b54908632110a66c2f6591eabd3345e3e4eb98fa6e264bf09efe12ee50f8f54e9f77b1" +
                "e355f6c50544e23fb1433ddf73be84d879de7c0046dc4996d9e773f4bc9efe5738829adb26c81b37c93a1b270b20329d" +
                "658675fc6ea534e0810a4432826bf58c941efb65d57a338bbd2e26640f89ffbc1a858efcb8550ee3a5e1998bd177e93a" +
                "7363c344fe6b199ee5d02e82d522c4feba15452f80288a821a579116ec6dad2b3b310da903401aa62100ab5d1a36553e" +
                "06203b33890cc9b832f79ef80560ccb9a39ce767967ed628c6ad573cb116dbefefd75499da96bd68a8a97b928a8bbc10" +
                "3b6621fcde2beca1231d206be6cd9ec7aff6f6c94fcd7204ed3455c68c83f4a41da4af2b74ef5c53f1d8ac70bdcb7ed1" +
                "85ce81bd84359d44254d95629e9855a94a7c1958d1f8ada5d0532ed8a5aa3fb2d17ba70eb6248e594e1a2297acbbb39d" +
                "502f1a8c6eb6f1ce22b3de1a1f40cc24554119a831a9aad6079cad88425de6bde1a9187ebb6092cf67bf2b13fd65f270" +
                "88d78b7e883c8759d2c4f5c65adb7553878ad575f9fad878e80a0c9ba63bcbcc2732e69485bbc9c90bfbd62481d9089b" +
                "eccf80cfe2df16a2cf65bd92dd597b0707e0917af48bbb75fed413d238f5555a7a569d80c3414a8d0859dc65a46128ba" +
                "b27af87a71314f318c782b23ebfe808b82b0ce26401d2e22f04d83d1255dc51addd3b75a2b1ae0784504df543af8969b" +
                "e3ea7082ff7fc9888c144da2af58429ec96031dbcad3dad9af0dcbaaaf268cb8fcffead94f3c7ca495e056a9b47acdb7" +
                "51fb73e666c6c655ade8297297d07ad1ba5e43f1bca32301651339e22904cc8c42f58c30c04aafdb038dda0847dd988d" +
                "cda6f3bfd15c4b4c4525004aa06eeff8ca61783aacec57fb3d1f92b0fe2fd1a85f6724517b65e614ad6808d6f6ee34df" +
                "f7310fdc82aebfd904b01e1dc54b2927094b2db68d6f903b68401adebf5a7e08d78ff4ef5d63653a65040cf9bfd4aca7" +
                "984a74d37145986780fc0b16ac451649de6188a7dbdf191f64b5fc5e2ab47b57f7f7276cd419c17a3ca8e1b939ae49e4" +
                "88acba6b965610b5480109c8b17b80e1b7b750dfc7598d5d5011fd2dcc5600a32ef5b52a1ecc820e308aa342721aac09" +
                "43bf6686b64b2579376504ccc493d97e6aed3fb0f9cd71a43dd497f01f17c0e2cb3797aa2a2f256656168e6c496afc5f" +
                "b93246f6b1116398a346f1a641f3b041e989f7914f90cc2c7fff357876e506b50d334ba77c225bc307ba537152f3f161" +
                "0e4eafe595f6d9d90d11faa933a15ef1369546868a7f3a45a96768d40fd9d03412c091c6315cf4fde7cb68606937380d" +
                "b2eaaa707b4c4185c32eddcdd306705e4dc1ffc872eeee475a64dfac86aba41c0618983f8741c5ef68d3a101e8a3b8ca" +
                "c60c905c15fc910840b94c00a0b9d0",
     "0aab4c900501b3e24d7cdf4663326a3a87df5e4843b2cbdb67cbf6e460fec350aa5371b1508f9f4528ecea23c436d94b" +
                "5e8fcd4f681e30a6ac00a9704a188a03"),
    ("TEST SHA(abc)", "833fe62409237b9d62ec77587520911e9a759cec1d19755b7da901b96dca3d42",
     "ec172b93ad5e563bf4932c70e1245034c35467ef2efd4d64ebf819683467e2bf",
     "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd" +
                "454d4423643ce80e2a9ac94fa54ca49f",
     "dc2a4459e7369633a52b1bf277839a00201009a3efbf3ecb69bea2186c26b58909351fc9ac90b3ecfdfbc7c66431e030" +
                "3dca179c138ac17ad9bef1177331a704")
]
for (name, seed, pub, message, sig) in vectors {
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: hex(seed))
    check(key.publicKey.rawRepresentation == hex(pub), "\(name) public key")
    check(UpdateSignature.accepts(hex(sig), message: hex(message), publicKey: hex(pub)), "\(name) verify")
    var altered = hex(sig)
    altered[0] ^= 1
    check(!UpdateSignature.accepts(altered, message: hex(message), publicKey: hex(pub)), "\(name) flipped signature")
    check(!UpdateSignature.accepts(hex(sig), message: hex(message) + Data([0]), publicKey: hex(pub)), "\(name) modified")
}

let signedBytes = Data(#"""
 { "notesURL":null, "schema":1, "bundleId":"local.cala", "version":"1.10.0", "build":2,
   "commit":"0123456789abcdef0123456789abcdef01234567",
   "minimumSystemVersion":"14.0", "publishedAt":"2026-11-22T10:00:00Z",
   "dmg":{"size":100,"url":"https://github.com/MineiToshio/cala-taskbar/releases/download/v1.10.0/Cala.dmg",
          "sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"},
   "app":{"unpackedSize":500,"keychainHelperSHA256":"abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"},
   "notes":{"es":"¡Hola!","en":"Hello"} }
"""#.utf8)
let key = Curve25519.Signing.PrivateKey(), wrong = Curve25519.Signing.PrivateKey()
let pub = key.publicKey.rawRepresentation, other = wrong.publicKey.rawRepresentation
func envelope(_ data: Data, signing bytes: Data? = nil, prefix: Data = Data("cala-update-manifest-v1\n".utf8)) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "manifest": data.base64EncodedString(),
        "signature": key.signature(for: prefix + (bytes ?? data)).base64EncodedString()
    ])
}
let feed = try envelope(signedBytes)
let verified = try UpdateSignature.verify(feed: feed, publicKeys: [other, pub])
let m = verified.manifest
check(verified.bytes == signedBytes && m.build == 2 && m.notes["es"] == "¡Hola!", "exact bytes, recovery key, ISO date")
func rejects(_ data: Data, keys: [Data] = [pub]) -> Bool { (try? UpdateSignature.verify(feed: data, publicKeys: keys)) == nil }
check(m.commit == "0123456789abcdef0123456789abcdef01234567", "signed commit SHA")
var manifestObject = try JSONSerialization.jsonObject(with: signedBytes) as! [String: Any]
manifestObject.removeValue(forKey: "commit")
check(rejects(try envelope(JSONSerialization.data(withJSONObject: manifestObject))), "schema 1 requires commit")
manifestObject["commit"] = "0123456"
check(rejects(try envelope(JSONSerialization.data(withJSONObject: manifestObject))), "reject abbreviated commit")
manifestObject["commit"] = String(repeating: "a", count: 40)
check(rejects(try envelope(JSONSerialization.data(withJSONObject: manifestObject), signing: signedBytes)), "reject changed commit with old signature")
var flipped = signedBytes
flipped[flipped.startIndex] ^= 1
check(rejects(try envelope(flipped, signing: signedBytes)), "flipped byte")
check(rejects(try envelope(signedBytes, prefix: Data())), "no domain")
check(rejects(feed, keys: [other]) && rejects(feed, keys: []) && rejects(feed, keys: [other, other, pub]), "wrong, absent, third key")
check(rejects(Data(#"{"manifest":"_","signature":"!"}"#.utf8)), "bad base64")
check(rejects(Data(#"{"signature":""}"#.utf8)), "missing field")
let json = String(decoding: feed, as: UTF8.self)
for extra in [#""new":42,"#, #""signature":"abcd","#] {
    check(rejects(Data(("{" + extra + json.dropFirst()).utf8)), "extra or repeated field")
}
let padded = feed + Data(repeating: 32, count: UpdateFeed.limit - feed.count)
check(!rejects(padded) && rejects(padded + Data([32])), "64 KiB envelope boundary")
do {
    _ = try UpdateSignature.verify(feed: envelope(Data([0]), signing: signedBytes), publicKeys: [pub])
    check(false, "unsigned malformed manifest")
} catch UpdateSignature.Invalid.signature { check(true, "authenticate before parsing") }
check(rejects(try envelope(Data([0]))), "signed malformed manifest")
let running = AppVersion(version: "1.9.12", build: "123456")!
let os = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
func eval(_ manifest: UpdateManifest, current: AppVersion = running, highest: AppVersion? = nil,
          skipped: String? = nil, blocked: Set<String> = [], testURLs: Bool = false) -> UpdateEvaluation {
    UpdateRules.evaluate(manifest, running: current, bundleId: "local.cala", os: os, highestSeen: highest,
                         skipped: skipped, blocked: blocked, testURLs: testURLs)
}
func changed(_ edit: (inout UpdateManifest) -> Void) -> UpdateManifest { var copy = m; edit(&copy); return copy }
let candidate = AppVersion(version: m.version, build: "2")!
check(eval(m) == .available(m), "developer build outranked by marketing version")
check(eval(m, current: candidate) == .upToDate, "equal")
check(eval(m, current: AppVersion(version: m.version, build: "3")!) == .upToDate, "lower build")
check(eval(m, current: AppVersion(version: m.version, build: "1")!) == .available(m), "higher build")
check(eval(m, current: AppVersion(version: "2.0.0", build: "1")!) == .upToDate, "lower version")
check(eval(m, highest: candidate) == .available(m) && eval(m, highest: AppVersion(version: "1.11.0", build: "1")) == .upToDate, "freshness")
check(eval(m, skipped: m.version) == .skipped(m) && eval(m, skipped: "1.1.0") == .available(m), "skip")
check(eval(m, blocked: ["1.10.0+2"]) == .upToDate && eval(m, blocked: ["01.10.0+02"]) == .upToDate &&
      eval(m, blocked: ["1.10.0+1"]) == .available(m), "only blocked version+build")
let newerSchema = try UpdateSignature.verify(feed: envelope(Data(#"{"schema":2,"future":[]}"#.utf8)), publicKeys: [pub]).manifest
check(eval(newerSchema) == .manualInstall, "future schema")
check(eval(changed { $0.bundleId = "local.other" }) == .manualInstall, "foreign app")
for text in ["1", "1.0", "1.2.3.4", "1..3", "1.2.+3", "1.2.٣", "1.2.3beta", "99999999999999999999999.0.0"] {
    check(AppVersion(version: text, build: "1") == nil, "invalid version \(text)")
}
for build in ["", "-1", "+2", "3a", "999999999999999999999"] { check(AppVersion(version: "1.0.0", build: build) == nil, "bad build") }
check(eval(changed { $0.minimumSystemVersion = "14.0.1" }) == .needsNewerMacOS("14.0.1"), "newer OS required")
check(!AppVersion.supports(minimum: "14.bad", os: os), "malformed OS")
for url in ["http://github.com/MineiToshio/cala-taskbar/releases/download/a", "https://github.com.evil/a",
            "https://github.com@evil/a", "https://github.com/MineiToshio/cala-taskbar/releases/downloads/x",
            "http://127.0.0.1:8765/a"] {
    check(eval(changed { $0.dmg.url = URL(string: url)! }, testURLs: true) == .manualInstall, "release URL \(url)")
}
check(UpdateFeed.permitsRedirect(URL(string: "https://release-assets.githubusercontent.com/a")!, testURLs: false), "HTTPS redirect")
for url in ["file:///tmp/a", "http://example.com/a", "https://user@evil/a"] {
    check(!UpdateFeed.permitsRedirect(URL(string: url)!, testURLs: true), "disallowed redirect")
}
for size in [Int64(0), -1, UpdateRules.assetLimit+1] { check(eval(changed { $0.dmg.size = size }) == .manualInstall, "size limit") }
let boundary = changed { $0.dmg.size = UpdateRules.assetLimit; $0.notes["en"] = String(repeating: "é", count: 4096) }
check(eval(boundary) == .available(boundary), "size and notes boundary")
check(eval(changed { $0.notes["fr"] = String(repeating: "é", count: 4097) }) == .manualInstall, "UTF-8 note bytes")
check(eval(changed { $0.dmg.sha256 = String(repeating: "g", count: 64) }) == .manualInstall, "nonhex digest")
check(eval(changed { $0.app.keychainHelperSHA256 = "01" }) == .manualInstall, "short digest")
check(UpdateRules.requiredSpace(m) == UpdateRules.reserve + 1100 &&
      UpdateRules.requiredSpace(changed { $0.app.unpackedSize = .max }) == nil, "space formula and overflow")

func http(_ status: Int, _ headers: [String: String] = [:]) -> FeedFailure? {
    UpdateRules.classify(status: status, headers: headers, error: nil)
}
check(http(200) == nil && http(204) == nil, "HTTP success")
for code in [404, 401, 403, 500] { check(http(code) == .feedUnavailable, "HTTP \(code)") }
check(http(429) == .rateLimited(retryAfter: nil) && http(429, ["Retry-After":"90"]) == .rateLimited(retryAfter: 90), "429")
check(http(403, ["retry-after":"42"]) == .rateLimited(retryAfter: 42) &&
      http(403, ["x-ratelimit-remaining":"0"]) == .rateLimited(retryAfter: nil) &&
      http(403, ["X-RateLimit-Remaining":"3"]) == .feedUnavailable, "403 rate-limit headers")
check(UpdateRules.classify(status: 200, headers: [:], error: URLError(.timedOut)) == .offline, "transport error")
let now = Date()
func delay(_ last: Date?, _ failures: Int, _ retry: Double?, _ jitter: Double) -> Double {
    UpdateRules.nextCheck(now: now, lastAttempt: last, failures: failures, retryAfter: retry, jitter: jitter).timeIntervalSince(now)
}
check(delay(nil,0,nil,0) == 120 && delay(nil,0,nil,1) == 600, "launch jitter")
check(delay(now,0,nil,0) == 22*3600 && delay(now,0,nil,1) == 26*3600, "daily jitter")
check(delay(now.addingTimeInterval(-28*3600),0,nil,1) == 0, "overdue wake")
for (failure,hours) in [1:1, 2:2, 3:4, 5:16, 6:24, 100:24] { check(delay(now,failure,nil,0) == Double(hours*3600), "backoff") }
check(delay(now,2,100_000,0) == 100_000 && delay(now,2,3,0) == 7200, "Retry-After floor")
for location in [AppLocationKind.other, .translocated, .diskImage] {
    check(UpdateRules.installPath(location: location, bundleWritable: true, parentWritable: true) == .unsupported, "location")
}
for bundle in [true,false] { for parent in [true,false] {
    check(UpdateRules.installPath(location: .applications, bundleWritable: bundle, parentWritable: parent) ==
          (bundle && parent ? .ready : .needsAdmin), "write access")
} }
for excluded in 0...7 {
    let result = UpdateRules.autoInstall(enabled: excluded != 1, path: excluded == 2 ? .needsAdmin : .ready,
                                        idleSeconds: excluded == 3 ? 599 : 600, blockers: excluded == 4 ? 1 : 0,
                                        presenting: excluded == 5, skipped: excluded == 6, blocked: excluded == 7, idleThreshold: 600)
    check(result == (excluded == 0), "auto install predicate \(excluded)")
}
check(UpdateRules.mayCheckAutomatically(enabled: true, path: .ready) &&
      UpdateRules.mayCheckAutomatically(enabled: true, path: .needsAdmin) &&
      !UpdateRules.mayCheckAutomatically(enabled: false, path: .ready) &&
      !UpdateRules.mayCheckAutomatically(enabled: true, path: .unsupported), "automatic check eligibility")
for (last, allowed) in [(nil, true), (now.addingTimeInterval(-59), false), (now.addingTimeInterval(-60), true)] {
    check(UpdateRules.mayCheckManually(now: now, lastManualAttempt: last) == allowed, "manual check throttle")
}
let config = UpdateFeed.configuration(version: "1.2.3", background: true)
check(!config.httpShouldSetCookies && config.httpCookieStorage == nil && !config.allowsConstrainedNetworkAccess &&
      config.httpAdditionalHeaders?["User-Agent"] as? String == "Cala/1.2.3", "background network policy")
check(UpdateFeed.configuration(version: "1", background: false).allowsConstrainedNetworkAccess, "foreground network policy")
print("PASS \(count) update core checks")

