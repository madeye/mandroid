import Foundation

/// Where a trust-store entry was found, and with which SELinux label.
public enum VerificationState: Sendable, Equatable {
    case absent
    /// The entry lists in the shell's own mount namespace but not where apps
    /// read the store, so no app can trust the certificate. The label is the
    /// one the shell's listing showed.
    case notVisibleToApps(label: String)
    case present(label: String)
}

extension VerificationState {
    /// Throws unless the entry is live everywhere it has to be, naming the
    /// failure mode instead of swallowing it.
    public func requireVisibleAfterInstall() throws {
        switch self {
        case .present:
            return
        case .notVisibleToApps:
            throw MandroidKitError.adb("The certificate store entry is present but not visible in an app namespace.")
        case .absent:
            throw MandroidKitError.adb("The certificate store entry was not visible after install.")
        }
    }
}

/// The guest-side procedure for adding one certificate to the system trust
/// store, kept in one place so the injectors and the acceptance script run
/// the same commands.
public enum GuestTrustStore {
    public static let moduleDirectory = "/data/adb/modules/capture-ca"
    public static let apexStore = "/apex/com.android.conscrypt/cacerts"
    public static let systemStore = "/system/etc/security/cacerts"

    public static func moduleProperties() -> String {
        """
        id=capture-ca
        name=Capture proxy CA
        version=1.0
        versionCode=1
        author=Mandroid
        description=Adds a debugging proxy CA to the system trust store at boot.
        """
    }

    public static func serviceScript() -> String {
        """
        #!/system/bin/sh
        # Builds a writable copy of the CA store and binds it over the read-only
        # store path in every mount namespace. Runs as root from the module directory.
        MODDIR=${0%/*}
        STORE=/system/etc/security/cacerts
        APEX_STORE=/apex/com.android.conscrypt/cacerts
        CERT=$(ls "$MODDIR"/*.0 2>/dev/null | head -1)
        [ -f "$CERT" ] || exit 1
        [ -d "$APEX_STORE" ] || APEX_STORE="$STORE"

        LABEL=$(grep -h 'security/cacerts' /system/etc/selinux/plat_file_contexts 2>/dev/null | awk '{print $2}' | head -1)
        [ -n "$LABEL" ] || LABEL=u:object_r:system_security_cacerts_file:s0

        # The stock entries are staged before any mount covers a store path.
        # Without an APEX store the source is $STORE itself, and a tmpfs over it
        # would leave nothing to copy. The staging starts empty and is gone
        # again once the store holds the entries: one that persisted would
        # carry a replaced certificate into every later rebuild.
        STOCK=$MODDIR/stock
        rm -r "$STOCK" 2>/dev/null
        mkdir -p "$STOCK"
        cp "$APEX_STORE"/* "$STOCK"/ 2>/dev/null

        mount -t tmpfs tmpfs "$STORE"
        cp "$STOCK"/* "$STORE"/ 2>/dev/null
        cp "$CERT" "$STORE/$(basename "$CERT")"
        chown root:root "$STORE"/* 2>/dev/null
        chmod 644 "$STORE"/* 2>/dev/null
        chmod 755 "$STORE"
        chcon -R "$LABEL" "$STORE" 2>/dev/null
        rm -r "$STOCK"

        seen=""
        for pid in $(ls /proc | grep -E '^[0-9]+$'); do
          ns="/proc/$pid/ns/mnt"
          target=$(readlink "$ns" 2>/dev/null) || continue
          case " $seen " in *" $target "*) continue ;; esac
          seen="$seen $target"
          if ! nsenter --mount="$ns" -- /system/bin/mount --bind "$STORE" "$APEX_STORE" 2>/dev/null; then
            [ ! -e "$ns" ] || echo "capture-ca: could not bind the store into $target" >&2
          fi
        done
        true
        """
    }

    /// The listing of the entry in the installing shell's own mount namespace.
    public static func verifyCommand(fileName: String) -> String {
        "ls -lZ \(systemStore)/\(fileName)"
    }

    /// The same listing through zygote64's mount namespace, which is where an
    /// app reads the store from. An entry that only exists in the shell's
    /// namespace never reaches an app, so this is the listing that decides
    /// whether apps can trust the certificate at all. The store path is probed
    /// the way the service script resolves it: without an APEX store the apps
    /// read the system store, and the listing goes there rather than failing.
    public static func zygoteVerifyCommand(fileName: String) -> String {
        "APEX_STORE=\(apexStore); STORE=\(systemStore); [ -d \"$APEX_STORE\" ] || APEX_STORE=\"$STORE\"; nsenter --mount=/proc/$(pidof zygote64)/ns/mnt -- ls -lZ \"$APEX_STORE/\(fileName)\""
    }

    /// The SELinux label of a store entry in one `ls -lZ` listing, or nil when
    /// the listing is not that entry: a regular-file line naming it, owned by
    /// root, carrying a SELinux label. ls's own error text never parses as an
    /// entry.
    public static func entryLabel(in listing: String, fileName: String) -> String? {
        let line = listing
            .replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard line.hasPrefix("-") else { return nil }
        let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // ls -lZ: mode, links, owner, group, SELinux context, size, date, name.
        guard fields.count >= 5, fields[2] == "root" else { return nil }
        guard let label = fields.first(where: { $0.hasPrefix("u:object_r:") }) else { return nil }
        guard let path = fields.last, path.split(separator: "/").last.map(String.init) == fileName else { return nil }
        return label
    }

    /// What the two listings together say: the entry absent from the shell's
    /// namespace, present there but not where apps read it, or present and
    /// labelled in both.
    public static func parseVerification(shellListing: String, appListing: String, fileName: String) -> VerificationState {
        guard let label = entryLabel(in: shellListing, fileName: fileName) else { return .absent }
        guard entryLabel(in: appListing, fileName: fileName) != nil else {
            return .notVisibleToApps(label: label)
        }
        return .present(label: label)
    }

    /// The guest script that takes one recorded install back out: the entry the
    /// record names, the binds that published it, and the module that would
    /// rebuild it at the next boot. The module identifier is a constant because
    /// one session holds one capture module; the entry name is what varies per
    /// record and what the script is rendered from. The script is inlined into
    /// `su -c '<script>'`, so it holds no single quotes.
    public static func removeScript(fileName: String) -> String {
        """
        MODDIR=\(moduleDirectory)
        ENTRY=$MODDIR/\(fileName)
        STORE=\(systemStore)
        APEX_STORE=\(apexStore)
        UMOUNT=/system/bin/umount
        [ -x "$UMOUNT" ] || UMOUNT=umount
        # Mounts are per namespace, so the binds have to come out of each one
        # that got them, exactly as the service script put them in.
        seen=""
        for pid in $(ls /proc | grep -E "^[0-9]+$"); do
          ns="/proc/$pid/ns/mnt"
          target=$(readlink "$ns" 2>/dev/null) || continue
          case " $seen " in *" $target "*) continue ;; esac
          seen="$seen $target"
          nsenter --mount="$ns" -- "$UMOUNT" "$STORE" 2>/dev/null
          nsenter --mount="$ns" -- "$UMOUNT" "$APEX_STORE" 2>/dev/null
        done
        umount "$STORE" 2>/dev/null
        umount "$APEX_STORE" 2>/dev/null
        rm -f "$ENTRY"
        rm -r "$MODDIR"
        """
    }
}
