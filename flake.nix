{
  description = "keller.io — GitOps dev shell (kustomize, kubeconform, sops, age, yamllint)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # KSOPS is not packaged in nixpkgs — vendor the released binary so kustomize
        # can run it as an exec generator (--enable-alpha-plugins --enable-exec).
        # Keep the version in sync with the repo-server init container (argocd values +
        # Terraform argocd.tf).
        ksops = pkgs.stdenvNoCC.mkDerivation rec {
          pname = "ksops";
          version = "4.3.2";
          src = pkgs.fetchurl {
            url = "https://github.com/viaduct-ai/kustomize-sops/releases/download/v${version}/ksops_${version}_Linux_x86_64.tar.gz";
            hash = "sha256-Nesao06fIQ4trXZ9SDhV4XawCVQJHE7H53qVjs0LArQ=";
          };
          sourceRoot = ".";
          dontConfigure = true;
          dontBuild = true;
          installPhase = "install -Dm755 ksops $out/bin/ksops";
        };
      in
      {
        devShells.default = pkgs.mkShell {
          name = "keller.io";

          # Tooling required by the justfile recipes and the CI pipeline.
          packages = with pkgs; [
            just # task runner
            kustomize # manifest rendering
            kubeconform # schema validation
            kubernetes-helm # `kustomize build --enable-helm`
            sops # secret encryption
            ksops # KSOPS exec generator for SOPS decryption during kustomize build
            age # age keys for SOPS (age + age-keygen)
            yamllint # YAML linting
            kubectl # cluster access
          ];

          shellHook = ''
            echo "keller.io dev shell — run 'just' for available recipes."
          '';
        };
      }
    );
}
