# zitadel-flake

A Nix flake that builds [Zitadel](https://zitadel.com/) from source and ships
a NixOS module to run it.

## What this is

nixpkgs is stuck on Zitadel **2.71.7**. The upstream pull request that would
bring nixpkgs to v4, [NixOS/nixpkgs#448518](https://github.com/NixOS/nixpkgs/pull/448518),
never landed. The likely cause: it omits `protoc-gen-es` from
`nativeBuildInputs`, even though `console/buf.gen.yaml` declares it as a
`local:` plugin, so `buf` looks for it on `PATH` and doesn't find it.

This repository packages Zitadel independently of nixpkgs, from a pinned
upstream source tag, kept current with a scheduled update workflow.

## Usage

```nix
{
  inputs.zitadel-flake.url = "github:codanael/zitadel-flake?ref=v4";
}
```

Do **not** add `inputs.nixpkgs.follows = "nixpkgs"` — see "Binary cache" below.

Then, in your NixOS configuration:

```nix
{
  inputs.zitadel-flake.url = "github:codanael/zitadel-flake?ref=v4";

  outputs = { self, nixpkgs, zitadel-flake, ... }: {
    nixosConfigurations.example = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        zitadel-flake.nixosModules.default
        { services.zitadel.enable = true; }
      ];
    };
  };
}
```

> **Import the module.** Besides the hardening and login-v2 settings below,
> it also sets `services.zitadel.package` to this flake's own prebuilt
> package (`lib.mkDefault`, so it's still overridable). This package excludes
> `apps/login` (Zitadel's separate Next.js login v2 application). Zitadel v4
> requires login v2 on *newly created* instances, so without the module's
> `DefaultInstance.Features.LoginV2.Required = false`, every interactive
> login — including the Zitadel console's own — redirects to `/ui/v2/login`,
> which this binary does not serve, and returns 404.

The flake exposes:

- `packages.x86_64-linux.zitadel` / `packages.x86_64-linux.default` — the
  package, built against this flake's own locked nixpkgs. This is what the
  binary cache serves.
- `overlays.default` — adds `zitadel` to `pkgs`, built against **your**
  nixpkgs. Convenient if you need the package outside `services.zitadel`,
  but see "Binary cache" below before reaching for it.
- `nixosModules.default` — the hardening and login-v2 settings described
  above; sets `services.zitadel.package` to `packages.<system>.zitadel`.
- `checks.x86_64-linux.zitadel-pg18` — a NixOS VM test that boots this
  package against PostgreSQL 18 and checks `init` and that login v2 is not
  required.

## Binary cache

A public [Cachix](https://www.cachix.org/) cache exists at the address
below. CI builds and pushes exactly one derivation to it:
`packages.<system>.zitadel`, built against **this flake's own locked
nixpkgs**.

Cache hits require consuming that same derivation. Importing
`nixosModules.default` gets you this for free (it sets
`services.zitadel.package` to it). If instead you apply `overlays.default`
against your own nixpkgs — most commonly by adding
`inputs.nixpkgs.follows = "nixpkgs"` to this flake's input — you get a
*different* derivation, evaluated against your nixpkgs, which was never
pushed anywhere: guaranteed cache miss, and a full local rebuild of Zitadel's
Go and Node.js/pnpm build graph.

```nix
{
  nix.settings = {
    substituters = [ "https://codanael-zitadel.cachix.org" ];
    trusted-public-keys = [
      "codanael-zitadel.cachix.org-1:EIfK6KfgpTFK1wcCgEKvkNeGU9aFK7Aql1a+V126+Ac="
    ];
  };
}
```

Or, with `cachix`:

```bash
cachix use codanael-zitadel
```

Without the substituter, `nix build` still works — it just builds Zitadel
(and its protobuf/console/Go dependencies) locally instead of fetching a
prebuilt closure.

## License

The Nix expressions in this repository (`pkgs/`, `modules/`, `tests/`, the
flake itself) are licensed under the [MIT License](./LICENSE), copyright
2026 codanael.

Zitadel itself, built from source by this flake, is licensed under
[AGPL-3.0](https://github.com/zitadel/zitadel/blob/main/LICENSE). This
repository's license does not change or relax that — anything built from
`zitadel-src` remains AGPL-3.0.
