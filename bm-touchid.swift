// bm-touchid: keeps the master password in Keychain and gives it out only after Touch ID
// (or the login password as fallback).
//
//   bm-touchid set <service> <account> <ttl> <lock 0|1>  store the password from stdin
//   bm-touchid get <service> <account> [note]            print the password after Touch ID
//   bm-touchid --forget                                  drop the cached approval
//
// The Keychain item trusts only this binary, so `security find-generic-password -w`
// and other programs get a macOS dialog that asks for the login password.
//
// The Touch ID dialog names the program that asks, as the kernel sees it (see caller()).
// The caller's own note can only follow that.
//
// The item holds JSON {"password", "ttl", "lock", "key"}, so only someone who knows the
// master password can change the cache settings; the environment cannot. A cached
// approval lives for ttl seconds (0 = no cache) and ends early when the screen locks if
// lock is true. It is a state file "pid expiry hmac" plus a running holder process with
// that pid. The HMAC is keyed with "key", 32 random bytes made by `set` that only this
// helper can read, so the state file (readable by your programs) gives nothing to guess
// offline and a program cannot forge an approval. It covers the holder's start time, so
// a new process that gets the pid of a dead holder does not revive the approval.
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

// The kernel's record of a process: start time and state.
func procInfo(_ pid: pid_t) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
}

func startTime(_ info: proc_bsdinfo) -> String { "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)" }

// MARK: Keychain

func query(_ service: String, _ account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service,
     kSecAttrAccount as String: account]
}

func readItem(_ service: String, _ account: String) -> (password: String, ttl: Int, lock: Bool, key: Data?)? {
    var q = query(service, account)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
    if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let p = j["password"] as? String {
        // An item without a cache key never gets a cache.
        guard let k = (j["key"] as? String).flatMap({ Data(base64Encoded: $0) }), k.count == 32 else { return (p, 0, true, nil) }
        return (p, j["ttl"] as? Int ?? 0, j["lock"] as? Bool ?? true, k)
    }
    // An item from bm 1.1 holds the bare password: no cache.
    guard let p = String(data: data, encoding: .utf8) else { return nil }
    return (p, 0, true, nil)
}

func storeItem(_ service: String, _ account: String, _ password: String, _ ttl: Int, _ lock: Bool) {
    SecItemDelete(query(service, account) as CFDictionary)
    // nil path = this binary. The ACL lists no other application.
    var me: SecTrustedApplication?
    var access: SecAccess?
    guard SecTrustedApplicationCreateFromPath(nil, &me) == errSecSuccess, let me,
          SecAccessCreate("bm master password" as CFString, [me] as CFArray, &access) == errSecSuccess, let access
    else { fail("cannot create Keychain access rule", 5) }
    // A new key for every `set` also ends any approval made with the old one.
    var key = Data(count: 32)
    guard key.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess
    else { fail("cannot make a random key", 5) }
    var item = query(service, account)
    item[kSecValueData as String] = try! JSONSerialization.data(
        withJSONObject: ["password": password, "ttl": ttl, "lock": lock, "key": key.base64EncodedString()] as [String: Any])
    item[kSecAttrAccess as String] = access
    item[kSecAttrLabel as String] = "bm"
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { fail("cannot store in Keychain (\(status))", 5) }
}

// MARK: Cached approval

func message(_ pid: pid_t, _ start: String, _ expiry: Int) -> Data { Data("\(pid):\(start):\(expiry)".utf8) }

func mac(_ key: Data, _ pid: pid_t, _ start: String, _ expiry: Int) -> String {
    let code = HMAC<SHA256>.authenticationCode(for: message(pid, start, expiry), using: SymmetricKey(data: key))
    return code.map { String(format: "%02x", $0) }.joined()
}

func hexData(_ s: String) -> Data? {
    guard s.count == 64 else { return nil }
    var d = Data()
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
        d.append(b)
        i = j
    }
    return d
}

func readState() -> (pid: pid_t, expiry: Int, mac: String)? {
    guard let s = try? String(contentsOf: stateFile, encoding: .utf8) else { return nil }
    let f = s.split(separator: " ").map(String.init)
    guard f.count == 3, let pid = pid_t(f[0]), pid > 0, let exp = Int(f[1]) else { return nil }
    return (pid, exp, f[2].trimmingCharacters(in: .whitespacesAndNewlines))
}

func cacheValid(_ key: Data?, _ ttl: Int) -> Bool {
    // A stopped holder (SIGSTOP) would miss the screen lock, so it approves nothing.
    guard ttl > 0, let key, let st = readState(), kill(st.pid, 0) == 0, exePath(st.pid) == me,
          let info = procInfo(st.pid), info.pbi_status != 4 /* SSTOP */,
          Int(Date().timeIntervalSince1970) < st.expiry, let tag = hexData(st.mac) else { return false }
    // Constant time compare.
    return HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: message(st.pid, startTime(info), st.expiry),
                                                  using: SymmetricKey(data: key))
}

func startHolder(_ key: Data, _ ttl: Int, _ lock: Bool) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: me)
    // Anyone can start a holder with any arguments; without the HMAC it approves nothing.
    p.arguments = ["--hold", String(ttl), lock ? "1" : "0"]
    // Detach from our stdio, so `$(bm ...)` does not wait for the holder.
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil, let info = procInfo(p.processIdentifier) else { return }
    let expiry = Int(Date().timeIntervalSince1970) + ttl
    let dir = stateFile.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    FileManager.default.createFile(atPath: stateFile.path,
                                   contents: "\(p.processIdentifier) \(expiry) \(mac(key, p.processIdentifier, startTime(info), expiry))\n".data(using: .utf8),
                                   attributes: [.posixPermissions: 0o600])
}

func hold(_ seconds: Double, _ forgetOnLock: Bool) -> Never {
    signal(SIGHUP, SIG_IGN)
    func done() -> Never {
        if readState()?.pid == getpid() { try? FileManager.default.removeItem(at: stateFile) }
        exit(0)
    }
    // SIGTERM (bm lock) removes the state file too. It is handled on the run loop: a
    // plain signal handler cannot safely do file work.
    signal(SIGTERM, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    term.setEventHandler { done() }
    term.resume()
    if forgetOnLock {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in done() }
    }
    Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in done() }
    withExtendedLifetime(term) { RunLoop.main.run() }
    done()
}

// SIGTERM, then SIGKILL: a stopped holder (SIGSTOP) does not act on SIGTERM. The state
// file goes in any case.
func forget() {
    if let st = readState(), st.pid != getpid(), exePath(st.pid) == me, let info = procInfo(st.pid) {
        // Same start time: still that holder, not a new process with its pid.
        let alive = { procInfo(st.pid).map(startTime) == startTime(info) }
        kill(st.pid, SIGTERM)
        var n = 0
        while alive() && n < 20 { usleep(25_000); n += 1 }
        if alive() { kill(st.pid, SIGKILL) }
    }
    try? FileManager.default.removeItem(at: stateFile)
}

// MARK: Who asks

// argv of a process as the kernel keeps it (KERN_PROCARGS2: argc, exec path, argv, env).
func processArgs(_ pid: pid_t) -> [String]? {
    var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
    var argmax: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: Int(argmax))
    mib = [CTL_KERN, KERN_PROCARGS2, pid]
    size = buf.count
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
    let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
    var i = 4
    while i < size && buf[i] != 0 { i += 1 }  // exec path
    while i < size && buf[i] == 0 { i += 1 }  // padding
    var argv: [String] = []
    while argv.count < argc && i < size {
        let start = i
        while i < size && buf[i] != 0 { i += 1 }
        argv.append(String(decoding: buf[start..<i], as: UTF8.self))
        i += 1
    }
    return argv.count == argc ? argv : nil
}

// The parent process: its executable path from the kernel, and for a shell also its
// arguments, e.g. "bm (/bin/bash -p /usr/local/bin/bm pass sw1)" or "/opt/homebrew/bin/node".
// argv[0] is left out: any caller can set it.
func caller() -> String {
    let ppid = getppid()
    guard let exe = exePath(ppid) else { return "process \(ppid)" }
    var who = exe
    let shells: Set = ["sh", "bash", "zsh", "dash", "ksh", "fish"]
    if shells.contains(URL(fileURLWithPath: exe).lastPathComponent), let argv = processArgs(ppid), argv.count > 1 {
        let rest = argv.dropFirst()
        who = ([exe] + rest).joined(separator: " ")
        // The script name first, unless the shell runs a -c command.
        if !rest.contains("-c"), let script = rest.first(where: { !$0.hasPrefix("-") }) {
            who = "\(URL(fileURLWithPath: script).lastPathComponent) (\(who))"
        }
    }
    // The parent ended while we looked: its pid may belong to another process now.
    return getppid() == ppid ? who : "a process that has ended"
}

// Dialog text: control and format characters (newlines, bidi overrides) become "?",
// long text is cut.
func printable(_ s: String, _ max: Int) -> String {
    let q: Unicode.Scalar = "?"
    var out = String.UnicodeScalarView()
    for u in s.unicodeScalars {
        let cat = u.properties.generalCategory
        out.append(cat == .control || cat == .format ? q : u)
    }
    let t = String(out)
    return t.count > max ? String(t.prefix(max - 1)) + "…" : t
}

func reason(_ note: String?) -> String {
    var r = "unlock bookmarks for " + printable(caller(), 200)
    if let note, !note.isEmpty { r += ", note from it: " + printable(note, 60) }
    return r
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

let usage = "usage: bm-touchid set <service> <account> <ttl> <lock 0|1> | get <service> <account> [note] | --forget"

switch args.count > 1 ? args[1] : "" {
case "--hold" where args.count >= 4:
    hold(Double(args[2]) ?? 0, args[3] != "0")
case "--forget":
    forget()
case "set" where args.count >= 6:
    guard let ttl = Int(args[4]), (0...999_999_999).contains(ttl), args[5] == "0" || args[5] == "1" else { fail(usage, 64) }
    guard let password = readLine(strippingNewline: true), !password.isEmpty else { fail("no password on stdin", 1) }
    storeItem(args[2], args[3], password, ttl, args[5] == "1")
    forget()
case "get" where args.count >= 4:
    guard let item = readItem(args[2], args[3]) else { fail("no Keychain item", 4) }
    if !cacheValid(item.key, item.ttl) {
        // Tests set this to check the cache without a Touch ID dialog. It can only deny.
        if env["BM_TOUCHID_NONINTERACTIVE"] == "1" { exit(3) }
        guard touchID(reason(args.count > 4 ? args[4] : nil)) else { exit(1) }
        if item.ttl > 0, let key = item.key { startHolder(key, item.ttl, item.lock) }
    }
    print(item.password)
default:
    fail(usage, 64)
}
exit(0)
