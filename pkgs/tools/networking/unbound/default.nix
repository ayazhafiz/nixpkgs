{ stdenv
, lib
, fetchurl
, openssl
, nettle
, expat
, libevent
, libsodium
, protobufc
, hiredis
, dns-root-data
, pkg-config
, makeWrapper
, symlinkJoin
  #
  # By default unbound will not be built with systemd support. Unbound is a very
  # commmon dependency. The transitive dependency closure of systemd also
  # contains unbound.
  # Since most (all?) (lib)unbound users outside of the unbound daemon usage do
  # not need the systemd integration it is likely best to just default to no
  # systemd integration.
  # For the daemon use-case, that needs to notify systemd, use `unbound-with-systemd`.
  #
, withSystemd ? false
, systemd ? null
  # optionally support DNS-over-HTTPS as a server
, withDoH ? false
, withECS ? false
, withDNSCrypt ? false
, withDNSTAP ? false
, withTFO ? false
, withRedis ? false
, libnghttp2
}:

stdenv.mkDerivation rec {
  pname = "unbound";
  version = "1.13.2";

  src = fetchurl {
    url = "https://nlnetlabs.nl/downloads/unbound/unbound-${version}.tar.gz";
    sha256 = "sha256-ChO1R/O5KgJrXr0EI/VMmR5XGAN/2fckRYF/agQOGoM=";
  };

  outputs = [ "out" "lib" "man" ]; # "dev" would only split ~20 kB

  nativeBuildInputs = [ makeWrapper ];

  buildInputs = [ openssl nettle expat libevent ]
    ++ lib.optionals withSystemd [ pkg-config systemd ]
    ++ lib.optionals withDoH [ libnghttp2 ];

  configureFlags = [
    "--with-ssl=${openssl.dev}"
    "--with-libexpat=${expat.dev}"
    "--with-libevent=${libevent.dev}"
    "--localstatedir=/var"
    "--sysconfdir=/etc"
    "--sbindir=\${out}/bin"
    "--with-rootkey-file=${dns-root-data}/root.key"
    "--enable-pie"
    "--enable-relro-now"
  ] ++ lib.optional stdenv.hostPlatform.isStatic [
    "--disable-flto"
  ] ++ lib.optionals withSystemd [
    "--enable-systemd"
  ] ++ lib.optionals withDoH [
    "--with-libnghttp2=${libnghttp2.dev}"
  ] ++ lib.optionals withECS [
    "--enable-subnet"
  ] ++ lib.optionals withDNSCrypt [
    "--enable-dnscrypt"
    "--with-libsodium=${symlinkJoin { name = "libsodium-full"; paths = [ libsodium.dev libsodium.out ]; }}"
  ] ++ lib.optionals withDNSTAP [
    "--enable-dnstap"
    "--with-protobuf-c=${protobufc}"
  ] ++ lib.optionals withTFO [
    "--enable-tfo-client"
    "--enable-tfo-server"
  ] ++ lib.optionals withRedis [
    "--enable-cachedb"
    "--with-libhiredis=${hiredis}"
  ];

  PROTOC_C = if withDNSTAP then "${protobufc}/bin/protoc-c" else null;

  # Remove references to compile-time dependencies that are included in the configure flags
  postConfigure = let
    inherit (builtins) storeDir;
  in ''
    sed -E '/CONFCMDLINE/ s;${storeDir}/[a-z0-9]{32}-;${storeDir}/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-;g' -i config.h
  '';

  installFlags = [ "configfile=\${out}/etc/unbound/unbound.conf" ];

  postInstall = ''
    make unbound-event-install
    wrapProgram $out/bin/unbound-control-setup \
      --prefix PATH : ${lib.makeBinPath [ openssl ]}
  '';

  preFixup = lib.optionalString (stdenv.isLinux && !stdenv.hostPlatform.isMusl) # XXX: revisit
    # Build libunbound again, but only against nettle instead of openssl.
    # This avoids gnutls.out -> unbound.lib -> openssl.out.
    # There was some problem with this on Darwin; let's not complicate non-Linux.
    ''
      configureFlags="$configureFlags --with-nettle=${nettle.dev} --with-libunbound-only"
      configurePhase
      buildPhase
      installPhase
    ''
  # get rid of runtime dependencies on $dev outputs
  + ''substituteInPlace "$lib/lib/libunbound.la" ''
  + lib.concatMapStrings
    (pkg: lib.optionalString (pkg ? dev) " --replace '-L${pkg.dev}/lib' '-L${pkg.out}/lib' --replace '-R${pkg.dev}/lib' '-R${pkg.out}/lib'")
    (builtins.filter (p: p != null) buildInputs);

  meta = with lib; {
    description = "Validating, recursive, and caching DNS resolver";
    license = licenses.bsd3;
    homepage = "https://www.unbound.net";
    maintainers = with maintainers; [ ehmry fpletz globin ];
    platforms = platforms.unix;
  };
}
