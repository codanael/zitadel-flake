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
  inputs.zitadel-flake = {
    url = "github:codanael/zitadel-flake?ref=v4";
    inputs.nixpkgs.follows = "nixpkgs";
  };
}
```

Then, in your NixOS configuration:

```nix
{
  imports = [ zitadel-flake.nixosModules.default ];
  nixpkgs.overlays = [ zitadel-flake.overlays.default ];
  services.zitadel.enable = true;
}
```

> **Import the module, not just the overlay.** This package excludes
> `apps/login` (Zitadel's separate Next.js login v2 application). Zitadel v4
> requires login v2 on *newly created* instances, so without the module's
> `DefaultInstance.Features.LoginV2.Required = false`, every interactive
> login — including the Zitadel console's own — redirects to `/ui/v2/login`,
> which this binary does not serve, and returns 404.

The flake exposes:

- `overlays.default` — adds `zitadel` to `pkgs`.
- `packages.x86_64-linux.zitadel` / `packages.x86_64-linux.default` — the
  package on its own, without the overlay.
- `nixosModules.default` — the hardening and login-v2 settings described
  above.
- `checks.x86_64-linux.zitadel-pg18` — a NixOS VM test that boots this
  package against PostgreSQL 18 and checks `init` and interactive login.

## Binary cache

A public [Cachix](https://www.cachix.org/) cache exists at the address
below, so that consumers won't have to rebuild Zitadel — and its Go and
Node.js/pnpm build graph — from scratch.

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
