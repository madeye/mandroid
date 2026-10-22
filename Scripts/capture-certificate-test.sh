#!/bin/sh
# Runtime acceptance for the certificate injectors, against an already booted
# rooted session. Never starts an emulator, never touches another module.
#
#   ANDROID_SERIAL=emulator-5554 ADB_SERVER_PORT=5137 \
#     Scripts/capture-certificate-test.sh --ca /path/to/proxy-ca.pem
#
# It reboots the session and unmounts the store paths on the way out, so point
# it at a scratch rooted emulator rather than one somebody is using.
#
# --shape picks the injector whose procedure it runs (default: kernelSU).
#
# kernelSU installs the CA as the KernelSU injector does, checks the store entry
# in the adb shell's mount namespace and in zygote64's, reboots, checks the
# entry again, then removes and checks that both mounts and the module directory
# are gone.
#
# writable-system runs the direct procedure on a userdebug session: `adb root`
# makes the shell root, the injector's install commands stage the script and the
# certificate and write the entry into the system store, the entry is checked in
# both namespaces, the session is rebooted, the script checks that the entry is
# still on the writable system image while the runtime store is gone, runs the
# injector's re-apply command the way a session start does, checks again, and
# then removes the entry and both mounts.
#
# The module text, the install commands, the re-apply command and the removal
# commands are all read out of the capture sources, so the script runs the
# injector's own procedure rather than a copy of it, and the guest paths it
# checks are asserted against what it read. Only the push that stages the
# rendered files is mirrored, since it is not a guest command.
#
# ADB overrides the adb binary (default: the app's platform-tools/adb).
# --render-only <dir> writes the rendered files out and stops; it needs no
# device. The writable-system shape also prints the command list it would run.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(dirname "$SCRIPT_DIR")
GUEST_SWIFT="$ROOT/MandroidKit/Capture/GuestTrustStore.swift"
INJECTOR_SWIFT="$ROOT/MandroidKit/Capture/KernelSUModuleInjector.swift"
WRITABLE_SWIFT="$ROOT/MandroidKit/Capture/WritableSystemInjector.swift"
DATA_ROOT="${MANDROID_DATA_ROOT:-$HOME/Library/Application Support/Mandroid}"
ADB="${ADB:-$DATA_ROOT/sdk/platform-tools/adb}"

# Guest paths, kept in step with GuestTrustStore and WritableSystemInjector.
MODULE_DIRECTORY=/data/adb/modules/capture-ca
SCRIPT_DIRECTORY=/data/local/tmp/capture-ca
SYSTEM_STORE=/system/etc/security/cacerts
APEX_STORE=/apex/com.android.conscrypt/cacerts

CA=""
RENDER_ONLY=""
SHAPE=kernelSU

fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

usage() {
  echo "usage: ANDROID_SERIAL=<serial> ADB_SERVER_PORT=<port> $0 [--shape kernelSU|writable-system] --ca <certificate>" >&2
  echo "       $0 [--shape kernelSU|writable-system] --ca <certificate> --render-only <directory>" >&2
}

# Prints the text of a capture-source function: the triple-quoted literal, or
# the single-line literal of a one-line function, dedented, with
# \(interpolations) resolved from the NAME=VALUE arguments given here, from the
# file's own constants and — for a dotted name like \(GuestTrustStore.systemStore)
# — from the file named with source=<file>. Fails loudly rather than returning
# something plausible when the shape it reads is gone.
module_text() {   # module_text <file> <functionName> [NAME=VALUE | source=<file> ...]
  python3 - "$@" <<'PY'
import re, sys

path, name = sys.argv[1], sys.argv[2]
values, sources = {}, [path]
for argument in sys.argv[3:]:
    key, _, value = argument.partition('=')
    if key == 'source':
        sources.append(value)
    else:
        values[key] = value

source = open(path).read()
texts = [open(p).read() for p in sources]
lines = source.split('\n')
head = 'func %s(' % name

start = next((i for i, l in enumerate(lines) if head in l), None)
if start is None:
    sys.exit('FAIL: %s not found in %s' % (head, path))
# The literal has to sit inside the function, so a body that is gone fails
# instead of reading whatever the next function happens to return.
end = next((i for i in range(start + 1, len(lines))
            if re.match(r'\s*(public |private |internal )?(static )?func ', lines[i])), len(lines))
opens = next((i for i in range(start, end) if lines[i].strip() == '"""'), None)
if opens is None:
    quoted = next((l for l in lines[start + 1:end] if '"' in l), None)
    if quoted is None:
        sys.exit('FAIL: no string literal after %s' % head)
    body = [quoted[quoted.index('"') + 1:quoted.rindex('"')]]
else:
    indent = len(lines[opens]) - len(lines[opens].lstrip())
    closes = next((i for i in range(opens + 1, end)
                   if lines[i] == ' ' * indent + '"""'), None)
    if closes is None:
        sys.exit('FAIL: unterminated string literal after %s' % head)
    body = [l[indent:] if l.strip() else '' for l in lines[opens + 1:closes]]

def resolve(match):
    key = match.group(1)
    if key in values:
        return values[key]
    # The member of a dotted name is looked up in the files the type could live
    # in; a bare name resolves from the function's own file first.
    member = key.rsplit('.', 1)[-1]
    for text in texts:
        constant = re.search(r'static let %s = "([^"]*)"' % re.escape(member), text)
        if constant is not None:
            return constant.group(1)
    sys.exit('FAIL: cannot resolve %s in %s' % (match.group(0), name))

text = re.sub(r'\\\(([\w.]+)\)', resolve, '\n'.join(body))
if '\\(' in text:
    sys.exit('FAIL: unresolved interpolation in %s' % name)
sys.stdout.write(text)
PY
}

# Prints the literal a Swift source gives one static constant, or nothing.
swift_constant() {   # swift_constant <file> <name>
  sed -n "s/.*static let $2 = \"\([^\"]*\)\".*/\1/p" "$1" | head -1
}

# Fails unless a path this script uses is the constant the sources use. The
# render guards below compare what was rendered against these same paths, so
# they only mean something while the two agree.
assert_constant() {   # assert_constant <file> <name> <expected>
  actual=$(swift_constant "$1" "$2")
  [ "$actual" = "$3" ] || fail "$2 in $(basename "$1") is ${actual:-missing}, but this script uses $3"
}

# Prints the store file name for a PEM or DER certificate, or nothing.
cert_hash() {
  hash=$(openssl x509 -in "$1" -subject_hash_old -noout 2>/dev/null || true)
  if [ -z "$hash" ]; then
    hash=$(openssl x509 -inform der -in "$1" -subject_hash_old -noout 2>/dev/null || true)
  fi
  case "$hash" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) printf '%s' "$hash" ;;
  esac
}

# render_module <directory> writes module.prop, service.sh and the certificate
# into <directory>, as the KernelSU injector stages them, and refuses to go on
# if the rendered module does not look like a trust store module.
render_module() {
  directory=$1
  mkdir -p "$directory"
  module_text "$GUEST_SWIFT" moduleProperties > "$directory/module.prop"
  module_text "$GUEST_SWIFT" serviceScript > "$directory/service.sh"
  chmod 755 "$directory/service.sh"
  cp "$CA" "$directory/$STORE_NAME"
  head -1 "$directory/service.sh" | grep -qx '#!/system/bin/sh' || fail "rendered service.sh is not a shell script"
  grep -q 'nsenter --mount=' "$directory/service.sh" || fail "rendered service.sh does not enter other mount namespaces"
  grep -q 'mount -t tmpfs' "$directory/service.sh" || fail "rendered service.sh does not build the writable store"
  grep -q 'rm -r "$STOCK"' "$directory/service.sh" || fail "rendered service.sh leaves its staging directory behind"
  # The paths this script installs to and checks are the paths the module uses.
  grep -qx "id=$(basename "$MODULE_DIRECTORY")" "$directory/module.prop" || fail "module.prop does not name $MODULE_DIRECTORY"
  grep -q '^name=' "$directory/module.prop" || fail "rendered module.prop has no name"
  grep -q "STORE=$SYSTEM_STORE" "$directory/service.sh" || fail "service.sh does not use the store this script checks: $SYSTEM_STORE"
  grep -q "APEX_STORE=$APEX_STORE" "$directory/service.sh" || fail "service.sh does not use the store this script checks: $APEX_STORE"
  echo "    $directory: module.prop, service.sh, $STORE_NAME"
}

# render_staging <directory> writes what the writable-system injector stages —
# the shared service script and the certificate under its store name — and
# nothing else: this shape installs no module and writes nothing under /data/adb.
render_staging() {
  directory=$1
  mkdir -p "$directory"
  module_text "$GUEST_SWIFT" serviceScript > "$directory/service.sh"
  chmod 755 "$directory/service.sh"
  cp "$CA" "$directory/$STORE_NAME"
  head -1 "$directory/service.sh" | grep -qx '#!/system/bin/sh' || fail "rendered service.sh is not a shell script"
  grep -q 'nsenter --mount=' "$directory/service.sh" || fail "rendered service.sh does not enter other mount namespaces"
  grep -q 'mount -t tmpfs' "$directory/service.sh" || fail "rendered service.sh does not build the writable store"
  grep -q 'rm -r "$STOCK"' "$directory/service.sh" || fail "rendered service.sh leaves its staging directory behind"
  grep -q "STORE=$SYSTEM_STORE" "$directory/service.sh" || fail "service.sh does not use the store this script checks: $SYSTEM_STORE"
  grep -q "APEX_STORE=$APEX_STORE" "$directory/service.sh" || fail "service.sh does not use the store this script checks: $APEX_STORE"
  echo "    $directory: service.sh, $STORE_NAME"
}

# One root shell command, as the selected shape's injector runs it: the KernelSU
# injector escalates with `su`, and the writable-system injector runs through
# the daemon it switched to root.
guest() {
  case "$SHAPE" in
    kernelSU) "$ADB" shell "su -c '$1'" </dev/null ;;
    writable-system) "$ADB" shell "$1" </dev/null ;;
  esac
}

# Runs each rendered command in order, one root shell each, echoing it first.
run_commands() {
  while IFS= read -r command; do
    [ -n "$command" ] || continue
    echo "    $command"
    guest "$command"
  done <<EOF
$1
EOF
}

# ls -lZ of a guest path in the adb shell's mount namespace. Standard error is
# deliberately not merged: ls prints the path it could not find in its own error
# text, and that text must never be able to pass for a listing.
shell_listing() {
  guest "ls -lZ $1" 2>/dev/null | tr -d '\r'
}

# The same listing through zygote64's mount namespace, which is where an app
# reads the store from. An entry that only exists in the shell's namespace never
# reaches an app, so this is the check that matters.
zygote_listing() {
  guest "nsenter --mount=/proc/\$(pidof zygote64)/ns/mnt -- ls -lZ $1" 2>/dev/null | tr -d '\r'
}

# A store entry is an ls -lZ line for the store name, owned by root, carrying a
# SELinux label. Anything else, including ls's own error text, prints why it is
# not one.
entry_problem() {
  case "$1" in
    -*) ;;
    *) printf '%s' "there is no entry to list"; return 0 ;;
  esac
  case "$1" in
    *"$STORE_NAME"*) ;;
    *) printf '%s' "the listing names another path"; return 0 ;;
  esac
  case "$1" in
    *root*) ;;
    *) printf '%s' "the entry is not owned by root"; return 0 ;;
  esac
  case "$1" in
    *u:object_r:*) ;;
    *) printf '%s' "the entry carries no SELinux label"; return 0 ;;
  esac
}

# Fails unless the certificate is in the store, labelled, and visible to apps.
check_present() {
  when=$1
  listing=$(shell_listing "$SYSTEM_STORE/$STORE_NAME")
  problem=$(entry_problem "$listing")
  if [ -n "$problem" ]; then
    fail "$when: $SYSTEM_STORE/$STORE_NAME is not in the shell namespace ($problem): ${listing:-no output}"
  fi
  echo "    shell:   $listing"
  listing=$(zygote_listing "$APEX_STORE/$STORE_NAME")
  problem=$(entry_problem "$listing")
  if [ -n "$problem" ]; then
    fail "$when: $APEX_STORE/$STORE_NAME is not visible from zygote64 ($problem): ${listing:-no output}"
  fi
  echo "    zygote64:$listing"
}

# An absent listing means nothing unless the guest answered: a dropped adb
# connection and a removed entry both print no listing at all.
confirm_guest_answers() {
  answered=$(guest "echo capture-ca-alive" | tr -d '\r')
  [ "$answered" = "capture-ca-alive" ] || fail "the guest did not answer (${answered:-nothing}); an empty listing below would prove nothing"
}

check_absent() {   # check_absent <listing> <what>
  problem=$(entry_problem "$1")
  if [ -z "$problem" ]; then
    fail "after removal: $2 still lists the store entry: $1"
  fi
}

# A root shell is what the rest of this script needs, and each shape reaches it
# its own way: `su` answers on a KernelSU session, while a writable-system
# session starts with a plain shell whose daemon has to be asked for root, which
# only a userdebug image accepts. Anything else means this script would report
# misleading failures.
check_rooted() {
  case "$SHAPE" in
    kernelSU)
      identity=$(guest id | tr -d '\r')
      case "$identity" in
        uid=0*) ;;
        *) fail "$ANDROID_SERIAL is not rooted (su -c id said: ${identity:-nothing})" ;;
      esac
      ;;
    writable-system)
      "$ADB" root >/dev/null 2>&1 || true
      "$ADB" wait-for-device
      identity=$("$ADB" shell id | tr -d '\r')
      case "$identity" in
        uid=0*) ;;
        *) fail "$ANDROID_SERIAL did not switch to root (id said: ${identity:-nothing}); this shape needs a userdebug image booted with a writable system partition" ;;
      esac
      ;;
  esac
  echo "    $ANDROID_SERIAL, $identity"
}

# Reboots the session, waits for it to come back and finish booting, and
# re-establishes the root shell, which a reboot always takes away.
reboot_session() {
  "$ADB" reboot
  attempts=0
  while [ "$attempts" -lt 180 ]; do
    state=$("$ADB" get-state 2>/dev/null || true)
    if [ "$state" != "device" ]; then break; fi
    sleep 1
    attempts=$((attempts + 1))
  done
  [ "$state" != "device" ] || fail "$ANDROID_SERIAL did not go down for the reboot"
  "$ADB" wait-for-device
  attempts=0
  while [ "$attempts" -lt 180 ]; do
    booted=$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
    if [ "$booted" = "1" ]; then break; fi
    sleep 5
    attempts=$((attempts + 1))
  done
  [ "$booted" = "1" ] || fail "$ANDROID_SERIAL did not finish booting after the reboot"
  check_rooted
}

check_device() {
  [ -x "$ADB" ] || fail "no adb at $ADB; set ADB to the app's platform-tools/adb"
  [ -n "${ANDROID_SERIAL:-}" ] || fail "set ANDROID_SERIAL to the serial of the rooted emulator"
  [ -n "${ADB_SERVER_PORT:-}" ] || fail "set ADB_SERVER_PORT to the port the app's adb server listens on"
  export ANDROID_ADB_SERVER_PORT="$ADB_SERVER_PORT"
  state=$("$ADB" get-state 2>/dev/null || true)
  [ "$state" = "device" ] || fail "no device $ANDROID_SERIAL on adb server port $ADB_SERVER_PORT"
  booted=$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
  [ "$booted" = "1" ] || fail "$ANDROID_SERIAL has not finished booting"
  echo "    $ANDROID_SERIAL on port $ADB_SERVER_PORT"
  check_rooted
}

# The writable-system injector's install commands, rendered out of its source
# with this script's staging directory and store name. The store paths the
# injector interpolates are resolved from GuestTrustStore itself rather than
# passed in here, so a moved path changes the render and trips the guards below.
writable_install_commands() {   # writable_install_commands <staging>
  commands=$(module_text "$WRITABLE_SWIFT" installCommands "staging=$1" \
    "fileName=$STORE_NAME" "module=$SCRIPT_DIRECTORY" "source=$GUEST_SWIFT")
  case "$commands" in
    remount*) ;;
    *) fail "the writable injector no longer makes the system partition writable first" ;;
  esac
  case "$commands" in
    *"cp $1/* $SCRIPT_DIRECTORY/"*) ;;
    *) fail "the writable injector no longer copies the staged files into $SCRIPT_DIRECTORY" ;;
  esac
  case "$commands" in
    *"cp $SCRIPT_DIRECTORY/$STORE_NAME $SYSTEM_STORE/$STORE_NAME"*) ;;
    *) fail "the writable injector no longer writes the entry into $SYSTEM_STORE" ;;
  esac
  case "$commands" in
    *"chown root:root $SYSTEM_STORE/$STORE_NAME"*) ;;
    *) fail "the writable injector no longer makes the entry root-owned in $SYSTEM_STORE" ;;
  esac
  case "$commands" in
    *chcon*) ;;
    *) fail "the writable injector no longer labels the entry" ;;
  esac
  case "$commands" in
    *"sh $SCRIPT_DIRECTORY/service.sh"*) ;;
    *) fail "the writable injector no longer applies the store to the running session" ;;
  esac
  case "$commands" in
    *"rm -r $1"*) ;;
    *) fail "the writable injector no longer cleans up $1" ;;
  esac
  printf '%s\n' "$commands"
}

# The writable-system injector's removal commands, guarded: they have to take
# the binds out of the namespaces that have them, delete the entry this script
# checks for, and remove the script directory the install left behind.
writable_remove_commands() {
  commands=$(module_text "$WRITABLE_SWIFT" removeCommands \
    "fileName=$STORE_NAME" "module=$SCRIPT_DIRECTORY" "source=$GUEST_SWIFT")
  case "$commands" in
    remount*) ;;
    *) fail "the writable injector no longer makes the system partition writable first" ;;
  esac
  case "$commands" in
    *"umount $SYSTEM_STORE"*) ;;
    *) fail "the writable injector no longer unmounts $SYSTEM_STORE" ;;
  esac
  case "$commands" in
    *"umount $APEX_STORE"*) ;;
    *) fail "the writable injector no longer unmounts $APEX_STORE" ;;
  esac
  case "$commands" in
    *"rm -f $SYSTEM_STORE/$STORE_NAME"*) ;;
    *) fail "the writable injector no longer deletes the entry from $SYSTEM_STORE" ;;
  esac
  case "$commands" in
    *"rm -r $SCRIPT_DIRECTORY"*) ;;
    *) fail "the writable injector no longer removes $SCRIPT_DIRECTORY" ;;
  esac
  printf '%s\n' "$commands"
}

# The command a session start runs to rebuild the store the reboot left empty,
# rendered out of the injector and guarded the same way. It is a one-line
# function in the source, which is why the extractor reads single-line literals.
writable_reapply_command() {
  reapply=$(module_text "$WRITABLE_SWIFT" reapplyCommand \
    "module=$SCRIPT_DIRECTORY" "source=$GUEST_SWIFT")
  case "$reapply" in
    *"sh $SCRIPT_DIRECTORY/service.sh"*) ;;
    *) fail "the writable injector no longer rebuilds the store from $SCRIPT_DIRECTORY/service.sh" ;;
  esac
  printf '%s\n' "$reapply"
}

# The writable-system procedure as a live run would issue it: rendered out of
# the injector, guarded against the paths this script checks, and printed rather
# than run, so the instrument can be read without a device. Each list is
# rendered into a variable before it is printed: a guard that fails inside a
# pipeline would otherwise lose its status to the printer and the run would
# carry on with commands that were never checked.
writable_plan() {   # writable_plan <staging>
  # All three lists are checked before any of them is printed, so a plan is
  # either the whole guarded procedure or nothing at all.
  install_commands=$(writable_install_commands "$1")
  reapply=$(writable_reapply_command)
  remove_commands=$(writable_remove_commands)
  echo "    staging at $1"
  echo "    install, one root shell each:"
  printf '%s\n' "$install_commands" | sed 's/^/      /'
  echo "    re-apply after a restart:"
  printf '%s\n' "$reapply" | sed 's/^/      /'
  echo "    remove, one root shell each:"
  printf '%s\n' "$remove_commands" | sed 's/^/      /'
}

# The writable-system procedure end to end, run the way the injector runs it:
# one plain root shell per command, no `su`, against a daemon switched to root.
#
# The entry is written into the store and the store is rebuilt for the running
# session, the session is then rebooted, and what the reboot left is checked
# before the re-apply runs: the entry survives on the AVD's writable system
# image, while the tmpfs store and its binds are gone with the session. A
# session start rebuilds them, which is what the injector's re-apply command
# does, and no app reads the store before that.
run_writable_system() {
  STAGING="/data/local/tmp/capture-ca-$(date +%s)-$$"
  LOCAL_STAGING=$(mktemp -d "${TMPDIR:-/tmp}/capture-ca.XXXXXX")
  trap 'rm -r "$LOCAL_STAGING"' EXIT

  step "staging the script and the certificate as $STORE_NAME"
  render_staging "$LOCAL_STAGING"
  "$ADB" push "$LOCAL_STAGING" "$STAGING"

  step "installing into $SYSTEM_STORE"
  COMMANDS=$(writable_install_commands "$STAGING")
  run_commands "$COMMANDS"

  step "checking the entry without a reboot"
  check_present "after install"

  step "rebooting"
  reboot_session

  step "checking what the reboot left"
  listing=$(shell_listing "$SYSTEM_STORE/$STORE_NAME")
  problem=$(entry_problem "$listing")
  if [ -n "$problem" ]; then
    fail "after reboot: $SYSTEM_STORE/$STORE_NAME is not on the writable system image ($problem): ${listing:-no output}"
  fi
  echo "    image:   $listing"
  check_absent "$(shell_listing "$APEX_STORE/$STORE_NAME")" "$APEX_STORE/$STORE_NAME in the shell namespace before the store is rebuilt"
  check_absent "$(zygote_listing "$APEX_STORE/$STORE_NAME")" "$APEX_STORE/$STORE_NAME from zygote64 before the store is rebuilt"
  echo "    the runtime store is gone: the entry is on the image and in no mounted store"

  step "rebuilding the store as a session start does"
  REAPPLY=$(writable_reapply_command)
  echo "    $REAPPLY"
  guest "$REAPPLY"
  check_present "after the rebuild"

  step "removing the certificate"
  COMMANDS=$(writable_remove_commands)
  run_commands "$COMMANDS"
  confirm_guest_answers
  for store in "$SYSTEM_STORE" "$APEX_STORE"; do
    check_absent "$(shell_listing "$store/$STORE_NAME")" "$store/$STORE_NAME in the shell namespace"
  done
  check_absent "$(zygote_listing "$APEX_STORE/$STORE_NAME")" "$APEX_STORE/$STORE_NAME from zygote64"
  leftover=$(guest "test -d $SCRIPT_DIRECTORY && echo present" 2>/dev/null || true)
  case "$leftover" in
    *present*) fail "after removal: $SCRIPT_DIRECTORY still exists" ;;
  esac
  echo "    the entry is gone in every namespace checked, and so is $SCRIPT_DIRECTORY"

  echo
  echo "PASS: install, reboot, rebuild, verification and removal all behaved"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --ca) [ $# -ge 2 ] || fail "--ca needs a path"; CA=$2; shift 2 ;;
    --shape) [ $# -ge 2 ] || fail "--shape needs kernelSU or writable-system"; SHAPE=$2; shift 2 ;;
    --render-only) [ $# -ge 2 ] || fail "--render-only needs a directory"; RENDER_ONLY=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; fail "unknown argument: $1" ;;
  esac
done
case "$SHAPE" in
  kernelSU|writable-system) ;;
  *) usage; fail "unknown shape: $SHAPE" ;;
esac
[ -n "$CA" ] || { usage; fail "--ca is required"; }
[ -f "$CA" ] || fail "no certificate at $CA"
[ -f "$GUEST_SWIFT" ] && [ -f "$INJECTOR_SWIFT" ] && [ -f "$WRITABLE_SWIFT" ] \
  || fail "no capture sources under $ROOT/MandroidKit/Capture"
# The paths this script checks are the constants the injectors use, or the
# guards below would be comparing the render with a guess.
assert_constant "$GUEST_SWIFT" moduleDirectory "$MODULE_DIRECTORY"
assert_constant "$GUEST_SWIFT" systemStore "$SYSTEM_STORE"
assert_constant "$GUEST_SWIFT" apexStore "$APEX_STORE"
assert_constant "$WRITABLE_SWIFT" scriptDirectory "$SCRIPT_DIRECTORY"

hash=$(cert_hash "$CA")
[ -n "$hash" ] || fail "$CA is not a certificate that can be named in the store"
STORE_NAME="$hash.0"

if [ -n "$RENDER_ONLY" ]; then
  if [ "$SHAPE" = "kernelSU" ]; then
    step "rendering the module"
    render_module "$RENDER_ONLY"
    echo
    echo "PASS: module rendered (no device touched)"
  else
    step "rendering the staging directory and the procedure"
    render_staging "$RENDER_ONLY"
    echo
    writable_plan "/data/local/tmp/capture-ca-staging"
    echo
    echo "PASS: procedure rendered (no device touched)"
  fi
  exit 0
fi

step "checking the session"
check_device

if [ "$SHAPE" = "writable-system" ]; then
  run_writable_system
  exit 0
fi

STAGING="/data/local/tmp/capture-ca-$(date +%s)-$$"
LOCAL_MODULE=$(mktemp -d "${TMPDIR:-/tmp}/capture-ca.XXXXXX")
trap 'rm -r "$LOCAL_MODULE"' EXIT

step "staging the module as $STORE_NAME"
render_module "$LOCAL_MODULE"
"$ADB" push "$LOCAL_MODULE" "$STAGING"

step "installing into $MODULE_DIRECTORY"
COMMANDS=$(module_text "$INJECTOR_SWIFT" installCommands "staging=$STAGING" "fileName=$STORE_NAME" "module=$MODULE_DIRECTORY")
case "$COMMANDS" in
  *"cp $STAGING/* $MODULE_DIRECTORY/"*) ;;
  *) fail "the injector no longer copies the staged files into $MODULE_DIRECTORY" ;;
esac
case "$COMMANDS" in
  *"sh $MODULE_DIRECTORY/service.sh"*) ;;
  *) fail "the injector no longer runs $MODULE_DIRECTORY/service.sh" ;;
esac
case "$COMMANDS" in
  *"rm -r $STAGING"*) ;;
  *) fail "the injector no longer cleans up $STAGING" ;;
esac
run_commands "$COMMANDS"

step "checking the entry without a reboot"
check_present "after install"

step "rebooting"
reboot_session

step "checking the entry the module restored at boot"
check_present "after reboot"

step "removing the module"
REMOVE=$(module_text "$GUEST_SWIFT" removeScript "fileName=$STORE_NAME")
case "$REMOVE" in
  *"MODDIR=$MODULE_DIRECTORY"*) ;;
  *) fail "the removal script does not remove the module this script installed: $MODULE_DIRECTORY" ;;
esac
case "$REMOVE" in
  *"ENTRY=$MODULE_DIRECTORY/$STORE_NAME"*|*"ENTRY=\$MODDIR/$STORE_NAME"*) ;;
  *) fail "the removal script does not name the entry this script installed: $STORE_NAME" ;;
esac
case "$REMOVE" in
  *"STORE=$SYSTEM_STORE"*) ;;
  *) fail "the removal script does not unmount the store this script checks: $SYSTEM_STORE" ;;
esac
case "$REMOVE" in
  *"APEX_STORE=$APEX_STORE"*) ;;
  *) fail "the removal script does not unmount the store this script checks: $APEX_STORE" ;;
esac
guest "$REMOVE"
confirm_guest_answers
for store in "$SYSTEM_STORE" "$APEX_STORE"; do
  check_absent "$(shell_listing "$store/$STORE_NAME")" "$store/$STORE_NAME in the shell namespace"
done
check_absent "$(zygote_listing "$APEX_STORE/$STORE_NAME")" "$APEX_STORE/$STORE_NAME from zygote64"
leftover=$(guest "test -d $MODULE_DIRECTORY && echo present" 2>/dev/null || true)
case "$leftover" in
  *present*) fail "after removal: $MODULE_DIRECTORY still exists" ;;
esac
echo "    the store entry is gone in every namespace checked, and so is $MODULE_DIRECTORY"

echo
echo "PASS: install, reboot, verification and removal all behaved"
