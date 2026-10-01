#!/bin/sh
#
# verify-nono-toolchain.sh — prove the *running* Paperclip image ships the whole
# Nono Battle client toolchain, at exactly the versions /app/Dockerfile pins.
#
# The image is the deliverable, so this has to run inside the running container:
#
#   cd docker && docker compose up -d --build
#   docker compose exec -T server sh docker/verify-nono-toolchain.sh
#
# Read-only: it installs nothing, writes nothing outside its own temp file, and
# is safe to run repeatedly and concurrently. The default run is offline and
# takes roughly a second; `--full` adds the network-touching probes.
#
# Design notes that matter when editing this:
#
# - Every version assertion is checked against the *tool's own output*, not
#   against a path that merely exists. A toolchain that is installed but wrong is
#   the failure mode that costs an agent an afternoon.
# - SDK component versions come from each package's own `source.properties`
#   rather than from `sdkmanager --list_installed`, which needs the network. That
#   keeps the default run offline; `--full` still does the list_installed
#   cross-check.
# - The pins at the top of this file are compared against the `ARG` block of the
#   `mobile-toolchain` stage in the Dockerfile. Two hand-maintained copies of the
#   same number will drift; this makes the drift a FAIL instead.
# - `build-tools` binaries (aapt, zipalign, aidl) are dynamically linked against
#   `lib64/libc++.so` *inside their own package directory*. Copy the top-level
#   executables without `lib64/` and they install cleanly and then fail at build
#   time, so those runtime libs are asserted explicitly.
#
# Shell portability: POSIX `sh`, and it is checked with `dash`. No arrays, no
# `local`, no `${var//pat/rep}` — all three are bashisms that dash rejects, and
# the image's `/bin/sh` is dash.
#
# Exit status: 0 pass, 1 fail, 2 usage error. `--expect-fail` inverts 0 and 1.

set -eu

# --------------------------------------------------------------------- pins
# These must equal the ARGs of the `mobile-toolchain` stage in /app/Dockerfile.
# `check_pin` enforces that, so edit both or neither.
PIN_TEMURIN_RELEASE='17.0.20.1+1'
PIN_TEMURIN_VERSION='17.0.20.1_1'
PIN_CMDLINE_TOOLS='19.0'
PIN_CMDLINE_TOOLS_BUILD='13114758'
PIN_PLATFORM_TOOLS='37.0.1'
PIN_PLATFORM='android-36'
PIN_PLATFORM_API='36'
PIN_PLATFORM_REVISION='2'
PIN_BUILD_TOOLS='36.1.0'
PIN_AAPT2='2.20-14042983'
PIN_GRADLE='9.3.1'
PIN_FLUTTER='3.47.6'
PIN_LICENSE_FILES='7'

# ------------------------------------------------------------------ options
OPT_FULL=0
OPT_STRICT=0
OPT_EXPECT_FAIL=0
OPT_JSON=0
OPT_CHECK_PINS=1
OPT_TIMEOUT_SLOW=600
OPT_TIMEOUT_FAST=120
DOCKERFILE=''

usage() {
  cat <<'EOF'
Usage: sh verify-nono-toolchain.sh [options]

Asserts that the running Paperclip image contains the full Nono Battle client
toolchain at the versions pinned by the `mobile-toolchain` stage of the
Dockerfile. Read-only, offline by default, and idempotent.

Options:
  --full           Also run the slow, network-dependent probes
                   (`sdkmanager --list_installed`, `flutter doctor`).
  --strict         Treat WARN and SKIP as failures, and require version strings
                   to match their strict patterns rather than a substring.
  --expect-fail    Invert the verdict: exit 0 only if something failed. This is
                   the negative-test mode that proves the harness is not vacuous.
  --json           Print one JSON object after the table.
  --no-check-pins  Skip the cross-check of this file's pins against the ARG
                   block in the Dockerfile (use when running outside the image).
  --dockerfile P   Cross-check the pins against P instead of locating a
                   Dockerfile relative to this script. Implies the pin check is
                   wanted, so it also overrides --no-check-pins.
  --timeout N      Seconds allowed for the slow probes (default 600).
  -h, --help       This text.

Exit status: 0 pass, 1 fail, 2 usage error.
EOF
}

die_usage() {
  printf 'verify-nono-toolchain.sh: %s\n\n' "$1" >&2
  usage >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --full) OPT_FULL=1 ;;
    --strict) OPT_STRICT=1 ;;
    --expect-fail) OPT_EXPECT_FAIL=1 ;;
    --json) OPT_JSON=1 ;;
    --no-check-pins) OPT_CHECK_PINS=0 ;;
    --dockerfile)
      [ $# -ge 2 ] || die_usage '--dockerfile needs a path'
      DOCKERFILE="$2"
      OPT_CHECK_PINS=1
      shift
      ;;
    --timeout)
      [ $# -ge 2 ] || die_usage '--timeout needs a value'
      OPT_TIMEOUT_SLOW="$2"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) die_usage "unknown option: $1" ;;
  esac
  shift
done
[ $# -eq 0 ] || die_usage "unexpected argument: $1"

if [ "$OPT_STRICT" -eq 1 ]; then
  STRICT_LABEL=' (strict)'
else
  STRICT_LABEL=''
fi

# ------------------------------------------------------------------ helpers
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
SKIP_COUNT=0
OUT=''
RC=0

ROWS_DIR="${TMPDIR:-/tmp}/nono-toolchain-verify.$$"
mkdir -p "$ROWS_DIR"
ROWS_FILE="$ROWS_DIR/rows.tsv"
: > "$ROWS_FILE"
cleanup() { rm -rf "$ROWS_DIR"; }
trap cleanup EXIT HUP INT TERM

# Escape every ERE metacharacter. Used to build the strict patterns from the
# pins, so a pin can never be half-interpreted as a regular expression.
escape_ere() {
  printf '%s' "$1" | sed -e 's/[][\.^$*+?(){}|\\/]/\\&/g'
}

# Collapse multi-line tool output into a single table cell, so a banner line
# cannot break the TSV or the table alignment.
flatten() {
  printf '%s' "$1" | tr '\t\n' '  ' | tr -s ' ' | sed 's/^ *//; s/ *$//'
}

record() {
  # record STATUS ID DESCRIPTION DETAIL
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(flatten "$4")" >> "$ROWS_FILE"
  case "$1" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    WARN) WARN_COUNT=$((WARN_COUNT + 1)) ;;
    SKIP) SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
  esac
  # Immediate feedback only matters when a probe can take minutes; otherwise it
  # would just duplicate the summary table.
  if [ "$OPT_FULL" -eq 1 ]; then
    case "$1" in
      FAIL|WARN) printf '%s  %-34s %s\n' "$1" "$2" "$(flatten "$4")" ;;
    esac
  fi
}

pass() { record PASS "$1" "$2" "$3"; }
warn() { record WARN "$1" "$2" "$3"; }
skip() { record SKIP "$1" "$2" "$3"; }
fail() { record FAIL "$1" "$2" "$3"; }

# run / run_fast — capture merged stdout+stderr in OUT and status in RC. Never
# aborts the harness: a missing or broken tool is a row, not a script error.
run() {
  RC=0
  if command -v timeout >/dev/null 2>&1; then
    OUT="$(timeout "$OPT_TIMEOUT_SLOW" "$@" 2>&1)" || RC=$?
  else
    OUT="$("$@" 2>&1)" || RC=$?
  fi
}

run_fast() {
  RC=0
  if command -v timeout >/dev/null 2>&1; then
    OUT="$(timeout "$OPT_TIMEOUT_FAST" "$@" 2>&1)" || RC=$?
  else
    OUT="$("$@" 2>&1)" || RC=$?
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

first_line() {
  printf '%s\n' "$1" | sed -n '/[^[:space:]]/{p;q;}'
}

# prop FILE KEY — read a `KEY=value` line out of a properties file. Prints
# nothing when the file or the key is missing, so callers must handle empty.
prop() {
  [ -f "$1" ] || return 0
  sed -n "s/^[[:space:]]*$2=\(.*\)$/\1/p" "$1" | sed -n '1p'
}

# on_path DIR — is DIR an element of $PATH? Installed-but-not-on-PATH is the
# failure mode that bites an agent which spawns a clean shell, so it gets its own
# row rather than being inferred from a working `command -v`.
on_path() {
  _rest="$PATH"
  while [ -n "$_rest" ]; do
    case "$_rest" in
      *:*) _on_path_elem="${_rest%%:*}"; _rest="${_rest#*:}" ;;
      *) _on_path_elem="$_rest"; _rest='' ;;
    esac
    if [ "$_on_path_elem" = "$1" ]; then
      return 0
    fi
  done
  return 1
}

# check_version ID DESCRIPTION NEEDLE [STRICT_REGEX]
# NEEDLE must appear in the merged output. Under --strict, STRICT_REGEX must also
# match a line, which is what catches `17.0.20.10` satisfying a naive substring
# test for `17.0.20.1`.
check_version() {
  _cv_id="$1"
  _cv_desc="$2"
  _cv_needle="$3"
  _cv_strict="${4:-}"
  if [ -z "$OUT" ]; then
    fail "$_cv_id" "$_cv_desc" 'command produced no output'
    return 0
  fi
  # Match against a horizontally-whitespace-squeezed copy. Tools align their
  # output in columns: Gradle prints `Launcher JVM:  17.0.20.1` with two spaces
  # and one with `Daemon JVM:  17.0.20.1`, and a needle written by hand against
  # the wrong one fails forever. Newlines are preserved so the strict patterns
  # can still anchor with ^.
  _cv_target="$(printf '%s\n' "$OUT" | tr -s '[:blank:]' ' ')"
  if ! printf '%s\n' "$_cv_target" | grep -qF -- "$_cv_needle"; then
    fail "$_cv_id" "$_cv_desc" \
      "expected to contain '$_cv_needle', got (exit=$RC): $(first_line "$OUT")"
    return 0
  fi
  if [ "$OPT_STRICT" -eq 1 ] && [ -n "$_cv_strict" ]; then
    if ! printf '%s\n' "$_cv_target" | grep -Eq -- "$_cv_strict"; then
      fail "$_cv_id" "$_cv_desc" "strict pattern '$_cv_strict' did not match: $(first_line "$OUT")"
      return 0
    fi
  fi
  pass "$_cv_id" "$_cv_desc" "$(first_line "$OUT")"
}

# check_prop ID DESCRIPTION FILE KEY EXPECTED
# The offline equivalent of a version check, for SDK packages that ship their
# revision in `source.properties`.
check_prop() {
  _cp_id="$1"
  _cp_desc="$2"
  _cp_file="$3"
  _cp_key="$4"
  _cp_want="$5"
  if [ ! -f "$_cp_file" ]; then
    fail "$_cp_id" "$_cp_desc" "missing $_cp_file"
    return 0
  fi
  _cp_got="$(prop "$_cp_file" "$_cp_key")"
  if [ "$_cp_got" = "$_cp_want" ]; then
    pass "$_cp_id" "$_cp_desc" "$_cp_key=$_cp_got"
  else
    fail "$_cp_id" "$_cp_desc" \
      "$_cp_key=${_cp_got:-<none>} in $_cp_file, expected $_cp_want"
  fi
}

# The JDK's feature version, derived rather than hand-copied: Temurin reports
# `17.0.20.1+1` in its distribution string and `17.0.20.1` in `java -version`,
# and the two have to be the same build.
# `%+*` strips the shortest `+...` suffix, unlike `%.*` which matches the empty
# string and therefore strips nothing.
PIN_TEMURIN_FEATURE="${PIN_TEMURIN_RELEASE%+*}"

ESC_TEMURIN="$(escape_ere "$PIN_TEMURIN_RELEASE")"
ESC_TEMURIN_FEATURE="$(escape_ere "$PIN_TEMURIN_FEATURE")"
ESC_CMDLINE_TOOLS="$(escape_ere "$PIN_CMDLINE_TOOLS")"
ESC_PLATFORM_TOOLS="$(escape_ere "$PIN_PLATFORM_TOOLS")"
ESC_GRADLE="$(escape_ere "$PIN_GRADLE")"
ESC_FLUTTER="$(escape_ere "$PIN_FLUTTER")"
ESC_AAPT2="$(escape_ere "$PIN_AAPT2")"

# ------------------------------------------------------------------ banners
printf '=== Nono Battle toolchain verification ===\n'
printf 'host        : %s %s\n' "$(uname -s 2>/dev/null || echo unknown)" "$(uname -m 2>/dev/null || echo unknown)"
printf 'user        : %s\n' "$(id -un 2>/dev/null || echo unknown)"
printf 'image build : %s %s\n' "${PAPERCLIP_BUILD_VERSION:-unknown}" "${PAPERCLIP_BUILD_COMMIT:-unknown}"
printf 'pinned      : JDK %s | cmdline-tools %s | platform-tools %s | %s (API %s r%s) | build-tools %s | gradle %s | flutter %s\n' \
  "$PIN_TEMURIN_RELEASE" "$PIN_CMDLINE_TOOLS" "$PIN_PLATFORM_TOOLS" \
  "$PIN_PLATFORM" "$PIN_PLATFORM_API" "$PIN_PLATFORM_REVISION" \
  "$PIN_BUILD_TOOLS" "$PIN_GRADLE" "$PIN_FLUTTER"
printf 'modes       : full=%s strict=%s expect_fail=%s\n\n' "$OPT_FULL" "$OPT_STRICT" "$OPT_EXPECT_FAIL"

# --------------------------------------------------------------- environment
JAVA_HOME="${JAVA_HOME:-}"
ANDROID_HOME="${ANDROID_HOME:-}"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-}"
FLUTTER_ROOT="${FLUTTER_ROOT:-}"
GRADLE_HOME="${GRADLE_HOME:-}"

check_env() {
  if [ -z "$2" ]; then
    fail "env:$1" "$1 is set and non-empty" 'UNSET'
  elif [ ! -d "$2" ]; then
    fail "env:$1" "$1 points at a real directory" "$2 (missing)"
  else
    pass "env:$1" "$1 is set and non-empty" "$2"
  fi
}

check_env JAVA_HOME "$JAVA_HOME"
check_env ANDROID_HOME "$ANDROID_HOME"
check_env ANDROID_SDK_ROOT "$ANDROID_SDK_ROOT"
check_env FLUTTER_ROOT "$FLUTTER_ROOT"
check_env GRADLE_HOME "$GRADLE_HOME"

if [ -n "$ANDROID_HOME" ] && [ -n "$ANDROID_SDK_ROOT" ]; then
  if [ "$ANDROID_HOME" = "$ANDROID_SDK_ROOT" ]; then
    pass 'env:ANDROID_HOME==ANDROID_SDK_ROOT' 'the two SDK variables agree' "$ANDROID_HOME"
  else
    fail 'env:ANDROID_HOME==ANDROID_SDK_ROOT' 'the two SDK variables agree' \
      "ANDROID_HOME=$ANDROID_HOME ANDROID_SDK_ROOT=$ANDROID_SDK_ROOT"
  fi
fi

# check_path_dir ID ENV_VAR_NAME DIR
# The ID is a stable short label rather than the full path, so the table stays
# readable and the row keeps the same identity across images. A row is skipped
# when its variable is unset rather than checked against a placeholder path: the
# matching `env:` row already reports that, and a row naming `/nonexistent/bin`
# would only send an operator looking for a directory nobody ever created.
check_path_dir() {
  if [ -z "$3" ]; then
    skip "path:$1" 'toolchain directory is on PATH' \
      "$2 is unset; see the env:$2 row"
  elif on_path "$3"; then
    pass "path:$1" 'toolchain directory is on PATH' "$3"
  else
    fail "path:$1" 'toolchain directory is on PATH' "absent from PATH: $3"
  fi
}

check_path_dir 'jdk/bin' JAVA_HOME "${JAVA_HOME:+$JAVA_HOME/bin}"
check_path_dir 'cmdline-tools/latest/bin' ANDROID_HOME \
  "${ANDROID_HOME:+$ANDROID_HOME/cmdline-tools/latest/bin}"
check_path_dir 'platform-tools' ANDROID_HOME "${ANDROID_HOME:+$ANDROID_HOME/platform-tools}"
check_path_dir 'build-tools/current' ANDROID_HOME "${ANDROID_HOME:+$ANDROID_HOME/build-tools/current}"
check_path_dir 'gradle/current/bin' GRADLE_HOME "${GRADLE_HOME:+$GRADLE_HOME/bin}"
check_path_dir 'flutter/bin' FLUTTER_ROOT "${FLUTTER_ROOT:+$FLUTTER_ROOT/bin}"

# ------------------------------------------------------------------ binaries
require_binary() {
  if have "$1"; then
    pass "binary:$1" "$2" "$(command -v "$1")"
  else
    fail "binary:$1" "$2" 'not found on PATH'
  fi
}

require_binary java 'JDK runtime'
require_binary javac 'JDK compiler'
require_binary jar 'JDK archiver'
require_binary keytool 'JDK keytool / signing'
require_binary sdkmanager 'Android SDK package manager'
require_binary avdmanager 'Android SDK AVD manager'
require_binary apkanalyzer 'Android SDK static analyzer'
require_binary adb 'Android Debug Bridge'
require_binary fastboot 'Android fastboot'
require_binary aapt 'build-tools resource compiler'
require_binary aapt2 'build-tools resource compiler (AAPT2)'
require_binary aidl 'build-tools AIDL compiler'
require_binary apksigner 'build-tools APK signer'
require_binary d8 'dexer'
require_binary dexdump 'dex dumper'
require_binary split-select 'build-tools split selector'
require_binary zipalign 'build-tools zipalign'
require_binary gradle 'Gradle'
require_binary flutter 'Flutter SDK'
require_binary dart 'Dart SDK'
require_binary unzip 'unzip (flutter and AGP shell out to it)'
require_binary git 'git (flutter reads its own version from the SDK checkout)'

# `emulator` is deliberately absent: it is a ~350 MB download that needs KVM, and
# nothing in the mobile client build path uses it. Asserting the absence is still
# worth it, so that "someone added the emulator image" reads as a deliberate,
# visible change instead of a silent multi-hundred-megabyte diff.
if have emulator; then
  warn 'binary:emulator' 'emulator absent by design' "present at $(command -v emulator)"
else
  pass 'binary:emulator' 'emulator absent by design' 'not installed (expected)'
fi

# ------------------------------------------------------------------ versions
if have java; then
  run_fast java -version
  check_version 'version:java' 'JDK runtime version' "$PIN_TEMURIN_FEATURE" \
    "^openjdk version \"$ESC_TEMURIN_FEATURE\""
  # Catches a distro openjdk swap that happens to be the same feature version:
  # the pins name Temurin specifically, and Temurin is what AGP is tested on.
  check_version 'version:java-vendor' 'JDK is Temurin, not a distro build' \
    "Temurin-$PIN_TEMURIN_RELEASE" "Temurin-$ESC_TEMURIN"
fi

if have javac; then
  run_fast javac -version
  check_version 'version:javac' 'JDK compiler version' "javac $PIN_TEMURIN_FEATURE" \
    "^javac $ESC_TEMURIN_FEATURE$"
  if [ -n "$JAVA_HOME" ]; then
    _javac_path="$(command -v javac)"
    case "$_javac_path" in
      "$JAVA_HOME"/*)
        pass 'version:javac-in-JAVA_HOME' 'javac is the JDK named by JAVA_HOME' "$_javac_path" ;;
      *)
        fail 'version:javac-in-JAVA_HOME' 'javac is the JDK named by JAVA_HOME' \
          "$_javac_path is outside $JAVA_HOME" ;;
    esac
  fi
fi

if have sdkmanager; then
  run sdkmanager --version
  check_version 'version:sdkmanager' "cmdline-tools is $PIN_CMDLINE_TOOLS" \
    "$PIN_CMDLINE_TOOLS" "^${ESC_CMDLINE_TOOLS}$"
fi

if [ -n "$ANDROID_HOME" ]; then
  # Independent, offline confirmation of the cmdline-tools pin: the package
  # ships its own revision, so a half-extracted or wrong-version install is
  # caught even if a stray `sdkmanager` on PATH answers first.
  check_prop 'version:cmdline-tools-pkg' "cmdline-tools package is $PIN_CMDLINE_TOOLS" \
    "$ANDROID_HOME/cmdline-tools/latest/source.properties" Pkg.Revision "$PIN_CMDLINE_TOOLS"

  check_prop 'version:platform-tools' "platform-tools is $PIN_PLATFORM_TOOLS" \
    "$ANDROID_HOME/platform-tools/source.properties" Pkg.Revision "$PIN_PLATFORM_TOOLS"

  if have adb; then
    run_fast adb version
    check_version 'version:adb' "adb is $PIN_PLATFORM_TOOLS" \
      "Version $PIN_PLATFORM_TOOLS-" "Version ${ESC_PLATFORM_TOOLS}-"
  fi
  if have fastboot; then
    run_fast fastboot --version
    check_version 'version:fastboot' "fastboot is $PIN_PLATFORM_TOOLS" \
      "version $PIN_PLATFORM_TOOLS-" "^fastboot version ${ESC_PLATFORM_TOOLS}-"
  fi

  _bt_dir="$ANDROID_HOME/build-tools/$PIN_BUILD_TOOLS"
  check_prop 'version:build-tools' "build-tools is $PIN_BUILD_TOOLS" \
    "$_bt_dir/source.properties" Pkg.Revision "$PIN_BUILD_TOOLS"

  # `current` is what the image puts on PATH, so a dangling or stale symlink is
  # invisible to every other row in this file.
  if [ -L "$ANDROID_HOME/build-tools/current" ]; then
    _bt_link="$(readlink "$ANDROID_HOME/build-tools/current")"
    case "$_bt_link" in
      *"$PIN_BUILD_TOOLS"*)
        pass 'symlink:build-tools/current' 'build-tools/current points at the pinned revision' "$_bt_link" ;;
      *)
        fail 'symlink:build-tools/current' 'build-tools/current points at the pinned revision' \
          "-> $_bt_link" ;;
    esac
  else
    fail 'symlink:build-tools/current' 'build-tools/current points at the pinned revision' \
      'missing or not a symlink'
  fi

  # aapt, zipalign and aidl link against libc++.so from their own lib64/, and d8
  # and apksigner are shell wrappers around jars in lib/. A build-tools tree
  # assembled without those directories installs cleanly and then fails with
  # "error while loading shared libraries" on the first real build.
  for _lib in lib64/libc++.so lib/d8.jar lib/apksigner.jar; do
    if [ -f "$_bt_dir/$_lib" ]; then
      pass "buildtools:$_lib" 'build-tools ships the runtime libs its binaries need' "$_bt_dir/$_lib"
    else
      fail "buildtools:$_lib" 'build-tools ships the runtime libs its binaries need' \
        "missing $_bt_dir/$_lib"
    fi
  done

  if have aapt2; then
    run_fast aapt2 version
    check_version 'version:aapt2' "aapt2 from build-tools $PIN_BUILD_TOOLS" \
      'Android Asset Packaging Tool (aapt)' "Android Asset Packaging Tool \(aapt\) ${ESC_AAPT2}"
  fi

  _plat_dir="$ANDROID_HOME/platforms/$PIN_PLATFORM"
  if [ -d "$_plat_dir" ]; then
    pass "platform:dir:$PIN_PLATFORM" "platform $PIN_PLATFORM is installed" "$_plat_dir"
  else
    fail "platform:dir:$PIN_PLATFORM" "platform $PIN_PLATFORM is installed" "missing $_plat_dir"
  fi
  check_prop 'version:platform-api' "platform API level is $PIN_PLATFORM_API" \
    "$_plat_dir/source.properties" AndroidVersion.ApiLevel "$PIN_PLATFORM_API"
  check_prop 'version:platform-revision' "platform revision is $PIN_PLATFORM_REVISION" \
    "$_plat_dir/source.properties" Pkg.Revision "$PIN_PLATFORM_REVISION"
  # android.jar is the compile classpath. Its absence is the failure a client
  # actually hits, and the platform directory existing does not imply it does.
  if [ -f "$_plat_dir/android.jar" ]; then
    pass 'platform:android.jar' 'compile classpath jar is present' "$_plat_dir/android.jar"
  else
    fail 'platform:android.jar' 'compile classpath jar is present' "missing $_plat_dir/android.jar"
  fi
fi

if have gradle; then
  run_fast gradle --version
  check_version 'version:gradle' "Gradle is $PIN_GRADLE" \
    "Gradle $PIN_GRADLE" "^Gradle ${ESC_GRADLE}$"
  # A second JDK earlier on PATH would make `gradle` run on something other than
  # JAVA_HOME while `java` still reports the pinned version. Check the JVM Gradle
  # actually launched, not the one on PATH.
  check_version 'version:gradle-jvm' 'Gradle launches on the pinned JDK' \
    'Launcher JVM: 17.0.20.1' '^Launcher JVM: 17\.0\.20\.1'
fi

if [ -n "$GRADLE_HOME" ]; then
  # The image sets GRADLE_HOME=/opt/gradle/current, where `current` is a symlink
  # to the pinned version. Asserting the literal env value would therefore
  # always fail, so resolve it and check where it actually lands.
  if [ ! -d "$GRADLE_HOME" ]; then
    fail 'symlink:gradle/current' 'GRADLE_HOME resolves to the pinned Gradle' \
      "$GRADLE_HOME is missing or not a directory"
  else
    _gradle_resolved="$(readlink -f "$GRADLE_HOME" 2>/dev/null || printf '%s' "$GRADLE_HOME")"
    case "$_gradle_resolved" in
      */gradle-"$PIN_GRADLE")
        pass 'symlink:gradle/current' 'GRADLE_HOME resolves to the pinned Gradle' "$_gradle_resolved" ;;
      *)
        fail 'symlink:gradle/current' 'GRADLE_HOME resolves to the pinned Gradle' \
          "$GRADLE_HOME resolves to $_gradle_resolved, expected a path ending in gradle-$PIN_GRADLE" ;;
    esac
  fi
fi

if have flutter; then
  run flutter --version
  check_version 'version:flutter' "Flutter is $PIN_FLUTTER" \
    "Flutter $PIN_FLUTTER" "^Flutter ${ESC_FLUTTER}( |$)"
fi
if [ -n "$FLUTTER_ROOT" ] && [ -f "$FLUTTER_ROOT/version" ]; then
  _flutter_file="$(sed -n '1p' "$FLUTTER_ROOT/version")"
  if [ "$_flutter_file" = "$PIN_FLUTTER" ]; then
    pass 'version:flutter-file' "FLUTTER_ROOT/version is $PIN_FLUTTER" "$_flutter_file"
  else
    fail 'version:flutter-file' "FLUTTER_ROOT/version is $PIN_FLUTTER" "got '$_flutter_file'"
  fi
fi

# ------------------------------------------------------------------ licenses
# The most common way a hand-built SDK becomes a broken dev loop: with no
# accepted licenses every sdkmanager and AGP call blocks on a stdin prompt, which
# in a non-interactive agent run looks like a hang with no error.
if [ -n "$ANDROID_HOME" ]; then
  _lic_dir="$ANDROID_HOME/licenses"
  if [ -d "$_lic_dir" ]; then
    pass 'licenses:dir' 'SDK license directory exists' "$_lic_dir"
  else
    fail 'licenses:dir' 'SDK license directory exists' "missing $_lic_dir"
  fi
  _accepted=0
  for _lic in android-sdk-license android-sdk-preview-license android-sdk-arm-dbt-license \
    google-gdk-license android-googletv-license android-googlexr-license mips-android-sysimage-license
  do
    if [ -s "$_lic_dir/$_lic" ]; then
      _accepted=$((_accepted + 1))
    else
      fail "licenses:$_lic" 'SDK license accepted at build time' "missing or empty: $_lic_dir/$_lic"
    fi
  done
  if [ "$_accepted" -eq "$PIN_LICENSE_FILES" ]; then
    pass 'licenses:accepted' "all $PIN_LICENSE_FILES SDK licenses accepted" \
      "$_accepted/$PIN_LICENSE_FILES non-empty"
  else
    fail 'licenses:accepted' "all $PIN_LICENSE_FILES SDK licenses accepted" \
      "$_accepted/$PIN_LICENSE_FILES non-empty"
  fi
fi

# --------------------------------------------------------------- writability
# `sdkmanager --install` and AGP's auto-provisioning write into the SDK, and
# flutter writes into its artifact cache on every invocation. A root-owned tree
# fails with EACCES only once a client build is already running.
check_writable() {
  if [ ! -d "$3" ]; then
    skip "$1" "$2" "absent: $3"
  elif [ -w "$3" ]; then
    pass "$1" "$2" "$3"
  else
    fail "$1" "$2" "not writable by $(id -un 2>/dev/null || echo '?')"
  fi
}

check_writable 'sdk:writable' 'ANDROID_HOME is writable by the invoking user' "$ANDROID_HOME"
check_writable 'gradle:writable' 'GRADLE_HOME is writable by the invoking user' "$GRADLE_HOME"
check_writable 'flutter:cache-writable' "flutter's artifact cache is writable" \
  "${FLUTTER_ROOT:-/nonexistent}/bin/cache"

# --------------------------------------------------------------------- rust
# Deliberately does not assert `cargo`: `rust-toolchain` is an ancestor of the
# `build` stage only and `production` is `FROM base`, so the runtime image ships
# the compiled runner and no Rust toolchain. Asserting cargo would be a false
# failure; asserting the compiled binary is the real regression guard.
if have cargo; then
  run_fast cargo --version
  pass 'rust:cargo' 'cargo present (not required by the production image)' "$(first_line "$OUT")"
else
  skip 'rust:cargo' 'build-stage only, not in the production image' 'absent (expected)'
fi

_runner_found=''
for _candidate in \
  /app/server/dist/vendor/paperclip-runner/bin/paperclip-runnerd \
  /app/packages/paperclip-runner/dist/bin/paperclip-runnerd
do
  if [ -x "$_candidate" ]; then
    _runner_found="$_candidate"
    break
  fi
done
if [ -n "$_runner_found" ]; then
  pass 'rust:runnerd-binary' 'compiled runner present and executable' "$_runner_found"
else
  fail 'rust:runnerd-binary' 'compiled runner present and executable' \
    'not found in server/dist/vendor or packages/paperclip-runner/dist'
fi

# -------------------------------------------------------------- pin agreement
find_dockerfile() {
  _self_dir=''
  if [ -n "${0:-}" ] && [ "$0" != 'sh' ]; then
    _self_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)" || _self_dir=''
  fi
  for _cand in \
    "${_self_dir:-/nonexistent}/../Dockerfile" \
    "${_self_dir:-/nonexistent}/Dockerfile" \
    /app/Dockerfile \
    ./Dockerfile
  do
    if [ -f "$_cand" ]; then
      printf '%s' "$_cand"
      return 0
    fi
  done
  return 1
}

# Read `ARG NAME=value` from the `mobile-toolchain` stage only. Matching against
# the whole file would let an unrelated ARG of the same name elsewhere satisfy
# the check.
dockerfile_arg() {
  [ -n "$DOCKERFILE" ] || return 0
  sed -n '/^FROM .* AS mobile-toolchain$/,/^FROM /p' "$DOCKERFILE" \
    | sed -n "s/^ARG[[:space:]]\{1,\}$1=\(.*\)$/\1/p" \
    | sed -n '1p'
}

check_pin() {
  if [ -z "$DOCKERFILE" ]; then
    skip "pin:$1" "Dockerfile ARG $1 matches this script" \
      'no Dockerfile found; pass --no-check-pins to silence'
    return 0
  fi
  _pin_actual="$(dockerfile_arg "$1")"
  if [ -z "$_pin_actual" ]; then
    fail "pin:$1" "Dockerfile ARG $1 matches this script" \
      "ARG $1 not found in the mobile-toolchain stage of $DOCKERFILE"
  elif [ "$_pin_actual" = "$2" ]; then
    pass "pin:$1" "Dockerfile ARG $1 matches this script" "$_pin_actual"
  else
    fail "pin:$1" "Dockerfile ARG $1 matches this script" \
      "Dockerfile=$_pin_actual this_script=$2"
  fi
}

if [ "$OPT_CHECK_PINS" -eq 1 ]; then
  # An explicit --dockerfile wins over discovery, so the caller can point the
  # cross-check at a specific checkout instead of whatever sits next to this
  # script.
  if [ -z "$DOCKERFILE" ]; then
    DOCKERFILE="$(find_dockerfile || true)"
  fi
  if [ -n "$DOCKERFILE" ]; then
    pass 'pin:dockerfile' 'Dockerfile located for the pin cross-check' "$DOCKERFILE"
  else
    skip 'pin:dockerfile' 'Dockerfile located for the pin cross-check' \
      'not found; are you running outside the image?'
  fi
  check_pin TEMURIN_RELEASE "$PIN_TEMURIN_RELEASE"
  check_pin TEMURIN_VERSION "$PIN_TEMURIN_VERSION"
  check_pin ANDROID_CMDLINE_TOOLS_BUILD "$PIN_CMDLINE_TOOLS_BUILD"
  check_pin ANDROID_SDK_PLATFORM "$PIN_PLATFORM"
  check_pin ANDROID_BUILD_TOOLS "$PIN_BUILD_TOOLS"
  check_pin GRADLE_VERSION "$PIN_GRADLE"
  check_pin FLUTTER_VERSION "$PIN_FLUTTER"

  # The ENV block is what an agent actually inherits, so its literals are part of
  # the contract even though no ARG feeds them. Strip a leading `ENV ` first:
  # the Dockerfile spells these as `ENV JAVA_HOME=/opt/jdk \`, not as a bare
  # assignment, and a pattern anchored at the start of the line silently matches
  # nothing at all.
  check_env_pin() {
    _cep_live="$2"
    _cep_found="$(sed -e 's/^[[:space:]]*ENV[[:space:]]\{1,\}//' "$DOCKERFILE" \
      | sed -n "s/^[[:space:]]*$1=\([^[:space:]]*\).*$/\1/p" \
      | sed -n '1p')"
    if [ -z "$_cep_found" ]; then
      skip "pin:ENV.$1" "Dockerfile ENV $1 matches the live value" \
        "ENV $1 not found in $DOCKERFILE"
    elif [ -z "$_cep_live" ]; then
      skip "pin:ENV.$1" "Dockerfile ENV $1 matches the live value" \
        "live value is unset; see the env:$1 row"
    elif [ "$_cep_found" = "$_cep_live" ]; then
      pass "pin:ENV.$1" "Dockerfile ENV $1 matches the live value" "$_cep_found"
    else
      fail "pin:ENV.$1" "Dockerfile ENV $1 matches the live value" \
        "Dockerfile=$_cep_found live=$_cep_live"
    fi
  }
  for _cep_var in JAVA_HOME ANDROID_HOME ANDROID_SDK_ROOT FLUTTER_ROOT GRADLE_HOME; do
    eval "_cep_value=\${$_cep_var:-}"
    check_env_pin "$_cep_var" "$_cep_value"
  done
fi

# ------------------------------------------------------------ informational
# d8 exists twice in the image: cmdline-tools ships one and build-tools ships
# another. PATH puts cmdline-tools first, so the resolved path is reported rather
# than asserted — both are legitimate dexers and a future reordering is not a
# defect worth failing a build over.
if have d8; then
  pass 'binary:d8-resolves-to' 'which d8 PATH selects (informational)' "$(command -v d8)"
fi

# -------------------------------------------------------------------- --full
if [ "$OPT_FULL" -eq 1 ]; then
  if have sdkmanager; then
    run sdkmanager --list_installed
    if printf '%s\n' "$OUT" | grep -q 'platform-tools'; then
      pass 'full:sdkmanager-list' 'sdkmanager lists the installed packages' \
        "$(printf '%s\n' "$OUT" | grep -c '|' || true) package lines"
    else
      fail 'full:sdkmanager-list' 'sdkmanager lists the installed packages' \
        "no platform-tools row in: $(first_line "$OUT")"
    fi
  fi
  if have flutter; then
    # This is the row that catches a well-meaning bump to the newest
    # cmdline-tools: from 20.0 on, sdkmanager is a shim over the new `android`
    # CLI and `flutter doctor` reports "Android license status unknown" instead
    # of reading the pre-accepted license files, which breaks every build.
    run flutter doctor -v
    if printf '%s\n' "$OUT" | grep -qi 'All Android licenses accepted'; then
      pass 'full:flutter-doctor-licenses' 'flutter sees the pre-accepted Android licenses' \
        'All Android licenses accepted'
    elif printf '%s\n' "$OUT" | grep -qi 'Android license status unknown'; then
      fail 'full:flutter-doctor-licenses' 'flutter sees the pre-accepted Android licenses' \
        'Android license status unknown: cmdline-tools is too new (20.0+ replaces sdkmanager)'
    else
      warn 'full:flutter-doctor-licenses' 'flutter sees the pre-accepted Android licenses' \
        "$(first_line "$OUT")"
    fi
  fi
else
  skip 'full:probes' 'network-dependent probes' 'not run (pass --full)'
fi

# ------------------------------------------------------------------- summary
if [ "$OPT_STRICT" -eq 1 ]; then
  NONZERO=$((FAIL_COUNT + WARN_COUNT + SKIP_COUNT))
else
  NONZERO=$FAIL_COUNT
fi

printf '\n'
printf -- '----------------------------------------------------------------------\n'
while IFS='	' read -r _row_status _row_id _row_desc _row_detail; do
  printf '%-4s  %-34s  %s\n' "$_row_status" "$_row_id" "$_row_desc"
  case "$_row_status" in
    FAIL|WARN) printf '      %s\n' "$_row_detail" ;;
  esac
done < "$ROWS_FILE"
printf -- '----------------------------------------------------------------------\n'
printf 'PASS=%s FAIL=%s WARN=%s SKIP=%s%s\n' \
  "$PASS_COUNT" "$FAIL_COUNT" "$WARN_COUNT" "$SKIP_COUNT" "$STRICT_LABEL"

if [ "$OPT_JSON" -eq 1 ]; then
  json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
  if [ "$NONZERO" -eq 0 ]; then
    _verdict='PASS'
  else
    _verdict='FAIL'
  fi
  printf '{"result":"%s","pass":%s,"fail":%s,"warn":%s,"skip":%s,"strict":%s,"full":%s,"expectFail":%s,"pins":{"temurin":"%s","cmdlineTools":"%s","platformTools":"%s","platform":"%s","buildTools":"%s","gradle":"%s","flutter":"%s"},"rows":[' \
    "$_verdict" "$PASS_COUNT" "$FAIL_COUNT" "$WARN_COUNT" "$SKIP_COUNT" \
    "$OPT_STRICT" "$OPT_FULL" "$OPT_EXPECT_FAIL" \
    "$PIN_TEMURIN_RELEASE" "$PIN_CMDLINE_TOOLS" "$PIN_PLATFORM_TOOLS" \
    "$PIN_PLATFORM" "$PIN_BUILD_TOOLS" "$PIN_GRADLE" "$PIN_FLUTTER"
  _json_first=1
  while IFS='	' read -r _row_status _row_id _row_desc _row_detail; do
    if [ "$_json_first" -eq 1 ]; then
      _json_first=0
    else
      printf ','
    fi
    printf '{"status":"%s","id":"%s","description":"%s","detail":"%s"}' \
      "$_row_status" "$(json_escape "$_row_id")" "$(json_escape "$_row_desc")" \
      "$(json_escape "$_row_detail")"
  done < "$ROWS_FILE"
  printf ']}\n'
fi

if [ "$NONZERO" -ne 0 ] && [ -d "${ANDROID_HOME:-/nonexistent}" ]; then
  # A completely empty toolchain is almost always the documented escape hatch
  # rather than a broken image, so name it instead of leaving 60 identical rows.
  if [ ! -e "${ANDROID_HOME:-/nonexistent}/platform-tools" ] \
    && [ ! -e "${JAVA_HOME:-/nonexistent}/bin/java" ]; then
    printf '\nHINT: the toolchain trees are empty, which is exactly what\n'
    printf '      --build-arg WITH_MOBILE_TOOLCHAIN=0 produces. Rebuild without\n'
    printf '      that build arg if you expected the mobile toolchain.\n'
  fi
fi

if [ "$OPT_EXPECT_FAIL" -eq 1 ]; then
  if [ "$NONZERO" -ne 0 ]; then
    printf 'NEGATIVE TEST OK: harness detected %s failure(s) as expected.\n' "$FAIL_COUNT"
    exit 0
  fi
  printf 'NEGATIVE TEST FAILED: harness reported no failures, so it detects nothing.\n'
  exit 1
fi

if [ "$NONZERO" -eq 0 ]; then
  printf 'RESULT: PASS\n'
  exit 0
fi
printf 'RESULT: FAIL\n'
exit 1
