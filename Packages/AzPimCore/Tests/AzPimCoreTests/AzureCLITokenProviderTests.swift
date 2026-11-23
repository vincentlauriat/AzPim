import Foundation
import Testing

#if os(macOS) // Process (Azure CLI) is macOS-only.
@testable import AzPimCore

/// Fake runner returning canned outputs and recording calls.
final class FakeRunner: ProcessRunning, @unchecked Sendable {
    var outputs: [ProcessOutput]
    private(set) var calls: [[String]] = []

    init(_ outputs: [ProcessOutput]) { self.outputs = outputs }

    func run(_ executable: URL, arguments: [String], environment: [String: String], timeout: Duration) async throws -> ProcessOutput {
        calls.append(arguments)
        return outputs.isEmpty ? ProcessOutput(status: 1, stdout: "", stderr: "no more outputs") : outputs.removeFirst()
    }
}

struct AzureCLITokenProviderTests {
    /// A stub executable named `az` (the runner is faked anyway): a real path must be named `az`, and not depend
    /// on the Azure CLI being installed on the machine running the tests (CI).
    static let sharedAZ: String = {
        let dir = FileManager.default.temporaryDirectory.appending(path: "azpim-stub-\(UUID().uuidString)")
        let binary = dir.appending(path: "az")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data("#!/bin/sh\n".utf8).write(to: binary)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return binary.path
    }()
    let fakeAZ = AzureCLITokenProviderTests.sharedAZ

    /// Executable named `az` in a fresh folder with the given permissions.
    private func makeAZ(folderMode: Int) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appending(path: "azpim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binary = dir.appending(path: "az")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try FileManager.default.setAttributes([.posixPermissions: folderMode], ofItemAtPath: dir.path)
        return binary.path
    }

    @Test func locatesConfiguredPathFirst() throws {
        let path = try makeAZ(folderMode: 0o755)
        let provider = AzureCLITokenProvider(configuredPath: path, runner: FakeRunner([]))
        #expect(provider.locateCLI()?.path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
    }

    /// A file directly in a root-owned sticky folder (/tmp-like) is refused; a group-writable non-admin folder too.
    @Test func trustChainRules() throws {
        let fileManager = FileManager.default
        #expect(!Validation.isTrustedChain(URL(fileURLWithPath: "/private/tmp/az"), fileManager: fileManager)
            || !fileManager.fileExists(atPath: "/private/tmp/az"))
        #expect(Validation.isTrustedChain(URL(fileURLWithPath: "/bin/sh"), fileManager: fileManager))
        let path = try makeAZ(folderMode: 0o775)
        let gid = (try fileManager.attributesOfItem(atPath: (path as NSString).deletingLastPathComponent)[.groupOwnerAccountID]
            as? NSNumber)?.uint32Value ?? 0
        #expect(Validation.isTrustedChain(URL(fileURLWithPath: path), fileManager: fileManager) == (gid == 0 || gid == 80))
    }

    /// A trusted link pointing into a world-writable folder is refused: the target is checked, not only the link.
    @Test func refusesLinkToUntrustedTarget() throws {
        let target = try makeAZ(folderMode: 0o777)
        let linkDir = FileManager.default.temporaryDirectory.appending(path: "azpim-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: linkDir, withIntermediateDirectories: true)
        let link = linkDir.appending(path: "az")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        #expect(Validation.azPath(link.path) == .invalidFormat("azCLIPath"))
    }

    /// A configured `az` in a world-writable folder is ignored (security review L2).
    @Test func ignoresConfiguredPathInWorldWritableFolder() throws {
        let path = try makeAZ(folderMode: 0o777)
        #expect(Validation.azPath(path) == .invalidFormat("azCLIPath"))
        let provider = AzureCLITokenProvider(configuredPath: path, runner: FakeRunner([]))
        #expect(provider.locateCLI()?.path != path)
    }

    @Test func missingCLIThrowsCliNotFound() async {
        let provider = AzureCLITokenProvider(configuredPath: "/nonexistent/az", runner: FakeRunner([]),
                                             fileManager: NoExecutables())
        await #expect(throws: TokenError.cliNotFound) {
            try await provider.token(for: .arm, tenantId: nil, claims: nil)
        }
    }

    @Test func parsesTokenAndCachesIt() async throws {
        let json = #"{"accessToken":"abc","expires_on":4102444800,"tenant":"t1","tokenType":"Bearer"}"#
        let runner = FakeRunner([ProcessOutput(status: 0, stdout: json, stderr: "")])
        let provider = AzureCLITokenProvider(configuredPath: fakeAZ, runner: runner)
        let first = try await provider.token(for: .arm, tenantId: "t1", claims: nil)
        let second = try await provider.token(for: .arm, tenantId: "t1", claims: nil)
        #expect(first.value == "abc")
        #expect(first.expiresOn == Date(timeIntervalSince1970: 4_102_444_800))
        #expect(first == second)
        #expect(runner.calls.count == 1)
        #expect(runner.calls[0] == ["account", "get-access-token", "--resource", "https://management.azure.com/",
                                    "--output", "json", "--tenant", "t1"])
    }

    @Test func fallsBackToJWTExpiry() throws {
        let jwt = fakeJWT(["exp": 4_102_444_800.0, "oid": "o"])
        let token = try AzureCLITokenProvider.parseToken(#"{"accessToken":"\#(jwt)","expiresOn":"2100-01-01 00:00:00.000000"}"#)
        #expect(token.expiresOn == Date(timeIntervalSince1970: 4_102_444_800))
    }

    @Test func expiredSessionMapsToLoginCommand() async {
        let stderr = "ERROR: AADSTS700082: The refresh token has expired due to inactivity. Please run 'az login'."
        let provider = AzureCLITokenProvider(configuredPath: fakeAZ,
                                             runner: FakeRunner([ProcessOutput(status: 1, stdout: "", stderr: stderr)]))
        await #expect(throws: TokenError.cliNotSignedIn(command: "az login --tenant t1")) {
            try await provider.token(for: .arm, tenantId: "t1", claims: nil)
        }
    }

    /// A claims challenge (MFA) becomes the `az login` command to copy (TRD, AppFlow › blocked states).
    @Test func claimsChallengeGivesStepUpCommand() async {
        let provider = AzureCLITokenProvider(configuredPath: fakeAZ, runner: FakeRunner([]))
        let claims = #"{"access_token":{"acrs":{"essential":true,"value":"c1"}}}"#
        let command = "az login --tenant t1 --scope https://management.core.windows.net//.default --claims-challenge "
            + Data(claims.utf8).base64EncodedString()
        await #expect(throws: TokenError.cliStepUp(command: command)) {
            try await provider.token(for: .arm, tenantId: "t1", claims: claims)
        }
    }

    /// The identity check reads the CLI again: a cached token would still name the user before `az login`.
    @Test func identityIgnoresCachedToken() async throws {
        func output(_ oid: String) -> ProcessOutput {
            let jwt = fakeJWT(["oid": oid, "tid": "t1", "upn": "\(oid)@x.com", "exp": 4_102_444_800.0])
            return ProcessOutput(status: 0, stdout: #"{"accessToken":"\#(jwt)","expires_on":4102444800}"#, stderr: "")
        }
        let runner = FakeRunner([output("userA"), output("userB")])
        let provider = AzureCLITokenProvider(configuredPath: fakeAZ, runner: runner)
        _ = try await provider.token(for: .arm, tenantId: nil, claims: nil)
        let identity = try await provider.identity(tenantId: nil)
        #expect(identity.objectId == "userB")
    }

    /// Concurrent sources share one `az` process (it takes 1–2 s to start).
    @Test func concurrentRequestsShareOneProcess() async throws {
        let json = #"{"accessToken":"abc","expires_on":4102444800}"#
        let runner = FakeRunner([ProcessOutput(status: 0, stdout: json, stderr: "")])
        let provider = AzureCLITokenProvider(configuredPath: fakeAZ, runner: runner)
        async let first = provider.token(for: .arm, tenantId: "t1", claims: nil)
        async let second = provider.token(for: .arm, tenantId: "t1", claims: nil)
        let tokens = try await [first, second]
        #expect(tokens.map(\.value) == ["abc", "abc"])
        #expect(runner.calls.count == 1)
    }

    @Test func unknownErrorKeepsFirstLine() {
        let error = AzureCLITokenProvider.mapError("ERROR: Something odd\nTraceback…", tenantArgument: [])
        #expect(error == .failed("Something odd"))
    }

    @Test func identityComesFromTokenClaims() async throws {
        let jwt = fakeJWT(["oid": "oid-1", "tid": "tid-1", "upn": "user@contoso.com", "exp": 4_102_444_800.0])
        let tokenJSON = #"{"accessToken":"\#(jwt)","expires_on":4102444800}"#
        let listJSON = #"[{"tenantId":"tid-1","tenantDisplayName":"Contoso"},{"tenantId":"tid-1","tenantDisplayName":"Contoso"}]"#
        let runner = FakeRunner([ProcessOutput(status: 0, stdout: tokenJSON, stderr: ""),
                                 ProcessOutput(status: 0, stdout: listJSON, stderr: "")])
        let identity = try await AzureCLITokenProvider(configuredPath: fakeAZ, runner: runner).identity(tenantId: nil)
        #expect(identity == SignedInIdentity(upn: "user@contoso.com", objectId: "oid-1", tenantId: "tid-1", tenantName: "Contoso"))
    }

    @Test func realProcessRunnerHandlesLargeOutput() async throws {
        // 200 KB on stdout: would deadlock if pipes were drained only after exit.
        let output = try await ProcessRunner().run(URL(fileURLWithPath: "/bin/sh"),
                                                   arguments: ["-c", "head -c 200000 /dev/zero | tr '\\0' x; echo err >&2"],
                                                   environment: [:], timeout: .seconds(10))
        #expect(output.status == 0)
        #expect(output.stdout.count == 200_000)
        #expect(output.stderr == "err\n")
    }

    @Test func realProcessRunnerTimesOut() async {
        await #expect(throws: TokenError.timedOut) {
            try await ProcessRunner().run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], environment: [:],
                                          timeout: .milliseconds(300))
        }
    }

    /// A child that ignores SIGTERM and a grandchild holding stdout must not defeat the timeout (security review L3).
    @Test func timeoutFiresWhenChildIgnoresTerminate() async {
        let start = Date.now
        await #expect(throws: TokenError.timedOut) {
            try await ProcessRunner().run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "trap '' TERM; sleep 8"],
                                          environment: [:], timeout: .milliseconds(300))
        }
        #expect(Date.now.timeIntervalSince(start) < 3)
    }

    /// Live check against the real Azure CLI session. Opt-in: AZPIM_LIVE=1 swift test
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AZPIM_LIVE"] == "1"))
    func liveAzureCLI() async throws {
        let provider = AzureCLITokenProvider()
        let identity = try await provider.identity(tenantId: nil)
        #expect(!identity.objectId.isEmpty)
        print("live identity:", identity.upn, identity.tenantId, identity.tenantName ?? "-")
    }
}

/// FileManager reporting nothing as executable (simulates a Mac without the Azure CLI).
final class NoExecutables: FileManager, @unchecked Sendable {
    override func isExecutableFile(atPath path: String) -> Bool { false }
}
#endif
