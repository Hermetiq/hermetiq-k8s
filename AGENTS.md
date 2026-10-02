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

## Architecture Diagram Maintenance Guide (Gemini 3.8+)

This repository maintains three primary customer-facing presentation diagrams in the root directory:
1. `hermetiq-gke-deployment.png`: End-to-end Kubernetes platform deployment architecture.
2. `hermetiq-nats-db-ingest.png`: BEP event ingestion pipeline, NATS JetStream, and partitioned PostgreSQL persistence.
3. `hermetiq-buildbarn-diagram.png`: Buildbarn caching, remote execution, worker pools, and storage topology.

These diagrams use a **3D isometric keynote glassmorphism presentation aesthetic** ("AI bling" style). They are customer-facing visuals featured in project documentation, READMEs, and executive architecture reviews.

### 1. CRITICAL RULE: Preventing Quality Loss (NEVER Use Full-Image Diffusion)

> [!CAUTION]
> **NEVER use full-image generative diffusion tools (such as `generate_image`) to regenerate or update these technical diagrams.**
>
> In PR #37, an automated agent attempted to update diagrams by calling `generate_image` on the entire image canvas. This resulted in catastrophic quality loss:
> - Crisp vector typography degraded into blurry, garbled AI hallucinations (e.g. "hermetic gateway", "Ezecute RPC", "Cack & Action Store", "heshes hasees").
> - Sharp geometric glass pedestals, edges, and connection routes were warped and artifacted.
> - High-contrast technical precision was replaced with diffusion noise and fuzzy textures.
>
> Generative diffusion models are stochastic latent synthesizers; they cannot reliably maintain precise technical text, exact port numbers, or strict network topologies across an entire architecture diagram.

### 2. Composition Architecture: How High-Quality Visuals Are Built

The high-quality presentation diagrams consist of two decoupled visual tiers:
1. **The 3D Glassmorphism Base Plate**:
   - Floating translucent pedestals, frosted acrylic slabs, hardware chassis (e.g., NVMe storage bays, server racks, glowing JetStream cubes).
   - Soft directional studio lighting, drop shadows, and clean off-white / light slate canvas (`#f6f8fc` to `#ffffff`).
   - **Crucially: The base visual plate contains ZERO or minimal baked-in text.**
2. **The Vector Typography & Annotation Overlay**:
   - Crisp, pixel-perfect digital typography (Inter, SF Pro, Roboto) rendered at native resolution (`1376 x 768` or `1920 x 1080`).
   - High-contrast labels, badges, protocol tags (`gRPC/TLS`, `:8982`, `:8981`, `Stream 0..N-1`), and color-coded directional conduits.
   - Clean semi-transparent badge containers (`background: rgba(255, 255, 255, 0.75)`, `border: 1px solid rgba(255, 255, 255, 0.9)`, subtle drop shadows).

### 3. How Future Agents Must Update These Diagrams (Delta Modifications)

When an architectural change, service rename, port change, or connection routing update is requested:

#### Method A: Programmatic Canvas / Image Patching (Recommended for Text & Flow Changes)
For updates to labels, ports, service names, or routing arrows:
1. **Isolate the Target Bounding Box**: Identify the exact coordinate rectangle `(x1, y1, x2, y2)` of the element to modify.
2. **Patch the Background**:
   - Sample the underlying background color or gradient (e.g., `#f8fafc`, `#ffffff`, or the frosted glass panel fill `rgba(...)`).
   - Draw a clean rounded rectangle or patch over the outdated text/arrow using Python (`PIL.ImageDraw`), Canvas, or OpenCV.
3. **Render Crisp Vector Typography**:
   - Use a true sans-serif font (e.g. `Inter-SemiBold.ttf`, `Inter-Regular.ttf`, or `DejaVuSans`).
   - Render the updated text at the exact font size, color (`#17223b` for titles, `#4d5b72` for body, `#66738a` for subtext), and alignment.
   - If a container badge is needed, draw the rounded rectangle with subtle border and shadow before drawing the text.
4. **Draw Directional Conduits & Connectors**:
   - Draw anti-aliased lines and arrowheads using the established semantic color palette (solid blue for RPCs, glowing magenta for event streams, green for metrics, purple for auth).
5. **Save Lossless PNG**: Save the result directly as a high-quality PNG.

#### Method B: SVG Source of Truth with Keynote Styling
The repository also maintains vector sources (e.g. `bb-architecture.svg.bak` in Downloads / docs):
1. **Edit the SVG directly**: Modify `<text>`, `<path>`, and `<rect>` elements in SVG.
2. **Apply Keynote Glassmorphism in SVG**:
   - Use `<filter id="shadow">` with `feDropShadow`.
   - Use linear and radial gradients with soft opacity stops (`fill="url(#glass-gradient)"`, `stroke="rgba(255,255,255,0.8)"`).
   - Use rounded corners (`rx="12" ry="12"`).
3. **Render to PNG**: Render via headless Chromium, `resvg`, or `cairosvg` at 1376x768 (or 2x 2752x1536) for pristine vector clarity.

#### Method C: Adding or Replacing 3D Visual Elements
If a completely new 3D component (e.g., a new storage appliance or cluster pedestal) is needed:
1. **Generate the Element in Isolation**: Use `generate_image` or 3D rendering for *only that specific isolated element on a transparent or neutral background*, with **NO TEXT**.
2. **Mask and Composite**: Composite the isolated 3D element onto the base diagram canvas.
3. **Overlay Text via Code**: Add all technical labels, titles, and arrows using the vector overlay method (Method A or B).

### 4. Mandatory Quality Gates & Verification Checklist

Before opening a PR or committing any diagram changes, the agent MUST execute this verification workflow:

1. **Pixel-Level Inspection (`view_file` / Visual Inspection)**:
   - Crop regions of interest and inspect them at 100% zoom.
   - **Zero Hallucination Test**: Check every single label in the image. Does every word match valid English and official Hermetiq/Kubernetes terminology?
   - If any text looks like "hermetic", "Ezecute", "heshes", "manocqer", or any other distorted artifact, the image **FAILS** immediately.
2. **Resolution & Format Verification**:
   - Output format: PNG, 8-bit/color RGB, non-interlaced.
   - Standard resolution: `1376 x 768` (16:9) or `1920 x 1080`.
   - File size: Typically 700 KB – 1.5 MB for clean PNGs.
3. **Architectural Invariants Verification (Issue #111 / #31)**:
   Verify that all 10 invariants are strictly upheld:
   - [ ] **1. Ingress Flow**: Gateway terminates TLS and routes to `bep-nats-pub` (NOT directly to JetStream).
   - [ ] **2. JetStream Separation**: `bep-nats-pub` publishes; partitioned Go `bep-nats-sub` subscribers consume.
   - [ ] **3. Query API Decoupled**: `grpc-api` / `bep-nats-query-api` reads PostgreSQL & GCS; NO connection to NATS streams.
   - [ ] **4. Log Chunk Offloading**: Subscribers upload progress chunks to GCS (with PostgreSQL fallback); API reads from GCS; PostgreSQL does NOT write to GCS.
   - [ ] **5. OIDC Isolation**: OIDC Provider connects only for authentication/SSO at Gateway/Edge; NO connection to telemetry pipelines or metrics.
   - [ ] **6. 1:1 Partition Mapping**: NATS JetStream partitions `0..N-1` map 1:1 to dedicated subscriber deployments `bep-nats-sub-0..N-1`.
   - [ ] **7. Default Partition**: Database partition timeline shows `<parent>_default` catch-all partition (should normally be 0 rows).
   - [ ] **8. Buildbarn Frontend RPCs**: `bb-frontend` -> `bb-scheduler:8982` (Execute RPC); `bb-browser` and `bb-frontend` -> `bb-storage:8981` (Storage RPCs).
   - [ ] **9. Buildbarn Storage RPC Color**: Storage connections use blue data lines; magenta is reserved for event streams.
   - [ ] **10. KEDA PromQL Backlog**: KEDA queries VictoriaMetrics via PromQL for queue backlog; NO connection to disk, PVC, or local storage.
4. **Tooling Hygiene**:
   - Run `helm lint charts/hermetiq charts/buildbarn charts/bb-worker-operator` to ensure zero chart regressions.

### 5. Visual Style Specifications & Design Tokens

- **Perspective**: 30° / 60° orthographic isometric projection on multi-tiered floating platforms.
- **Canvas / Background**: Clean studio slate `#f6f8fc` to `#ffffff` with subtle ambient lighting.
- **Color Palette**:
  - Ingress / Gateway: Deep Indigo `#4f46e5` / `#6366f1`
  - Messaging / NATS: Vibrant Emerald `#059669` / `#10b981` / Glowing Magenta `#d946ef` for JetStream
  - Microservices / Subscribers: Vivid Cobalt `#0284c7` / `#0ea5e9`
  - Storage / Database: Warm Amber `#d97706` / Gold `#f59e0b`
  - Telemetry / Observability: Jade Green `#10b981` / Rose Crimson `#e11d48`
- **Typography**: Inter, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto.
  - Section headers: 700 15px uppercase, letter-spacing 0.08em
  - Component titles: 700 16px `#17223b`
  - Body / Subtext: 500 13px `#4d5b72` / 11.5px `#66738a`

### 6. Reference Master Assets & Style Benchmarks

For reference and delta baseline editing, master originals and style benchmarks are archived at:
- **Hermetiq Presentation Originals (Light Keynote Style)**:
  - `bb-architecture-ai.png` (Buildbarn Remote Execution Cluster)
  - `hermetiq-architecture-ai.png` (Hermetiq Platform Architecture)
  - `bep-ingest-architecture-ai.png` (BEP Ingest & PostgreSQL Partitioning Pipeline)
- **High-Tech Datacenter Benchmark (Dark Glassmorphic Style)**:
  - `fixed-images/bb-architecture-ai.png` (Buildbarn High-Tech Datacenter Architecture)
- **RobOS Infographic & Living Architecture Benchmarks**:
  - `agent-tier-dispatch-algorithm.jpg` (RobOS Agent Tier Dispatch Algorithm)
  - `kgraph-living-architecture.jpg` (SDLC Knowledge Graph: Living Architecture Engine)
- **Vector Technical Source**:
  - `bb-architecture.svg.bak` / `charts/buildbarn/docs/*.svg`
