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

This example runs one Fabric sandbox per end user and scales GPU inference from 1 to N pods, one GPU each. The pairing files in this directory are OpenClaw + Ollama, Hermes + vLLM, and Deep Agents + NIM. `nemoclaw apply` creates the sandboxes. The Helm chart in this directory serves inference.

The GPU Deployment, HPA, and pods are named by pairing: `openclaw-ollama`, `hermes-vllm`, or `deepagents-nim`. Sandboxes call the chart Service, which keeps the historical DNS name:

```text
http://<release>-metrics-proxy.<namespace>.svc.cluster.local:8081/v1
```

The default single-runtime Helm release is `nemoclaw-gpu` in namespace `nemoclaw-gpu`. Step 6d uses Helm releases `nemoclaw-gpu-vllm` (`hermes-vllm`), `nemoclaw-gpu-ollama` (`openclaw-ollama`), and `nemoclaw-gpu-nim` (`deepagents-nim`). The chart generates a local inference API key in Secret `<release>-metrics-proxy-inference-api`. Each pairing file reads it from an environment variable. Do not print that key, and do not commit it.

Kubernetes HPA scales the inference pods on a Pods `AverageValue` metric. GPU utilization targets 40%. LLM latency targets 3000 ms. `./scripts/set-hpa-metric.sh` switches the metric without changing the runtime or the sandboxes.

v1 has no release download and no published Fabric agent images ([#12638](https://github.com/NVIDIA/NemoClaw/issues/12638)). Build the CLI bundle and the agent images from this checkout. NemoClaw does not place NIM ([#12649](https://github.com/NVIDIA/NemoClaw/issues/12649)). For NIM, install this chart with `INFERENCE_RUNTIME=nim` and apply `deepagents-nim.yaml`. Hermes uses vLLM.

## Deployment architecture

<img width="1672" height="941" alt="architecture" src="https://github.com/user-attachments/assets/4e61491d-7a8b-4ce7-9910-9715965e4e7c" />

One end user, one sandbox, one agent. `nemoclaw apply` installs a managed OpenShell gateway and starts `fabric-agent-ctl serve` in each sandbox. These files set `authentication.profile: development`. Only NemoClaw can mint those tokens.

A load test sends each prompt with `kubectl exec` into `fabric-agent-ctl invoke`. That skips gateway auth. The operator command is `./scripts/invoke.sh`, which runs `openshell sandbox exec`. `development` gives the OpenShell CLI no token, so `invoke.sh` waits until you switch the file to `oidc` and register the gateway.

Inference is the GPU chart Service `/v1` above. Envoy, when installed, load-balances with LeastRequest. Each GPU pod is 2/2 Ready when healthy: the inference runtime (`ollama`, `vllm`, or `nim`) and `metrics-proxy` (auth, `/v1`, health, `/metrics`).

LLM latency is chat-completions duration on that GPU pod, averaged over completed samples from the last 30 seconds. In-flight chats do not count. After 15 seconds with no completed sample the gauge publishes 0 so HPA can scale down. That 0 is not 0 ms of latency.

## Prerequisites

You need an existing Kubernetes cluster. This example does not install Kubernetes, the GPU Operator, or a local k3s. `kubectl get nodes` must succeed with a kubeconfig you control.

Confirm the following before you build or apply. Cluster setup belongs to the platform operator; NemoClaw does not check it.

| Requirement | What to confirm |
| --- | --- |
| Client access | A kubeconfig and an exact context. NemoClaw never selects a context for you. |
| Agent Sandbox | CRD `sandboxes.agents.x-k8s.io` and a controller in `agent-sandbox-system`. Without the API, the OpenShell chart's preflight stops the gateway install. See [Deploy to Kubernetes](../../docs/build-deploy/kubernetes.md#prerequisites). |
| GPU nodes | Allocatable `nvidia.com/gpu`, NVIDIA GPU Operator, and a DCGM exporter. |
| Metrics Server | Present so HPA can read resource metrics. |
| Helm | Helm 3 or 4 on the client that runs `./scripts/install-hpa.sh`. `nemoclaw apply` uses the bundled Helm provider and does not need a host Helm CLI. |
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

Build the image for the pairing you will apply. Hermes is the image for `hermes-vllm.yaml`. Deep Agents is the image for `deepagents-nim.yaml`. OpenClaw is the image for `openclaw-ollama.yaml`. Step 6d needs OpenClaw, Hermes, and Deep Agents.

```bash
cd "$NEMOCLAW_ROOT"
docker buildx version
cargo images build --platform "$IMAGE_PLATFORM" hermes
docker image inspect nc-fabric:hermes --format '{{index .RepoDigests 0}}'
mkdir -p examples/kubernetes-gpu-autoscaling/.local
cargo images export-metadata nc-fabric:hermes \
  --output examples/kubernetes-gpu-autoscaling/.local/hermes.metadata.json
```

The inspect command prints an index digest. Put that value in every `image.ref` in the pairing YAML. Export metadata to a new file; the bundle is checked against that digest. Do not commit `*.metadata.json` or `.local/`. For Deep Agents or OpenClaw, replace `hermes` in those commands.

A local Docker image is not visible to kubelet. Either push the index to a registry the nodes can pull, or import it into **each** node's kubelet containerd store (`ctr -n k8s.io images import`). After a local import, tag the digest reference kubelet uses, not only the `:hermes` / `:openclaw` name:

```bash
# On each node that will run sandboxes. Use the node's containerd address.
ctr --address /run/containerd/containerd.sock -n k8s.io images import image.tar
ctr --address /run/containerd/containerd.sock -n k8s.io images tag \
  docker.io/library/nc-fabric:hermes \
  docker.io/library/nc-fabric@sha256:DIGEST
```

Without that digest tag, `imagePullPolicy: IfNotPresent` still tries Docker Hub and the sandbox init container stays in `ErrImagePull`. When images live on only some nodes, pin the sandboxes to those nodes (see [Apply](#6-apply-one-pairing)).

### 5. Install GPU inference

`install-hpa.sh` starts the GPU chart. It does not create sandboxes or start agents. Run it before `nemoclaw apply`. The chart serves one runtime at a time.

| Pairing | `INFERENCE_RUNTIME` |
| --- | --- |
| Hermes + vLLM | `vllm` |
| OpenClaw + Ollama | `ollama` |
| Deep Agents + NIM | `nim` |

Skip the install when the chart already serves that runtime. `ENABLE_ENVOY_LB=1` (the script default) installs Envoy Gateway. `ENABLE_ENVOY_LB=0` skips it; sandboxes then use the metrics-proxy ClusterIP Service.

```bash
cd "$NEMOCLAW_ROOT/examples/kubernetes-gpu-autoscaling"
DCGM_NAMESPACE=gpu-operator MAX_REPLICAS=8 ENABLE_ENVOY_LB=0 \
  INFERENCE_RUNTIME=vllm \
  ./scripts/install-hpa.sh
kubectl get pods,hpa -n nemoclaw-gpu
```

That vLLM install creates Deployment and HPA `hermes-vllm`. Ollama creates `openclaw-ollama`. NIM creates `deepagents-nim`. `kubectl get pods` shows those names plus a ReplicaSet suffix.

OpenClaw uses the same Helm release with Ollama (`INFERENCE_RUNTIME=ollama`). A later pairing runs `install-hpa.sh` again with its runtime and replaces that release's pods. Sandboxes that are already Running stay up. `./scripts/set-hpa-metric.sh` changes only the HPA metric. Run it after the sandbox pods are Ready.

For NIM, create `secrets.env` from `secrets.env.example` and run `./scripts/apply-local-secrets.sh` before `install-hpa.sh` with `INFERENCE_RUNTIME=nim`. Do not commit `secrets.env`.

Each GPU pod is 2/2 Ready when the runtime has the model and the metrics proxy answers.

### 6. Apply one pairing

Edit the pairing file (or a rendered copy under `.local/`):

1. Set `metadata.uid` to a new UUID.
2. Set `gateway.kubernetes.context` to the exact kubeconfig context (`kubectl config current-context`).
3. Replace every `image.ref` with the index digest from step 4.
4. Point `endpoint` at the metrics-proxy Service if you skipped Envoy, or at the Envoy Service if you installed it. See [the Kubernetes GPU example](../kubernetes/gpu-autoscaling/README.md#find-the-service-and-key).

NemoClaw rejects YAML anchors, aliases, and merge keys. Repeat shared settings; do not generate aliases with PyYAML.

When the image is only on some nodes, allow driver config and pin each sandbox. Repeat `driverConfig` on every sandbox:

```yaml
spec:
  gateway:
    config:
      openshell.drivers.kubernetes:
        allow_driver_config: true
        image_pull_policy: if_not_present
  sandboxes:
    user-0000:
      driverConfig:
        kubernetes:
          pod:
            node_selector:
              kubernetes.io/hostname: GPU_NODE
```

`./scripts/check.sh` validates the three YAML files and reads the cluster. It does not apply.

```bash
cd "$NEMOCLAW_ROOT/examples/kubernetes-gpu-autoscaling"
export PATH="$NEMOCLAW_ROOT/dist/${BUNDLE_PLATFORM}/bin:$PATH"
export NEMOCLAW_V1_ROOT="$NEMOCLAW_ROOT"
export NEMOCLAW_CLUSTER_KUBECONFIG="${NEMOCLAW_CLUSTER_KUBECONFIG:-$HOME/.kube/config}"
export NEMOCLAW_AGENT_IMAGE_METADATA="${PWD}/.local/hermes.metadata.json"
export GPU_INFERENCE_API_KEY="$(kubectl -n nemoclaw-gpu get secret nemoclaw-gpu-metrics-proxy-inference-api -o jsonpath='{.data.api-key}' | base64 -d)"
./scripts/check.sh
```

`nemoclaw apply` starts the agents. It creates the OpenShell gateway and one Fabric sandbox per user. Apply leaves the GPU chart unchanged. Keep the `--state-dir`; destroy needs it.

A sandbox is ready when its `user-NNNN` pod is `1/1 Running`. Skip apply when those pods are already Running.

| Step | File | Harness | Chart runtime | State directory | Namespace |
| --- | --- | --- | --- | --- | --- |
| 6a OpenClaw + Ollama | [`openclaw-ollama.yaml`](openclaw-ollama.yaml) | `nvidia.fabric.openclaw` | `ollama` | `.local/gpu-autoscaling-openclaw` | `nemoclaw-v1-gpu-autoscaling-openclaw` |
| 6b Hermes + vLLM | [`hermes-vllm.yaml`](hermes-vllm.yaml) | `nvidia.fabric.hermes` | `vllm` | `.local/gpu-autoscaling` | `nemoclaw-v1-gpu-autoscaling` |
| 6c Deep Agents + NIM | [`deepagents-nim.yaml`](deepagents-nim.yaml) | `nvidia.fabric.langchain.deepagents` | `nim` | `.local/gpu-autoscaling-deepagents` | `nemoclaw-v1-gpu-autoscaling-dagent` |
| 6d OpenClaw + Hermes + Deep Agents | rendered `.local/openclaw-hermes-deepagents.yaml` | OpenClaw, Hermes, and Deep Agents | `ollama`, `vllm`, and `nim`, one release each | `.local/gpu-autoscaling-mixed` | `nemoclaw-v1-gpu-autoscaling-mixed` |

Each pairing file declares sandboxes `user-0000` and `user-0001`. `render-sandboxes.sh` prints a wider file. It does not apply. Put the real image digest and a new `metadata.uid` in that file before apply. `.local/` is gitignored.

Hermes. The chart must serve vLLM.

```bash
cd "$NEMOCLAW_ROOT/examples/kubernetes-gpu-autoscaling"
export PATH="$NEMOCLAW_ROOT/dist/${BUNDLE_PLATFORM}/bin:$PATH"
E2E_USERS=10 ./scripts/render-sandboxes.sh hermes-vllm > .local/hermes-vllm-10.yaml
nemoclaw apply --non-interactive --bundle "$NEMOCLAW_ROOT/dist/${BUNDLE_PLATFORM}" \
  --state-dir .local/gpu-autoscaling .local/hermes-vllm-10.yaml
kubectl get pods -n nemoclaw-v1-gpu-autoscaling
```

OpenClaw. The chart must serve Ollama.

```bash
E2E_USERS=10 ./scripts/render-sandboxes.sh openclaw-ollama > .local/openclaw-ollama-10.yaml
nemoclaw apply --non-interactive --bundle "$NEMOCLAW_ROOT/dist/${BUNDLE_PLATFORM}" \
  --state-dir .local/gpu-autoscaling-openclaw .local/openclaw-ollama-10.yaml
kubectl get pods -n nemoclaw-v1-gpu-autoscaling-openclaw
```

Deep Agents uses `render-sandboxes.sh deepagents-nim` and `--state-dir .local/gpu-autoscaling-deepagents`. The chart must serve NIM.

If apply fails with `observation transport failed` while the gateway pod is not Ready, keep the state directory, wait until the gateway StatefulSet pod is `1/1 Ready`, then run the same `nemoclaw apply` again. Do not change `metadata.uid` or `--state-dir`.

### 6d. OpenClaw, Hermes, and Deep Agents together

Step 6d runs 3 OpenClaw sandboxes, 3 Hermes sandboxes, and 3 Deep Agents sandboxes in one NemoClaw deployment. It installs this chart three times on the same GPUs. Helm release `nemoclaw-gpu-vllm` runs Deployment and HPA `hermes-vllm`. Helm release `nemoclaw-gpu-ollama` runs Deployment and HPA `openclaw-ollama`. Helm release `nemoclaw-gpu-nim` runs Deployment and HPA `deepagents-nim`. Each HPA ceiling is 8. Three idle replicas already occupy three GPUs. A pod that does not fit stays Pending. A quiet runtime holds only the replicas it is still running. Scale-down removes one of those replicas every 10 seconds after a 60 second wait.

The mixed renderer points sandboxes at each release's ClusterIP Service (`<release>-metrics-proxy`), so Envoy is optional. Watch all three pairings in one terminal with `./scripts/get-hpa.sh -w`. NIM needs NGC Secrets in `nemoclaw-gpu-nim` before Helm; copy `secrets.env.example` to `secrets.env` and paste `NGC_API_KEY` first.

```bash
cd "$NEMOCLAW_ROOT/examples/kubernetes-gpu-autoscaling"
DCGM_NAMESPACE=gpu-operator ENABLE_ENVOY_LB=0 ./scripts/install-two-runtimes.sh
kubectl get deploy,hpa,pods -n nemoclaw-gpu-vllm
kubectl get deploy,hpa,pods -n nemoclaw-gpu-ollama
kubectl get deploy,hpa,pods -n nemoclaw-gpu-nim
```

Those commands print `hermes-vllm`, `openclaw-ollama`, and `deepagents-nim`. The Services stay `nemoclaw-gpu-vllm-metrics-proxy`, `nemoclaw-gpu-ollama-metrics-proxy`, and `nemoclaw-gpu-nim-metrics-proxy`.

Put the real image digests in `openclaw-ollama.yaml`, `hermes-vllm.yaml`, and `deepagents-nim.yaml` before rendering. Export each image's metadata to its own file. Add node selectors in the rendered file when the images are node-local.

```bash
export PATH="$NEMOCLAW_ROOT/dist/${BUNDLE_PLATFORM}/bin:$PATH"
export NEMOCLAW_OPENCLAW_IMAGE_METADATA="${PWD}/.local/openclaw.metadata.json"
export NEMOCLAW_HERMES_IMAGE_METADATA="${PWD}/.local/hermes.metadata.json"
export NEMOCLAW_DEEPAGENTS_IMAGE_METADATA="${PWD}/.local/deepagents.metadata.json"
export GPU_OLLAMA_API_KEY="$(kubectl -n nemoclaw-gpu-ollama get secret nemoclaw-gpu-ollama-metrics-proxy-inference-api -o jsonpath='{.data.api-key}' | base64 -d)"
export GPU_VLLM_API_KEY="$(kubectl -n nemoclaw-gpu-vllm get secret nemoclaw-gpu-vllm-metrics-proxy-inference-api -o jsonpath='{.data.api-key}' | base64 -d)"
export GPU_NIM_API_KEY="$(kubectl -n nemoclaw-gpu-nim get secret nemoclaw-gpu-nim-metrics-proxy-inference-api -o jsonpath='{.data.api-key}' | base64 -d)"
./scripts/render-mixed-sandboxes.sh > .local/openclaw-hermes-deepagents.yaml
nemoclaw apply --non-interactive --bundle "$NEMOCLAW_ROOT/dist/${BUNDLE_PLATFORM}" \
  --state-dir .local/gpu-autoscaling-mixed .local/openclaw-hermes-deepagents.yaml
kubectl get pods -n nemoclaw-v1-gpu-autoscaling-mixed
```

`user-0000` through `user-0002` are OpenClaw. `user-0003` through `user-0005` are Hermes. `user-0006` through `user-0008` are Deep Agents. Ready means each pod is `1/1 Running`. Skip apply when those pods are already Running. To update an existing mixed deployment, set `MIXED_UID` (and `MIXED_NAME` if the applied name differs) to the live `metadata` values and set `NEMOCLAW_TARGET_NODE` when the images are node-local.

Apply writes `terraform.tfstate` in the state directory from that command. Apply refuses to take over a namespace that already exists. OpenClaw and Deep Agents use their own namespaces, so their sandboxes can stay up beside Hermes.

After the `user-NNNN` pods are Ready, switch the metric with `./scripts/set-hpa-metric.sh` and start a client under [Load tests](#load-tests).

After apply, a gateway prompt is:

```bash
NEMOCLAW_V1_STATE_DIR=.local/gpu-autoscaling ./scripts/invoke.sh
```

`development` gives that command no operator token. To use it, set `gateway.kubernetes.authentication.profile` to `oidc`, fill `openshell.gateway.oidc`, and set `token.env`. Export a bearer token, apply again with the same state directory, port-forward the gateway, and run `openshell gateway add`. Those `oidc` steps have not been run on a cluster. Until an issuer exists, keep `development` for apply. The load clients below do not need that token.

## Load tests

The cluster serves inference and prints the HPA. A client only sends chats. The same client flags work from any host with kubectl and the apply state directory. The client does not set `maxReplicas` and does not print the HPA.

Leave this watch running. It prints every GPU-chart HPA, pod, and GPU index in one terminal. Rows use the pairing names (`hermes-vllm`, `openclaw-ollama`, `deepagents-nim`).

```bash
cd "$NEMOCLAW_ROOT/examples/kubernetes-gpu-autoscaling"
./scripts/get-hpa.sh -w
```

`INFLIGHT` is the concurrent chats per user. `MAX_TOKENS` is the maximum reply length. GPU utilization sets both flags on the client. Latency omits them. Hermes latency is `INFLIGHT=1` and `MAX_TOKENS=2048` in the code, and a leftover `MAX_TOKENS` from a GPU-utilization run does not apply. The HPA `maxReplicas` is the GPU ceiling. The client reads it and stops new chats there. The sandbox pods from apply must be Ready before the client starts. One sandbox per user.

Hermes GPU utilization:

```bash
cd "$NEMOCLAW_ROOT/examples/kubernetes-gpu-autoscaling"
INFLIGHT=2 MAX_TOKENS=1024 E2E_USERS=10 ./scripts/client-hermes.sh
```

Hermes latency. Switch the metric first, then run the client with the flags omitted:

```bash
cd "$NEMOCLAW_ROOT/examples/kubernetes-gpu-autoscaling"
./scripts/set-hpa-metric.sh latency_avg
E2E_USERS=10 ./scripts/client-hermes.sh
```

OpenClaw GPU utilization is `INFLIGHT=4 MAX_TOKENS=2048` with [`client-openclaw.sh`](scripts/client-openclaw.sh). OpenClaw latency omits the flags (`INFLIGHT=1`, `MAX_TOKENS=2048`). Deep Agents GPU utilization is `INFLIGHT=3` with [`client-deepagents.sh`](scripts/client-deepagents.sh). One chat in flight stayed at 5 GPUs.

Step 6d uses one state directory, one HPA watch, and three clients. Start `./scripts/get-hpa.sh -w` first. After the mixed sandbox pods are Ready, run each client. Each client reads its own HPA (`openclaw-ollama`, `hermes-vllm`, or `deepagents-nim`).

```bash
cd "$NEMOCLAW_ROOT/examples/kubernetes-gpu-autoscaling"
export NEMOCLAW_V1_STATE_DIR=.local/gpu-autoscaling-mixed
export V1_NAMESPACE=nemoclaw-v1-gpu-autoscaling-mixed
NAMESPACE=nemoclaw-gpu-ollama HPA_NAME=openclaw-ollama \
  E2E_USERS=3 E2E_USER_OFFSET=0 INFLIGHT=4 MAX_TOKENS=2048 \
  ./scripts/client-openclaw.sh
```

```bash
cd "$NEMOCLAW_ROOT/examples/kubernetes-gpu-autoscaling"
export NEMOCLAW_V1_STATE_DIR=.local/gpu-autoscaling-mixed
export V1_NAMESPACE=nemoclaw-v1-gpu-autoscaling-mixed
NAMESPACE=nemoclaw-gpu-vllm HPA_NAME=hermes-vllm \
  E2E_USERS=3 E2E_USER_OFFSET=3 INFLIGHT=2 MAX_TOKENS=1024 \
  ./scripts/client-hermes.sh
```

```bash
cd "$NEMOCLAW_ROOT/examples/kubernetes-gpu-autoscaling"
export NEMOCLAW_V1_STATE_DIR=.local/gpu-autoscaling-mixed
export V1_NAMESPACE=nemoclaw-v1-gpu-autoscaling-mixed
NAMESPACE=nemoclaw-gpu-nim HPA_NAME=deepagents-nim \
  E2E_USERS=3 E2E_USER_OFFSET=6 INFLIGHT=3 \
  ./scripts/client-deepagents.sh
```

Switch one pairing's metric with `NAMESPACE=nemoclaw-gpu-ollama RELEASE=nemoclaw-gpu-ollama ./scripts/set-hpa-metric.sh latency_avg`, `NAMESPACE=nemoclaw-gpu-vllm RELEASE=nemoclaw-gpu-vllm ./scripts/set-hpa-metric.sh gpu_utilization`, or `NAMESPACE=nemoclaw-gpu-nim RELEASE=nemoclaw-gpu-nim ./scripts/set-hpa-metric.sh gpu_utilization`.

The Fabric clients run next to the apply state and use `kubectl exec`. They do not serve the v0 Hermes HTTP port, so a host without that state cannot send chats to `:8642`.

Set `E2E_OUTPUT_DIR` to keep each run's logs apart. The chart `maxReplicas` is 8. Recorded runs in [`RESULTS-6b.md`](RESULTS-6b.md) and [`RESULTS-6c.md`](RESULTS-6c.md) peaked at 7 because another workload held one GPU.

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
  --state-dir .local/gpu-autoscaling
```

Repeat for `.local/gpu-autoscaling-openclaw`, `.local/gpu-autoscaling-deepagents`, and `.local/gpu-autoscaling-mixed` when those deployments exist.

`./scripts/hpa-reset.sh` restores an idle HPA without deleting the release. Remove the GPU release when you are finished with inference:

```bash
helm uninstall nemoclaw-gpu -n nemoclaw-gpu
```

For step 6d, uninstall `nemoclaw-gpu-vllm`, `nemoclaw-gpu-ollama`, and `nemoclaw-gpu-nim` in their namespaces of the same name.
