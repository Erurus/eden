{
  lib,
  stdenv,
  SDL2,
  autoconf,
  boost,
  catch2_3,
  cmake,
  fetchFromGitHub,
  cpp-jwt,
  cubeb,
  discord-rpc,
  enet,
  fetchgit,
  fetchurl,
  ffmpeg-headless,
  fmt,
  glslang,
  libopus,
  libusb1,
  libva,
  lz4,
  python3,
  unzip,
  nix-update-script,
  nlohmann_json,
  nv-codec-headers-12,
  pkg-config,
  qt6,
  vulkan-headers,
  vulkan-loader,
  yasm,
  simpleini,
  zlib,
  vulkan-memory-allocator,
  zstd,
}:

let
  inherit (qt6)
    qtbase
    qtmultimedia
    qtwayland
    wrapQtAppsHook
    qttools
    qtwebengine
    ;

  compat-list = stdenv.mkDerivation {
    pname = "yuzu-compatibility-list";
    version = "unstable-2024-02-26";

    src = fetchFromGitHub {
      owner = "flathub";
      repo = "org.yuzu_emu.yuzu";
      rev = "9c2032a3c7e64772a8112b77ed8b660242172068";
      hash = "sha256-ITh/W4vfC9w9t+TJnPeTZwWifnhTNKX54JSSdpgaoBk=";
    };

    buildCommand = ''
      cp $src/compatibility_list.json $out
    '';
  };

  nx_tzdb = stdenv.mkDerivation rec {
    pname = "nx_tzdb";
    version = "221202";

    src = fetchurl {
      url = "https://github.com/lat9nq/tzdb_to_nx/releases/download/${version}/${version}.zip";
      hash = "sha256-mRzW+iIwrU1zsxHmf+0RArU8BShAoEMvCz+McXFFK3c=";
    };

    nativeBuildInputs = [ unzip ];

    buildCommand = ''
      unzip $src -d $out
    '';

  };

in

stdenv.mkDerivation (finalAttrs: {
  pname = "eden";
  version = "unstable-2025-06-5";

  src = fetchgit {
    url = "https://git.eden-emu.dev/eden-emu/eden";
    rev = "6397bb0809b654f977c552a789b666596f15cee4";
    hash = "sha256-uLiiZjFk4z2maKM6QEzXmXZFp3M+ypOgyTD4CBYfBGw=";
    fetchSubmodules = true;
  };

  nativeBuildInputs = [
    cmake
    glslang
    pkg-config
    python3
    qttools
    wrapQtAppsHook
  ];

  buildInputs = [
    # vulkan-headers must come first, so the older propagated versions
    # don't get picked up by accident
    vulkan-headers

    boost
    catch2_3
    cpp-jwt
    cubeb
    discord-rpc
    # intentionally omitted: dynarmic - prefer vendored version for compatibility
    enet

    # ffmpeg deps (also includes vendored)
    # we do not use internal ffmpeg because cuda errors
    autoconf
    yasm
    libva # for accelerated video decode on non-nvidia
    nv-codec-headers-12 # for accelerated video decode on nvidia
    ffmpeg-headless
    # end ffmpeg deps

    fmt
    # intentionally omitted: gamemode - loaded dynamically at runtime
    # intentionally omitted: httplib - upstream requires an older version than what we have
    libopus
    libusb1
    # intentionally omitted: LLVM - heavy, only used for stack traces in the debugger
    lz4
    nlohmann_json
    qtbase
    qtmultimedia
    qtwayland
    qtwebengine
    # intentionally omitted: renderdoc - heavy, developer only
    SDL2
    # intentionally omitted: stb - header only libraries, vendor uses git snapshot
    vulkan-memory-allocator
    # intentionally omitted: xbyak - prefer vendored version for compatibility
    zlib
    zstd
  ];

  # This changes `ir/opt` to `ir/var/empty` in `externals/dynarmic/src/dynarmic/CMakeLists.txt`
  # making the build fail, as that path does not exist
  dontFixCmake = true;

  cmakeFlags = [
    # actually has a noticeable performance impact
    (lib.cmakeBool "YUZU_ENABLE_LTO" true)
    (lib.cmakeBool "YUZU_TESTS" false)

    (lib.cmakeBool "ENABLE_QT6" true)
    (lib.cmakeBool "ENABLE_QT_TRANSLATION" true)

    # use system libraries
    # NB: "external" here means "from the externals/ directory in the source",
    # so "off" means "use system"
    (lib.cmakeBool "YUZU_USE_EXTERNAL_SDL2" false)
    (lib.cmakeBool "YUZU_USE_EXTERNAL_VULKAN_HEADERS" true)
    "-DVulkan_INCLUDE_DIRS=${vulkan-headers}/include"

    # # don't use system ffmpeg, suyu uses internal APIs
    # (lib.cmakeBool "YUZU_USE_BUNDLED_FFMPEG" true)

    # don't check for missing submodules
    (lib.cmakeBool "YUZU_CHECK_SUBMODULES" false)

    # enable some optional features
    (lib.cmakeBool "YUZU_USE_QT_WEB_ENGINE" true)
    (lib.cmakeBool "YUZU_USE_QT_MULTIMEDIA" true)
    (lib.cmakeBool "USE_DISCORD_PRESENCE" true)

    # We dont want to bother upstream with potentially outdated compat reports
    (lib.cmakeBool "YUZU_ENABLE_COMPATIBILITY_REPORTING" false)
    (lib.cmakeBool "ENABLE_COMPATIBILITY_LIST_DOWNLOAD" false) # We provide this deterministically
  ];

  env = {
    # Does some handrolled SIMD
    NIX_CFLAGS_COMPILE = lib.optionalString stdenv.hostPlatform.isx86_64 "-msse4.1";
  };

  qtWrapperArgs = [
    # Fixes vulkan detection.
    # FIXME: patchelf --add-rpath corrupts the binary for some reason, investigate
    "--prefix LD_LIBRARY_PATH : ${vulkan-loader}/lib"
  ];

  # Setting this through cmakeFlags does not work.
  # https://github.com/NixOS/nixpkgs/issues/114044
  preConfigure = lib.concatStringsSep "\n" [
    ''
      cmakeFlagsArray+=(
        "-DTITLE_BAR_FORMAT_IDLE=${finalAttrs.pname} | ${finalAttrs.version} (nixpkgs) {}"
        "-DTITLE_BAR_FORMAT_RUNNING=${finalAttrs.pname} | ${finalAttrs.version} (nixpkgs) | {}"
      )
    ''
    # provide pre-downloaded tz data
    ''
      mkdir -p build/externals/nx_tzdb
      ln -s ${nx_tzdb} build/externals/nx_tzdb/nx_tzdb
    ''
  ];

  postConfigure = ''
    ln -sf ${compat-list} ./dist/compatibility_list/compatibility_list.json
  '';

  postInstall = "
    install -Dm444 $src/dist/72-yuzu-input.rules $out/lib/udev/rules.d/72-yuzu-input.rules
  ";

  meta = {
    description = "Fork of yuzu, an open-source Nintendo Switch emulator";
    homepage = "https://git.eden-emu.dev/eden-emu/eden";
    mainProgram = "eden";
    platforms = lib.platforms.linux;
    badPlatforms = [
      # Several conversion errors, probably caused by the update to GCC 14
      "aarch64-linux"
    ];
    maintainers = with lib.maintainers; [ liberodark ];
    license = with lib.licenses; [
      gpl3Plus
      # Icons
      asl20
      mit
      cc0
    ];
  };
})