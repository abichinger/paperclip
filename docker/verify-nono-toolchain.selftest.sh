#!/bin/sh
#
# verify-nono-toolchain.selftest.sh — prove verify-nono-toolchain.sh actually
# detects things, without needing Docker or the built image.
#
# A verification harness that cannot fail is worse than no harness. This builds a
# throwaway toolchain tree that mirrors the real `/opt` layout, with stub
# binaries that print the exact version strings the real tools print, and then
# runs the harness against it eleven times: once healthy, and ten times with a
# specific fault injected. Each case asserts both the exit status and a marker
# row, so a harness that silently stopped checking something fails here.
#
# The version strings below are not invented. They were captured from the real
# artifacts whose SHA-1s match Google's own repository2-1.xml:
#   build-tools 36.1.0, platform-tools 37.0.1, cmdline-tools 19.0, Temurin
#   17.0.20.1+1. Only the JDK and Gradle lines are hand-shaped, from their
#   documented output formats.
#
# Nothing outside $TMPDIR is written. Safe to run repeatedly, concurrently, and
# on a developer machine or in CI.
#
# Usage: sh verify-nono-toolchain.selftest.sh [--keep] [case-name-substring]
#   --keep   leave the stub tree on disk and print its path
#
# Exit status: 0 when every case behaves as specified, 1 otherwise.

set -eu

SELFTEST_KEEP=0
SELFTEST_FILTER=''
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) SELFTEST_KEEP=1 ;;
    -h|--help)
      cat <<'EOF'
Usage: sh verify-nono-toolchain.selftest.sh [--keep] [case-name-substring]

Builds a throwaway toolchain tree that mirrors the real /opt layout, with stub
binaries that print the version strings the real tools print, then runs the
harness once healthy and ten more times with one specific fault injected. Each
case asserts both the exit status and a marker row.

  --keep   leave the stub tree on disk and print its path
  <arg>    run only the cases whose name contains <arg>

Exit status: 0 when every case behaves as specified, 1 otherwise.
EOF
      exit 0
      ;;
    *) SELFTEST_FILTER="$1" ;;
  esac
  shift
done

SELFTEST_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
HARNESS="$SELFTEST_DIR/verify-nono-toolchain.sh"
REPO_DOCKERFILE="$SELFTEST_DIR/../Dockerfile"

[ -f "$HARNESS" ] || { printf 'missing harness: %s\n' "$HARNESS" >&2; exit 1; }
[ -f "$REPO_DOCKERFILE" ] || { printf 'missing Dockerfile: %s\n' "$REPO_DOCKERFILE" >&2; exit 1; }

# Prefer dash over /bin/sh. The image's /bin/sh already is dash, but a developer
# machine's may be bash, and then the positive case would silently stop proving
# POSIX compliance. bash is still checked separately below.
if command -v dash >/dev/null 2>&1; then
  SH=dash
else
  SH=sh
  printf 'note: dash not found; falling back to %s, which may be bash\n' "$SH"
fi

STUB="${TMPDIR:-/tmp}/nono-toolchain-selftest.$$"
rm -rf "$STUB"
mkdir -p "$STUB"
cleanup() {
  if [ "$SELFTEST_KEEP" -eq 1 ]; then
    printf 'stub tree kept at %s\n' "$STUB"
  else
    rm -rf "$STUB"
  fi
}
trap cleanup EXIT HUP INT TERM

JDK="$STUB/jdk"
SDK="$STUB/android-sdk"
GRADLE="$STUB/gradle"
FLUTTER="$STUB/flutter"
STUB_BIN="$STUB/usr-bin"

# stub PATH BODY — an executable at PATH that prints BODY. No stub body contains
# a `$`, so the heredoc needs no quoting gymnastics.
stub() {
  _s_path="$1"
  _s_body="$2"
  cat > "$_s_path" <<STUBEOF
#!/bin/sh
cat <<'__EOF__'
$_s_body
__EOF__
STUBEOF
  chmod 755 "$_s_path"
}

# ---------------------------------------------------------------- stub tree
mkdir -p "$JDK/bin" "$STUB_BIN"

stub "$JDK/bin/java" 'openjdk version "17.0.20.1" 2026-07-21
OpenJDK Runtime Environment Temurin-17.0.20.1+1 (build 17.0.20.1+1-LTS)
OpenJDK 64-Bit Server VM Temurin-17.0.20.1+1 (build 17.0.20.1+1-LTS, mixed mode, sharing)'
stub "$JDK/bin/javac" 'javac 17.0.20.1'
for _t in jar keytool; do
  stub "$JDK/bin/$_t" "${_t} 17.0.20.1"
done
# unzip and git live in the image's system PATH rather than in a toolchain tree,
# but the harness asserts both, because flutter and the SDK shells out to them.
stub "$STUB_BIN/unzip" 'UnZip 6.0'
stub "$STUB_BIN/git" 'git version 2.47.0'

CT="$SDK/cmdline-tools/latest"
mkdir -p "$CT/bin"
printf 'Pkg.Revision=19.0\nPkg.Path=cmdline-tools;19.0\nPkg.Desc=Android SDK Command-line Tools\n' \
  > "$CT/source.properties"
stub "$CT/bin/sdkmanager" '19.0'
for _t in avdmanager apkanalyzer d8; do
  stub "$CT/bin/$_t" "${_t} from cmdline-tools 19.0"
done

PT="$SDK/platform-tools"
mkdir -p "$PT"
printf 'Pkg.UserSrc=false\nPkg.Revision=37.0.1\n' > "$PT/source.properties"
stub "$PT/adb" 'Android Debug Bridge version 1.0.41
Version 37.0.1-15733141
Installed as /opt/android-sdk/platform-tools/adb
Running on Linux 6.1.0-41-amd64 (x86_64)'
stub "$PT/fastboot" 'fastboot version 37.0.1-15733141
Installed as /opt/android-sdk/platform-tools/fastboot'

BT="$SDK/build-tools/36.1.0"
mkdir -p "$BT/lib" "$BT/lib64"
printf 'Pkg.UserSrc=false\nPkg.Revision=36.1.0\n' > "$BT/source.properties"
# These three are files the harness checks for existence because the real
# binaries need them at runtime: aapt/zipalign/aidl link against
# lib64/libc++.so, and d8/apksigner are wrappers around jars in lib/.
: > "$BT/lib64/libc++.so"
: > "$BT/lib/d8.jar"
: > "$BT/lib/apksigner.jar"
stub "$BT/aapt" 'Android Asset Packaging Tool, v0.2-14042983'
stub "$BT/aapt2" 'Android Asset Packaging Tool (aapt) 2.20-14042983'
stub "$BT/aidl" ': AIDL Compiler: built for platform SDK version 36'
stub "$BT/d8" 'd8 8.13.17'
stub "$BT/dexdump" 'Copyright (C) 2007 The Android Open Source Project'
stub "$BT/split-select" 'split-select --help'
stub "$BT/zipalign" 'Zip alignment utility'
printf '#!/bin/sh\nexec java -jar "$(dirname "$0")/../lib/apksigner.jar" "$@"\n' > "$BT/apksigner"
chmod 755 "$BT/apksigner"
ln -s 36.1.0 "$SDK/build-tools/current"

PLAT="$SDK/platforms/android-36"
mkdir -p "$PLAT"
cat > "$PLAT/source.properties" <<'PROPEOF'
Pkg.Desc=Android SDK Platform 16
Pkg.UserSrc=false
Platform.Version=16
Platform.CodeName=
Pkg.Revision=2
AndroidVersion.ApiLevel=36
AndroidVersion.ExtensionLevel=17
AndroidVersion.IsBaseSdk=true
Layoutlib.Api=15
Layoutlib.Revision=1
Platform.MinToolsRev=22
PROPEOF
: > "$PLAT/android.jar"

for _lic in android-sdk-license android-sdk-preview-license android-sdk-arm-dbt-license \
  google-gdk-license android-googletv-license android-googlexr-license mips-android-sysimage-license
do
  mkdir -p "$SDK/licenses"
  printf '24333f8a63b6825ea9c5514f83c2829b004d1fee\n' > "$SDK/licenses/$_lic"
done

GRADLE_HOME_REAL="$GRADLE/gradle-9.3.1"
mkdir -p "$GRADLE_HOME_REAL/bin"
stub "$GRADLE_HOME_REAL/bin/gradle" '------------------------------------------------------------
Gradle 9.3.1
------------------------------------------------------------

Build time:    2026-09-14T10:22:31Z
Revision:      1a2b3c4d5e6f
Kotlin:        2.4.0
Groovy:        3.0.24
Launcher JVM:  17.0.20.1 (Eclipse Adoptium 17.0.20.1+1)
Daemon JVM:    17.0.20.1 (Eclipse Adoptium 17.0.20.1+1) (x86_64-23.0.1-linux-gnu)
OS:            Linux 6.1.0 x86_64'
ln -s gradle-9.3.1 "$GRADLE/current"

mkdir -p "$FLUTTER/bin/cache"
printf '3.47.6\n' > "$FLUTTER/version"
stub "$FLUTTER/bin/flutter" 'Flutter 3.47.6 • channel stable • https://github.com/flutter/flutter.git
Framework • revision 8f2c1d9e (3 weeks ago) • 2026-08-24 12:00:00 -0700
Engine • revision 4b7a0c31
Tools • Dart 3.11.0 • DevTools 2.51.0'
stub "$FLUTTER/bin/dart" 'Dart SDK version: 3.11.0 (stable) on "linux_x64"'

# The same PATH layout the image's ENV block produces, in the same order, so the
# `path:` rows are testing order as well as membership.
BASE_PATH="$JDK/bin:$FLUTTER/bin:$CT/bin:$PT:$SDK/build-tools/current:$GRADLE/current/bin:$STUB_BIN"
# The real system PATH, minus any stub directory. The harness needs coreutils
# (sed, tr, timeout, readlink) and git; the JSON case also wants node, which on a
# developer machine is frequently installed outside /usr/bin.
EC_SYS_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v "^$STUB" | paste -sd: -)"
SYS_PATH="$EC_SYS_PATH"

HEALTHY_PATH="$BASE_PATH:$SYS_PATH"
export JAVA_HOME="$JDK"
export ANDROID_HOME="$SDK"
export ANDROID_SDK_ROOT="$SDK"
export FLUTTER_ROOT="$FLUTTER"
export GRADLE_HOME="$GRADLE/current"
export PATH="$HEALTHY_PATH"
export PAPERCLIP_BUILD_VERSION=0.0.0-selftest
export PAPERCLIP_BUILD_COMMIT=selftest

# ------------------------------------------------------------------- cases
CASES_RUN=0
CASES_OK=0
CASE_LOG="$STUB/cases.log"
: > "$CASE_LOG"
# Which shell expect_case invokes the harness with. Reset to the default after any
# case that changes it.
EC_SHELL="$SH"

# BASH_ENV is cleared for every harness invocation. A non-interactive bash
# sources that file at startup, and a developer's or CI runner's version
# commonly does `export PATH=...`, which silently replaces the PATH this test
# just built and makes every binary look missing. That is a property of the
# environment, not of the harness, so the test must not measure it.
run_harness() {
  env BASH_ENV= "$EC_SHELL" "$HARNESS" --dockerfile "$STUB_DOCKERFILE" "$@"
}

# expect_case NAME EXPECTED_EXIT MARKERS [-- HARNESS_ARGS...]
# MARKERS is one required substring, or several separated by `;;`. Assert the
# exit status, and assert every marker appears in the output. The markers are
# what make these tests meaningful: exit 1 alone would also be produced by a
# harness that crashed, and a nonzero exit from a usage error is a different bug
# from a nonzero exit from a detected failure.
expect_case() {
  _ec_name="$1"
  _ec_want_exit="$2"
  _ec_markers="$3"
  shift 3
  _ec_args=''
  if [ "${1:-}" = '--' ]; then
    shift
    _ec_args="$*"
  fi
  if [ -n "$SELFTEST_FILTER" ]; then
    case "$_ec_name" in
      *"$SELFTEST_FILTER"*) ;;
      *) return 0 ;;
    esac
  fi
  CASES_RUN=$((CASES_RUN + 1))
  # shellcheck disable=SC2086 # _ec_args is a deliberately re-split argument list
  _ec_out="$(run_harness $_ec_args 2>&1)" && _ec_exit=0 || _ec_exit=$?
  printf '===== %s =====\n%s\nexit=%s (want %s)\n\n' \
    "$_ec_name" "$_ec_out" "$_ec_exit" "$_ec_want_exit" >> "$CASE_LOG"
  _ec_ok=1
  if [ "$_ec_exit" -ne "$_ec_want_exit" ]; then
    _ec_ok=0
    printf '  exit status %s, expected %s\n' "$_ec_exit" "$_ec_want_exit"
  fi
  _ec_rest=";;$_ec_markers;;"
  while [ "$_ec_rest" != ';;' ]; do
    _ec_one="${_ec_rest#;;}"
    _ec_one="${_ec_one%%;;*}"
    _ec_rest=";;${_ec_rest#*"$_ec_one";;}"
    if ! printf '%s\n' "$_ec_out" | grep -qF -- "$_ec_one"; then
      _ec_ok=0
      printf '  missing expected marker: %s\n' "$_ec_one"
    fi
  done
  if [ "$_ec_ok" -eq 1 ]; then
    CASES_OK=$((CASES_OK + 1))
    printf 'ok    %-38s exit=%s  %s\n' "$_ec_name" "$_ec_exit" "$_ec_markers"
  else
    printf 'FAIL  %-38s exit=%s  (wanted exit=%s and %s)\n' \
      "$_ec_name" "$_ec_exit" "$_ec_want_exit" "$_ec_markers"
  fi
}

# A Dockerfile that actually describes the stub image. The ARG pins are copied
# through untouched, so the pin cross-check still validates them against the real
# values, but the ENV literals are re-rooted at the stub tree. Without this the
# ENV cross-check would correctly report that the running image disagrees with the
# repository's Dockerfile, and the healthy case could never pass.
#
# This is the point of the ENV half of the cross-check: it compares what the
# Dockerfile declares against what the running image actually has, so the test
# fixture has to make those two agree the way a real build does.
STUB_DOCKERFILE="$STUB/Dockerfile.stub"
sed -e "s#/opt/jdk#$JDK#g" \
    -e "s#/opt/android-sdk#$SDK#g" \
    -e "s#/opt/flutter#$FLUTTER#g" \
    -e "s#/opt/gradle#$GRADLE#g" \
    "$REPO_DOCKERFILE" > "$STUB_DOCKERFILE"
grep -q "ENV JAVA_HOME=$JDK" "$STUB_DOCKERFILE" \
  || { printf 'selftest setup error: could not re-root the ENV block\n' >&2; exit 1; }

# Two doctored copies, so each half of the cross-check has something real to
# disagree with. Editing the repo's own Dockerfile is not an option.
DRIFTED_DOCKERFILE="$STUB/Dockerfile.drifted"
sed 's/^ARG ANDROID_BUILD_TOOLS=.*/ARG ANDROID_BUILD_TOOLS=35.0.0/' \
  "$STUB_DOCKERFILE" > "$DRIFTED_DOCKERFILE"
grep -q 'ARG ANDROID_BUILD_TOOLS=35.0.0' "$DRIFTED_DOCKERFILE" \
  || { printf 'selftest setup error: could not doctor the Dockerfile\n' >&2; exit 1; }

# The ENV literals are a second, separate half of the cross-check, so they need
# their own doctored copy. Pointing ENV JAVA_HOME at a different directory is the
# realistic drift: someone moves the JDK tree and forgets the ENV line.
DRIFTED_ENV_DOCKERFILE="$STUB/Dockerfile.env-drifted"
sed -e "s|^ENV JAVA_HOME=$JDK|ENV JAVA_HOME=$JDK-relocated|" \
  "$STUB_DOCKERFILE" > "$DRIFTED_ENV_DOCKERFILE"
grep -q "ENV JAVA_HOME=$JDK-relocated" "$DRIFTED_ENV_DOCKERFILE" \
  || { printf 'selftest setup error: could not doctor the ENV block\n' >&2; exit 1; }

printf '=== verify-nono-toolchain.sh self-test ===\n'
printf 'harness : %s\n' "$HARNESS"
printf 'shell   : %s\n' "$SH"
printf 'pins from: %s\n' "$REPO_DOCKERFILE"
printf 'as if at : %s\n' "$STUB_DOCKERFILE"

# 1. The healthy case. If this one fails, every other case is meaningless: a
#    harness that fails on a good image makes its negative results worthless.
expect_case 'healthy image' 0 'RESULT: PASS'

# 2. The headline negative test from the issue: strip every toolchain directory
#    off PATH and require that the harness notices. --expect-fail inverts the
#    verdict, so exit 0 here means "the harness found failures", which is what a
#    vacuous harness could not produce.
PATH="$SYS_PATH"
expect_case 'PATH stripped of toolchain' 0 'NEGATIVE TEST OK' -- --expect-fail
PATH="$HEALTHY_PATH"

# 3. One fault at a time, each requiring the specific row that owns it. A
#    harness that only asked "is java on PATH" would pass all of these.
SAVED_JAVA_HOME="$JAVA_HOME"
unset JAVA_HOME
expect_case 'JAVA_HOME unset' 1 'env:JAVA_HOME;;JAVA_HOME is set and non-empty;;UNSET'
export JAVA_HOME="$SAVED_JAVA_HOME"

mv "$SDK/licenses" "$STUB/licenses.saved"
expect_case 'licenses dir removed' 1 'licenses:dir;;licenses:accepted'
mv "$STUB/licenses.saved" "$SDK/licenses"
expect_case 'licenses restored' 0 'RESULT: PASS'

: > "$SDK/licenses/android-sdk-license"
expect_case 'license file emptied' 1 'licenses:android-sdk-license;;missing or empty'
printf '24333f8a63b6825ea9c5514f83c2829b004d1fee\n' > "$SDK/licenses/android-sdk-license"
expect_case 'license file restored' 0 'RESULT: PASS'

mv "$PLAT/source.properties" "$STUB/platform-source.properties.saved"
expect_case 'platform source.properties removed' 1 \
  'version:platform-api;;version:platform-revision;;missing'
mv "$STUB/platform-source.properties.saved" "$PLAT/source.properties"

mv "$BT/lib64/libc++.so" "$STUB/libc++.so.saved"
expect_case 'build-tools lib64 removed' 1 'buildtools:lib64/libc++.so;;missing '"$BT"'/lib64/libc++.so'
mv "$STUB/libc++.so.saved" "$BT/lib64/libc++.so"

mv "$PLAT/android.jar" "$STUB/android.jar.saved"
expect_case 'android.jar removed' 1 'platform:android.jar;;missing '"$PLAT"'/android.jar'
mv "$STUB/android.jar.saved" "$PLAT/android.jar"

rm -f "$SDK/build-tools/current"
expect_case 'build-tools/current symlink removed' 1 'symlink:build-tools/current;;missing or not a symlink'
ln -s 36.1.0 "$SDK/build-tools/current"

# 4. Version drift, which is what a presence-only harness cannot catch. Two
#    shapes matter: a different feature version, and a *longer* version that
#    contains the pin as a substring. The second is the trap that --strict exists
#    to close, so both modes are asserted.
cp "$JDK/bin/java" "$STUB/java.saved"
stub "$JDK/bin/java" 'openjdk version "21.0.1" 2023-10-17
OpenJDK Runtime Environment Temurin-21.0.1+12 (build 21.0.1+12-LTS)'
expect_case 'java 21.0.1 instead of 17.0.20.1' 1 \
  'version:java;;expected to contain'
stub "$JDK/bin/java" 'openjdk version "17.0.20.10" 2027-01-01
OpenJDK Runtime Environment Temurin-17.0.20.10+1 (build 17.0.20.10+1-LTS)'
expect_case 'java 17.0.20.10, lenient mode' 1 'version:java-vendor'
expect_case 'java 17.0.20.10, strict mode' 1 'version:java;;strict pattern' -- --strict
cp "$STUB/java.saved" "$JDK/bin/java"
expect_case 'healthy after restoring java' 0 'RESULT: PASS'

# 5. Gradle launching on a different JDK than JAVA_HOME. This is a real failure
#    mode: `java` still reports the pinned version while Gradle uses another JDK.
cp "$GRADLE_HOME_REAL/bin/gradle" "$STUB/gradle.saved"
stub "$GRADLE_HOME_REAL/bin/gradle" 'Gradle 9.3.1

Launcher JVM:  21.0.1 (Eclipse Adoptium 21.0.1+12)'
expect_case 'gradle on the wrong JVM' 1 'version:gradle-jvm;;Launcher JVM: 17.0.20.1'
cp "$STUB/gradle.saved" "$GRADLE_HOME_REAL/bin/gradle"

# 6. The pin cross-check, against a Dockerfile that genuinely disagrees.
expect_case 'Dockerfile pin drift, expect-fail' 0 'NEGATIVE TEST OK' \
  -- --expect-fail --dockerfile "$DRIFTED_DOCKERFILE"
expect_case 'Dockerfile pin drift, exact row' 1 'pin:ANDROID_BUILD_TOOLS;;Dockerfile=35.0.0 this_script=36.1.0' \
  -- --dockerfile "$DRIFTED_DOCKERFILE"

expect_case 'Dockerfile ENV literal drift' 1 \
  "pin:ENV.JAVA_HOME;;Dockerfile=$JDK-relocated" \
  -- --dockerfile "$DRIFTED_ENV_DOCKERFILE"

# 7. The harness's own strictness and the negative-test switch, asserted against
#    a healthy image. If either behaved the other way round, cases 2 and 6 would
#    be theatre rather than evidence.
expect_case 'strict rejects SKIP rows' 1 'RESULT: FAIL' -- --strict
expect_case 'expect-fail on a healthy image' 1 'NEGATIVE TEST FAILED' -- --expect-fail
EC_SHELL=bash
expect_case 'healthy under bash too' 0 'RESULT: PASS'
EC_SHELL="$SH"

# 8. The JSON output has to be machine-readable or it is decoration. Node is
#    present in this repo's toolchain and in the image, but the case degrades to
#    a structural check rather than failing spuriously where it is not.
CASES_RUN=$((CASES_RUN + 1))
_json_line="$(EC_SHELL=bash run_harness --json 2>&1 | sed -n '/^{/p')"
_json_verdict=FAIL
_json_note=''
if command -v node >/dev/null 2>&1; then
  _json_note="$(printf '%s' "$_json_line" | node -e '
    let raw = "";
    process.stdin.on("data", (chunk) => (raw += chunk));
    process.stdin.on("end", () => {
      try {
        const parsed = JSON.parse(raw);
        if (parsed.result !== "PASS") throw new Error("result=" + parsed.result);
        if (!Array.isArray(parsed.rows)) throw new Error("rows is not an array");
        if (parsed.rows.length < 50) throw new Error("only " + parsed.rows.length + " rows");
        if (parsed.pins.flutter !== "3.47.6") throw new Error("flutter pin=" + parsed.pins.flutter);
        const flutterRow = parsed.rows.find((row) => row.id === "version:flutter");
        if (!flutterRow || flutterRow.status !== "PASS") throw new Error("flutter row is not PASS");
        process.stdout.write("valid, " + parsed.rows.length + " rows");
      } catch (error) {
        process.stdout.write(error.message);
        process.exit(1);
      }
    });
  ' 2>&1)" && _json_verdict=OK || _json_verdict=FAIL
else
  case "$_json_line" in
    '{"result":"PASS"'*'"rows":['*']}') _json_verdict=OK; _json_note='structural check only (no node)' ;;
    *) _json_note="unparseable: $(printf '%s' "$_json_line" | cut -c1-80)" ;;
  esac
fi
if [ "$_json_verdict" = OK ]; then
  CASES_OK=$((CASES_OK + 1))
  printf 'ok    %-34s %s\n' 'json output' "$_json_note"
else
  printf 'FAIL  %-34s %s\n' 'json output' "$_json_note"
fi

# 9. The runnerd row is the one that reaches outside the toolchain trees, into
#    the app itself, so confirm it is genuinely reading the real path rather than
#    passing on a stub.
if [ -x /app/server/dist/vendor/paperclip-runner/bin/paperclip-runnerd ]; then
  expect_case 'runnerd row resolves in this image' 0 'rust:runnerd-binary' -- --no-check-pins
else
  printf 'skip  %-38s no built runnerd in this checkout\n' 'runnerd row'
fi

printf '\n%s/%s cases behaved as specified\n' "$CASES_OK" "$CASES_RUN"
printf 'full harness output for every case: %s\n' "$CASE_LOG"
if [ "$CASES_OK" -ne "$CASES_RUN" ]; then
  printf '\nself-test FAILED\n'
  exit 1
fi
printf 'self-test PASSED\n'
exit 0
