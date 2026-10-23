// bm-touchid: ask for Touch ID (or the login password as fallback). Exit 0 on success.
//
//   bm-touchid <reason>   succeed at once if a recent approval is still valid
//   bm-touchid --forget   drop the cached approval
//
// A cached approval is a "holder" process. It lives for BM_TOUCHID_TTL seconds
// (default 3600, 0 = no cache) and exits early when the screen locks if
// BM_TOUCHID_LOCK is not 0. The approval is valid while the holder runs.
import Foundation
import LocalAuthentication

let env = ProcessInfo.processInfo.environment
let ttl = Double(env["BM_TOUCHID_TTL"] ?? "") ?? 3600
let forgetOnLock = env["BM_TOUCHID_LOCK"] != "0"
let pidFile = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache/bm/touchid.pid")
let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path

func fail(_ msg: String, _ code: Int32) -> Never {
    FileHandle.standardError.write("bm-touchid: \(msg)\n".data(using: .utf8)!)
    exit(code)
}

// The holder pid, if that process is alive and is this same binary.
func holderPid() -> pid_t? {
    guard let s = try? String(contentsOf: pidFile, encoding: .utf8),
          let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)),
          kill(pid, 0) == 0 else { return nil }
    var buf = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0,
          URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path == me else { return nil }
    return pid
}

func hold() -> Never {
    signal(SIGHUP, SIG_IGN)
    try? FileManager.default.createDirectory(at: pidFile.deletingLastPathComponent(), withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    try? "\(getpid())".write(to: pidFile, atomically: true, encoding: .utf8)
    func done() -> Never {
        if holderPid() == getpid() { try? FileManager.default.removeItem(at: pidFile) }
        exit(0)
    }
    signal(SIGTERM) { _ in
        try? FileManager.default.removeItem(at: pidFile)
        exit(0)
    }
    if forgetOnLock {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in done() }
    }
    Timer.scheduledTimer(withTimeInterval: ttl, repeats: false) { _ in done() }
    RunLoop.main.run()
    done()
}

let args = CommandLine.arguments
if args.count > 1 && args[1] == "--hold" { hold() }
if args.count > 1 && args[1] == "--forget" {
    if let pid = holderPid() { kill(pid, SIGTERM) }
    exit(0)
}
if ttl > 0, holderPid() != nil { exit(0) }

let reason = args.count > 1 ? args[1] : "unlock"
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
guard ok else { exit(1) }

if ttl > 0 {
    // Start the holder detached from our stdio, so `$(bm ...)` does not wait for it.
    let p = Process()
    p.executableURL = URL(fileURLWithPath: me)
    p.arguments = ["--hold"]
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
}
exit(0)
