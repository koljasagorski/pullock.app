import Foundation
import PullockIPC
import Security
import Testing

@Test func productionRequirementsCompileWithDistinctFixedRoles() throws {
    let requirements = try ProcessRole.allCases.map { try DeveloperIDPeerRequirement(teamID: "TESTTEAM01", role: $0) }
    #expect(Set(requirements.map(\.text)).count == 3)
    for requirement in requirements {
        var compiled: SecRequirement?
        #expect(SecRequirementCreateWithString(requirement.text as CFString, [], &compiled) == errSecSuccess)
        #expect(compiled != nil)
        // The current ad-hoc test runner must not satisfy any production role.
        var ownCode: SecCode?
        #expect(SecCodeCopySelf([], &ownCode) == errSecSuccess)
        let code = try #require(ownCode)
        #expect(SecCodeCheckValidity(code, [], compiled) != errSecSuccess)
    }
}

@Test func signingRequirementCannotBeInjectedThroughTeamID() {
    for team in ["", "short", "TESTTEAM001", "testteam01", "TEST\" or ", "TESTTEAM0\n", "ＴＥＳＴＴＥＡＭ０１"] {
        #expect(throws: PeerPolicyError.invalidTeam) { try DeveloperIDPeerRequirement(teamID: team, role: .app) }
    }
}

@Test func ownerSessionRejectsRootWrongUserAndSessionSwitch() throws {
    let owner = try OwnerSessionPolicy(uid: 501, auditSession: 100, active: true)
    try owner.validate(effectiveUID: 501, auditSession: 100)
    #expect(throws: PeerPolicyError.wrongUser) { try owner.validate(effectiveUID: 0, auditSession: 100) }
    #expect(throws: PeerPolicyError.wrongUser) { try owner.validate(effectiveUID: 502, auditSession: 100) }
    #expect(throws: PeerPolicyError.wrongSession) { try owner.validate(effectiveUID: 501, auditSession: 101) }
    let inactive = try OwnerSessionPolicy(uid: 501, auditSession: 100, active: false)
    #expect(throws: PeerPolicyError.inactiveSession) { try inactive.validate(effectiveUID: 501, auditSession: 100) }
}

@Test func invalidOwnerCannotBecomeSessionAuthority() {
    for (uid, session): (UInt32, Int32) in [(0, 100), (.max, 100), (501, 0), (501, -1)] {
        #expect(throws: PeerPolicyError.invalidOwner) { try OwnerSessionPolicy(uid: uid, auditSession: session, active: true) }
    }
}

@Test func daemonCannotUseClientRolePreparation() {
    #expect(throws: PeerPolicyError.invalidRole) {
        try DaemonClientConnection.prepare(teamID: "TESTTEAM01", clientRole: .daemon)
    }
}

@Test func transportAllowsOnlyByteContainers() {
    let interface = PullockXPCInterface.make()
    let selector = #selector(PullockXPCTransport.exchange(_:reply:))
    let expected = NSSet(object: NSData.self) as! Set<AnyHashable>
    #expect(interface.classes(for: selector, argumentIndex: 0, ofReply: false) == expected)
    #expect(interface.classes(for: selector, argumentIndex: 0, ofReply: true) == expected)
}
