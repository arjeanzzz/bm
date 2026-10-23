// bm-touchid: keeps the master password in Keychain and gives it out only after Touch ID
// (or the login password as fallback).
//
//   bm-touchid set <service> <account> <ttl> <lock 0|1>  store the password from stdin
//   bm-touchid get <service> <account> [reason]          print the password after Touch ID
//   bm-touchid --forget                                  drop the cached approval
//
// The Keychain item trusts only this binary, so `security find-generic-password -w`
// and other programs get a macOS dialog that asks for the login password.
//
// The item holds JSON {"password", "ttl", "lock"}, so only someone who knows the master
// password can change the cache settings; the environment cannot. A cached approval
// lives for ttl seconds (0 = no cache) and ends early when the screen locks if lock is
// true. It is a state file "pid expiry hmac" plus a running holder process with that pid.
// The HMAC is keyed with the master password, so a program without it cannot forge an
// approval.
import CryptoKit
import Foundation
import LocalAuthentication
import Security

let env = ProcessInfo.processInfo.environment
let stateFile = URL(fileURLWithPath: env["BM_TOUCHID_STATE"] ?? NSHomeDirectory() + "/.cache/bm/touchid.state")
let args = CommandLine.arguments

func fail(_ msg: String, _ code: Int32) -> Never {
    FileHandle.standardError.write("bm-touchid: \(msg)\n".data(using: .utf8)!)
    exit(code)
}

func exePath(_ pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
    return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path
}
let me = exePath(getpid())!

// MARK: Keychain

func query(_ service: String, _ account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service,
     kSecAttrAccount as String: account]
}

func readItem(_ service: String, _ account: String) -> (password: String, ttl: Int, lock: Bool)? {
    var q = query(service, account)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
    if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let p = j["password"] as? String {
        return (p, j["ttl"] as? Int ?? 0, j["lock"] as? Bool ?? true)
    }
    // An item from bm 1.1 holds the bare password: no cache.
    return String(data: data, encoding: .utf8).map { ($0, 0, true) }
}

func storeItem(_ service: String, _ account: String, _ password: String, _ ttl: Int, _ lock: Bool) {
    SecItemDelete(query(service, account) as CFDictionary)
    // nil path = this binary. The ACL lists no other application.
    var me: SecTrustedApplication?
    var access: SecAccess?
    guard SecTrustedApplicationCreateFromPath(nil, &me) == errSecSuccess, let me,
          SecAccessCreate("bm master password" as CFString, [me] as CFArray, &access) == errSecSuccess, let access
    else { fail("cannot create Keychain access rule", 5) }
    var item = query(service, account)
    item[kSecValueData as String] = try! JSONSerialization.data(
        withJSONObject: ["password": password, "ttl": ttl, "lock": lock] as [String: Any])
    item[kSecAttrAccess as String] = access
    item[kSecAttrLabel as String] = "bm"
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { fail("cannot store in Keychain (\(status))", 5) }
}

// MARK: Cached approval

func mac(_ password: String, _ pid: pid_t, _ expiry: Int) -> String {
    let code = HMAC<SHA256>.authenticationCode(for: Data("\(pid):\(expiry)".utf8),
                                               using: SymmetricKey(data: Data(password.utf8)))
    return code.map { String(format: "%02x", $0) }.joined()
}

func readState() -> (pid: pid_t, expiry: Int, mac: String)? {
    guard let s = try? String(contentsOf: stateFile, encoding: .utf8) else { return nil }
    let f = s.split(separator: " ").map(String.init)
    guard f.count == 3, let pid = pid_t(f[0]), let exp = Int(f[1]) else { return nil }
    return (pid, exp, f[2].trimmingCharacters(in: .whitespacesAndNewlines))
}

func cacheValid(_ password: String, _ ttl: Int) -> Bool {
    guard ttl > 0, let st = readState(), kill(st.pid, 0) == 0, exePath(st.pid) == me,
          Int(Date().timeIntervalSince1970) < st.expiry else { return false }
    return st.mac == mac(password, st.pid, st.expiry)
}

func startHolder(_ password: String, _ ttl: Int, _ lock: Bool) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: me)
    // Anyone can start a holder with any arguments; without the HMAC it approves nothing.
    p.arguments = ["--hold", String(ttl), lock ? "1" : "0"]
    // Detach from our stdio, so `$(bm ...)` does not wait for the holder.
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return }
    let expiry = Int(Date().timeIntervalSince1970) + ttl
    let dir = stateFile.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    FileManager.default.createFile(atPath: stateFile.path,
                                   contents: "\(p.processIdentifier) \(expiry) \(mac(password, p.processIdentifier, expiry))\n".data(using: .utf8),
                                   attributes: [.posixPermissions: 0o600])
}

func hold(_ seconds: Double, _ forgetOnLock: Bool) -> Never {
    signal(SIGHUP, SIG_IGN)
    signal(SIGTERM) { _ in exit(0) }
    func done() -> Never {
        if readState()?.pid == getpid() { try? FileManager.default.removeItem(at: stateFile) }
        exit(0)
    }
    if forgetOnLock {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in done() }
    }
    Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in done() }
    RunLoop.main.run()
    done()
}

func forget() {
    if let st = readState(), exePath(st.pid) == me { kill(st.pid, SIGTERM) }
    try? FileManager.default.removeItem(at: stateFile)
}

func touchID(_ reason: String) -> Bool {
    let context = LAContext()
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
        fail(error?.localizedDescription ?? "not available", 2)
    }
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
        ok = success
        sem.signal()
    }
    sem.wait()
    return ok
}

// MARK: Main

let usage = "usage: bm-touchid set <service> <account> <ttl> <lock 0|1> | get <service> <account> [reason] | --forget"

switch args.count > 1 ? args[1] : "" {
case "--hold" where args.count >= 4:
    hold(Double(args[2]) ?? 0, args[3] != "0")
case "--forget":
    forget()
case "set" where args.count >= 6:
    guard let ttl = Int(args[4]), ttl >= 0, args[5] == "0" || args[5] == "1" else { fail(usage, 64) }
    guard let password = readLine(strippingNewline: true), !password.isEmpty else { fail("no password on stdin", 1) }
    storeItem(args[2], args[3], password, ttl, args[5] == "1")
    forget()
case "get" where args.count >= 4:
    guard let item = readItem(args[2], args[3]) else { fail("no Keychain item", 4) }
    if !cacheValid(item.password, item.ttl) {
        // Tests set this to check the cache without a Touch ID dialog. It can only deny.
        if env["BM_TOUCHID_NONINTERACTIVE"] == "1" { exit(3) }
        guard touchID(args.count > 4 ? args[4] : "unlock") else { exit(1) }
        if item.ttl > 0 { startHolder(item.password, item.ttl, item.lock) }
    }
    print(item.password)
default:
    fail(usage, 64)
}
exit(0)
