// bm-touchid: ask for Touch ID (or the login password as fallback). Exit 0 on success.
import Foundation
import LocalAuthentication

let reason = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "unlock"
let context = LAContext()
var error: NSError?
guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
    FileHandle.standardError.write("bm-touchid: \(error?.localizedDescription ?? "not available")\n".data(using: .utf8)!)
    exit(2)
}
let done = DispatchSemaphore(value: 0)
var ok = false
context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
    ok = success
    done.signal()
}
done.wait()
exit(ok ? 0 : 1)
