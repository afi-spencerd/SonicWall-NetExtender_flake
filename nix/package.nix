{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  wrapGAppsHook3,
  writeShellScript,
  glibc,
  # Runtime PATH dependencies, not link-time ones: both `nxcli` and the GUI hand
  # the SAML login URL to a browser via github.com/pkg/browser, which shells out
  # to `xdg-open`; `setsid` detaches it (see xdgOpenShim below).
  xdg-utils,
  util-linux,
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

let
  # NetExtender hands the SAML login URL to github.com/pkg/browser, whose
  # OpenURL runs `xdg-open` through cmd.Run() -- that is, it *waits* for it to
  # exit. Plain xdg-open in turn only returns once the browser it launched
  # quits, so unless a browser already happens to be running, the client parks
  # in StateNeedSaml forever and never polls the appliance for the SAML result:
  # authentication just hangs. This shim sits in front of the real xdg-open,
  # launches it detached and returns immediately.
  xdgOpenShim = writeShellScript "xdg-open-detached" ''
    if [ -n "''${_NE_XDG_OPEN_SHIM-}" ]; then
        # The PATH scrubbing below did not take. Fall back to the xdg-open we
        # ship rather than risk recursing back into this shim.
        exec ${lib.getExe' xdg-utils "xdg-open"} "$@"
    fi
    _NE_XDG_OPEN_SHIM=1
    export _NE_XDG_OPEN_SHIM

    # Drop our own directory so the next `xdg-open` on PATH is the session's
    # (portal- or desktop-aware) one where there is one, and the bundled
    # xdg-utils otherwise -- the same precedence the wrapper below sets up.
    scrubbed=
    IFS=:
    for dir in $PATH; do
        if [ "$dir" != "@self@" ]; then
            scrubbed=''${scrubbed:+$scrubbed:}$dir
        fi
    done
    unset IFS
    PATH=''${scrubbed:-${lib.makeBinPath [ xdg-utils ]}}
    export PATH

    # setsid rather than a bare `&`: the browser must outlive nxcli, and must
    # not take the Ctrl-C that stops it, which a shared process group would
    # deliver to both.
    ${lib.getExe' util-linux "setsid"} xdg-open "$@" >/dev/null 2>&1 &
    exit 0
  '';
in

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

    install -Dm755 ${xdgOpenShim} "$dst/browser-shim/xdg-open"
    substituteInPlace "$dst/browser-shim/xdg-open" \
      --replace-fail @self@ "$dst/browser-shim"

    # Without an `xdg-open` on PATH, SAML logon fails outright with "unable to
    # open default system browser". Suffix rather than prefix: nxcli only needs
    # *a* working xdg-open, so a session-provided one (which may be portal- or
    # desktop-aware) should still win.
    #
    # The shim, on the other hand, is prefixed -- it has to be the xdg-open
    # NetExtender itself resolves, so that the blocking one never runs in the
    # foreground of the login. It re-dispatches to the session's xdg-open.
    makeWrapper "$dst/nxcli" "$out/bin/nxcli" \
      --prefix PATH : "$dst/browser-shim" \
      --suffix PATH : ${lib.makeBinPath [ xdg-utils ]}

    # `nxcli` doubles as the `netExtender` CLI (upstream symlinks it as such).
    # It takes its command name from cobra, never from argv[0], so pointing the
    # alias at the wrapper is enough.
    ln -s nxcli "$out/bin/netExtender"

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

    # The GUI opens the SAML URL the same way nxcli does, so it needs the same
    # non-blocking xdg-open in front.
    makeWrapper "$dst/NetExtender" "$out/bin/NetExtender" \
      "''${gappsWrapperArgs[@]}" \
      --prefix PATH : "$dst/browser-shim" \
      --suffix PATH : ${lib.makeBinPath [ xdg-utils ]}
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
