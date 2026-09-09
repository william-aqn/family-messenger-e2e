# escape=`
# Windows container that builds the Flutter Windows desktop app (MSVC has no
# Linux cross-compiler, so this is the only way to do it in Docker). Driven by
# build.ps1; follows Microsoft's "Install Build Tools into a container" guide
# and the tauu/flutter-windows-builder image.
FROM mcr.microsoft.com/windows/servercore:ltsc2022

SHELL ["cmd", "/S", "/C"]

ARG FLUTTER_VERSION=3.47.2
ARG MINGIT_VERSION=2.47.1

# Visual Studio Build Tools 2022 with the C++ workload Flutter requires
# (MSVC v143, Windows SDK, CMake). Exit code 3010 means "installed, reboot
# pending" and is fine inside an image. The removed SDKs cannot be installed
# into containers and would fail the whole setup.
RUN curl -SL --output vs_buildtools.exe https://aka.ms/vs/17/release/vs_buildtools.exe `
    && (start /w vs_buildtools.exe --quiet --wait --norestart --nocache `
        --installPath "%ProgramFiles(x86)%\Microsoft Visual Studio\2022\BuildTools" `
        --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended `
        --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        --add Microsoft.VisualStudio.Component.VC.CMake.Project `
        --add Microsoft.VisualStudio.Component.VC.ATL `
        --remove Microsoft.VisualStudio.Component.Windows10SDK.10240 `
        --remove Microsoft.VisualStudio.Component.Windows10SDK.10586 `
        --remove Microsoft.VisualStudio.Component.Windows10SDK.14393 `
        --remove Microsoft.VisualStudio.Component.Windows81SDK `
        || IF "%ERRORLEVEL%"=="3010" EXIT 0) `
    && del /q vs_buildtools.exe

# Google's root CA, so pub.dev and storage.googleapis.com validate even when
# the container cannot reach the Windows root-certificate update service.
ADD https://pki.goog/repo/certs/gtsr1.pem C:/TEMP/gtsr1.pem
RUN powershell -NoLogo -ExecutionPolicy Bypass -Command "Import-Certificate -FilePath C:\TEMP\gtsr1.pem -CertStoreLocation Cert:\LocalMachine\Root | Out-Null" `
    && del /q C:\TEMP\gtsr1.pem

# Portable Git (the Flutter tool shells out to it) and the Flutter SDK zip.
RUN curl -SL --output mingit.zip "https://github.com/git-for-windows/git/releases/download/v%MINGIT_VERSION%.windows.1/MinGit-%MINGIT_VERSION%-64-bit.zip" `
    && mkdir C:\git && tar -xf mingit.zip -C C:\git && del /q mingit.zip `
    && curl -SL --output flutter.zip "https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_%FLUTTER_VERSION%-stable.zip" `
    && tar -xf flutter.zip -C C:\ && del /q flutter.zip `
    && setx /M PATH "%PATH%;C:\git\cmd;C:\flutter\bin"

RUN git config --global --add safe.directory * `
    && flutter config --no-analytics --enable-windows-desktop `
    && flutter precache --windows `
    && (flutter doctor -v || EXIT 0)

COPY entrypoint.ps1 C:\entrypoint.ps1
WORKDIR C:\work
ENTRYPOINT ["powershell", "-NoLogo", "-ExecutionPolicy", "Bypass", "-File", "C:\\entrypoint.ps1"]
