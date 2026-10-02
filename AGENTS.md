# AGENTS.md

This file provides instructions and guidelines for AI coding assistants (including Gemini 3.8+, Claude Code, Codex, and Antigravity) working with the code and architecture artifacts in this repository.

## Repository Overview & Stack

- **Helm Charts**: Located under `charts/`:
  - `charts/hermetiq`: Main Hermetiq platform chart (web UI, API proxies, BEP publisher/subscribers, JetStream, DB migrations).
  - `charts/buildbarn`: Buildbarn remote cache, remote execution, Buildbarn Browser, and storage.
  - `charts/bb-worker-operator`: Kubernetes operator managing `RbeWorker` custom resources and KEDA autoscalers.
- **Custom Values & Overrides**: Located in `custom-values/` for various infrastructure targets (GKE, on-prem, AWS).
- **Validation**:
  - Run `helm lint charts/hermetiq`
  - Run `helm lint charts/buildbarn`
  - Run `helm lint charts/bb-worker-operator`

---

## Architecture Diagram Generation & Maintenance (Gemini 3.8+)

This repository maintains three primary architectural diagrams in the root directory:
1. `hermetiq-gke-deployment.png`: End-to-end Kubernetes platform deployment architecture.
2. `hermetiq-nats-db-ingest.png`: BEP event ingestion pipeline, NATS JetStream, and partitioned PostgreSQL persistence.
3. `hermetiq-buildbarn-diagram.png`: Buildbarn caching, remote execution, worker pools, and storage topology.

For customer-facing and presentation collateral, diagrams use a **3D isometric presentation aesthetic** (the "keynote glassmorphism" style). Future Gemini models (Gemini 3.8+) and other multimodal AI agents must adhere to the style definitions, prompt templates, and technical constraints below when generating or updating these diagrams.

### 1. Visual Style & Aesthetic Specifications

When generating or editing diagrams in this style:
- **Perspective**: 3D isometric view (orthographic isometric projection, 30° / 60° angles) looking down onto multi-tiered floating platforms or pedestals.
- **Surface Materials & Geometry**:
  - Frosted glass and translucent acrylic pedestals with subtle bevels and rounded corners (glassmorphism).
  - Clean separation into layered architectural planes (Ingress plane, Microservices plane, Messaging/Queue plane, Data & Storage plane).
  - Soft ambient occlusion, realistic directional studio drop shadows, and subtle edge lighting.
  - No messy clutter: clear visual hierarchy with high contrast and spacious component positioning.
- **Background**: Clean, crisp off-white or light slate studio canvas (`#f8fafc` to `#ffffff`) with subtle ambient diffusion.
- **Color Coding**:
  - **Networking / Ingress / Gateway**: Deep Indigo / Violet (`#4f46e5` / `#6366f1`).
  - **Messaging / NATS JetStream**: Vibrant Emerald / Teal (`#059669` / `#10b981`).
  - **Microservices / Go Services / Subscribers**: Vivid Cobalt / Sky Blue (`#0284c7` / `#0ea5e9`).
  - **Storage / PostgreSQL / GCS / VictoriaMetrics**: Warm Amber / Coral / Gold (`#d97706` / `#f59e0b`).
  - **Observability / KEDA / Grafana**: Crimson / Rose (`#e11d48`).
- **Connection Grammar**:
  - **Solid sleek arrows**: Synchronous control plane and RPC flows (e.g., Bazel BEP → TLS Gateway → Publisher).
  - **Glowing blue conduits / pipelines**: Heavy payload blob and CAS reads/writes (e.g., Buildbarn Frontend → Storage, Subscribers → GCS).
  - **Dashed / pulsed lines**: Telemetry, metrics queries, and async scaling loops (e.g., KEDA → VictoriaMetrics PromQL).
- **Typography & Labels**:
  - Clean sans-serif modern typography (Inter, SF Pro, or Roboto style).
  - Clear, legible component titles, protocol tags (e.g. `gRPC/TLS`, `Port 8981`, `JetStream`), and port numbers.
  - Zero illegible glyphs, gibberish artifacts, or hallucinatory labels.

### 2. Architectural Rules & Topology Invariants (Issue #111)

Under no circumstances should any generated or modified diagram violate these core technical invariants:

1. **Ingress Routing (`hermetiq-gke-deployment.png`)**:
   - The Edge TLS Gateway (`edge-tls-gateway`) terminates external TLS and proxies directly to the BEP publisher (`bep-nats-pub`).
   - The Gateway does **NOT** connect directly to NATS JetStream.
2. **Stream Publishing & Consumption**:
   - `bep-nats-pub` is the exclusive ingress publisher to the NATS JetStream stream (`events.build_event`).
   - Partitioned Go subscribers (`bep-nats-sub`) consume JetStream events via consumer groups.
3. **Query API Decoupling**:
   - The Query API (`bep-nats-query-api` / `grpc-api`) reads directly from PostgreSQL (metadata) and Google Cloud Storage (chunked blobs).
   - The Query API does **NOT** connect to or read from NATS stream topics.
4. **Subscriber Data Offloading**:
   - Subscribers write structured build metadata to PostgreSQL.
   - Subscribers offload large raw payload chunks directly to Google Cloud Storage (GCS).
5. **OIDC / SSO Isolation**:
   - OIDC Provider connects exclusively to the Edge TLS Gateway for authentication/SSO.
   - It has no data-path arrows to backend storage or data services.
6. **1:1 Partition Mapping (`hermetiq-nats-db-ingest.png`)**:
   - NATS JetStream partitions `0..N-1` map 1:1 to dedicated subscriber deployments (`bep-nats-sub-partition-0`, `partition-1`, etc.).
7. **Default Partition**:
   - The 5-partition timeline includes `<parent>_default` as the catch-all partition alongside numeric partitions.
8. **Buildbarn Frontend Connections (`hermetiq-buildbarn-diagram.png`)**:
   - Frontend execution RPC connects to `scheduler:8982`.
   - Browser and frontend blobstore reads connect to `storage:8981`.
9. **Storage Connection Styling**:
   - Storage connections use rich blue data conduit styling.
10. **KEDA Scaling Architecture**:
    - KEDA queries VictoriaMetrics via PromQL (`sum(nats_jetstream_consumer_num_pending)`) through the Kubernetes metrics adapter.
    - KEDA does **NOT** connect to disk, PVCs, or NATS internals directly.
11. **Internal L4 Routing**:
    - Internal worker execution queues and inter-service communications use Kubernetes L4 ClusterIP routing without TLS termination.

### 3. Image Generation with Gemini 3.8+ / Antigravity Tools

To generate or update these images using the agent `generate_image` tool:

#### Tool Invocation Pattern
```json
{
  "ImageName": "hermetiq_platform_3d",
  "AspectRatio": "16:9",
  "ImagePaths": ["/home/ndipiazza/source/hermetiq/hermetiq-k8s/hermetiq-gke-deployment.png"],
  "Prompt": "<Detailed prompt below>"
}
```

#### Base Prompts for Each Diagram

##### A. Platform Architecture (`hermetiq-gke-deployment.png`)
```text
A stunning 3D isometric architectural diagram of the Hermetiq Kubernetes platform on a clean white background. 
Isometric perspective with frosted glass translucent floating pedestals and modern enterprise glassmorphism aesthetics.
Layers from top to bottom:
1. Top layer: 'Clients & Bazel Runners' sending gRPC/TLS traffic to 'Edge TLS Gateway'. An 'OIDC Provider' connects to the Edge TLS Gateway for SSO authentication.
2. Ingress layer: 'Edge TLS Gateway' routes traffic down to 'bep-nats-pub' (publisher service) and 'Web UI'.
3. Messaging layer: 'bep-nats-pub' publishes events into 'NATS JetStream Cluster' (green glowing cluster pedestal).
4. Processing layer: Dedicated 'bep-nats-sub' subscribers pull from JetStream partitions and write build metadata to 'PostgreSQL Cluster' (amber cylinder) and large blobs to 'Google Cloud Storage'.
5. Query layer: 'Query API' reads directly from 'PostgreSQL' and 'Google Cloud Storage'. It does NOT connect to NATS JetStream.
6. Observability: 'VictoriaMetrics & Grafana' collecting metrics, with 'KEDA' querying VictoriaMetrics via PromQL to autoscale subscribers.
Clean, sharp typography, precise isometric angles, glowing blue data conduits, elegant soft ambient lighting.
```

##### B. BEP Ingest & Database Partitioning (`hermetiq-nats-db-ingest.png`)
```text
A high-end 3D isometric diagram of the Hermetiq BEP event ingestion and database partitioning pipeline on a clean light background.
Isometric view with elegant glassmorphism translucent platforms, soft shadows, and clean modern tech aesthetics.
Flow from left to right:
1. 'Bazel BEP Stream' enters 'bep-nats-pub' microservice via gRPC.
2. 'bep-nats-pub' distributes events into 'NATS JetStream' partitioned subjects (Partition 0, Partition 1, Partition 2, ..., and Catch-all Partition <parent>_default).
3. 1:1 mapping: each partition maps directly to a dedicated Go subscriber deployment ('bep-nats-sub-0', 'bep-nats-sub-1', ..., 'bep-nats-sub-default').
4. The subscribers write relational build records into a partitioned 'PostgreSQL' database (divided into monthly and hash partition blocks) and stream heavy payload chunks directly into 'Google Cloud Storage (GCS)'.
5. 'Query API' stands apart, reading historical metadata from PostgreSQL and blobs from GCS, with zero connection to the NATS streams.
6. 'KEDA Scaler' monitors partition consumer lag via PromQL queries to 'VictoriaMetrics'.
Vibrant green for JetStream, cobalt blue for Go subscriber pods, amber gold for PostgreSQL partitions, clean legible text labels.
```

##### C. Buildbarn Deployment Architecture (`hermetiq-buildbarn-diagram.png`)
```text
A sophisticated 3D isometric technical diagram of Hermetiq Buildbarn deployment architecture on a clean white studio background.
Featuring layered floating translucent glass pedestals, rounded cards, and isometric projection.
Key components:
1. Ingress: Bazel clients and Web Browser connecting through an Ingress / Gateway layer.
2. Routing & Frontend: 'bb-frontend' routing execution requests to 'bb-scheduler' on port 8982, and CAS/blobstore reads to 'bb-storage' on port 8981 via blue data conduits. 'bb-browser' providing human UI.
3. Scheduling & Queuing: 'bb-scheduler' managing execution queues and assigning actions to workers over internal Kubernetes L4 ClusterIP connections (no TLS termination).
4. Storage Layer: 'bb-storage' distributed across CAS (Content Addressable Storage) and AC (Action Cache) with SSD/NVMe volume backing.
5. Worker Fleet: 'bb-worker' pools managed by the 'BB Worker Operator' custom controller, with KEDA autoscaling worker pods based on queue depth metrics in VictoriaMetrics.
Glowing blue data conduits for CAS storage paths, sleek directional control arrows, clean enterprise aesthetic.
```

### 4. How to Update These Diagrams (Delta Updates)

When an architecture change or component update is required:
1. **Pass the Base Image**: Always supply the path to the current diagram in the `ImagePaths` parameter of `generate_image` (e.g. `ImagePaths: ["/home/ndipiazza/source/hermetiq/hermetiq-k8s/hermetiq-gke-deployment.png"]`).
2. **Describe Specific Deltas**: In the prompt, explicitly instruct the model to maintain the exact 3D isometric perspective, glass pedestal styling, color scheme, and typography, but apply the specific modifications. Example:
   ```text
   Reference the attached 3D isometric architecture diagram. Maintain the exact same isometric angle, glassmorphism pedestal styling, and color coding.
   Modify the following:
   - Change the Redis cache component to DragonflyDB.
   - Ensure the Edge TLS Gateway route clearly splits to bep-nats-pub and Web UI.
   - Retain all other components, connections, and labels exactly as depicted.
   ```
3. **Verify Topology & Text**: Inspect the resulting output image to ensure:
   - All labels are legible English without garbled characters.
   - Arrow directions correctly reflect data and control flow.
   - None of the 10 architecture invariants listed in Section 2 are broken.
4. **Publish Output**:
   - Convert/save the image to the repository root matching the original filename (`hermetiq-gke-deployment.png`, etc.).
   - Verify file size and dimensions (typically 1920x1080 or 1600x900 PNG).
   - Run `helm lint charts/hermetiq` to ensure repository hygiene.
