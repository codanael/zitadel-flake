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
  version = "4.19.0";

  zitadelRepo = zitadelSrc;

  d = zitadelSrc.lastModifiedDate;
  buildDate =
    "${lib.substring 0 4 d}-${lib.substring 4 2 d}-${lib.substring 6 2 d}"
    + "T${lib.substring 8 2 d}:${lib.substring 10 2 d}:${lib.substring 12 2 d}Z";

  goModulesHash = "sha256-8/TkV1JTKNSIknzEPbTDWzcOZQ6jCEkc6vSLLhdLYrs="; # @hash:goModules

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
      postPatch ? "",
    }:
    stdenv.mkDerivation {
      pname = "${pname}-buf-generated";
      inherit version postPatch;

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
    hash = "sha256-IhkrjXXm0gkGoZVwYdEYOeuqReEKhAoHqdYdLnYKVYY="; # @hash:protobufGenerated
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

  # `postConfigure`, not `preBuild`: buildGoModule copies the parent's
  # `preBuild` verbatim into the `goModules` fixed-output derivation (see
  # pkgs/build-support/go/module.nix — `prePatch`, `patches`, `postPatch`,
  # `preBuild`, `sourceRoot` and `env` are all inherited, deliberately, to keep
  # vendor hashes stable across nixpkgs). The store paths interpolated below
  # would therefore become build inputs of `zitadel.goModules`, making the Go
  # module cache depend on the console and protobuf derivations — i.e. on every
  # other hash in this repo. Resolving `goModules` first on a version bump then
  # fails inside *those* derivations, which still carry the previous release's
  # hashes, and that is what broke every automatic update after 4.16.3.
  #
  # `postConfigure` is not inherited, and the parent's configurePhase runs it
  # after GOPATH/GOPROXY are exported and after `cd $modRoot`, so the generated
  # files still land before buildPhase. `goModules` stays a leaf that depends on
  # `src` alone.
  postConfigure = ''
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
