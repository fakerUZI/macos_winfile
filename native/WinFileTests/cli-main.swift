// 命令行测试入口（由 run_native_tests.sh 使用）
import Foundation

@main
enum CLITestRunner {
    static func main() {
        NativeTestSuite.run()
        let failures = MainActor.assumeIsolated { TestReporter.shared.failures.count }
        exit(failures == 0 ? 0 : 1)
    }
}
