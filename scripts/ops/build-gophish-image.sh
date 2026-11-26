#!/usr/bin/env bash
# Local build/test/scan only: never pushes an image or changes the cluster.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
recipe="$repo_root/images/gophish"
image="localhost/gophish-rebuild:0.12.1-go1.27.4"
contract_image="localhost/gophish-rebuild-contract:0.12.1-go1.27.4"
output="${1:?Usage: build-gophish-image.sh OUTPUT_DIRECTORY}"
mkdir -p "$output"
output="$(realpath "$output")"
work="$(mktemp -d /tmp/opencode/gophish-build.XXXXXX)"
trap 'rm -rf -- "$work"' EXIT
result="$work/result"
mkdir -p "$result"
source_ref="$(<"$recipe/source-ref.txt")"
if [[ ! "$source_ref" =~ ^[a-f0-9]{40}$ ]]; then
  echo "Invalid upstream source commit" >&2
  exit 1
fi

git init --quiet "$work/source"
git -C "$work/source" remote add origin https://github.com/gophish/gophish.git
git -C "$work/source" fetch --quiet --depth 1 origin "$source_ref"
git -C "$work/source" -c advice.detachedHead=false checkout --quiet --detach FETCH_HEAD
[[ "$(git -C "$work/source" rev-parse HEAD)" == "$source_ref" ]]
# Zero-context format avoids false whitespace errors in the stored Go diff.
# Safe here because the exact pristine source commit was verified immediately above.
git -C "$work/source" apply --unidiff-zero --check "$recipe/source.patch"
git -C "$work/source" apply --unidiff-zero "$recipe/source.patch"
cp "$recipe/go.mod" "$recipe/go.sum" "$work/source/"
cp "$recipe/Containerfile" "$work/source/Containerfile.rebuild"
cp "$recipe/bootstrap_security_test.go" "$work/source/models/"
mkdir -p "$work/source/rebuildcontract"
cp "$recipe/contract_test.go" "$work/source/rebuildcontract/"
cp "$recipe/contract-config.json" "$work/source/"
printf '.git\n.cache\n' > "$work/source/.containerignore"

podman build --layers --target runtime --file "$work/source/Containerfile.rebuild" \
  --tag "$image" "$work/source"
podman build --layers --target contract --file "$work/source/Containerfile.rebuild" \
  --tag "$contract_image" "$work/source"
podman run --rm --network=none --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges --user 10001:10001 --pids-limit 128 \
  --memory 512m --cpus 1 --tmpfs /data:rw,mode=1777 "$contract_image"

podman save --format docker-archive --output "$result/gophish.docker.tar" "$image"
trivy image --input "$result/gophish.docker.tar" --scanners vuln \
  --format json --output "$result/trivy.json"
python3 "$recipe/check_scan.py" "$result/trivy.json"
podman save --format oci-archive --output "$result/gophish.oci.tar" "$image"
podman image inspect "$image" --format '{{.Id}}' > "$result/image-id.txt"
(cd "$result" && sha256sum gophish.oci.tar > archive.sha256)
# Export fresh archives, never ask podman to modify an earlier Docker archive.
# Retain the previous successful artifacts if build/test/scan fails.
mv -- "$result/gophish.docker.tar" "$result/gophish.oci.tar" \
  "$result/trivy.json" "$result/image-id.txt" "$result/archive.sha256" "$output/"
printf 'Local tested image: %s\nArtifacts: %s\nNo image published; no cluster changes.\n' \
  "$image" "$output"
