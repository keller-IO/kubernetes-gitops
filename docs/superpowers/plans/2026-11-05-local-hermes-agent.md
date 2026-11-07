# Local Hermes Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install and accept a local CLI-only Hermes Agent whose 27B Vulkan model falls back to GWDG SAIA and then Blablador while agent tools run in rootless Podman.

**Architecture:** Hermes runs on the host and owns a pinned `llama.cpp` Vulkan runtime plus the local GGUF. Its `llamacpp` main route has two named OpenAI-compatible fallback providers. Terminal, file, and code execution use Hermes' Docker-compatible backend forced to rootless Podman. The launch directory is the only general host workspace; Hermes v0.22.7 additionally mounts its sandbox home writable and its own skill, attachment, and cache staging directories read-only.

**Tech Stack:** Hermes Agent v0.22.7, llama.cpp b11671 Vulkan, Qwen3.8-27B UD-Q4_K_M GGUF, OpenAI-compatible APIs, rootless Podman, YAML configuration.

**Spec:** `docs/superpowers/specs/2026-11-05-local-hermes-agent-design.md`

## Global Constraints

- Install Hermes Agent v0.22.7 from commit `b200f5bc60e31588ba2cb60e288029c4a54ba5fa` with browser and computer-use components disabled.
- Use only `Qwen3.8-27B-UD-Q4_K_M.gguf` from Hugging Face revision `4ca720788d1e01f1bff70c033e0d0028fd02e502` as the local main model.
- Require model size `16464440224` bytes and SHA-256 `322e194ff79741c7baa497c240f677f54b201b0efab44ca8e50f122b39123482` before publishing the final filename.
- Use `custom:saia:qwen3-coder-next` before `custom:blablador:alias-code` in `fallback_providers`.
- Never print, log, commit, or place `SAIA_API_KEY` or `BLABLADOR_API_KEY` in command-line arguments.
- Keep provider credentials out of the Podman sandbox; `docker_forward_env` and `env_passthrough` remain empty.
- Use rootless `/usr/bin/podman`, eight CPUs, 16384 MiB memory, a persistent container, writable current-directory mount, and enabled networking.
- Enable only `terminal`, `file`, `web`, `skills`, `todo`, `memory`, `session_search`, and `clarify` for CLI sessions.
- Do not modify Kubernetes, the live cluster, `/etc/hermes`, or the existing Hermes deployment on other systems.
- Do not commit `~/.hermes`, model files, credentials, generated Podman state, or any backup archive.

## Review Focus

- Missing or empty `SAIA_API_KEY` or missing `BLABLADOR_API_KEY` in the protected source must abort before `.env` replacement; Task 3 tests this precondition.
- A partial, wrong-sized, or checksum-mismatched GGUF must never appear under the final `.gguf` name; Task 2 downloads to `.part` and verifies both size and SHA-256 before rename.
- Vulkan runtime absence or failure must stop acceptance instead of silently accepting CPU inference; Tasks 2 and 4 verify the installed backend and runtime log.
- The 262,144-token local model still starts with the reduced CLI toolset rather than the full preset; Tasks 3 and 4 read back and exercise the exact list.
- The Podman container must expose the selected workspace, its Hermes-managed sandbox home, and only the reviewed Hermes-owned read-only support mounts. It must expose neither provider variables nor unrelated host paths; Task 4 inspects mounts and executes negative environment checks.

---

## File Structure

- `~/.local/bin/hermes`: installer-owned CLI launcher; create through the pinned installer only.
- `~/.hermes/hermes-agent/`: installer-owned v0.22.7 source checkout; do not edit it.
- `~/.hermes/models/Qwen3.8-27B-UD-Q4_K_M.gguf`: verified local model artifact.
- `~/.hermes/config.yaml`: non-secret provider, fallback, runtime, toolset, and Podman configuration.
- `~/.hermes/.env`: mode-0600 credential file containing only runtime environment values and provider secrets.
- `~/.hermes/backups/pre-local-setup-<timestamp>/`: local pre-change copy of existing configuration files when present.
- Hermes-managed Podman volumes and containers: persistent sandbox state; never edit their storage directly.

### Task 1: Preflight, Backup, and Pinned Hermes Installation

**Files:**
- Create: `~/.local/bin/hermes` through the installer
- Create: `~/.hermes/hermes-agent/` through the installer
- Create if needed: `~/.hermes/backups/pre-local-setup-<timestamp>/`
- Preserve if present: `~/.hermes/config.yaml`, `~/.hermes/.env`, `~/.hermes/auth.json`

**Interfaces:**
- Consumes: openSUSE host with `git`, `curl`, `tar`, SHA-256 utilities, Vulkan, and rootless Podman.
- Produces: a working Hermes v0.22.7 CLI and a private pre-change backup path for rollback.

- [ ] **Step 1: Prove host prerequisites without changing state**

Run:

```bash
command -v git curl sha256sum podman vulkaninfo
podman info --format '{{.Host.Security.Rootless}}'
vulkaninfo --summary
test -n "${SAIA_API_KEY:-}"
test -r /home/ingo/ansible/apikey.env
```

Expected: every command exists, Podman prints `true`, Vulkan lists the AMD Radeon device, and both credential-source checks exit 0 without printing key values.

- [ ] **Step 2: Back up existing Hermes control files if they exist**

First run `ls "$HOME"` to verify the backup parent. If `~/.hermes` already exists, run:

```bash
backup_dir="$HOME/.hermes/backups/pre-local-setup-$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 0700 "$backup_dir"
: > "$backup_dir/absent-files"
for name in config.yaml .env auth.json; do
  if test -f "$HOME/.hermes/$name"; then
    cp -a "$HOME/.hermes/$name" "$backup_dir/$name"
  else
    printf '%s\n' "$name" >> "$backup_dir/absent-files"
  fi
done
```

Expected: the backup directory contains only existing control files plus `absent-files`, which names every control file that did not exist before the change, and is not inside the Git worktree. If `~/.hermes` does not exist yet, create the same backup directory after installation with all three names in `absent-files` and no copies.

- [ ] **Step 3: Download and verify the pinned installer**

Run:

```bash
installer_dir=$(mktemp -d)
installer="$installer_dir/hermes-install-v0.22.7.sh"
curl -fsSLo "$installer" \
  https://raw.githubusercontent.com/NousResearch/hermes-agent/b200f5bc60e31588ba2cb60e288029c4a54ba5fa/scripts/install.sh
printf '%s  %s\n' \
  abf338605dae6dd28d101673ac6aed7995c955745db46d47676bc591a7957209 \
  "$installer" | sha256sum --check --strict
```

Expected: `...: OK`. Keep `installer_dir` and `installer` in the same shell for Step 4.

- [ ] **Step 4: Install the exact release without optional desktop tools**

Run:

```bash
bash "$installer" \
  --commit b200f5bc60e31588ba2cb60e288029c4a54ba5fa \
  --skip-browser --skip-computer-use --non-interactive
rm -f -- "$installer" && rmdir -- "$installer_dir"
```

Expected: installer exits 0 and creates `~/.local/bin/hermes` without launching an interactive setup wizard.

- [ ] **Step 5: Verify installation identity**

Run:

```bash
export PATH="$HOME/.local/bin:$PATH"
hash -r
"$HOME/.local/bin/hermes" --version
git -C "$HOME/.hermes/hermes-agent" rev-parse HEAD
```

Expected: version contains `0.22.7`; Git prints exactly `b200f5bc60e31588ba2cb60e288029c4a54ba5fa`; `command -v hermes` resolves to `~/.local/bin/hermes` for the remaining steps.

### Task 2: Verified Local Model and Vulkan Runtime

**Files:**
- Create: `~/.hermes/models/Qwen3.8-27B-UD-Q4_K_M.gguf`
- Create temporarily: `~/.hermes/models/Qwen3.8-27B-UD-Q4_K_M.gguf.part`
- Modify: `~/.hermes/config.yaml` through `hermes config set`
- Create: Hermes PM-owned `llamacpp-vulkan` runtime files

**Interfaces:**
- Consumes: Hermes CLI from Task 1 and the immutable Hugging Face model revision.
- Produces: verified model ID `Qwen3.8-27B-UD-Q4_K_M`, llama.cpp Vulkan runtime, and enabled managed local runtime configuration.

- [ ] **Step 1: Verify the Hermes data parent before creating the model directory**

Run `ls "$HOME/.hermes"`, then create `~/.hermes/models` with mode `0755` if absent.

Expected: the directory belongs to the current user and is outside every Git worktree.

- [ ] **Step 2: Download to an unpublished partial filename**

Run:

```bash
curl --fail --location --continue-at - \
  --output "$HOME/.hermes/models/Qwen3.8-27B-UD-Q4_K_M.gguf.part" \
  "https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/4ca720788d1e01f1bff70c033e0d0028fd02e502/Qwen3.8-27B-UD-Q4_K_M.gguf?download=true"
```

Expected: curl exits 0; interrupted runs retain the `.part` file for resume.

- [ ] **Step 3: Reject incomplete or changed model content**

Run:

```bash
test "$(stat -c %s "$HOME/.hermes/models/Qwen3.8-27B-UD-Q4_K_M.gguf.part")" = 16464440224
printf '%s  %s\n' \
  322e194ff79741c7baa497c240f677f54b201b0efab44ca8e50f122b39123482 \
  "$HOME/.hermes/models/Qwen3.8-27B-UD-Q4_K_M.gguf.part" | sha256sum --check --strict
```

Expected: size check and SHA-256 check pass. On failure, keep the `.part` suffix for investigation and stop; never rename it.

- [ ] **Step 4: Publish the verified GGUF atomically**

Rename the verified `.part` file to `Qwen3.8-27B-UD-Q4_K_M.gguf` on the same filesystem.

Expected: only the final complete file appears in Hermes' model listing; no `.part` file remains.

- [ ] **Step 5: Install the Hermes-pinned Vulkan engine**

Run:

```bash
hermes pm install llamacpp-vulkan
hermes pm doctor
```

Expected: PM reports `llamacpp-vulkan` installed and healthy; the stable release pin resolves to llama.cpp `b11671`. Stop if Vulkan installation fails; do not install or accept the CPU backend as a substitute.

- [ ] **Step 6: Select the managed local runtime and model**

Run:

```bash
hermes config set local_runtime.backend vulkan
hermes config set local_runtime.enabled true
hermes config set model.provider llamacpp
hermes config set model.default Qwen3.8-27B-UD-Q4_K_M
```

Expected: `hermes config get local_runtime --json` shows `enabled: true` and `backend: vulkan`; `hermes config get model --json` shows the exact provider and model ID.

### Task 3: Provider, Toolset, Podman, and Secret Configuration

**Files:**
- Modify: `~/.hermes/config.yaml` through `hermes config set`
- Modify atomically: `~/.hermes/.env`
- Read only: `/home/ingo/ansible/apikey.env`

**Interfaces:**
- Consumes: local runtime from Task 2, exported `SAIA_API_KEY`, protected `BLABLADOR_API_KEY` source, and `/usr/bin/podman`.
- Produces: complete three-route policy, reduced CLI toolset, rootless Podman backend, and mode-0600 secret environment.

- [ ] **Step 1: Fail closed before touching `.env` if either source credential is absent**

Start one Bash process with xtrace disabled. The first portion must succeed before creating a temporary file:

```bash
set +x
set -euo pipefail
: "${SAIA_API_KEY:?SAIA_API_KEY is not exported}"
saia_key=$SAIA_API_KEY
unset BLABLADOR_API_KEY
set -a
source /home/ingo/ansible/apikey.env
set +a
: "${BLABLADOR_API_KEY:?BLABLADOR_API_KEY is absent from protected source}"
blablador_key=$BLABLADOR_API_KEY
```

Expected: success is silent. Any missing value aborts before a temporary `.env` file is created. The `unset` ensures that only the protected source, not an inherited environment value, can satisfy the Blablador check.

- [ ] **Step 2: Replace only the three managed `.env` entries atomically**

Continue in the same Bash process so the variables never cross a process boundary:

```bash
env_path="$HOME/.hermes/.env"
umask 077
tmp=$(mktemp "${env_path}.tmp.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
: > "$tmp"
if test -f "$env_path"; then
  while IFS= read -r line || test -n "$line"; do
    case "$line" in
      SAIA_API_KEY=*|BLABLADOR_API_KEY=*|HERMES_DOCKER_BINARY=*) continue ;;
    esac
    printf '%s\n' "$line" >> "$tmp"
  done < "$env_path"
fi
printf 'SAIA_API_KEY=%s\n' "$saia_key" >> "$tmp"
printf 'BLABLADOR_API_KEY=%s\n' "$blablador_key" >> "$tmp"
printf 'HERMES_DOCKER_BINARY=%s\n' /usr/bin/podman >> "$tmp"
chmod 0600 "$tmp"
mv -f -- "$tmp" "$env_path"
trap - EXIT
unset saia_key blablador_key BLABLADOR_API_KEY
```

Expected: `stat -c '%a %U' ~/.hermes/.env` prints `600` and the current username. Name-only checks confirm each managed variable occurs exactly once; no command displays values.

- [ ] **Step 3: Configure named providers and fast failover**

Run:

```bash
hermes config set providers.saia.api https://chat-ai.academiccloud.de/v1
hermes config set providers.saia.key_env SAIA_API_KEY
hermes config set providers.saia.transport chat_completions
hermes config set providers.saia.default_model qwen3-coder-next
hermes config set providers.saia.request_timeout_seconds 900
hermes config set providers.saia.stale_timeout_seconds 180
hermes config set providers.blablador.api https://api.blablador.fz-juelich.de/v1
hermes config set providers.blablador.key_env BLABLADOR_API_KEY
hermes config set providers.blablador.transport chat_completions
hermes config set providers.blablador.default_model alias-code
hermes config set providers.blablador.request_timeout_seconds 900
hermes config set providers.blablador.stale_timeout_seconds 180
hermes config set fallback_providers \
  '[{"provider":"custom:saia","model":"qwen3-coder-next"},{"provider":"custom:blablador","model":"alias-code"}]'
hermes config set fallback.min_switch_reset_seconds 0
hermes config set agent.api_max_retries 1
hermes config set agent.auto_recovery_cycles 0
```

Expected: `hermes config get fallback_providers --json` preserves SAIA first and Blablador second; no literal key appears in `config.yaml`.

- [ ] **Step 4: Configure the reduced CLI tool surface**

Run:

```bash
hermes config set platform_toolsets.cli \
  '["terminal","file","web","skills","todo","memory","session_search","clarify"]'
```

Expected: `hermes config get platform_toolsets.cli --json` equals the eight-item list and contains no `hermes-cli`, browser, cron, messaging, or delegation preset.

- [ ] **Step 5: Configure the persistent rootless Podman sandbox**

Run:

```bash
hermes config set terminal.backend docker
hermes config set terminal.docker_mount_cwd_to_workspace true
hermes config set terminal.container_cpu 8
hermes config set terminal.container_memory 16384
hermes config set terminal.container_disk 0
hermes config set terminal.container_persistent true
hermes config set terminal.docker_persist_across_processes true
hermes config set terminal.docker_network true
hermes config set terminal.docker_forward_env '[]'
hermes config set terminal.env_passthrough '[]'
```

Expected: config readback has the exact values. Leave `terminal.docker_image` unset so Hermes v0.22.7 owns the compatible default. The explicit zero disables Hermes' otherwise-default 50-GB storage quota, so Podman storage-driver quota support is not assumed.

Then inspect pre-existing credential mounts before any sandbox exists:

```bash
hermes config get terminal.credential_files --json
```

Expected: the list is empty or absent. Hermes mounts every configured entry read-only into the container, and this config path does not apply the `.env`/`auth.json` block list used for skill-registered files. Remove any entry before the first tool call; empty `docker_forward_env` and `env_passthrough` do not cover this path.

- [ ] **Step 6: Validate the complete static configuration**

Run:

```bash
hermes config check
hermes doctor
```

Expected: no invalid provider, model, runtime, terminal backend, or toolset errors. Optional-provider warnings unrelated to the selected configuration do not block acceptance.

### Task 4: End-to-End Acceptance and Recovery

**Files:**
- Read: `~/.hermes/logs/llama-server.log`
- Read: `~/.hermes/config.yaml`
- Inspect: Hermes-labeled rootless Podman container

**Interfaces:**
- Consumes: complete Task 3 configuration.
- Produces: evidence for local inference, direct SAIA and Blablador routes, Podman isolation, and local-to-SAIA recovery.

- [ ] **Step 1: Start the local model and prove basic inference**

From the intended repository directory, run:

```bash
hermes chat --provider llamacpp \
  --model Qwen3.8-27B-UD-Q4_K_M \
  -q 'Reply with exactly LOCAL_OK.'
```

Expected: response contains `LOCAL_OK`, provider/model status names `llamacpp` and the exact model ID, and no cloud fallback notice appears.

- [ ] **Step 2: Prove Vulkan rather than CPU acceptance**

Inspect `hermes status` and the current `~/.hermes/logs/llama-server.log` for the active backend and GPU placement.

Expected: runtime backend is `vulkan`, the AMD Radeon device is selected, and the model is not reported as CPU-only. Any CPU-only launch blocks acceptance.

- [ ] **Step 3: Create the sandbox through an explicit terminal tool call**

Run a local-model one-shot that instructs Hermes to use the terminal tool to execute `pwd` and `printf SANDBOX_OK`, then return both outputs.

Expected: tool output reports `/workspace` and `SANDBOX_OK`; the command executes in a Hermes-labeled Podman container.

- [ ] **Step 4: Inspect the sandbox boundary deterministically**

Use `podman ps --filter label=hermes-agent=1` to identify the current profile's running container. Inspect its mounts and execute these checks inside it:

```bash
test -d /workspace
test -z "${SAIA_API_KEY:-}${BLABLADOR_API_KEY:-}"
test ! -e /home/ingo/.ssh
test ! -e /home/ingo/.kube
```

Classify every bind mount. `/workspace` must be the only general host workspace
and must be writable. The writable `/root` source must remain below
`~/.hermes/sandboxes/docker/`. Every other source must be a directory below
`~/.hermes` mounted read-only for Hermes skills, attachments, or cache staging;
no credential-file bind mount may be present. Hermes v0.22.7 creates these
support mounts unconditionally, but explicitly blocks its master `.env` and
`auth.json` stores from that mechanism.

Also inspect resource fields with:

```bash
podman inspect --format '{{.HostConfig.Memory}} {{.HostConfig.NanoCpus}}' "$container_id"
```

Expected: the workspace mount source is the directory where Hermes was launched, the mount classification and all four checks pass, the resource fields are `17179869184 8000000000`, no storage-size option is present, and the container runs under rootless Podman. If the rootless cgroup probe made Hermes omit CPU or memory limits, stop acceptance and fix cgroup delegation rather than accepting an unbounded sandbox. Fixing delegation does not change the existing persistent container, which Hermes would reuse. At this point it holds only the Step 3 sentinel state, so remove exactly that unbounded Hermes-labeled container with `podman rm -f "$container_id"`, then repeat Steps 3 and 4 and accept only when the resource fields match. No other agent tool call may run against an unbounded container. Do not print the container environment.

- [ ] **Step 5: Test SAIA directly with chat and one terminal tool call**

Run one exact-response prompt and one prompt that requires the terminal tool using `--provider custom:saia --model qwen3-coder-next`.

Expected: chat returns the requested sentinel; the tool call executes in the same Podman sandbox and returns its sentinel without exposing provider credentials.

- [ ] **Step 6: Test Blablador directly with chat and one terminal tool call**

Repeat Step 5 with `--provider custom:blablador --model alias-code`.

Expected: chat and tool calling succeed. This verifies the third route directly; it does not claim a second fallback activation in the same turn.

- [ ] **Step 7: Prove automatic local-to-SAIA fallback from a real request-time failure**

Do not set `local_runtime.enabled` to `false`: Hermes v0.22.7 treats that
administrative switch as a non-fallback configuration error. Accept only
evidence from a genuine request-time failure of the active local server. For
this implementation, correlate the observed Vulkan `ErrorDeviceLost`, the
visible fallback notice, the exact `custom:saia:qwen3-coder-next` activation
log, and the requested response sentinel. A future fresh acceptance must
capture another genuine request-time failure or use an upstream-supported
fault-injection mechanism; do not destabilize the GPU merely to manufacture
one.

Expected: the failed local request switches to `custom:saia`, SAIA returns the
requested sentinel, and `local_runtime.enabled` remains `true` throughout.

- [ ] **Step 8: Prove the next turn returns to the local primary**

Start a fresh default-provider one-shot requesting `LOCAL_RESTORED`.

Expected: response contains `LOCAL_RESTORED`, status names `llamacpp`, and no fallback notice appears.

- [ ] **Step 9: Run final diagnostics and inspect repository state**

Run:

```bash
hermes config check
hermes doctor
git status --short
```

Expected: Hermes diagnostics pass the selected configuration. Git shows only the reviewed design and plan documents; it must not show credentials, model data, Hermes state, or generated Podman files.

## Rollback Procedure

1. Stop active Hermes CLI processes and leave managed model files in place unless deletion is explicitly requested.
2. Restore each of `config.yaml`, `.env`, and `auth.json` that exists in the Task 1 backup, preserving mode `0600` for secret-bearing files.
3. Independently of step 2, remove each of these three files that is listed in the backup's `absent-files`, so a file that did not exist before the change does not survive the rollback. Do not remove the model, runtime, sessions, or sandbox without separate approval.
4. Verify rollback with `hermes config check` and `hermes doctor`.
5. Remove the Hermes-labeled Podman container or the 16.5-GB GGUF only on explicit request because both are destructive and force recreation or redownload.
6. To revert the host-runtime corrections, remove the Hermes delegation
   drop-in below `/etc/systemd/system/user@1000.service.d/`, run
   `systemctl daemon-reload`, and start a new login session; remove `ingo` from
   the `render` group and remove the `user:ingo` ACL from
   `/dev/dri/renderD128` only if no other local GPU workflow needs them.
7. Remove the exact `LLAMA_ARG_N_PARALLEL=1` entry from `~/.hermes/.env` only
   when restoring automatic llama.cpp slot selection; doing so restores the
   observed multi-slot Vulkan instability risk on this host.
