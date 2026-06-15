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
