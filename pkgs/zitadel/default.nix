# `@hash:<name>` markers are read by scripts/update-zitadel.sh; do not remove them.
{
  stdenv,
  buildGoModule,
  callPackage,
  lib,
  zitadelSrc,          # flake input, see flake.nix

  buf,
  cacert,
  dart-sass,
  grpc-gateway,
  protoc-gen-connect-go,
  protoc-gen-go,
  protoc-gen-go-grpc,
  protoc-gen-validate,
  statik,
}:

let
  version = "4.16.3";

  zitadelRepo = zitadelSrc;

  d = zitadelSrc.lastModifiedDate;
  buildDate =
    "${lib.substring 0 4 d}-${lib.substring 4 2 d}-${lib.substring 6 2 d}"
    + "T${lib.substring 8 2 d}:${lib.substring 10 2 d}:${lib.substring 12 2 d}Z";

  goModulesHash = "sha256-UmbS5W/3arbV0kXfhu1v4Y4Z0+GUvTXSYA7SciHVTbE="; # @hash:goModules

  buildZitadelProtocGen =
    name:
    buildGoModule {
      pname = "protoc-gen-${name}";
      inherit version;

      src = zitadelRepo;

      proxyVendor = true;
      vendorHash = goModulesHash;

      buildPhase = ''
        go install internal/protoc/protoc-gen-${name}/main.go
      '';

      postInstall = ''
        mv $out/bin/main $out/bin/protoc-gen-${name}
      '';
    };

  protoc-gen-authoption = buildZitadelProtocGen "authoption";
  protoc-gen-zitadel = buildZitadelProtocGen "zitadel";

  generateProtobufCode =
    {
      pname,
      version,
      nativeBuildInputs ? [ ],
      bufArgs ? "",
      workDir ? ".",
      outputPath,
      hash,
    }:
    stdenv.mkDerivation {
      pname = "${pname}-buf-generated";
      inherit version;

      src = zitadelRepo;

      nativeBuildInputs = nativeBuildInputs ++ [
        buf
        cacert
      ];

      buildPhase = ''
        cd ${workDir}
        HOME=$TMPDIR buf generate ${bufArgs}
      '';

      installPhase = ''
        cp -r ${outputPath} $out
      '';

      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
      outputHash = hash;
    };

  protobufGenerated = generateProtobufCode {
    pname = "zitadel";
    inherit version;
    nativeBuildInputs = [
      grpc-gateway
      protoc-gen-authoption
      protoc-gen-connect-go
      protoc-gen-go
      protoc-gen-go-grpc
      protoc-gen-validate
      protoc-gen-zitadel
    ];
    outputPath = ".artifacts";
    hash = "sha256-1INvsNAKusd+7UtXX9RKUUqtEjFPscT6tZ81+8n1ToY="; # @hash:protobufGenerated
  };
in
buildGoModule (finalAttrs: {
  pname = "zitadel";
  inherit version;

  src = zitadelRepo;

  nativeBuildInputs = [
    dart-sass
    statik
  ];

  proxyVendor = true;
  vendorHash = goModulesHash;

  ldflags = [
    "-X 'github.com/zitadel/zitadel/cmd/build.version=v${version}'"
    "-X 'github.com/zitadel/zitadel/cmd/build.commit=${zitadelSrc.shortRev}'"
    "-X 'github.com/zitadel/zitadel/cmd/build.date=${buildDate}'"
  ];

  excludedPackages = [ "apps/login" ];

  doCheck = false;

  preBuild = ''
    substituteInPlace internal/api/ui/login/static/resources/generate.go \
      --replace-fail \
        "//go:generate pnpm sass themes/scss/zitadel.scss themes/zitadel/css/zitadel.css" \
        "//go:generate sass themes/scss/zitadel.scss themes/zitadel/css/zitadel.css"

    mkdir -p pkg/grpc
    cp -r ${protobufGenerated}/grpc/github.com/zitadel/zitadel/pkg/grpc/* pkg/grpc
    mkdir -p openapi/v2/zitadel
    cp -r ${protobufGenerated}/grpc/zitadel/ openapi/v2/zitadel

    go generate internal/api/ui/login/static/resources/generate.go
    go generate internal/api/ui/login/statik/generate.go
    go generate internal/notification/statik/generate.go
    go generate internal/statik/generate.go

    mkdir -p docs/apis/assets
    go run internal/api/assets/generator/asset_generator.go \
      -directory=internal/api/assets/generator/ \
      -assets=docs/apis/assets/assets.md

    cp -r ${finalAttrs.passthru.console}/* internal/api/ui/console/static
  '';

  installPhase = ''
    mkdir -p $out/bin
    install -Dm755 $GOPATH/bin/zitadel $out/bin/
  '';

  passthru = {
    inherit protobufGenerated;
    console = callPackage (import ./console.nix {
      inherit generateProtobufCode version zitadelRepo;
    }) { };
  };

  meta = {
    description = "Identity and access management platform";
    homepage = "https://zitadel.com/";
    downloadPage = "https://github.com/zitadel/zitadel/releases";
    platforms = lib.platforms.linux;
    license = lib.licenses.agpl3Only;
    sourceProvenance = [ lib.sourceTypes.fromSource ];
    mainProgram = "zitadel";
  };
})
