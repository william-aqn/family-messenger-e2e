# Builder image: Go + Node + Flutter + Android SDK/NDK + Linux desktop toolchain.
# Used through deploy/builder/docker-compose.yml to produce server binaries,
# the web client, Android APK/App Bundle and the Flutter Linux desktop bundle
# without installing anything on the host. Windows and macOS/iOS builds still
# need their native toolchains (see README).
FROM ubuntu:24.04

ARG GO_VERSION=1.26.3
ARG NODE_MAJOR=26
ARG FLUTTER_VERSION=3.47.2
ARG ANDROID_CMDLINE_TOOLS=13114758
ARG ANDROID_BUILD_TOOLS=36.0.0

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    GOPATH=/root/go \
    ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    PUB_CACHE=/root/.pub-cache \
    PATH=/usr/local/go/bin:/root/go/bin:/opt/flutter/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:$PATH

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git unzip zip xz-utils bash file \
      openjdk-17-jdk-headless \
      clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev build-essential \
      libsecret-1-dev \
    && rm -rf /var/lib/apt/lists/*

# Go (cross-compiles the server for every platform).
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar -C /usr/local -xz

# Node for the web client.
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Flutter (stable tag), with Android and Linux artifacts pre-cached.
RUN git clone --depth 1 -b "${FLUTTER_VERSION}" https://github.com/flutter/flutter.git /opt/flutter \
    && git config --global --add safe.directory '*' \
    && flutter config --no-analytics --enable-linux-desktop \
    && flutter precache --android --linux

# Android SDK: command-line tools, platform matching the Flutter defaults, build tools, NDK.
RUN mkdir -p "${ANDROID_HOME}/cmdline-tools" \
    && curl -fsSL -o /tmp/cmdline-tools.zip "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS}_latest.zip" \
    && unzip -q /tmp/cmdline-tools.zip -d "${ANDROID_HOME}/cmdline-tools" \
    && mv "${ANDROID_HOME}/cmdline-tools/cmdline-tools" "${ANDROID_HOME}/cmdline-tools/latest" \
    && rm /tmp/cmdline-tools.zip \
    && ext=/opt/flutter/packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt \
    && compile_sdk="$(grep -oE 'compileSdkVersion: Int = [0-9]+' "$ext" | grep -oE '[0-9]+$' || echo 36)" \
    && ndk="$(grep -oE 'ndkVersion: String = "[0-9.]+"' "$ext" | grep -oE '[0-9.]+' || echo 28.2.13676358)" \
    && echo "compileSdk=$compile_sdk ndk=$ndk" \
    && yes | sdkmanager --licenses >/dev/null \
    && sdkmanager --install "platform-tools" "platforms;android-${compile_sdk}" "build-tools;${ANDROID_BUILD_TOOLS}" "ndk;${ndk}" >/dev/null \
    && flutter config --android-sdk "${ANDROID_HOME}" \
    && yes | flutter doctor --android-licenses >/dev/null \
    && flutter doctor

COPY build.sh /usr/local/bin/build
RUN chmod +x /usr/local/bin/build

WORKDIR /src
ENTRYPOINT ["/usr/local/bin/build"]
CMD ["help"]
