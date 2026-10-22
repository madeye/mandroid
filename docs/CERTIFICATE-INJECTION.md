# Certificate injection for HTTPS capture

Status: implemented. The KernelSU path is verified on device; the
writable-system path is not. §9 records what has and has not run.

Goal: let a user point Mandroid at a debugging proxy running on the Mac
(Reqable, Charles, mitmproxy, Proxyman) and have guest apps trust that proxy's
root CA, so HTTPS traffic can be decrypted. The proxy itself is not part of this
feature; per-app proxy endpoints already exist (see DESIGN §7 "Per-app HTTP
proxy settings").

## 1. Scope

In scope:

- Obtaining a root CA: from a certificate file the user selects or PEM they
  paste, or automatically from a proxy endpoint.
- Installing that CA into the guest system trust store, on two session shapes:
  a KernelSU-rooted session, and a writable-system (`google_apis`) session.
- Reporting whether the install is live, and removing it again.
- A host-side pre-flight check that the proxy actually signs with the CA we
  installed.

Out of scope:

- Configuring or starting the proxy, and setting per-app proxy endpoints. The
  two features stay independent; see §8.
- SSL pinning bypass. Apps that pin their own CA still fail after this feature
  succeeds; that needs a separate hooking story.
- Play Integrity consequences. Injection does not change the documented
  limitation, and the feature must not claim otherwise.
- Per-host or per-app certificate scoping.
- Reading CA files directly out of a proxy tool's data directory on the Mac
  (deferred; see §7).

## Using it

1. Start the debugging proxy on the Mac. Configuring it, including per-app
   proxy endpoints, stays outside this feature.
2. Give Mandroid the proxy's root CA from Settings ▸ Capture certificates:
   **Choose Certificate…** for a file, paste PEM text, or enter the proxy's
   host and port and use **Get from Proxy…**.
3. Confirm the certificate. Mandroid shows its subject and validity window
   before anything is installed.
4. Install. The pre-flight check runs first and guards the install: a TLS
   session through the proxy whose leaf must chain to the chosen CA. It is
   required on the fetch-from-proxy path and runs whenever a proxy address is
   entered; on a file or pasted PEM with no proxy address it is skipped after
   an explicit "not verified" confirmation. A verdict other than trusted
   aborts the install and is reported in place of installing. Installing needs
   a rooted session: a KernelSU session with the capture feature on, or a
   session booted from a userdebug image with a writable system partition.
5. Watch the status line for the installed subject and expiry, and use
   **Remove Certificate** to take it out. Removal runs the procedure belonging
   to how the certificate was installed, so the session must be able to offer
   that shape.

Two limits were measured during development. Chrome verifies against the Chrome
Root Store and rejects a CA installed in the system store
(`NET::ERR_CERT_AUTHORITY_INVALID`) even while other apps trust it. Apps that
pin their own certificate still fail after a successful install.

## 2. Measured behaviour this design rests on

All measurements from a macOS host, Google Play Android 36.1 ARM64 revision 4
image (API 36), KernelSU v3.3.0 LKM on a patched ramdisk.

- The runtime trust store is `/apex/com.android.conscrypt/cacerts`. The legacy
  path `/system/etc/security/cacerts` resolves to the same content inside app
  mount namespaces; covering only one of the two was not enough during
  development, so both are mounted.
- Entry file names must be the certificate's `subject_hash_old` plus `.0`.
  Verified against stock entries: a stock file's contents hashed with
  `openssl x509 -subject_hash_old` reproduce its file name exactly.
- Entries must carry the SELinux label `u:object_r:system_security_cacerts_file:s0`,
  which is what `plat_file_contexts` assigns to that directory. With the label
  applied there were no AVC denials for app reads.
- The store is read per process from the filesystem. A mount added after a
  process started is not picked up by that process, so the runtime path binds
  into every existing mount namespace, zygote included, and then the target app
  is started. The validated end-to-end path was injection at boot followed by an
  app cold start.
- The bind does not reach every namespace. On the Play image the init namespace
  refuses it while the shell's own namespace and zygote64's accept it, so apps
  trust the certificate and the processes that stay in the init namespace do
  not; see §11.
- A KernelSU module's `service.sh` runs late enough that the APEX store exists,
  and early enough that user apps start afterwards. Injection from
  `post-fs-data.sh` is unsafe: the APEX may not be mounted yet, which would copy
  an incomplete store.
- Chrome is not a valid acceptance test: it uses the Chrome Root Store and
  rejects a system-store CA with `NET::ERR_CERT_AUTHORITY_INVALID`. During
  development the same CA was simultaneously accepted by Google Play services
  and by the app under test. Verification must use the target app, or the
  host-side chain check in §5.
- With KernelSU's shipped patched ramdisk, `adb shell` is not root: the ramdisk
  is patched without `--allow-shell`. A root shell is what performs the install,
  so the feature needs a ramdisk variant that grants it (§4).
- CA endpoint probe through a Reqable instance on the host: `chls.pro/ssl` did
  not resolve, and `mitm.it` answered 404 (an earlier release answered with a
  short text page instead of a certificate). No generic "download your CA"
  endpoint answered, so acquisition cannot rely on a single well-known URL.
  Reqable 3.3.1 does present its CA in the handshake chain, which is the
  strategy that answers for it (§7).

## 3. Components

Host side (`MandroidKit`):

- `CaptureCertificate` — the CA we intend to install: PEM bytes, subject,
  computed store file name, validity window, and how it was obtained. Pure data,
  no I/O.
- `CertificateAuthorityResolver` — the automatic half of acquisition: given an
  `HTTPProxyEndpoint`, returns a `CaptureCertificate` using an ordered strategy
  list (§7). Each strategy is independently testable against a fake proxy.
  Selecting a file and pasting PEM need no proxy and sit outside the resolver.
- `CertificateChainChecker` — opens a TLS session to a canary host through the
  proxy, extracts the presented leaf, and reports whether it chains to a given
  `CaptureCertificate`. This is the pre-flight check that catches "wrong CA" and
  "pinning" before anything touches the guest. It runs whenever a proxy endpoint
  is known; on the manual paths it is skipped after an explicit warning (§8).
- `CaptureCertificateStore` — per-AVD record of what was installed and where,
  stored in the app data folder next to the other per-AVD state.
- `GuestTrustStore` — the guest-side contract, expressed as a small set of
  commands run over ADB: resolve store paths, write an entry, label it, rebind
  every mount namespace, count entries, report the entry that matches a given
  file name. Both injectors use it, so verification and rollback are shared.
- `CertificateInjector` — two implementations of one contract
  (`install`, `verify`, `remove`):
  - `KernelSUModuleInjector` — renders a KernelSU module (properties file,
    service script, the certificate) and installs it into the guest, then
    applies it immediately so no reboot is needed.
  - `WritableSystemInjector` — for userdebug sessions: push the entry into the
    system store directly. The AVD's writable system image keeps it across
    reboots; nothing is installed into `/data/adb`.

Guest side:

- The module's service script performs the store build and the per-namespace
  bind at boot. It is the same procedure the immediate-apply path runs, so both
  are exercised by the same code.

App UI:

- A `Capture certificates` section in Settings, next to the KernelSU section:
  choosing a certificate file or pasting PEM is the primary action, with the
  proxy endpoint (reusing `HTTPProxyEndpoint`) and an obtain-from-proxy action
  beside it. Either source resolves to a certificate whose subject and validity
  are shown for confirmation before anything is installed. The section also
  shows live status and removal, and states plainly that it needs a rooted
  session and that pinned apps will still fail.

## 4. KernelSU session behaviour

The existing patcher produces one patched ramdisk per image and kernel, cached
under a key built from the tool version and the input hashes. Two additions:

- The patch must optionally include `--allow-shell`, because the installer runs
  as the ADB shell user. The cache key must include that choice, otherwise the
  rooted session silently replaces the non-root one (this already bit us
  manually during development).
- `--allow-shell` stays opt-in and is surfaced as such: enabling the capture
  certificate feature implies it for that session, turning the feature off
  leaves the original non-root patch in place. KERNELSU.md documents the
  difference, where it previously promised that shell is never granted root.

Install procedure (validated by hand during development):

1. Render the module into a temporary directory: properties file, service
   script, and the certificate under its store name.
2. Push it and place it under the modules directory with root ownership and
   store-appropriate permissions.
3. Run the service script once through a root shell so the effects apply to the
   running session immediately, and verify the store from the guest.
4. Record the install in `CaptureCertificateStore` and report status.

Removal deletes the module directory, undoes the running session's binds where
that is possible, and reboots on request; state after removal is "no injected
certificate" without needing a fresh image.

Failure modes that must be reported, not swallowed: no root available (feature
disabled with the reason), store not writable, store entry present but not
visible in an app namespace, and proxy unreachable during pre-flight.

## 5. Writable-system sessions

A `google_apis` (userdebug) image recognises `adb root`, so injection can write
the store directly without KernelSU. This path rests on three pieces of
groundwork:

- A launch option for writable system, threaded through the runner's launch
  options and the AVD configuration, with a note that it is meaningless on Play
  images.
- An image choice: the SDK bootstrap already plans and downloads arbitrary
  system image tags through the repository manifests and the mirror setting, so
  `google_apis` for the same API level can reuse that machinery. The download is
  several gigabytes; the UI must state the size before starting.
- A session-shape check before the feature is offered: Play image without
  KernelSU gives "unavailable, here is why" rather than a disabled button.

The entry itself lives on the AVD's writable system partition and survives a
restart, but the runtime bind does not: without KernelSU there is no boot hook,
so the runner re-applies the store build when a session starts with the capture
feature enabled, and removal means deleting the entry rather than uninstalling a
module. This path is therefore "effective from the next app launch" after each
boot, not unconditionally persistent.

## 6. Risks

- KernelSU support is bound to one image revision and kernel. A new system image
  invalidates the patch and the feature must degrade to "root unavailable".
- Granting shell root changes the security posture of a session. It is opt-in,
  per session, and does not persist when the capture feature is off.
- The APEX store path and its labels can change in a future Android release. The
  store resolution and label lookup are therefore read from the guest
  (`file_contexts`, existence probes) rather than hardcoded.
- Apps that pin their CA fail despite a successful install; the feature must say
  so rather than appear broken.
- Bind-mounting a directory and then deleting its contents removes the mounted
  store from every process at once (observed during development). The module
  keeps its store under the module directory and never treats a mounted path as
  disposable.

## 7. CA acquisition, in order

1. Manual: the user picks a PEM/DER file or pastes PEM text. Always available,
   needs no cooperation from the proxy, and is the route measured to work with
   Reqable.
2. Well-known CA endpoints fetched through the user's proxy — mitmproxy
   (`mitm.it`), Charles (`chls.pro/ssl`), and similar documented endpoints.
3. Issuer extraction from a live handshake: connect through the proxy to the
   canary host and take the issuing CA from the presented chain, when the proxy
   includes it. Reqable 3.3.1 includes its CA, so this is the strategy that
   answers for it; the release measured earlier sent only the leaf, which left
   manual selection as the fallback.

The automatic strategies report their outcome so the UI can explain why they
fell through, and manual selection is offered again at that point. Reading a
known tool's data directory on the Mac was considered and left out of scope; it
is the obvious next strategy if manual selection proves annoying.

## 8. Decisions recorded at review

- Certificate source: manual selection and pasted PEM come first; the automatic
  strategies follow and fall back to manual with a stated reason (§7).
- Per-app proxy configuration stays out of this feature. One action that
  configures both would be convenient, but it couples two features that are
  otherwise independent, and the proxy settings already have their own UI.
- Both session shapes ship together: the KernelSU track and the writable-system
  track, including the groundwork in §5. They are separate work items (§10) with
  separate verification, not separate releases.
- The immediate-apply path stays. Both injectors share one store-building
  procedure, so it is a thin addition that keeps a reboot out of the install
  loop; the module path still provides persistence across restarts.
- The pre-flight verdict is mandatory only on the fetch-from-proxy path. When
  the user installs from a file or pasted PEM with a proxy endpoint configured,
  the check still runs; with no endpoint it is skipped after an explicit
  "not verified" confirmation, so installing a certificate before configuring a
  proxy stays possible. The strict install entry point keeps throwing on any
  verdict other than `.trusted`; the unverified path is a separate one.

## 9. Verification

The unit suite covers store name computation, certificate parsing (PEM, DER,
pasted text, malformed input), resolver strategy order and fallbacks against a
stub proxy, the pre-flight chain check with a correct and a foreign CA, module
rendering, injector command lists, launch-option composition, session-shape
classification and injector/removal selection, and per-AVD record read/write.
The suite passes on this branch (184 tests in 40 suites at the time of
writing).

What has run on device:

- The guest-side acceptance script, `Scripts/capture-certificate-test.sh`, with
  `--shape kernelSU` against a Play image booted from the shell-root ramdisk:
  install, entry visibility in the shell's and zygote64's mount namespaces, the
  reboot, the module's boot-time rebuild, and removal. It passes. The run also
  exposed two defects in the script itself, both fixed: the adb shell consumed
  the script's own command list from standard input, and the removal drift
  guard rejected the `$MODDIR` form the removal script uses.
- The Settings section, against a rooted KernelSU session: choosing a
  certificate file installs it, the status line reports it, and a real app
  (`com.xiaomi.im.wms`) with a per-app proxy set through Mandroid reached a
  Reqable instance on the host. Before the install the proxy recorded a client
  TLS handshake failure; after it, the same request was captured decrypted.
  Turning that app's proxy off returned it to a direct, working request.
- Every acquisition path in Settings, against Reqable 3.3.1 on the host: the
  file picker, pasted PEM, and **Get from Proxy…** all resolve to the same
  certificate (`0a65b4da.0`, valid to 2033-05-31) and complete the install.
  The proxy path resolves it through the handshake chain, not through a
  download endpoint.

What has not run:

- The writable-system live path — `adb root`, the writable system image,
  install, reboot, the runner's post-boot re-apply, and removal — has never run
  on an emulator. The acceptance script's writable-system shape has not run
  either, for the same missing image.
- No app that pins its own certificate has been tried. The statement that such
  apps still fail is carried over from the design, not measured alongside the
  run above. Chrome remains excluded as evidence for or against trust.

The acceptance script's removal step unmounts the trust-store paths in every
mount namespace, which tears down an in-use capture session until the device
reboots. It must only be pointed at a scratch emulator.

## 10. Work breakdown

Each item is independently verifiable and can land on its own branch.

| # | Deliverable | Acceptance |
|---|---|---|
| 1 | `CaptureCertificate`, `GuestTrustStore` contract, store-name computation | Unit tests cover hash naming, PEM/DER parsing, and the guest command shapes |
| 2 | `CertificateAuthorityResolver` with the automatic strategies | Stub proxy exercises each strategy and the all-fail path that returns the user to manual selection |
| 3 | `CertificateChainChecker` pre-flight | Correct CA passes, foreign CA fails, unreachable proxy fails cleanly |
| 4 | KernelSU ramdisk variant with `--allow-shell`, cache keyed on the choice | Both variants coexist in the cache; the non-root session is unaffected |
| 5 | `KernelSUModuleInjector` (render, install, immediate apply, verify, remove) | Scripted session test: install → verify → restart → verify → remove |
| 6 | Settings UI section and per-AVD record | State survives app restart; unavailable sessions explain themselves |
| 7 | Writable-system groundwork (launch option, image choice, session check) | `adb root` session injects and survives a restart |
| 8 | `WritableSystemInjector` | Same scripted lifecycle as item 5 on a userdebug image |
| 9 | Documentation: KERNELSU.md note on `--allow-shell`, capture guide, Chrome and pinning caveats | Docs match measured behaviour |
| 10 | Injector selection by session shape, plus a writable-system mode for the acceptance script | A rooted session of either shape resolves to its injector; an unprivileged session explains why the feature is unavailable |

## 11. Follow-ups

Recorded during the final review and deliberately left out of the first
release. None of these blocks the feature; each is a place the next change
should tighten.

Device verification comes first: §9 records what has run and what has not, and
nothing below replaces the writable-system path.

- **The init mount namespace refuses the store bind.** Measured on the Play
  image with a shell-root ramdisk: the service script prints
  `capture-ca: could not bind the store into mnt:[4026531841]`, and that inode
  is the namespace init, logd, vold, keystore2 and the vendor HALs stay in. The
  shell's namespace and zygote64's accept the bind, so apps read the injected
  entry and the acceptance checks pass, but a process that never leaves the
  init namespace does not see it. Why the bind fails there — SELinux policy for
  the root context KernelSU hands the shell, or the read-only APEX mount in
  that namespace — was not determined. Either show the failure cannot matter
  for the processes involved, or report it as its own state instead of one
  line of standard error the install ignores.

- **Acceptance-script regression test.** The fake-adb harness that exercised
  the script's device path was written during development and never landed. It
  is the only thing that has ever run that path, so it should be committed as a
  test before the script is trusted.
- **Coverage gaps in the app layer.** No test drives `remove` end to end, the
  corrupt-record state has no in-app exit, and the injectors' I/O paths have no
  coverage; the same is true of the `--allow-shell` flag reaching `ksud`, the
  persisted defaults key, capability detection on a feature-off session, and
  the root-switch-before-detect ordering that makes the writable shape
  reachable at all.
- **Error fidelity in `CertificateImporter`.** Any OpenSSL failure on the CA
  check is reported as "not a certificate", the DER retry path is unreachable
  and would also need `-inform der`, and missing validity fields fall back
  silently.
- **Verification parsing.** The Swift entry parser is looser than the
  acceptance script's; the script's shape check is the one worth mirroring.
- **Chain wording paths.** The empty-chain reason is unreachable, and the
  issuer reported for `.foreignIssuer` is taken from the top of the presented
  chain, which assumes the signing CA is last.
- **Certificate provenance.** `CaptureCertificate` does not carry the source the
  design describes; the resolver reports it only to the UI.
- **UI polish.** The `.trusted` status line is unreachable, the unverified path
  shows two consecutive modals, the root switch runs before the user confirms,
  the "Installed image" line ignores the selected tag, the picker only lists the
  highest API level while the boot lookup searches all of them, and the hybrid
  session's removal refusal names a toggle that is already on.
- **Script robustness.** The one-line extractor heuristic can read the wrong
  function if a literal moves, the script adds a second data-root variable name,
  it does not check for a pre-existing module directory before installing, and
  on a fallback image its entry check lists the APEX path only.
- **Duplication.** The "entry was not visible" string, the SELinux label lookup
  and the root-switch pair are each written more than once.
- **Taxonomy.** `.notIntercepted` is an imprecise name for "a chain this Mac
  already trusts"; the honest copy covers it today, and a rename is a design
  decision for later.
- **Image download picks the manifest's first candidate.** With no preferred
  API level, downloading `google_apis` for a virtual device that runs a specific
  level can select a newer or canary image the device's user data cannot boot
  with. The correct image exists for the same level; the downloader should
  prefer the level already installed rather than the manifest's order. Found
  while verifying the writable-system shape on device.
- **A device reboot the app does not drive skips the writable-system re-apply.**
  The KernelSU shape rebuilds the store from its boot hook, but the
  writable-system shape rebuilds it from the runner's session start. An
  `adb reboot` (or any reboot outside the app) therefore leaves the entry on the
  system image yet unbound, so apps stop trusting it until the next emulator
  start. Either hook the guest's boot completion or state the limitation where
  the certificate is shown. Measured on device.
