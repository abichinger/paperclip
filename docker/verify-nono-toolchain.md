# Verifying the Nono Battle client toolchain in the Paperclip image

The image is the deliverable, so verification has to run **inside the image**. This
directory holds the harness that does it:

| File | What it is |
| --- | --- |
| `verify-nono-toolchain.sh` | The harness. POSIX `sh` (checked with `dash`), no dependencies beyond coreutils, read-only, idempotent. |
| `verify-nono-toolchain.selftest.sh` | Proves the harness is not vacuous. Builds a throwaway stub toolchain and runs the harness 24 times with one specific fault injected each time. No Docker needed. |
| `verify-nono-toolchain.md` | This file — the copy-paste host commands. |

The toolchain it verifies is what the `mobile-toolchain` stage of `/app/Dockerfile`
bakes in: Eclipse Temurin JDK 17.0.20.1+1, Android `cmdline-tools` 19.0,
`platform-tools` 37.0.1, `build-tools;36.1.0`, `platforms;android-36` (API 36, rev 2),
Gradle 9.3.1, Flutter stable 3.47.6, and seven pre-accepted SDK licenses.

Every one of those numbers is cross-checked at runtime against the `ARG` block of
the same Dockerfile stage, so this file and the Dockerfile cannot drift apart
without the harness failing.

## Verify an image you just built

This is the primary check. It needs no database, no ports, and no compose stack.

```bash
# From the repository root.
docker build --target production -t paperclip-local:toolchain-check .

# --user 1000:1000 matters. The image has no USER directive: the entrypoint drops
# to `node` (uid 1000) with gosu, and that is the uid an agent run actually gets.
# Running the check as root would make the two writability rows pass trivially.
docker run --rm --user 1000:1000 --entrypoint sh \
  paperclip-local:toolchain-check docker/verify-nono-toolchain.sh
```

Expected tail on a healthy image:

```
PASS=79 FAIL=0 WARN=0 SKIP=2
RESULT: PASS
```

Exit status is `0` on pass and `1` on any failure, so it drops straight into CI:

```bash
docker run --rm --user 1000:1000 --entrypoint sh \
  paperclip-local:toolchain-check docker/verify-nono-toolchain.sh \
  || echo "TOOLCHAIN BROKEN"
```

## Verify the image the stack is actually running

```bash
cd docker
docker compose up -d
docker compose exec -T server sh docker/verify-nono-toolchain.sh
```

Two things to know about this path:

- **The `build:` block in `docker/docker-compose.yml` is commented out**, and the
  service uses `image: abichinger/paperclip:latest`. So `docker compose up -d
  --build` does not build your local tree; it starts the published image. Either
  uncomment the `build:` block, or verify the local build with the `docker run`
  form above.
- Until this script ships in a published image, pipe it in rather than reading it
  from inside the container. This works against any image and keeps the pin
  cross-check working, because it falls back to `/app/Dockerfile`:

  ```bash
  docker compose exec -T server sh -s < docker/verify-nono-toolchain.sh
  ```

## Options

```bash
sh docker/verify-nono-toolchain.sh --help
```

| Flag | Effect |
| --- | --- |
| `--full` | Adds the slow, network-dependent probes: `sdkmanager --list_installed` and `flutter doctor`. Off by default so the default run is offline and takes about a second. |
| `--strict` | Treats `WARN` and `SKIP` as failures, and requires version strings to match their strict patterns rather than a substring. Use in CI. |
| `--expect-fail` | Inverts the verdict: exits `0` only if something failed. This is what the negative test uses. |
| `--json` | Emits one JSON object after the table, for scraping. |
| `--dockerfile P` | Cross-check the pins against `P` instead of locating a Dockerfile next to the script. It also re-enables the pin check, so put it *after* `--no-check-pins` if you use both. |
| `--no-check-pins` | Skip the pin cross-check entirely (use when running outside the image). |
| `--timeout N` | Seconds allowed for the slow probes. Default 600. |

## What it asserts

81 rows on a healthy image.

- **Environment** — `JAVA_HOME`, `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `FLUTTER_ROOT`
  and `GRADLE_HOME` are set, non-empty and point at real directories;
  `ANDROID_HOME` and `ANDROID_SDK_ROOT` agree; and all six toolchain directories
  are individually on `PATH`. Installed-but-not-on-`PATH` is the failure mode that
  bites an agent which spawns a clean shell, so it is asserted per directory
  rather than inferred from a working `command -v`.
- **Binaries** — 22 tools resolve: the four JDK tools, the cmdline-tools set
  (`sdkmanager`, `avdmanager`, `apkanalyzer`), `adb`, `fastboot`, eight
  build-tools tools, `gradle`, `flutter`, `dart`, plus `unzip` and `git` from the
  system `PATH`. `emulator` is asserted **absent by design**, so that adding the
  emulator image later reads as a deliberate, visible change.
- **Versions, from the tools' own output** — Temurin `17.0.20.1` *and* the
  `Temurin-17.0.20.1+1` distribution string, so a distro `openjdk` of the same
  feature version is caught; `javac` agreeing with `JAVA_HOME`; `sdkmanager` 19.0
  confirmed twice (its own `--version` and the package's `source.properties`);
  `adb`/`fastboot` 37.0.1; `aapt2` `2.20-14042983`; `gradle` 9.3.1 **and the JVM
  Gradle actually launched**; `flutter` 3.47.6 confirmed twice. Matching ignores
  runs of spaces, because Gradle column-aligns its own output
  (`Launcher JVM:  17.0.20.1`).
- **SDK package revisions** — `build-tools;36.1.0`, `platform-tools` 37.0.1 and
  `platforms;android-36` are read from each package's own `source.properties`, so
  the default run needs no network. `android.jar` is checked separately: it is the
  compile classpath, and its absence is the failure a client actually hits.
- **build-tools runtime libs** — `lib64/libc++.so`, `lib/d8.jar` and
  `lib/apksigner.jar` must exist. `aapt`, `zipalign` and `aidl` are dynamically
  linked against `libc++.so` *inside their own package directory*, and `d8` and
  `apksigner` are shell wrappers around jars in `lib/`. A build-tools tree
  assembled without those directories installs cleanly and then fails with
  `error while loading shared libraries` on the first real build.
- **Symlinks** — `build-tools/current` points at the pinned revision and
  `GRADLE_HOME` resolves through `current` to `gradle-9.3.1`. Both are what the
  image puts on `PATH`, so a dangling or stale link is invisible to every other
  row.
- **Licenses** — all seven SDK license files are present and non-empty. This is
  the most common way a hand-built SDK becomes a broken dev loop: with no accepted
  licenses every `sdkmanager` and AGP call blocks on a stdin prompt, which in a
  non-interactive agent run looks like a hang with no error.
- **Writability** — `ANDROID_HOME`, `GRADLE_HOME` and flutter's artifact cache are
  writable by the invoking user. `sdkmanager --install`, AGP's auto-provisioning
  and every `flutter` invocation write there, and a root-owned tree fails with
  `EACCES` only once a client build is already running.
- **Pin agreement** — this script's pins are compared against the `ARG` block of
  the `mobile-toolchain` stage *and* the `ENV` literals of the `production` stage
  in the Dockerfile, and the `ENV` comparison is against the live values, not
  against the file.
- **Rust** — asserts the *compiled* `paperclip-runnerd` is present and executable.
  It deliberately does **not** assert `cargo`: `rust-toolchain` is an ancestor of
  the `build` stage only and `production` is `FROM base`, so the runtime image
  ships the compiled runner and no Rust toolchain. That row is a `SKIP`, and it
  flips to `PASS` if a future image change adds cargo.

### Deliberately not asserted

| Thing | Why |
| --- | --- |
| `emulator` | ~350 MB and needs KVM; nothing in the client build path uses it. Asserted *absent*. |
| `cargo` / `rustc` | Build-stage only; see above. |
| `xz` | `xz-utils` is installed in the `mobile-toolchain` stage, which `production` does not inherit from. It is only needed to unpack the Flutter tarball at build time. Asserting it would be a false failure. |
| `bcc_compat` | Ships in `build-tools;36.1.0` but is dynamically linked against `libncurses.so.5`, which the package does not ship. It cannot work in this image; it is legacy RenderScript tooling. |
| The NDK | Not baked by default, by design — `r28c` alone is ~2.4 GB. Pass `--build-arg ANDROID_SDK_NDK=<v>` to add it; AGP auto-provisions it on first build otherwise. |
| `d8` on `PATH` | Exists twice: cmdline-tools ships one and build-tools ships another, and `PATH` puts cmdline-tools first. The resolved path is reported, not asserted — both are legitimate dexers. |

## Negative test — proving the harness is not vacuous

A verification script that cannot fail is worse than none. Two ways to check.

### Locally, without Docker

This is the reproducible one. It builds a stub toolchain whose tools print the
exact version strings the real tools print, then injects one fault at a time:

```bash
sh docker/verify-nono-toolchain.selftest.sh
```

```
ok    healthy image                          exit=0  RESULT: PASS
ok    PATH stripped of toolchain             exit=0  NEGATIVE TEST OK
ok    JAVA_HOME unset                        exit=1  env:JAVA_HOME;;…;;UNSET
ok    licenses dir removed                   exit=1  licenses:dir;;licenses:accepted
ok    platform source.properties removed     exit=1  version:platform-api;;…;;missing
ok    build-tools lib64 removed              exit=1  buildtools:lib64/libc++.so;;…
ok    android.jar removed                    exit=1  platform:android.jar;;…
ok    build-tools/current symlink removed    exit=1  symlink:build-tools/current;;…
ok    java 21.0.1 instead of 17.0.20.1       exit=1  version:java;;expected to contain
ok    java 17.0.20.10, lenient mode          exit=1  version:java-vendor
ok    java 17.0.20.10, strict mode           exit=1  version:java;;strict pattern
ok    gradle on the wrong JVM                exit=1  version:gradle-jvm;;…
ok    Dockerfile pin drift, exact row        exit=1  pin:ANDROID_BUILD_TOOLS;;…
ok    Dockerfile ENV literal drift           exit=1  pin:ENV.JAVA_HOME;;…
ok    strict rejects SKIP rows               exit=1  RESULT: FAIL
ok    expect-fail on a healthy image         exit=1  NEGATIVE TEST FAILED
…
24/24 cases behaved as specified
self-test PASSED
```

`--keep` leaves the stub tree on disk and prints its path; a case-name substring
runs only the matching cases.

### Against the real image

Strip the toolchain directories off `PATH` and confirm the harness notices:

```bash
docker run --rm --user 1000:1000 --entrypoint sh paperclip-local:toolchain-check sh -c '
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  sh /app/docker/verify-nono-toolchain.sh --expect-fail
'
```

Expected tail:

```
PASS=40 FAIL=27 WARN=0 SKIP=2
NEGATIVE TEST OK: harness detected 27 failure(s) as expected.
```

`--expect-fail` exits `0` **only** when failures were found, so if this ever prints
`NEGATIVE TEST FAILED: harness reported no failures`, the harness has stopped
detecting anything and that is the bug.

Every other injected fault, and what each one proves:

| Injected fault | Expected |
| --- | --- |
| `PATH` stripped of the JDK/SDK/Gradle/Flutter dirs | 6 `path:` + 22 `binary:` FAILs, `--expect-fail` exits 0 |
| `JAVA_HOME` unset | `env:JAVA_HOME` FAIL `UNSET` |
| A `java` on `PATH` reporting `21.0.1` | `version:java` FAIL — version drift is caught, not just presence |
| A `java` reporting `17.0.20.10` | lenient mode catches the vendor string; `--strict` catches the feature version, which a substring match alone would not |
| `licenses/` removed | `licenses:dir` and `licenses:accepted` FAIL |
| A license file truncated to 0 bytes | `licenses:android-sdk-license` FAIL `missing or empty` |
| A platform's `source.properties` removed | `version:platform-api` and `version:platform-revision` FAIL |
| `build-tools/lib64/libc++.so` removed | `buildtools:lib64/libc++.so` FAIL |
| `android.jar` removed | `platform:android.jar` FAIL |
| `build-tools/current` symlink removed | `symlink:build-tools/current` FAIL |
| `gradle` reporting a different `Launcher JVM` | `version:gradle-jvm` FAIL while `version:gradle` still passes |
| A Dockerfile `ARG` that disagrees with the script | `pin:<ARG>` FAIL with both values |
| A Dockerfile `ENV` that disagrees with the live value | `pin:ENV.<VAR>` FAIL with both values |
| `--strict` on a healthy image | the 2 `SKIP`s become failures, exit 1 |
| `--expect-fail` on a healthy image | `NEGATIVE TEST FAILED`, exit 1 |

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| Everything fails and the output ends with a `HINT` about empty trees | The image was built with `--build-arg WITH_MOBILE_TOOLCHAIN=0`, which is the documented lean-image escape hatch. Rebuild without it. |
| `sdkmanager` hangs on a license prompt | Licenses were not accepted at build time; check `$ANDROID_HOME/licenses`. `--full` prints the exact `flutter doctor` verdict. |
| `FAIL binary:gradle` but `gradle --version` works in your shell | You are in a different shell than the one the image `ENV PATH` was applied to. Re-exec, or source the image env. |
| `FAIL sdk:writable` or `flutter:cache-writable` | The tree is root-owned. The `mobile-toolchain` stage ends with `chown -R node:node` on all three for exactly this; if you override the entrypoint, also pass `--user 1000:1000`. |
| `FAIL version:gradle-jvm` while `version:gradle` passes | A second JDK is winning on `PATH`. `JAVA_HOME` and the JVM Gradle launches must be the same one. |
| `FAIL pin:<ARG>` | A pin here and the matching `ARG` in the Dockerfile have drifted. Update both; the check exists so the two cannot disagree. |
| `FAIL pin:ENV.<VAR>` | The Dockerfile declares a path the running image does not have. Usually a moved tree with a stale `ENV` line. |
| `full:flutter-doctor-licenses` FAIL with `Android license status unknown` | `cmdline-tools` was bumped to 20.0 or newer, where `sdkmanager` is a shim over the new `android` CLI and stops reading the pre-accepted license files. This breaks every build. Pin it back to 19.0. |

## Adding a tool

1. Add the binary to the `require_binary` calls, and, if it has a pinnable
   version, a `check_version` or `check_prop` row.
2. Put the expected value in the `PIN_*` block at the top **and** in the `ARG`
   block of the `mobile-toolchain` stage of the Dockerfile. The pin-agreement
   check exists precisely so the two cannot disagree.
3. Add a fault-injection case to the self-test. A new row with no negative case is
   a row nothing proves.
