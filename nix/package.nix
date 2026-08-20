{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  wrapGAppsHook3,
  glibc,
  # GUI-only dependencies (NEEDED by the webkit2gtk-4.1 build of the client)
  glib,
  gtk3,
  gdk-pixbuf,
  libsoup_3,
  webkitgtk_4_1,
  # Build the webkit2gtk GUI client in addition to the CLI + service.
  # Disable to get a lean CLI-only closure (no GTK/WebKit dependencies).
  withGui ? true,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "sonicwall-netextender";
  version = "10.3.5-36";

  src = fetchurl {
    url = "https://software.sonicwall.com/NetExtender/NetExtender-linux-amd64-${finalAttrs.version}.tar.gz";
    hash = "sha256-iFgvqW+x3fKHaDvDZqcZil4+bs3Edz35E236Pkk9o4Y=";
  };

  # The tarball unpacks into a top-level `netextender/` directory.
  sourceRoot = "netextender";

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
  ]
  ++ lib.optional withGui wrapGAppsHook3;

  buildInputs = [
    # nxcli, NEService, wg and wireguard-go link against glibc
    # (libc/libresolv/libpthread/libdl).
    glibc
  ]
  ++ lib.optionals withGui [
    glib
    gtk3
    gdk-pixbuf
    libsoup_3
    webkitgtk_4_1
  ];

  # We wrap the GUI binary by hand so the CLI/service entry points keep a lean
  # environment; let wrapGAppsHook only assemble gappsWrapperArgs for us.
  dontWrapGApps = true;

  installPhase = ''
    runHook preInstall

    dst=$out/share/netextender
    mkdir -p "$dst" "$out/bin"

    # --- CLI, service and bundled WireGuard userspace tooling ---
    install -Dm755 nxcli "$dst/nxcli"
    install -Dm755 NEService "$dst/NEService"
    install -Dm755 wg "$dst/wg"
    install -Dm755 wireguard-go "$dst/wireguard-go"
    install -Dm755 wg-quick "$dst/wg-quick"
    cp -r locales "$dst/locales"
    install -Dm644 nx-icon.png "$dst/nx-icon.png"

    # wg-quick ships a `#!/bin/bash` shebang; rewrite it to the store bash.
    patchShebangs "$dst/wg-quick"

    # `nxcli` doubles as the `netExtender` CLI (upstream symlinks it as such).
    ln -s "$dst/nxcli" "$out/bin/nxcli"
    ln -s "$dst/nxcli" "$out/bin/netExtender"

  ''
  + lib.optionalString withGui ''
    # Match install.sh: use the libwebkit2gtk-4.1 build of the GUI + upgrader.
    install -Dm755 NetExtender_webkit2_41 "$dst/NetExtender"
    install -Dm755 autoUpgrader_webkit2_41 "$dst/autoUpgrader"

    # Desktop entry, repointed from /usr/local/netextender to the store.
    install -Dm644 com.sonicwall.NetExtender.desktop \
      "$out/share/applications/com.sonicwall.NetExtender.desktop"
    substituteInPlace "$out/share/applications/com.sonicwall.NetExtender.desktop" \
      --replace-fail /usr/local/netextender/NetExtender "$out/bin/NetExtender" \
      --replace-fail /usr/local/netextender/nx-icon.png "$dst/nx-icon.png"

    makeWrapper "$dst/NetExtender" "$out/bin/NetExtender" \
      "''${gappsWrapperArgs[@]}"
  ''
  + ''
    runHook postInstall
  '';

  # The service and CLI resolve `wg`/`wg-quick`/`locales` via the runtime path
  # /usr/local/netextender, materialized by the NixOS module. autoPatchelfHook
  # must not treat the bundled wg-quick (a script) as a broken dependency.
  dontAutoPatchelf = false;

  meta = {
    description = "SonicWall NetExtender SSL-VPN client (CLI, service, and optional GUI)";
    homepage = "https://www.sonicwall.com/products/remote-access/vpn-clients";
    # Proprietary, redistributed as a pre-built binary tarball.
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "netExtender";
  };
})
