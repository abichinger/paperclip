# syntax=docker/dockerfile:1.20
FROM node:24-trixie-slim AS base
ARG USER_UID=1000
ARG USER_GID=1000
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates gosu curl gh git wget ripgrep python3 tini \
  && rm -rf /var/lib/apt/lists/* \
  && corepack enable

# Modify the existing node user/group to have the specified UID/GID to match host user
RUN usermod -u $USER_UID --non-unique node \
  && groupmod -g $USER_GID --non-unique node \
  && usermod -g $USER_GID -d /paperclip node

FROM base AS deps
WORKDIR /app
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml .npmrc ./
COPY cli/package.json cli/
COPY server/package.json server/
COPY ui/package.json ui/
COPY packages/shared/package.json packages/shared/
COPY packages/db/package.json packages/db/
COPY packages/adapter-utils/package.json packages/adapter-utils/
COPY packages/google-sheets-mcp-server/package.json packages/google-sheets-mcp-server/
COPY packages/kv-demo-mcp-server/package.json packages/kv-demo-mcp-server/
COPY packages/mcp-server/package.json packages/mcp-server/
COPY packages/paperclip-eval-kernel/package.json packages/paperclip-eval-kernel/
COPY packages/paperclip-runner/package.json packages/paperclip-runner/
COPY packages/skills-catalog/package.json packages/skills-catalog/
COPY packages/tailscale-https-broker/package.json packages/tailscale-https-broker/
COPY packages/teams-catalog/package.json packages/teams-catalog/
COPY packages/adapters/claude-local/package.json packages/adapters/claude-local/
COPY packages/adapters/codex-local/package.json packages/adapters/codex-local/
COPY packages/adapters/cursor-cloud/package.json packages/adapters/cursor-cloud/
COPY packages/adapters/cursor-local/package.json packages/adapters/cursor-local/
COPY packages/adapters/gemini-local/package.json packages/adapters/gemini-local/
COPY packages/adapters/grok-local/package.json packages/adapters/grok-local/
COPY packages/adapters/kimi-local/package.json packages/adapters/kimi-local/
COPY packages/adapters/hermes/package.json packages/adapters/hermes/
COPY packages/adapters/hermes-gateway/package.json packages/adapters/hermes-gateway/
COPY packages/adapters/openclaw-gateway/package.json packages/adapters/openclaw-gateway/
COPY packages/adapters/opencode-local/package.json packages/adapters/opencode-local/
COPY packages/adapters/pi-local/package.json packages/adapters/pi-local/
COPY packages/plugins/sdk/package.json packages/plugins/sdk/
COPY --parents packages/plugins/sandbox-providers/./*/package.json packages/plugins/sandbox-providers/
COPY packages/plugins/paperclip-plugin-fake-sandbox/package.json packages/plugins/paperclip-plugin-fake-sandbox/
COPY packages/plugins/plugin-llm-wiki/package.json packages/plugins/plugin-llm-wiki/
COPY packages/plugins/plugin-workspace-diff/package.json packages/plugins/plugin-workspace-diff/
COPY patches/ patches/
COPY scripts/link-plugin-dev-sdk.mjs scripts/

RUN pnpm install --frozen-lockfile

FROM base AS rust-toolchain
WORKDIR /app
# Debian's packaged rust lags the ecosystem (trixie ships 1.85) and the
# runner's dependency tree now requires a newer rustc. Install rustup from a
# version-pinned, checksum-verified installer and let the runner's own
# rust-toolchain.toml choose the compiler — one pin, owned by the runner
# package, shared by CI and image builds alike.
#
# The C toolchain is explicit: apt's cargo used to pull gcc in as a
# dependency, and rustup does not — without it every build script dies on
# "linker `cc` not found".
RUN apt-get update \
  && apt-get install -y --no-install-recommends gcc libc6-dev pkg-config \
  && rm -rf /var/lib/apt/lists/*
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH
ARG RUSTUP_VERSION=1.29.0
ARG RUSTUP_SHA256_AMD64=4acc9acc76d5079515b46346a485974457b5a79893cfb01112423c89aeb5aa10
ARG RUSTUP_SHA256_ARM64=9732d6c5e2a098d3521fca8145d826ae0aaa067ef2385ead08e6feac88fa5792
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) rustTarget="x86_64-unknown-linux-gnu"; sha256="$RUSTUP_SHA256_AMD64" ;; \
      arm64) rustTarget="aarch64-unknown-linux-gnu"; sha256="$RUSTUP_SHA256_ARM64" ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSLo /tmp/rustup-init "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${rustTarget}/rustup-init"; \
    echo "${sha256}  /tmp/rustup-init" | sha256sum -c -; \
    chmod +x /tmp/rustup-init; \
    /tmp/rustup-init -y --no-modify-path --profile minimal --default-toolchain none; \
    rm /tmp/rustup-init
# Install the package-owned compiler before any application source enters the
# stage. rustup-init above installs rustup itself, not the selected compiler.
COPY packages/paperclip-runner/rust-toolchain.toml /tmp/runner-toolchain/rust-toolchain.toml
RUN cd /tmp/runner-toolchain && rustup show

# Pin the recipe generator and its dependency lockfile. It is a build-only tool
# and uses the same package-owned compiler as both native build stages.
FROM rust-toolchain AS rust-chef
RUN cd /tmp/runner-toolchain && cargo install cargo-chef --version 0.1.73 --locked

FROM rust-chef AS runner-plan
WORKDIR /app/packages/paperclip-runner
COPY packages/paperclip-runner/rust-toolchain.toml ./
COPY packages/paperclip-runner/runner ./runner
RUN cd runner && cargo chef prepare --recipe-path /tmp/runner-recipe.json

FROM rust-chef AS runner-deps
WORKDIR /app/packages/paperclip-runner/runner
COPY packages/paperclip-runner/rust-toolchain.toml ../
# The recipe changes only when dependency manifests, the lockfile, or target
# metadata change. Source edits can reuse this compiled dependency layer.
COPY --from=runner-plan /tmp/runner-recipe.json /tmp/runner-recipe.json
RUN cargo chef cook --release --locked --package paperclip-runner-core --bin paperclip-runnerd --recipe-path /tmp/runner-recipe.json \
  && find . -mindepth 1 -maxdepth 1 ! -name target -exec rm -rf {} +

FROM runner-deps AS runner-build
WORKDIR /app/packages/paperclip-runner
# Rust embeds protocol schemas and fixtures with include_str!. Keep those
# alongside the complete Cargo workspace so every compile-time input keys
# this layer. Ordinary server/UI edits can then reuse the native build.
COPY packages/paperclip-runner/rust-toolchain.toml ./
COPY packages/paperclip-runner/runner ./runner
COPY packages/paperclip-runner/protocol ./protocol
# Cargo fingerprints source mtimes. Normalize them here and after the full
# source copy below so a fresh checkout cannot invalidate unchanged inputs.
RUN find runner protocol -type f -exec touch -d @0 {} + \
  && touch -d @0 rust-toolchain.toml \
  && cargo build --release --manifest-path runner/Cargo.toml --locked -p paperclip-runner-core --bin paperclip-runnerd

FROM runner-build AS build
WORKDIR /app
COPY --from=deps /app /app
COPY . .
RUN find packages/paperclip-runner/runner packages/paperclip-runner/protocol -type f -exec touch -d @0 {} + \
  && touch -d @0 packages/paperclip-runner/rust-toolchain.toml
# Both the browser bundle and server stamp need the source commit. Declare it
# after the stable dependency layers, before either application build.
ARG PAPERCLIP_BUILD_COMMIT=""
RUN pnpm --filter @paperclipai/ui build
RUN pnpm --filter @paperclipai/plugin-sdk build
# The server build runs scripts/write-build-stamp.mjs, which stamps the built
# commit into dist/build-info.json. The build context has no .git, so the
# script reads PAPERCLIP_BUILD_COMMIT instead. Docker exposes an ARG to the
# next RUN as an environment variable. The production stage below declares the
# same ARG again for the runtime fallback; an ARG goes out of scope at the
# end of its stage. Empty for local `docker build`, which then writes no stamp.
ENV NODE_OPTIONS=--max-old-space-size=4096
RUN pnpm --filter @paperclipai/server build
RUN test -f server/dist/index.js || (echo "ERROR: server build output missing" && exit 1)
RUN rm -rf packages/paperclip-runner/runner/target

# Remote OpenCode and ACPX runs require a controller-owned provider pack to
# verify the sandbox installation or stage matching assets. Ship it in the
# standard image so downstream Cloud compositions inherit the same artifacts.
# Grok's native executable stays an external sandbox prerequisite; this pack
# contains only its launcher.
FROM build AS runner-provider-pack
# Unstamped local builds remain usable, but cannot qualify a remote pack.
# Never invent a source revision to make an unqualified pack look verified.
RUN mkdir -p /provider-pack \
  && if [ -n "${PAPERCLIP_BUILD_COMMIT}" ]; then \
    PAPERCLIP_RUNNER_SOURCE_REVISION="${PAPERCLIP_BUILD_COMMIT}" node packages/paperclip-runner/scripts/build-provider-pack.mjs /provider-pack; \
  else \
    echo "Skipping remote provider pack: supply a full PAPERCLIP_BUILD_COMMIT to enable remote OpenCode/ACPX execution"; \
  fi

# Android + Flutter toolchain for mobile client work.
#
# A separate stage, not a `production` RUN, for two cache reasons. This payload
# is ~3.4 GB and downloads from four independent upstreams, so it wants a layer
# cache entry that neither the weekly CLI_TOOLS_CACHE_EPOCH bump above nor an
# app-source commit can invalidate. It also copies nothing from the build
# context, so it keys purely on the pins below; `production` COPYs the trees in.
#
# Unlike the CLI toolchain, nothing here is `@latest` and nothing here is
# weekly-moving, so it deliberately does NOT take the CLI_TOOLS_CACHE_EPOCH
# stamp. Its cache key is the pins, which is the stronger guarantee: bump a
# version, and exactly one tool re-downloads.
FROM base AS mobile-toolchain
# Escape hatch, not a default. Self-hosted images and CI that never touch a
# mobile client should not pay ~3.4 GB for this stage, so
# `--build-arg WITH_MOBILE_TOOLCHAIN=0` produces the previous lean image. The
# stage still creates the four empty /opt trees, so the COPYs in `production`
# stay unconditional and the resulting digest stays stable.
ARG WITH_MOBILE_TOOLCHAIN=1
# Temurin 17 rather than Debian's openjdk-17: the base is
# node:24-trixie-slim (Debian 13), whose main archive ships openjdk-21 and
# openjdk-25 but no openjdk-17-jdk-headless package, so that option does not
# exist for this base. 17 is the right floor anyway: AGP 8.x and AGP 9.x both
# accept JDK 17, and it is the newest JDK every AGP a client can plausibly use
# is tested against. RELEASE is the release tag, VERSION the asset filename
# suffix; the two differ only in how the '+' is written.
ARG TEMURIN_RELEASE=17.0.20.1+1
ARG TEMURIN_VERSION=17.0.20.1_1
ARG TEMURIN_SHA256_AMD64=3808d1d15e3ec6bd5b84057fb5d84c33d8a1536a258146bcea2e603fc726e08e
ARG TEMURIN_SHA256_ARM64=457b57af8f9c93ec39080bb8c764f559dc8c89a6da1a39d718a400b7890d3e41
# Android command-line tools 19.0 (archive build 13114758).
#
# 19.0, not the newest 23.0: from 20.0 onward `sdkmanager` is a shim over the
# new `android` CLI, prints "The --licenses option is no longer needed", and
# `flutter doctor` then reports "Android license status unknown" instead of
# reading the pre-accepted license files. Verified both ways against Flutter
# 3.47.6: 23.0 fails the license check, 19.0 reports "All Android licenses
# accepted".
#
# Google publishes only a SHA-1 for this archive (the value below is straight
# out of dl.google.com/android/repository/repository2-1.xml). SHA-256 is
# checked instead, and the published SHA-1 is verified during the build, so the
# pin is anchored to Google's own metadata *and* stronger than it.
ARG ANDROID_CMDLINE_TOOLS_BUILD=13114758
ARG ANDROID_CMDLINE_TOOLS_SHA1=5fdcc763663eefb86a5b8879697aa6088b041e70
ARG ANDROID_CMDLINE_TOOLS_SHA256=7ec965280a073311c339e571cd5de778b9975026cfcbe79f2b1cdcb1e15317ee
# One platform + one build-tools, matching major versions. 36 is not a guess:
# Flutter 3.47.6's own gradle_utils.dart declares `compileSdkVersionInt = 36`,
# so a stock `flutter create` app compiles against exactly this platform. SDK
# components are not fetched by Gradle, so exactly one usable set has to be
# present; anything else the client declares is a one-ARG change here.
ARG ANDROID_SDK_PLATFORM=android-36
ARG ANDROID_BUILD_TOOLS=36.1.0
# The NDK is NOT baked by default, and the reason is size: r28c alone is
# ~2.4 GB extracted, which would more than double the stage. A Flutter project
# is still buildable without it, because AGP auto-provisions the NDK from the
# pre-accepted licenses above on first build — so this is a network-at-first-
# build cost, not a capability gap. Set `--build-arg
# ANDROID_SDK_NDK=28.1.13356709` (the version Flutter 3.47.6's template
# resolves to) for a fully offline-capable loop.
ARG ANDROID_SDK_NDK=""
# Gradle 9.3.1 — the version Flutter 3.47.6 writes into a generated project's
# gradle-wrapper.properties. Deliberately 9.x, not 8.x: AGP 9.1.0 (the version
# the same template pins) rejects Gradle 8, so an 8.x system gradle could not
# drive a stock Flutter project at all. This is a convenience `gradle` for
# scratch work; a real client build should use ./gradlew, which fetches the
# version the project pins, so this pin can never silently downgrade a build.
ARG GRADLE_VERSION=9.3.1
ARG GRADLE_SHA256=b266d5ff6b90eada6dc3b20cb090e3731302e553a27c5d3e4df1f0d76beaff06
# Flutter stable. Verified against Google's own release manifest
# (flutter_infra_release/releases/releases_linux.json), which publishes the
# SHA-256 for each archive, so this pin is not self-asserted.
#
# Flutter publishes stable Linux archives for x86_64 only. On an arm64 build
# this stage logs why and leaves /opt/flutter empty; the JDK, Android SDK and
# Gradle halves are unaffected, because those upstream projects do ship arm64.
ARG FLUTTER_VERSION=3.47.6
ARG FLUTTER_SHA256=f1631b9c2c8b3529323db412b0d1beacf4a748f8783b0d7cf599a8fd5f461675
RUN set -eux; \
    mkdir -p /opt/jdk /opt/android-sdk /opt/gradle /opt/flutter; \
    if [ "$WITH_MOBILE_TOOLCHAIN" != "1" ]; then \
      echo "WITH_MOBILE_TOOLCHAIN=$WITH_MOBILE_TOOLCHAIN: skipping the Flutter + Android toolchain"; \
      exit 0; \
    fi; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) jdkTriple="x64" ;; \
      arm64) jdkTriple="aarch64" ;; \
      *) echo "ERROR: unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    apt-get update; \
    apt-get install -y --no-install-recommends unzip xz-utils; \
    rm -rf /var/lib/apt/lists/*; \
    jdkSha="$TEMURIN_SHA256_AMD64"; \
    if [ "$arch" = "arm64" ]; then jdkSha="$TEMURIN_SHA256_ARM64"; fi; \
    jdkTag="$(printf '%s' "$TEMURIN_RELEASE" | sed 's/+/%2B/g')"; \
    curl -fsSLo /tmp/jdk.tar.gz "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-${jdkTag}/OpenJDK17U-jdk_${jdkTriple}_linux_hotspot_${TEMURIN_VERSION}.tar.gz"; \
    echo "${jdkSha}  /tmp/jdk.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/jdk.tar.gz -C /opt/jdk --strip-components=1; \
    rm /tmp/jdk.tar.gz; \
    export JAVA_HOME=/opt/jdk ANDROID_HOME=/opt/android-sdk ANDROID_SDK_ROOT=/opt/android-sdk; \
    export PATH="$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"; \
    java -version; \
    curl -fsSLo /tmp/cmdline-tools.zip "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS_BUILD}_latest.zip"; \
    echo "${ANDROID_CMDLINE_TOOLS_SHA256}  /tmp/cmdline-tools.zip" | sha256sum -c -; \
    echo "${ANDROID_CMDLINE_TOOLS_SHA1}  /tmp/cmdline-tools.zip" | sha1sum -c -; \
    unzip -q /tmp/cmdline-tools.zip -d /opt/android-sdk/cmdline-tools; \
    rm /tmp/cmdline-tools.zip; \
    mv /opt/android-sdk/cmdline-tools/cmdline-tools /opt/android-sdk/cmdline-tools/latest; \
    sdkmanager --version; \
    mkdir -p "$ANDROID_HOME/licenses"; \
    printf '%s' 24333f8a63b6825ea9c5514f83c2829b004d1fee > "$ANDROID_HOME/licenses/android-sdk-license"; \
    printf '%s' 84831b9409646a918e30573bab4c9c91346d8abd > "$ANDROID_HOME/licenses/google-gdk-license"; \
    printf '%s' 601085b94cd77f0b54ff86406957099ebe79c4d6 > "$ANDROID_HOME/licenses/android-googletv-license"; \
    printf '%s' ceff83576aac4f7f37cb98fe189e9fb3c49d3b81 > "$ANDROID_HOME/licenses/android-googlexr-license"; \
    printf '%s' 859f317696f67ef3d7f30a50a5560e7834b43903 > "$ANDROID_HOME/licenses/android-sdk-arm-dbt-license"; \
    printf '%s' e9acab5b5fbb560a72cfaecce8946896ff6aab9d > "$ANDROID_HOME/licenses/mips-android-sysimage-license"; \
    printf '%s' 33b6a2b64607f11b759f320ef9dff4ae5c47d97a > "$ANDROID_HOME/licenses/android-sdk-preview-license"; \
    yes | sdkmanager --licenses > /dev/null; \
    sdkPackages="platform-tools platforms;${ANDROID_SDK_PLATFORM} build-tools;${ANDROID_BUILD_TOOLS}"; \
    if [ -n "$ANDROID_SDK_NDK" ]; then sdkPackages="$sdkPackages ndk;$ANDROID_SDK_NDK"; fi; \
    sdkmanager --install $sdkPackages; \
    curl -fsSLo /tmp/gradle.zip "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip"; \
    echo "${GRADLE_SHA256}  /tmp/gradle.zip" | sha256sum -c -; \
    unzip -q /tmp/gradle.zip -d /opt/gradle; \
    rm /tmp/gradle.zip; \
    ln -s "gradle-${GRADLE_VERSION}" /opt/gradle/current; \
    gradle --version; \
    if [ "$arch" = "amd64" ]; then \
      curl -fsSLo /tmp/flutter.tar.xz "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"; \
      echo "${FLUTTER_SHA256}  /tmp/flutter.tar.xz" | sha256sum -c -; \
      tar -xJf /tmp/flutter.tar.xz -C /opt; \
      rm /tmp/flutter.tar.xz; \
      export FLUTTER_ROOT=/opt/flutter; \
      export PATH="$FLUTTER_ROOT/bin:$PATH"; \
      flutter config --no-analytics > /dev/null; \
      flutter --version; \
      flutter precache --android; \
    else \
      echo "WARNING: $arch has no published stable Flutter Linux archive; skipping Flutter"; \
    fi; \
    ln -s "$ANDROID_BUILD_TOOLS" "$ANDROID_HOME/build-tools/current"; \
    sdkmanager --list_installed; \
    adb version; \
    aapt2 version; \
    chown -R node:node /opt/android-sdk /opt/gradle /opt/flutter
# The agent half of the image runs as `node` (see the entrypoint's gosu drop),
# and both of these trees are written at run time — sdkmanager installs extra
# components, AGP auto-provisions them, and flutter writes into
# $FLUTTER_ROOT/bin/cache on every invocation. Root-owned, all three fail with
# EACCES. Handing them to the user that actually builds against them is not a
# privilege change: `node` can already run arbitrary code, and nothing in the
# entrypoint executes anything out of these trees as root.

FROM base AS production
ARG USER_UID=1000
ARG USER_GID=1000
# Refreshes the tool layer below when it changes (CI stamps an ISO week, so
# the @latest CLI tools advance weekly). Without it the cached layer would
# freeze the tools until an unrelated cache bust.
ARG CLI_TOOLS_CACHE_EPOCH=""
WORKDIR /app
# Tool and OS layer BEFORE the app copy: it references nothing from /app, and
# the app copy changes on every commit — ordered the other way around, this
# (the single most expensive layer: four CLI toolchains + apt, per arch) can
# never hit the layer cache and rebuilds on every build.
RUN echo "cli-tools-epoch: ${CLI_TOOLS_CACHE_EPOCH}" \
  && npm install --global --omit=dev @anthropic-ai/claude-code@latest @openai/codex@latest opencode-ai @google/gemini-cli@latest @moonshot-ai/kimi-code@latest \
  && apt-get update \
  && apt-get install -y --no-install-recommends openssh-client jq unzip \
  && rm -rf /var/lib/apt/lists/* \
  && mkdir -p /paperclip \
  && chown node:node /paperclip

# Mobile toolchain trees, still ahead of the app copy below so their ~3.4 GB
# keys only on the pins in the `mobile-toolchain` stage and never on app
# source. `unzip` above is not incidental: flutter shells out to it to unpack
# engine artifacts on every build, so a flutter-only container without it fails
# with "Missing 'unzip' tool" long before it reaches anything of its own.
# Empty trees when that stage ran with WITH_MOBILE_TOOLCHAIN=0, which keeps
# these four lines unconditional and therefore keeps the digest stable.
COPY --from=mobile-toolchain /opt/jdk /opt/jdk
COPY --from=mobile-toolchain /opt/android-sdk /opt/android-sdk
COPY --from=mobile-toolchain /opt/gradle /opt/gradle
COPY --from=mobile-toolchain /opt/flutter /opt/flutter

COPY scripts/docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

COPY --chown=node:node --from=build /app /app

COPY --from=runner-provider-pack /provider-pack /opt/paperclip-runner/provider-pack
# Managed deployments can remap node's UID at startup. This immutable pack
# contains public code and integrity metadata, never credentials; it must remain
# readable afterward.
# Keep it root-owned and verify access as an unrelated unprivileged UID.
RUN chmod -R a+rX /opt/paperclip-runner/provider-pack \
  && if [ -f /opt/paperclip-runner/provider-pack/provider-pack.json ]; then \
    gosu 65534:65534 node -e 'const fs = require("node:fs"); const path = require("node:path"); const root = "/opt/paperclip-runner/provider-pack"; const manifest = JSON.parse(fs.readFileSync(path.join(root, "provider-pack.json"), "utf8")); for (const artifact of Object.values(manifest.payload.artifacts)) fs.readFileSync(path.join(root, artifact.path)); fs.accessSync(path.join(root, manifest.payload.artifacts.nodeCommand.path), fs.constants.X_OK);'; \
  fi
ENV PAPERCLIP_RUNNER_REMOTE_PROVIDER_PACK_PATH=/opt/paperclip-runner/provider-pack

# Declare per-build metadata after the stable RUN layers. Docker includes
# in-scope ARG values in a RUN's environment even when its command does not
# mention them; declaring these earlier invalidates the weekly tool cache.
# The build stage still receives the commit before writing dist/build-info.json.
# Empty for local builds, preserving the server's normal version fallbacks.
ARG PAPERCLIP_BUILD_VERSION=""
ARG PAPERCLIP_BUILD_COMMIT=""
# Every value here is a literal or an already-expanded $PATH — no ARG is
# referenced, so declaring these now cannot invalidate the cached tool layers
# the way a per-build ARG would. The two "current" symlinks exist precisely so
# this needs no build ARG of its own: the version on PATH is the version the
# `mobile-toolchain` stage installed, with no second pin to drift out of sync.
ENV JAVA_HOME=/opt/jdk \
    ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    FLUTTER_ROOT=/opt/flutter \
    GRADLE_HOME=/opt/gradle/current \
    PATH=/opt/jdk/bin:/opt/flutter/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/opt/android-sdk/build-tools/current:/opt/gradle/current/bin:$PATH
ENV NODE_ENV=production \
  HOME=/paperclip \
  HOST=0.0.0.0 \
  PORT=3100 \
  SERVE_UI=true \
  PAPERCLIP_HOME=/paperclip \
  PAPERCLIP_INSTANCE_ID=default \
  PAPERCLIP_BUILD_VERSION=${PAPERCLIP_BUILD_VERSION} \
  PAPERCLIP_BUILD_COMMIT=${PAPERCLIP_BUILD_COMMIT} \
  USER_UID=${USER_UID} \
  USER_GID=${USER_GID} \
  PAPERCLIP_CONFIG=/paperclip/instances/default/config.json \
  PAPERCLIP_DEPLOYMENT_MODE=authenticated \
  PAPERCLIP_DEPLOYMENT_EXPOSURE=private \
  OPENCODE_ALLOW_ALL_MODELS=true \
  GEMINI_SANDBOX=false

EXPOSE 3100

# tini, not node, is PID 1. The entrypoint ends in `exec`, so without an init
# node inherits PID 1 and never wait()s the orphans the kernel re-parents onto
# it -- agent runs spawn git/claude/esbuild/sh descendants that outlive their
# leader, so they pile up as permanent zombies (~79/h measured) until the
# cgroup pid limit is exhausted and *every* fork() in the container fails.
# tini reaps adopted orphans and forwards signals, so the exec chain below and
# graceful shutdown are unchanged. Mirrors docker/agent-runtime/Dockerfile.base.
ENTRYPOINT ["/usr/bin/tini", "--", "docker-entrypoint.sh"]
CMD ["node", "--import", "./server/node_modules/tsx/dist/loader.mjs", "server/dist/index.js"]

# Cloud image variant (build with `--target cloud`): the production image
# plus built bundled sandbox-provider plugins. Managed instances receive a
# `plugins.autoInstall` key list through PAPERCLIP_MANAGED_CONFIG and
# install those plugins from the bundled catalog at boot
# (server/src/services/bundled-plugins.ts), which requires each plugin's
# dist/ to exist in the image — the default image ships only their source,
# so auto-install logs "bundle not present" and skips. The plugins are
# built in this separate target so the default (self-hosted) image stays
# lean; CI pins the default build to `--target production`. Both targets
# inherit the build-owned remote provider pack from the standard image.
#
# The sandbox providers are intentionally excluded from the pnpm workspace
# (see pnpm-workspace.yaml), so each installs standalone exactly as its
# README prescribes. Installing in a `build`-based stage (not `production`)
# keeps devDependencies available for tsc: `production` sets
# NODE_ENV=production, which would make pnpm skip them.
#
# CLOUD_BUNDLED_PLUGINS is the space-separated list of sandbox-provider
# directory names to build into the variant. Only what managed deployments
# actually auto-install belongs here — every entry adds its node_modules
# to the image. Growing the list is a one-line workflow change.
FROM build AS cloud-plugins
ARG CLOUD_BUNDLED_PLUGINS="daytona"
RUN set -eu; \
  for name in $CLOUD_BUNDLED_PLUGINS; do \
    dir="packages/plugins/sandbox-providers/$name"; \
    test -d "$dir" || { echo "ERROR: unknown sandbox provider '$name'" >&2; exit 1; }; \
    pnpm -C "$dir" install --ignore-workspace --no-lockfile; \
    pnpm -C "$dir" build; \
    test -f "$dir/dist/manifest.js" || { echo "ERROR: $dir is missing dist/manifest.js after build" >&2; exit 1; }; \
  done

# The hosted image variant ships selected optional peer packages
# pre-installed. A managed tenant then needs no separate install step.
# The self-hosted image stays on the opt-in contract: it never runs this
# stage, so a package like `@sentry/node` stays a true optional peer
# dependency. A self-hosted operator installs it by hand (see
# doc/observability.md).
#
# CLOUD_BUNDLED_SERVER_DEPS names the optional peer packages to install.
# The value is a space-separated list, the same shape as
# CLOUD_BUNDLED_PLUGINS above. The stage reads each package's version
# from the `peerDependencies` block of `server/package.json` at build
# time, so the version has one committed home.
#
# The stage fails the build in three cases:
# - the argument is empty
# - server/package.json declares no version for a named package
# - the named package is not an optional peer
#
# This check keeps the argument limited to packages the server already
# treats as optional.
#
# The install happens in its own isolated directory, not inside
# `server`'s own workspace install. The self-hosted target above never
# gains these packages this way. The directory sits under `/app`, not
# `server/`, and `--ignore-workspace` below excludes it from the pnpm
# workspace. From that directory, pnpm still finds the `packageManager`
# pin in the repo's own `package.json` by walking up — the same pnpm
# version the rest of the build uses.
#
# The install writes no lock file (`--no-lockfile`, the same flag the
# `cloud-plugins` stage above uses). Two builds of the same commit can
# therefore install different transitive versions of a named package.
# Three facts make this an accepted trade-off:
# - the `cloud-plugins` stage above already has the same property, with
#   the same flag
# - the direct version of each named package comes from one exact,
#   single-sourced place: the `peerDependencies` block of
#   `server/package.json`
# - an automated check asserts the installed direct version after every
#   build, so a transitive drift that breaks the package still fails the
#   build
FROM build AS cloud-server-deps
WORKDIR /app/.cloud-server-deps
ARG CLOUD_BUNDLED_SERVER_DEPS="@sentry/node"
RUN set -eu; \
  test -n "$CLOUD_BUNDLED_SERVER_DEPS" || { echo "ERROR: CLOUD_BUNDLED_SERVER_DEPS is empty; name at least one optional peer package to install" >&2; exit 1; }; \
  echo '{"name":"paperclip-cloud-server-deps","private":true}' > package.json; \
  specifiers=""; \
  for name in $CLOUD_BUNDLED_SERVER_DEPS; do \
    version="$(node -e "const pkg=require('/app/server/package.json'); const name=process.argv[1]; const version=(pkg.peerDependencies||{})[name]; if(!version){console.error('ERROR: server/package.json declares no peerDependencies version for '+JSON.stringify(name));process.exit(1);} const meta=(pkg.peerDependenciesMeta||{})[name]; if(!meta||meta.optional!==true){console.error('ERROR: '+JSON.stringify(name)+' is not declared as an optional peer dependency in server/package.json; CLOUD_BUNDLED_SERVER_DEPS may name only optional peer packages');process.exit(1);} process.stdout.write(version);" "$name")"; \
    test -n "$version" || { echo "ERROR: could not resolve a version for '$name'" >&2; exit 1; }; \
    specifiers="$specifiers ${name}@${version}"; \
  done; \
  test -n "$specifiers" || { echo "ERROR: CLOUD_BUNDLED_SERVER_DEPS names no package" >&2; exit 1; }; \
  pnpm add --ignore-workspace --no-lockfile $specifiers

FROM production AS cloud
COPY --chown=node:node --from=cloud-plugins /app/packages/plugins/sandbox-providers /app/packages/plugins/sandbox-providers
# Land the isolated install inside the server's own `node_modules`, the
# directory Node's module resolution walks up to from `/app/server` for
# both a CommonJS `require.resolve` and an ECMAScript `import` — an entry
# on `NODE_PATH` would satisfy only the first and silently fail the second.
COPY --chown=node:node --from=cloud-server-deps /app/.cloud-server-deps/node_modules /app/server/node_modules
