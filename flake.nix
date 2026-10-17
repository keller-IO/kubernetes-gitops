{
  description = "keller.io — GitOps and Talos operations dev shell";

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

        # rulesync is not packaged in nixpkgs — vendor the published npm CLI so the
        # tool-native agent configs (AGENTS.md, CLAUDE.md, .claude/, .opencode/,
        # .codex/, .cursor/) are generated from the committed .rulesync/ source via
        # `just agents-setup`. The npm tarball ships a prebuilt dist/, so only its
        # runtime dependencies are installed (devDependencies/scripts stripped in
        # postPatch) and the lockfile lives in nix/rulesync/ (the tarball has none).
        # On a version bump update `version`, the `src` hash, `npmDepsHash`, and
        # regenerate nix/rulesync/package-lock.json (`npm install
        # --package-lock-only` in the unpacked tarball with devDependencies and
        # scripts removed, e.g. `jq 'del(.devDependencies, .scripts)'`).
        rulesync = pkgs.buildNpmPackage rec {
          pname = "rulesync";
          version = "36.0.2";

          src = pkgs.fetchurl {
            url = "https://registry.npmjs.org/rulesync/-/rulesync-${version}.tgz";
            hash = "sha256-65EOUZnMTsnvAjQgmcHb+isngaalnGK9Xw75+cWbTWg=";
          };

          postPatch = ''
            cp ${./nix/rulesync/package-lock.json} package-lock.json
            ${pkgs.jq}/bin/jq 'del(.devDependencies, .scripts)' package.json > package.json.tmp
            mv package.json.tmp package.json
          '';

          dontNpmBuild = true; # dist/ is already built upstream
          npmDepsHash = "sha256-8vIFR1rmDvAx0ieAVmK7BiuEYsGR7VfbRhzRzP4qMN8=";

          meta = {
            description = "Unified AI rules management CLI — generates tool-native agent configs";
            homepage = "https://rulesync.dyoshikawa.com";
            license = pkgs.lib.licenses.mit;
            mainProgram = "rulesync";
          };
        };
      in
      {
        packages.rulesync = rulesync;

        devShells.default = pkgs.mkShell {
          name = "keller.io";

          # Tooling required by validation and cluster operations.
          packages = with pkgs; [
            just # task runner
            renovate # dependency extraction and configuration validation
            kustomize # manifest rendering
            kubeconform # schema validation
            kubernetes-helm # `kustomize build --enable-helm`
            sops # secret encryption
            ksops # KSOPS exec generator for SOPS decryption during kustomize build
            age # age keys for SOPS (age + age-keygen)
            yamllint # YAML linting
            kubectl # cluster access
            talosctl # Talos node diagnostics and maintenance
            jq # parse Kubernetes and Talos JSON output
            cosign # verify container image signatures and provenance
            skopeo # inspect registry image metadata and resolve digests
            trivy # scan container images for vulnerabilities
            yq-go # query, update, and inspect YAML
            podman # run pinned container images for contract tests
            argocd # inspect ArgoCD state
            rulesync # generate tool-native agent configs from .rulesync/
          ];

          shellHook = ''
            echo "keller.io dev shell — run 'just' for available recipes."
          '';
        };
      }
    );
}
