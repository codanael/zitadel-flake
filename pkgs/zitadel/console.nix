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

  grpc-gateway,
  protoc-gen-es,
  protoc-gen-grpc-web,
  protoc-gen-js,
}:

let
  nodejs = nodejs_22;

  consoleProtobuf = generateProtobufCode {
    pname = "zitadel-console";
    inherit version;
    nativeBuildInputs = [
      grpc-gateway
      protoc-gen-grpc-web
      protoc-gen-js
    ];
    workDir = "console";
    bufArgs = "../proto --include-imports --include-wkt";
    outputPath = "src/app/proto";
    hash = "sha256-OVMxgFfnJ0oV0AIW7oOOBxCizMxP+xuj3ggvYA3yZgo="; # @hash:consoleProtobuf
  };

  protoProtobuf = generateProtobufCode {
    pname = "zitadel-proto";
    inherit version;
    nativeBuildInputs = [ protoc-gen-es ];
    workDir = "packages/zitadel-proto";
    bufArgs = "../../proto";
    outputPath = ".";
    hash = "sha256-ObYXT9bQsfnoHQ80waw10GSfdSkFuuQ9gxNvyzK22Fg="; # @hash:protoProtobuf
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
