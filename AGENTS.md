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

### 4. The 3-Pass Verification Framework

To guarantee presentation-grade visuals with zero hallucinations and full architectural rigor, every diagram modification MUST undergo and pass all three independent verification passes before committing:

```
Pass 1: Architecture & Flow Verification (Invariants & Topology)
   │
   ▼
Pass 2: Glassmorphism Aesthetics & Bling (Keynote 3D Presentation)
   │
   ▼
Pass 3: Typography & Label Zero-Hallucination (Pixel-Perfect Legibility)
```

#### Pass 1: Architecture & Flow Verification
Verify every data path and service boundary against the 10 invariants established in Issues #31 and #111:
1. **Ingress Flow**: Gateway terminates TLS at the cluster edge and routes to `bep-nats-pub` (:50091) and `grpc-api` (:50091, :8008, :5150) via L4 ClusterIP routing.
2. **JetStream Separation**: `bep-nats-pub` acts strictly as the publisher into NATS JetStream; Go-based `bep-nats-sub` subscribers consume partitions. `bep-nats-pub` never writes directly to PostgreSQL or GCS.
3. **Query API Decoupled**: `grpc-api` / `bep-nats-query-api` reads PostgreSQL metadata and GCS progress chunks; it maintains ZERO NATS dependencies and subscribes to no streams.
4. **Log Chunk Offloading**: `bep-nats-sub` uploads progress log chunks directly to GCS (with DB progress fallback); PostgreSQL stores metadata only and never writes directly to GCS.
5. **OIDC Isolation**: OIDC Provider connects exclusively to Edge Gateway and application pods for auth/SSO; it has no link to telemetry pipelines or metrics scrapers.
6. **1:1 Partition Mapping**: NATS JetStream partitions `Stream 0..N-1` map 1:1 to dedicated subscriber deployments `bep-nats-sub-0..N-1` (`replica: 1 each`).
7. **Default Partition**: PostgreSQL conveyor partition timeline explicitly displays the `<parent>_default` catch-all partition with an alert indicator if rows > 0.
8. **Buildbarn Frontend RPCs**: `bb-frontend` routes Execute RPCs to `bb-scheduler:8982` and CAS/AC to `bb-storage:8981`; `bb-browser` reads directly from storage (:8981).
9. **Buildbarn Storage RPC Traffic**: Worker storage connections (`:8981 CAS · AC · FSAC`) use blue data conduits, distinct from magenta event streams.
10. **KEDA PromQL Backlog**: KEDA queries VictoriaMetrics via PromQL for queue backlog (`tasks_scheduled_total`); no connection to worker local disks, PVCs, or NVMe chassis.

#### Pass 2: Glassmorphism Aesthetics & "Bling" Quality
Ensure the customer-facing keynote aesthetic is maintained with full visual polish:
- **Depth & Lighting**: Translucent floating pedestals, soft studio lighting, directional drop shadows, and multi-tier isometric projection.
- **Card Containers**: Semi-transparent frosted acrylic glass cards (`rgba(255, 255, 255, 0.94)`, `backdrop-filter: blur(12px)`, `border: 1px solid rgba(255, 255, 255, 0.95)`, `box-shadow: 0 4px 14px rgba(15, 23, 42, 0.08)`).
- **Micro-Pills & Badges**: Clean rounded pill badges (`border-radius: 5px`, `border: 1px solid rgba(203, 213, 225, 0.9)`) matching component dimensions.
- **Geometric Alignment**: Symmetrical top-right edge boxes (`ClusterIP Services` at `818px x 128px`, `OIDC Provider` at `1115px x 128px`), 1:1 parent table stack alignment, and seamless bottom conveyor timeline.
- **No Diffusion Degradation**: No noisy artifacts, blurred edges, warped boxes, or mangled textures.

#### Pass 3: Typography & Label Zero-Hallucination
Inspect 100% of visible text elements across all three images:
- **Vector Rendering**: All updated text must be rendered through true digital typography (Google Inter, Apple SF Pro, or Roboto) via headless Chromium / Chrome.
- **Zero Garble Policy**: Absolutely zero pseudo-words, scrambled characters, or latent diffusion hallucinations.
- **Resolved Hallucination Reference**:
  - `remote wite` -> `remote write`
  - `pisfens` -> `grafana`
  - `bep-nsts-pub` -> `bep-nats-pub :50091`
  - `web-ut-80` -> `web-ui :80`
  - `Gafana` -> `Grafana`
  - `Bszel clients` -> `Bazel clients`
  - `outprt_tests` -> `output_tests`
  - `remote_ramne` -> `remote_exec`
  - `parents tents` -> `parent tables`
  - `normal evorts · BEFBEP stream` -> `SQL metadata writes (batch INSERT)`
  - `retamed` -> `retained`
  - `source tom` -> `source of truth`
  - `protobol chonks` -> `gzip protobuf chunks`
  - `GRE Workload` -> `GKE Workload Identity`
  - Erroneous `bep-nats-pub` under consumer writer pod -> `bep-nats-sub`

---

### 5. Automated Diagram Generation Pipeline

The repository provides an automated diagram generator script:

```bash
# Run from repository root:
./scripts/generate_diagrams.py
```

#### How it works:
1. Loads the high-resolution 3D base plates (`hermetiq-architecture-ai.png`, `bep-ingest-architecture-ai.png`, `bb-architecture-ai.png`).
2. Pre-processes the base plates via `prepare_clean_base_images()` using smooth background inpainting and vertical rib interpolation to dissolve baked-in AI text. This enables high-transparency frosted glass overlays (`rgba(..., 0.45)`) without underlying ghost text bleeding through.
3. Composes the HTML/CSS frosted-glass vector overlays with exact, tight bounding box coordinates.
4. Renders each diagram with Google Chrome headless at native 1376x768 resolution:
   `google-chrome --headless --disable-gpu --hide-scrollbars --screenshot=<output.png> --window-size=1376,768 <overlay.html>`
5. Writes the production PNGs directly to repository root:
   - `hermetiq-gke-deployment.png`
   - `hermetiq-nats-db-ingest.png`
   - `hermetiq-buildbarn-diagram.png`

#### How Future Agents Must Update Diagrams:
1. Open `scripts/generate_diagrams.py`.
2. Locate the relevant diagram template (`build_d1_html`, `build_d2_html`, or `build_d3_html`).
3. Keep bounding boxes **tight** to the text actually used (e.g. `ClusterIP Services` at `226x76px`, `Query API` at `198x86px`, `GCS progress store` at `232x86px`). Never let textareas cover underlying 3D glass slabs, beveled edges, or storage partition ribs.
4. Use transparent frosted glass tokens (`.glass-ice-trans`, `.glass-violet-trans`, `.glass-cyan-trans`) with subtle linear gradients (`rgba(..., 0.45) 0%`, `rgba(..., 0.28) 50%`) and `backdrop-filter: blur(8px) saturate(180%)` so underlying 3D base plates and lighting shine through.
5. Apply **high-contrast, bold typography** (`font-weight: 700`–`800`) using dark slate (`#0f172a`, `#1e293b`) and dark saturated accents (`#3730a3`, `#5b21b6`, `#0369a1`, `#047857`). Strictly avoid faint, washed-out light gray (`#64748b`, `#475569`) at small font sizes.
6. If modifying elements that overlay baked-in base image text, ensure `prepare_clean_base_images()` includes the inpainting coordinates so no ghost text shows through.
7. Execute `python3 scripts/generate_diagrams.py`.
8. Use `view_file` to inspect cropped regions of modified areas at 100% zoom.
9. Verify against the 3-Pass Verification Framework (Pass 1, Pass 2, Pass 3).
10. Run `helm lint charts/hermetiq charts/buildbarn charts/bb-worker-operator`.
11. Commit and submit PR.

---

### 6. Visual Style Specifications & Design Tokens

- **Perspective**: 30° / 60° orthographic isometric projection on multi-tiered floating platforms.
- **Canvas / Background**: Clean studio slate `#f6f8fc` to `#ffffff` with subtle ambient lighting.
- **Glass Transparency**:
  - High-transparency cards: `rgba(..., 0.45)` down to `rgba(..., 0.28)` with `backdrop-filter: blur(8px) saturate(180%)`.
  - Frosted micro-pills: `rgba(255, 255, 255, 0.90)` to `0.92` with `backdrop-filter: blur(10px)`.
- **Color Palette**:
  - Ingress / Gateway: Deep Indigo `#4f46e5` / `#3730a3`
  - Messaging / NATS: Vibrant Emerald `#059669` / `#047857` / Magenta `#7e22ce` for JetStream
  - Microservices / Subscribers: Vivid Cobalt `#0284c7` / `#0369a1`
  - Storage / Database: Deep Navy `#0f172a` / `#1e293b` / Rose Crimson `#e11d48`
  - Telemetry / Observability: Jade Green `#047857` / Slate `#334155`
- **Typography**: Inter, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto.
  - Section headers: 800 15px uppercase, letter-spacing 0.08em
  - Component titles: 800 11px `#0f172a`
  - Subtitles & Accent lines: 800 8px–10px (`#3730a3`, `#5b21b6`, `#0369a1`, `#047857`)
  - Body / Subtext: 700 7.5px–8px `#1e293b` (strictly avoid low-contrast light grays)

### 7. Reference Master Assets & Style Benchmarks

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
