<!--
  SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
  SPDX-License-Identifier: Apache-2.0
-->

# Agent Scaling: NemoClaw Kubernetes autoscaling on multi-GPUs

| Catalog field | Value |
| --- | --- |
| Description | One Fabric sandbox per end user, with GPU inference scaled by Kubernetes HPA. |
| Industry | Cloud Services |
| Requirements | Kubernetes 1.25+ · Helm 3 or 4 · NVIDIA GPU Operator and DCGM · Metrics Server · Docker Buildx · OpenShell CLI matching [`versions.json`](../../versions.json) · a NemoClaw bundle built from this checkout · experimental |
| NemoClaw | this checkout (`nemoclaw.nvidia.com/v1alpha1`) |
| Harness | OpenClaw, Hermes, or Deep Agents |
| OpenShell | the version in [`versions.json`](../../versions.json) |

This example runs one Fabric sandbox per end user and scales GPU inference from 1 to N pods, one GPU each. OpenClaw uses Ollama, Hermes uses vLLM, and Deep Agents uses NIM. `nemoclaw apply` creates the sandboxes in namespace `nemoclaw-v1-agents`. The Helm chart in this directory serves inference in namespace `nemoclaw-gpu`.

The GPU Deployment, HPA, and pods are named by pairing: `openclaw-ollama`, `hermes-vllm`, or `deepagents-nim`. Sandboxes call the chart Service, which keeps the historical DNS name:

```text
http://<release>-metrics-proxy.nemoclaw-gpu.svc.cluster.local:8081/v1
```

`./scripts/install-runtimes.sh` installs Helm releases `nemoclaw-gpu-ollama`, `nemoclaw-gpu-vllm`, and `nemoclaw-gpu-nim` in `nemoclaw-gpu`. Do not keep a Helm release named `nemoclaw-gpu` there; those Deployment names collide. The chart generates a local inference API key in Secret `<release>-metrics-proxy-inference-api`. Do not print that key, and do not commit it.

Kubernetes HPA scales the inference pods on a Pods `AverageValue` metric. GPU utilization targets 40%. LLM latency targets 3000 ms. `./scripts/set-hpa-metric.sh` switches the metric without changing the runtime or the sandboxes.

v1 has no release download and no published Fabric agent images ([#12638](https://github.com/NVIDIA/NemoClaw/issues/12638)). Build the CLI bundle and the agent images from this checkout. NemoClaw does not place NIM ([#12649](https://github.com/NVIDIA/NemoClaw/issues/12649)); this chart does, with `INFERENCE_RUNTIME=nim`.

## Deployment architecture

<img width="1672" height="941" alt="architecture" src="https://github.com/user-attachments/assets/4e61491d-7a8b-4ce7-9910-9715965e4e7c" />

One end user, one sandbox, one agent. `nemoclaw apply` installs a managed OpenShell gateway and starts `fabric-agent-ctl serve` in each sandbox. These files set `authentication.profile: development`. Only NemoClaw can mint those tokens.

A load test sends each prompt with `kubectl exec` into `fabric-agent-ctl invoke`. That skips gateway auth. The operator command is `./scripts/invoke.sh`, which runs `openshell sandbox exec`. `development` gives the OpenShell CLI no token, so `invoke.sh` waits until you switch the file to `oidc` and register the gateway.

Inference is the GPU chart Service `/v1` above. Envoy, when installed, load-balances with LeastRequest. Each GPU pod is 2/2 Ready when healthy: the inference runtime (`ollama`, `vllm`, or `nim`) and `metrics-proxy` (auth, `/v1`, health, `/metrics`).

LLM latency is chat-completions duration on that GPU pod, averaged over completed samples from the last 30 seconds. In-flight chats do not count. After 15 seconds with no completed sample the gauge publishes 0 so HPA can scale down. That 0 is not 0 ms of latency.

## Prerequisites

You need an existing Kubernetes cluster. This example does not install Kubernetes, the GPU Operator, or a local k3s. `kubectl get nodes` must succeed with a kubeconfig you control. Set `KUBECONFIG` and `NEMOCLAW_CLUSTER_KUBECONFIG` to that file when `~/.kube/config` is missing or does not reach the API.

Confirm the following before you build or apply. Cluster setup belongs to the platform operator; NemoClaw does not check it.

| Requirement | What to confirm |
| --- | --- |
| Client access | A kubeconfig and an exact context. NemoClaw never selects a context for you. |
| Agent Sandbox | CRD `sandboxes.agents.x-k8s.io` and a controller in `agent-sandbox-system`. Without the API, the OpenShell chart's preflight stops the gateway install. See [Deploy to Kubernetes](../../docs/build-deploy/kubernetes.md#prerequisites). |
| GPU nodes | Allocatable `nvidia.com/gpu`, NVIDIA GPU Operator, and a DCGM exporter. |
| Metrics Server | Present so HPA can read resource metrics. |
| Helm | Helm 3 or 4 on the client that runs `./scripts/install-runtimes.sh`. `nemoclaw apply` uses the bundled Helm provider and does not need a host Helm CLI. |
| Default StorageClass | Present. The managed gateway's SQLite volume uses it. |
| Gateway volume | A **local block-backed** class or volume, not NFS. OpenShell SQLite uses WAL and stalls on NFS (including some `local-path` provisioners that write under shared NFS). Apply then fails with `observation transport failed`. |
| Image build host | Native Linux matching the sandbox nodes, Docker Engine with Buildx, and a containerd image store. Check with `docker buildx version` and `docker info --format '{{json .DriverStatus}}'` for `io.containerd.snapshotter.v1`. |

List node architectures and pick the matching bundle and image platforms (`linux_amd64` / `linux/amd64`, or `linux_arm64` / `linux/arm64`):

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.architecture}{"\t"}GPUs={.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'
```

Copy [`local.env.example`](local.env.example) to `local.env` (gitignored) and set at least:

- `DCGM_NAMESPACE` to the DCGM exporter namespace (`gpu-operator` for the Helm GPU Operator, `gpu-operator-resources` for the microk8s GPU addon).
- `NEMOCLAW_TARGET_NODE` to one node's Kubernetes hostname when you must keep GPU pods on a single node of a shared cluster. Leave it unset to let the scheduler place them.
- `USE_EXISTING_PROMETHEUS=1` plus `MONITORING_NS` and `PROM_RELEASE` when the cluster already has Prometheus. Do not install a second stack.
- `ENABLE_ENVOY_LB=0` to skip Envoy and use the metrics-proxy ClusterIP Service only.

## Quick start

Set `NEMOCLAW_ROOT` to this checkout. Stay in `examples/kubernetes-gpu-autoscaling` for every `./scripts/...` command after the build steps.

```bash
export NEMOCLAW_ROOT="$(git rev-parse --show-toplevel)"
export NEMOCLAW_CLUSTER_KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
# Match the sandbox nodes: linux_amd64 / linux/amd64, or linux_arm64 / linux/arm64
export BUNDLE_PLATFORM=linux_amd64
export IMAGE_PLATFORM=linux/amd64
```

### 1. Checkout

```bash
cd "$NEMOCLAW_ROOT"
```

Work from this revision. There is no published image or installer to pull.

### 2. Confirm GPUs, DCGM, and Agent Sandbox

```bash
kubectl get pods -n "${DCGM_NAMESPACE:-gpu-operator}" -l app=nvidia-dcgm-exporter
kubectl get crd sandboxes.agents.x-k8s.io
kubectl get --raw /apis/agents.x-k8s.io/v1alpha1 >/dev/null
```

### 3. Build the NemoClaw bundle

`rust-toolchain.toml` selects Rust 1.99.1. `cargo ci tools` installs protobuf 36.2 under `.tools/protoc-36.2`. See [Build local artifacts](../../docs/build-deploy/build.md).

```bash
cd "$NEMOCLAW_ROOT"
. "${HOME}/.cargo/env"
rustc --version
cargo ci tools
.tools/protoc-36.2/bin/protoc --version
cargo run -p nemoclaw-build -- bundle --platform "$BUNDLE_PLATFORM"
export PATH="$NEMOCLAW_ROOT/dist/${BUNDLE_PLATFORM}/bin:$PATH"
nemoclaw --help
```

`rustc --version` must print `rustc 1.99.1`. `protoc --version` must print `libprotoc 36.2`. Help must list `plan`, `apply`, `export`, and `destroy`. Keep this bundle unchanged while a deployment uses it.

`nemoclaw apply` does not need a host `openshell` binary. Install the OpenShell CLI at the version in [`versions.json`](../../versions.json) only if you will run `./scripts/invoke.sh` or `openshell` yourself. Do not install the OpenShell `.deb` package; that installer starts a local user gateway.

### 4. Build Fabric agent images

v1 does not publish `nc-fabric` images. `cargo images build` needs Docker Buildx on a host whose architecture matches the sandbox nodes. See [Prepare agent images](../../docs/build-deploy/kubernetes.md#prepare-agent-images) and [Build agent images](../../docs/build-deploy/build.md#build-agent-images).

This example needs OpenClaw (`openclaw-ollama.yaml`), Hermes (`hermes-vllm.yaml`), and Deep Agents (`deepagents-nim.yaml`).

```bash
cd "$NEMOCLAW_ROOT"
docker buildx version
mkdir -p examples/kubernetes-gpu-autoscaling/.local
for agent in openclaw hermes deepagents; do
  cargo images build --platform "$IMAGE_PLATFORM" "$agent"
  docker image inspect "nc-fabric:${agent}" --format '{{index .RepoDigests 0}}'
  cargo images export-metadata "nc-fabric:${agent}" \
    --output "examples/kubernetes-gpu-autoscaling/.local/${agent}.metadata.json"
done
```

The inspect command prints an index digest. Export it as `OPENCLAW_IMAGE_REF`, `HERMES_IMAGE_REF`, or `DEEPAGENTS_IMAGE_REF` before rendering, or put it in the pairing YAML `image.ref`. Export metadata to a new file; the bundle is checked against that digest. Do not commit `*.metadata.json` or `.local/`.

A local Docker image is not visible to kubelet. Either push the index to a registry the nodes can pull, or import it into **each** node's kubelet containerd store (`ctr -n k8s.io images import`). After a local import, tag the digest reference kubelet uses, not only the `:hermes` / `:openclaw` / `:deepagents` name:

```bash
# On each node that will run sandboxes. Use the node's containerd address.
ctr --address /run/containerd/containerd.sock -n k8s.io images import image.tar
ctr --address /run/containerd/containerd.sock -n k8s.io images tag \
  docker.io/library/nc-fabric:hermes \
  docker.io/library/nc-fabric@sha256:DIGEST
```

Without that digest tag, `imagePullPolicy: IfNotPresent` still tries Docker Hub and the sandbox init container stays in `ErrImagePull`. When images live on only some nodes, pin the sandboxes in [Apply](#6-apply-the-mixed-sandboxes).

### 5. Install GPU inference

`./scripts/install-runtimes.sh` installs Ollama, vLLM, and NIM in namespace `nemoclaw-gpu`. It does not create sandboxes. Run it before `nemoclaw apply`.

NIM needs NGC Secrets in that namespace first. Copy `secrets.env.example` to `secrets.env` and paste `NGC_API_KEY`. Do not commit `secrets.env`. `ENABLE_ENVOY_LB=0` skips Envoy; sandboxes use each release's metrics-proxy ClusterIP Service.

```bash
cd "$NEMOCLAW_ROOT/examples/kubernetes-gpu-autoscaling"
DCGM_NAMESPACE=gpu-operator ENABLE_ENVOY_LB=0 ./scripts/install-runtimes.sh
kubectl get deploy,hpa,pods -n nemoclaw-gpu
```

That command prints Deployments and HPAs `hermes-vllm`, `openclaw-ollama`, and `deepagents-nim`. The Services stay `nemoclaw-gpu-vllm-metrics-proxy`, `nemoclaw-gpu-ollama-metrics-proxy`, and `nemoclaw-gpu-nim-metrics-proxy`. Do not keep Helm release `nemoclaw-gpu` in that namespace; those Deployment names collide.

Each HPA ceiling is 8. Three idle replicas already occupy three GPUs. A pod that does not fit stays Pending. A quiet runtime holds only the replicas it is still running. Scale-down removes one of those replicas every 10 seconds after a 60 second wait.

Each GPU pod is 2/2 Ready when the runtime has the model and the metrics proxy answers.

### 6. Apply the mixed sandboxes

One NemoClaw deployment: 3 OpenClaw, 3 Hermes, and 3 Deep Agents sandboxes in namespace `nemoclaw-v1-agents`. [`render-mixed-sandboxes.sh`](scripts/render-mixed-sandboxes.sh) reads [`openclaw-ollama.yaml`](openclaw-ollama.yaml), [`hermes-vllm.yaml`](hermes-vllm.yaml), and [`deepagents-nim.yaml`](deepagents-nim.yaml), and points each sandbox at its release's ClusterIP Service. Apply leaves the GPU chart unchanged. Keep the `--state-dir`; destroy needs it.

The renderer copies harness settings from the pairing files, writes inference Service DNS in namespace `nemoclaw-gpu`, and sets `gateway.kubernetes.namespace` to `nemoclaw-v1-agents`. The default `metadata.name` is `gpu-autoscaling-mixed` (at most 40 characters). It sets `gateway.kubernetes.context` from `GATEWAY_CONTEXT` or `kubectl config current-context`. Put each image digest in `OPENCLAW_IMAGE_REF`, `HERMES_IMAGE_REF`, and `DEEPAGENTS_IMAGE_REF`, or in the pairing files. NemoClaw rejects YAML anchors, aliases, and merge keys.

When the images are only on some nodes, set `NEMOCLAW_TARGET_NODE` to that node's Kubernetes hostname. The renderer then pins every sandbox and sets `allow_driver_config` with `image_pull_policy: if_not_present` on the gateway.

```bash
cd "$NEMOCLAW_ROOT/examples/kubernetes-gpu-autoscaling"
export PATH="$NEMOCLAW_ROOT/dist/${BUNDLE_PLATFORM}/bin:$PATH"
export NEMOCLAW_CLUSTER_KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export NEMOCLAW_OPENCLAW_IMAGE_METADATA="${PWD}/.local/openclaw.metadata.json"
export NEMOCLAW_HERMES_IMAGE_METADATA="${PWD}/.local/hermes.metadata.json"
export NEMOCLAW_DEEPAGENTS_IMAGE_METADATA="${PWD}/.local/deepagents.metadata.json"
export OPENCLAW_IMAGE_REF="$(docker image inspect nc-fabric:openclaw --format '{{index .RepoDigests 0}}')"
export HERMES_IMAGE_REF="$(docker image inspect nc-fabric:hermes --format '{{index .RepoDigests 0}}')"
export DEEPAGENTS_IMAGE_REF="$(docker image inspect nc-fabric:deepagents --format '{{index .RepoDigests 0}}')"
export GPU_OLLAMA_API_KEY="$(kubectl -n nemoclaw-gpu get secret nemoclaw-gpu-ollama-metrics-proxy-inference-api -o jsonpath='{.data.api-key}' | base64 -d)"
export GPU_VLLM_API_KEY="$(kubectl -n nemoclaw-gpu get secret nemoclaw-gpu-vllm-metrics-proxy-inference-api -o jsonpath='{.data.api-key}' | base64 -d)"
export GPU_NIM_API_KEY="$(kubectl -n nemoclaw-gpu get secret nemoclaw-gpu-nim-metrics-proxy-inference-api -o jsonpath='{.data.api-key}' | base64 -d)"
./scripts/render-mixed-sandboxes.sh > .local/openclaw-hermes-deepagents.yaml
nemoclaw apply --non-interactive --bundle "$NEMOCLAW_ROOT/dist/${BUNDLE_PLATFORM}" \
  --state-dir .local/gpu-autoscaling-mixed .local/openclaw-hermes-deepagents.yaml
kubectl get pods -n nemoclaw-v1-agents
```

`user-0000` through `user-0002` are OpenClaw. `user-0003` through `user-0005` are Hermes. `user-0006` through `user-0008` are Deep Agents. Ready means each pod is `1/1 Running` in `nemoclaw-v1-agents`. Skip apply when those pods are already Running there. To update an existing mixed deployment, set `MIXED_UID` (and `MIXED_NAME` if the applied name differs) to the live `metadata` values and keep the same `--state-dir`. Apply cannot move a deployment to another namespace; destroy it, then apply again with the same `--state-dir` and `MIXED_UID`.

Apply writes `terraform.tfstate` in that `--state-dir`, or in a `state/` subdirectory of it. Load clients and `invoke.sh` accept either path. Apply refuses to take over a namespace that already exists, including `nemoclaw-gpu`.

If apply fails with `observation transport failed` while the gateway pod is not Ready, keep the state directory, wait until the gateway StatefulSet pod is `1/1 Ready`, then run the same `nemoclaw apply` again. Do not change `metadata.uid` or `--state-dir`.

After the `user-NNNN` pods are Ready, start the client under [Load tests](#load-tests).

After apply, a gateway prompt is:

```bash
NEMOCLAW_V1_STATE_DIR=.local/gpu-autoscaling-mixed ./scripts/invoke.sh
```

`development` gives that command no operator token. To use it, set `gateway.kubernetes.authentication.profile` to `oidc`, fill `openshell.gateway.oidc`, and set `token.env`. Export a bearer token, apply again with the same state directory, port-forward the gateway, and run `openshell gateway add`. Those `oidc` steps have not been run on a cluster. Until an issuer exists, keep `development` for apply. The load clients below do not need that token.

## Load tests

The cluster serves inference and prints the HPA. A client only sends chats. The same client flags work from any host with kubectl and the apply state directory. The client does not set `maxReplicas` and does not print the HPA.

Leave this watch running. It prints every GPU-chart HPA, pod, and GPU index in one terminal. Rows use the pairing names (`hermes-vllm`, `openclaw-ollama`, `deepagents-nim`).

```bash
cd "$NEMOCLAW_ROOT/examples/kubernetes-gpu-autoscaling"
./scripts/get-hpa.sh -w
```

`INFLIGHT` is the concurrent chats per user. `MAX_TOKENS` is the maximum reply length. GPU utilization sets both flags on the client. Latency omits them (`INFLIGHT=1` and `MAX_TOKENS=2048` in the code). The HPA `maxReplicas` is the GPU ceiling. The client reads it and stops new chats there. The sandbox pods from apply must be Ready before the client starts.

After the mixed sandbox pods are Ready, run [`client.sh`](scripts/client.sh) with `gpu_utilization` or `latency_avg`. That command switches every pairing to the named metric, then starts OpenClaw, Hermes, and Deep Agents together. Do not leave one release on GPU utilization and another on latency. Set `NEMOCLAW_V1_STATE_DIR` to the apply `--state-dir` from that deployment. The client finds `terraform.tfstate` there or in `state/`.

GPU utilization:

```bash
cd "$NEMOCLAW_ROOT/examples/kubernetes-gpu-autoscaling"
export NEMOCLAW_V1_STATE_DIR=.local/gpu-autoscaling-mixed
export V1_NAMESPACE=nemoclaw-v1-agents
./scripts/client.sh gpu_utilization
```

That starts OpenClaw with `INFLIGHT=4 MAX_TOKENS=2048` at offset 0, Hermes with `INFLIGHT=2 MAX_TOKENS=1024` at offset 3, and Deep Agents with `INFLIGHT=3` at offset 6. Each pairing uses 3 users. Lines are prefixed `[openclaw]`, `[hermes]`, or `[deepagents]`.

Latency. The same client omits `INFLIGHT` and `MAX_TOKENS`:

```bash
cd "$NEMOCLAW_ROOT/examples/kubernetes-gpu-autoscaling"
export NEMOCLAW_V1_STATE_DIR=.local/gpu-autoscaling-mixed
export V1_NAMESPACE=nemoclaw-v1-agents
./scripts/client.sh latency_avg
```

`./scripts/client.sh` with no argument starts the three pairings when every HPA already uses the same metric.

The Fabric clients run next to the apply state and use `kubectl exec`. They do not serve the v0 Hermes HTTP port, so a host without that state cannot send chats to `:8642`.

Set `E2E_OUTPUT_DIR` to keep each run's logs apart. The chart `maxReplicas` is 8. Recorded single-pairing runs in [`RESULTS-6b.md`](RESULTS-6b.md) and [`RESULTS-6c.md`](RESULTS-6c.md) peaked at 7 because another workload held one GPU.

## HPA-only load

`./scripts/hpa-load-test-dgx-8xh100.sh` checks that HPA can change GPU pod count from synthetic inference load in `files/load-generator.ts`. It does not create sandboxes. GPU utilization is the default. For latency:

```bash
HPA_METRIC=latency_avg HPA_TARGET_LATENCY_MS=3000 ./scripts/hpa-load-test-dgx-8xh100.sh
```

`./scripts/get-hpa.sh` and `./scripts/hpa-watch.sh` print the live metric. `./scripts/hpa-load-test-brev-4xl40s.sh` is the same check for 4× L40S.

## Uninstall

Destroy the sandboxes with the same state directory you applied:

```bash
nemoclaw destroy --non-interactive --bundle "$NEMOCLAW_ROOT/dist/${BUNDLE_PLATFORM}" \
  --state-dir .local/gpu-autoscaling-mixed
```

`./scripts/hpa-reset.sh` restores an idle HPA without deleting the release. Remove the GPU releases when you are finished with inference:

```bash
helm uninstall nemoclaw-gpu-vllm nemoclaw-gpu-ollama nemoclaw-gpu-nim -n nemoclaw-gpu
```

If an earlier install left the same release names in `nemoclaw-gpu-vllm`, `nemoclaw-gpu-ollama`, and `nemoclaw-gpu-nim`, uninstall those leftovers after the sandboxes in `nemoclaw-v1-agents` are Ready. `UNINSTALL_LEGACY_NAMESPACES=1 ./scripts/install-runtimes.sh` does that after the charts in `nemoclaw-gpu` come up.
