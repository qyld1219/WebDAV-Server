import AppKit

let arguments = CommandLine.arguments

if arguments.contains("--selftest") {
    let code = MainActor.assumeIsolated { SelfTest.run() }
    exit(code)
}

// 主线程顶层代码，直接假定已在 MainActor 上
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
}
