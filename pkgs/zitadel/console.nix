# `@hash:<name>` markers are read by scripts/update-zitadel.sh; do not remove them.
{
  generateProtobufCode,
  version,
  zitadelRepo,
}:

{
  stdenv,
  fetchPnpmDeps,
  pnpmConfigHook,
  pnpm_10,
  nodejs_22,

  buf,
  cacert,
  grpc-gateway,
  protoc-gen-grpc-web,
}:

let
  nodejs = nodejs_22;

  # console/package.json pins google-protobuf 4.0.2 at runtime. nixpkgs'
  # protoc-gen-js (3.21.4) predates it: the 3.21.4 generator emits jspb
  # reader calls (e.g. readPackedEnum) that google-protobuf 4.x removed.
  # Building the matching upstream tag from source (bzlmod bazel) works but
  # is fragile; buf.build hosts it at the exact matching version as a
  # remote plugin, and consoleProtobuf is already a network-capable FOD, so
  # pin that instead — same fix, far less surface.
  #
  # protoc-gen-grpc-web stays at nixpkgs' 1.5.0 despite console/package.json
  # pinning grpc-web@2.0.2: unlike google-protobuf, grpc-web's npm runtime
  # (GrpcWebClientBase, MethodDescriptor, MethodType) hasn't dropped anything
  # 1.5.0-generated code calls, so there's no runtime defect to fix. Bumping
  # the generator to buf.build/grpc/web:v2.0.2 was tried: it correctly types
  # oneof-member fields in `*.AsObject` as optional (a real fix upstream
  # made), which then fails TS compilation of console app code written
  # against the old (incorrectly non-optional) types — e.g.
  # app-detail.component.ts calling `setMetadataUrl(samlConfig?.metadataUrl)`.
  # Fixing that means patching zitadel's own source, which is out of scope
  # for a generator-version pin.
  consoleProtobuf = generateProtobufCode {
    pname = "zitadel-console";
    inherit version;
    nativeBuildInputs = [
      grpc-gateway
      protoc-gen-grpc-web
    ];
    workDir = "console";
    bufArgs = "../proto --include-imports --include-wkt";
    outputPath = "src/app/proto";
    postPatch = ''
      substituteInPlace console/buf.gen.yaml \
        --replace-fail "plugin: js" "plugin: buf.build/protocolbuffers/js:v4.0.2"
    '';
    hash = "sha256-TZdbyeAXO97MVRtpmKasQ5NiHCHHc27cRiySLNt3l84="; # @hash:consoleProtobuf
  };

  client = stdenv.mkDerivation (finalAttrs: {
    pname = "zitadel-client";
    inherit version;

    src = zitadelRepo;

    pnpmDeps = fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      pnpm = pnpm_10;
      fetcherVersion = 3;
      hash = "sha256-zsH4+rU9A3FAGqufgbadtqz/N0/KbxgvO/tXN0uEyGY="; # @hash:clientPnpmDeps
    };

    pnpmWorkspaces = [
      "@zitadel/proto"
      "@zitadel/client"
    ];

    nativeBuildInputs = [
      pnpmConfigHook
      pnpm_10
      nodejs
    ];

    preBuild = ''
      cp -r ${protoProtobuf}/{cjs,es,types} packages/zitadel-proto
    '';

    buildPhase = ''
      runHook preBuild
      pnpm --filter=@zitadel/client run build
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      cp -r packages/zitadel-client/dist "$out"
      runHook postInstall
    '';
  });

  # packages/zitadel-proto's devDependency @bufbuild/protoc-gen-es (2.12.0,
  # matching console's @bufbuild/protobuf pin) is already pnpm-managed —
  # build with pnpm's own store instead of nixpkgs' protoc-gen-es (2.11.0),
  # so the lockfile governs both the generator and the runtime. Reuses
  # `client`'s pnpmDeps: fetchPnpmDeps fetches the whole workspace lockfile
  # regardless of --filter, so no separate hash needs resolving here.
  protoProtobuf = stdenv.mkDerivation {
    pname = "zitadel-proto-buf-generated";
    inherit version;

    src = zitadelRepo;

    pnpmDeps = client.pnpmDeps;
    pnpmWorkspaces = [ "@zitadel/proto" ];

    nativeBuildInputs = [
      pnpmConfigHook
      pnpm_10
      nodejs
      buf
      cacert
    ];

    buildPhase = ''
      runHook preBuild
      pnpm --filter=@zitadel/proto run generate
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r packages/zitadel-proto/{cjs,es,types} $out/
      runHook postInstall
    '';

    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-EpDC7g/zrMA+z6JBionD1CZYU1/JHWUYUNdgQsYmTiI="; # @hash:protoProtobuf
  };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "zitadel-console";
  inherit version;

  src = zitadelRepo;

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    pnpm = pnpm_10;
    fetcherVersion = 3;
    hash = "sha256-zsH4+rU9A3FAGqufgbadtqz/N0/KbxgvO/tXN0uEyGY="; # @hash:consolePnpmDeps
  };

  pnpmWorkspaces = [
    "@zitadel/proto"
    "@zitadel/client"
    "console"
  ];

  nativeBuildInputs = [
    pnpmConfigHook
    pnpm_10
    nodejs
  ];

  preBuild = ''
    cp -r ${consoleProtobuf} console/src/app/proto
    cp -r ${protoProtobuf}/{cjs,es,types} packages/zitadel-proto
    cp -r ${client} packages/zitadel-client/dist
  '';

  buildPhase = ''
    runHook preBuild
    pnpm --filter=console run build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    cp -r console/dist/console "$out"
    runHook postInstall
  '';

  passthru = {
    inherit consoleProtobuf protoProtobuf client;
  };
})
