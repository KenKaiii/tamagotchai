@testable import Tama
import Testing

@Suite("FileSystemToolHelpers")
struct FileSystemToolHelpersTests {
    @Test("resolvePath returns absolute path unchanged")
    func resolveAbsolutePath() {
        let result = FileSystemToolHelpers.resolvePath("/usr/bin/swift", workingDirectory: "/home/user")
        #expect(result == "/usr/bin/swift")
    }

    @Test("resolvePath joins relative path with working directory")
    func resolveRelativePath() {
        let result = FileSystemToolHelpers.resolvePath("src/main.swift", workingDirectory: "/home/user/project")
        #expect(result == "/home/user/project/src/main.swift")
    }

    @Test("resolvePath handles trailing slash on working directory")
    func resolvePathTrailingSlash() {
        let result = FileSystemToolHelpers.resolvePath("file.txt", workingDirectory: "/home/user")
        #expect(result == "/home/user/file.txt")
    }

    @Test("binaryExtensions contains key types")
    func binaryExtensionsContainsKeyTypes() {
        let expected = ["jpg", "zip", "exe", "sqlite", "png", "pdf", "mp3", "wasm"]
        for ext in expected {
            #expect(FileSystemToolHelpers.binaryExtensions.contains(ext), "Expected binaryExtensions to contain \(ext)")
        }
    }

    @Test("ignoredDirectories contains .git and node_modules")
    func ignoredDirectoriesContainsExpected() {
        #expect(FileSystemToolHelpers.ignoredDirectories.contains(".git"))
        #expect(FileSystemToolHelpers.ignoredDirectories.contains("node_modules"))
        #expect(FileSystemToolHelpers.ignoredDirectories.contains(".build"))
        #expect(FileSystemToolHelpers.ignoredDirectories.contains("DerivedData"))
    }
}
