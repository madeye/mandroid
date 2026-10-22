import Foundation
import Testing
@testable import MandroidKit

@Suite struct GuestTrustStoreTests {
    /// A store entry as `ls -lZ` prints it, the shape every parse below means
    /// when it says "entry".
    private static let labelled = "-rw-r--r-- 1 root root u:object_r:system_security_cacerts_file:s0 1818 2026-10-16 17:02 /system/etc/security/cacerts/c76e9e25.0"

    @Test func serviceScriptCoversBothStorePathsAndEveryNamespace() {
        let script = GuestTrustStore.serviceScript()
        #expect(script.contains("/apex/com.android.conscrypt/cacerts"))
        #expect(script.contains("/system/etc/security/cacerts"))
        #expect(script.contains("nsenter --mount="))
        #expect(script.contains("mount -t tmpfs"))
        #expect(script.contains("plat_file_contexts"))
        #expect(script.contains("*.0"))
    }

    @Test func modulePropertiesCarryTheIdentifier() {
        let properties = GuestTrustStore.moduleProperties()
        #expect(properties.contains("id=reqable-ca") == false)
        #expect(properties.contains("id=capture-ca"))
        #expect(properties.contains("name="))
    }

    @Test func stockEntriesAreStagedBeforeTheTmpfsCoversTheStore() throws {
        // Without an APEX store the source is the system store itself, so the
        // stock copy has to happen before the tmpfs lands on it — otherwise an
        // empty directory is copied onto itself and every stock CA disappears.
        let script = GuestTrustStore.serviceScript()
        let staged = try #require(script.range(of: "cp \"$APEX_STORE\"/* \"$STOCK\"/"))
        let mounted = try #require(script.range(of: "mount -t tmpfs tmpfs \"$STORE\""))
        let populated = try #require(script.range(of: "cp \"$STOCK\"/* \"$STORE\"/"))
        #expect(staged.upperBound <= mounted.lowerBound)
        #expect(mounted.upperBound <= populated.lowerBound)
    }

    @Test func stagingIsClearedBeforeUseAndGoneOnceTheStoreIsPopulated() throws {
        // A staging directory that survived a run would carry a replaced
        // certificate into every later rebuild of the store.
        let script = GuestTrustStore.serviceScript()
        let cleared = try #require(script.range(of: "rm -r \"$STOCK\" 2>/dev/null"))
        let staged = try #require(script.range(of: "cp \"$APEX_STORE\"/* \"$STOCK\"/"))
        let populated = try #require(script.range(of: "chcon -R \"$LABEL\" \"$STORE\""))
        let removed = try #require(script.range(of: "rm -r \"$STOCK\"", options: .backwards))
        #expect(cleared.upperBound <= staged.lowerBound)
        #expect(populated.upperBound <= removed.lowerBound)
    }

    @Test func serviceScriptExitsZeroAfterTheNamespaceLoop() {
        // A pid can vanish between the namespace scan and the bind; that must
        // not fail the script and with it the install.
        let script = GuestTrustStore.serviceScript().trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(script.hasSuffix("true"))
    }

    @Test func aFailedBindOnALiveNamespaceIsAnnounced() {
        let script = GuestTrustStore.serviceScript()
        #expect(script.contains("could not bind the store into"))
        // A namespace that vanished mid-loop is not worth a note; one that is
        // still there and refused the bind is.
        #expect(script.contains("[ ! -e \"$ns\" ]"))
    }

    @Test func zygoteListingEntersZygotesMountNamespace() {
        // The shape the acceptance script's zygote_listing runs, so an entry
        // only the installing shell can see never reads as success here.
        let command = GuestTrustStore.zygoteVerifyCommand(fileName: "c76e9e25.0")
        #expect(command.contains("nsenter --mount=/proc/$(pidof zygote64)/ns/mnt -- ls -lZ \"$APEX_STORE/c76e9e25.0\""))
        // The store path is probed the way the service script resolves it: on
        // an image without an APEX store the apps read the system store, and
        // the listing must go there rather than fail.
        #expect(command.contains("APEX_STORE=/apex/com.android.conscrypt/cacerts"))
        #expect(command.contains("STORE=/system/etc/security/cacerts"))
        #expect(command.contains("[ -d \"$APEX_STORE\" ] || APEX_STORE=\"$STORE\""))
    }

    @Test func entryIsRecognisedByNameOwnershipAndLabel() {
        #expect(GuestTrustStore.entryLabel(in: Self.labelled, fileName: "c76e9e25.0")
                == "u:object_r:system_security_cacerts_file:s0")
        #expect(GuestTrustStore.entryLabel(in: Self.labelled + "\r\n", fileName: "c76e9e25.0")
                == "u:object_r:system_security_cacerts_file:s0")
    }

    @Test func entryShapeIsRequiredNotSubstrings() {
        // ls error text can name the path and mention root while being no
        // entry at all.
        #expect(GuestTrustStore.entryLabel(in: "ls: c76e9e25.0: Permission denied for root",
                                           fileName: "c76e9e25.0") == nil)
        // A line that names another file whose path merely contains the name.
        #expect(GuestTrustStore.entryLabel(in: Self.labelled.replacingOccurrences(of: "c76e9e25.0", with: "not-c76e9e25.0"),
                                           fileName: "c76e9e25.0") == nil)
        #expect(GuestTrustStore.entryLabel(in: Self.labelled, fileName: "other0000.0") == nil)
        // Not owned by root.
        #expect(GuestTrustStore.entryLabel(in: Self.labelled.replacingOccurrences(of: "1 root root", with: "1 shell shell"),
                                           fileName: "c76e9e25.0") == nil)
        // No SELinux label to carry.
        #expect(GuestTrustStore.entryLabel(in: Self.labelled.replacingOccurrences(of: "u:object_r:system_security_cacerts_file:s0 ", with: ""),
                                           fileName: "c76e9e25.0") == nil)
    }

    @Test func verificationParsesLabelledEntryInBothNamespaces() {
        #expect(GuestTrustStore.parseVerification(shellListing: Self.labelled, appListing: Self.labelled,
                                                  fileName: "c76e9e25.0")
                == .present(label: "u:object_r:system_security_cacerts_file:s0"))
    }

    @Test func entryPresentOnlyInTheShellIsNotVisibleToApps() {
        #expect(GuestTrustStore.parseVerification(shellListing: Self.labelled, appListing: "",
                                                  fileName: "c76e9e25.0")
                == .notVisibleToApps(label: "u:object_r:system_security_cacerts_file:s0"))
        #expect(GuestTrustStore.parseVerification(shellListing: Self.labelled,
                                                  appListing: "ls: /apex/com.android.conscrypt/cacerts/c76e9e25.0: No such file or directory",
                                                  fileName: "c76e9e25.0")
                == .notVisibleToApps(label: "u:object_r:system_security_cacerts_file:s0"))
    }

    @Test func missingEntryIsAbsentEitherWay() {
        #expect(GuestTrustStore.parseVerification(shellListing: "", appListing: "", fileName: "c76e9e25.0") == .absent)
        #expect(GuestTrustStore.parseVerification(shellListing: "No such file or directory", appListing: Self.labelled,
                                                  fileName: "c76e9e25.0") == .absent)
    }

    @Test func installReportsEachWayTheEntryCanBeMissing() {
        #expect(throws: MandroidKitError.adb("The certificate store entry was not visible after install.")) {
            try VerificationState.absent.requireVisibleAfterInstall()
        }
        #expect(throws: MandroidKitError.adb("The certificate store entry is present but not visible in an app namespace.")) {
            try VerificationState.notVisibleToApps(label: "u:object_r:system_security_cacerts_file:s0")
                .requireVisibleAfterInstall()
        }
        #expect(throws: Never.self) {
            try VerificationState.present(label: "u:object_r:system_security_cacerts_file:s0")
                .requireVisibleAfterInstall()
        }
    }

    @Test func removalTargetsModuleDirectoryAndRunningBinds() {
        let script = GuestTrustStore.removeScript(fileName: "c76e9e25.0")
        #expect(script.contains(GuestTrustStore.moduleDirectory))
        #expect(script.contains("umount"))
    }

    @Test func removalUnmountsBothStoresInEveryMountNamespace() {
        let script = GuestTrustStore.removeScript(fileName: "c76e9e25.0")
        // The script is inlined into `su -c '<script>'`, so a quote would break it.
        #expect(!script.contains("'"))
        #expect(script.contains("nsenter --mount="))
        #expect(script.contains("STORE=\(GuestTrustStore.systemStore)"))
        #expect(script.contains("APEX_STORE=\(GuestTrustStore.apexStore)"))
        #expect(script.contains("umount \"$STORE\""))
        #expect(script.contains("umount \"$APEX_STORE\""))
        #expect(script.contains("rm -r \"$MODDIR\""))
    }

    @Test func removalIsRenderedForTheRecordedEntry() {
        let script = GuestTrustStore.removeScript(fileName: "c76e9e25.0")
        #expect(script.contains("ENTRY=$MODDIR/c76e9e25.0"))
        #expect(script.contains("rm -f \"$ENTRY\""))
        #expect(!GuestTrustStore.removeScript(fileName: "other0000.0").contains("c76e9e25.0"))
    }
}
