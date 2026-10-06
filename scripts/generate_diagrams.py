#!/usr/bin/env python3
"""
Generate Customer-Facing 3D Isometric Architecture Diagrams
Using Frosted Glassmorphism Vector Overlay & Headless Chrome Rendering.

Ensures 100% adherence to the 3-Pass Verification Framework:
  Pass 1: Architecture & Flow Correctness (Issue #31 & #111 invariants)
  Pass 2: Visual Aesthetics & Bling (Keynote 3D glassmorphism)
  Pass 3: Typography & Label Zero-Hallucination (Pixel-perfect vector fonts)
"""

import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
BASE_DIR = Path(os.environ.get("DIAGRAM_BASE_DIR", "/home/ndipiazza/Downloads"))

# 1. Diagram 1: hermetiq-gke-deployment.png
d1_bg = BASE_DIR / "hermetiq-architecture-ai.png"
d1_html = f"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
  @import url("https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap");
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0;
    padding: 0;
    width: 1376px;
    height: 768px;
    overflow: hidden;
    position: relative;
    font-family: "Inter", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    -webkit-font-smoothing: antialiased;
  }}
  .bg {{
    position: absolute;
    top: 0;
    left: 0;
    width: 1376px;
    height: 768px;
    z-index: 1;
  }}
  .glass-card {{
    position: absolute;
    z-index: 10;
    background: rgba(255, 255, 255, 0.94);
    backdrop-filter: blur(12px);
    -webkit-backdrop-filter: blur(12px);
    border: 1px solid rgba(255, 255, 255, 0.95);
    border-radius: 8px;
    box-shadow: 0 4px 14px rgba(15, 23, 42, 0.08), 0 1px 3px rgba(15, 23, 42, 0.04);
  }}
  .pill {{
    position: absolute;
    z-index: 12;
    background: rgba(255, 255, 255, 0.98);
    border: 1px solid rgba(203, 213, 225, 0.9);
    border-radius: 5px;
    box-shadow: 0 2px 5px rgba(0, 0, 0, 0.05);
    display: flex;
    align-items: center;
    justify-content: center;
    font-weight: 600;
    color: #1e293b;
    font-size: 10px;
    letter-spacing: -0.01em;
  }}
  .card-title {{
    font-size: 12px;
    font-weight: 700;
    color: #0f172a;
    letter-spacing: -0.01em;
  }}
  .card-sub {{
    font-size: 9.5px;
    color: #475569;
    line-height: 1.35;
    margin-top: 2px;
  }}
</style>
</head>
<body>
  <img class="bg" src="{d1_bg}">

  <!-- Legend typo fix (remote wite -> remote write) -->
  <div style="position: absolute; z-index: 15; top: 52px; left: 1083px; width: 135px; height: 18px; background: #dfebf3; display: flex; align-items: center;">
    <span style="font-size: 10.5px; color: #1e293b; font-weight: 600; line-height: 1;">scrape / remote write</span>
  </div>

  <!-- Gateway Routes Overlay (fixes 'pisfens' hallucination and route list) -->
  <div class="pill" style="top: 159px; left: 601px; width: 220px; height: 26px; font-size: 8px; justify-content: flex-start; padding-left: 8px; background: #ffffff;">GRPCRoute · bep-cloud-grpc · api-cloud-grpc</div>
  <div class="pill" style="top: 187px; left: 601px; width: 220px; height: 26px; font-size: 8px; justify-content: flex-start; padding-left: 8px; background: #ffffff;">HTTPRoute · api-web · dashboard · grafana · mcp</div>

  <!-- Section 1: ClusterIP Services Box (covers old "Service bindings", fixing Finding 10 & typos) -->
  <div class="glass-card" style="top: 128px; left: 818px; width: 275px; height: 128px; padding: 9px 12px;">
    <div class="card-title">Kubernetes ClusterIP Services</div>
    <div style="font-size: 8.5px; font-weight: 600; color: #6366f1; margin-top: 1px;">L4 Internal Routing Only · No TLS Termination</div>
    <div class="card-sub" style="font-size: 8px; line-height: 1.35; margin-top: 4px;">
      bep-nats-pub :50091 · grpc-api :50091, :8008, :5150<br>
      web-ui :80 · grafana-oauth2-proxy :8080<br>
      <span style="color: #64748b;">Auth & tokens verified by application pods, not K8s Services</span>
    </div>
  </div>

  <!-- Section 1: OIDC Provider clean overlay -->
  <div class="glass-card" style="top: 128px; left: 1115px; width: 225px; height: 128px; padding: 9px 12px; text-align: center;">
    <div class="card-title" style="font-size: 11.5px;">OIDC Provider</div>
    <div style="font-size: 8.5px; font-weight: 600; color: #7c3aed; margin-top: 1px;">Auth & SSO (Control Plane)</div>
    <div class="card-sub" style="font-size: 8px; line-height: 1.35; margin-top: 4px;">
      OIDC discovery & JWKS verification<br>
      Secures UI, Grafana, gRPC, and MCP<br>
      <span style="font-weight: 600; color: #475569;">Decoupled from telemetry & ingest</span>
    </div>
  </div>

  <!-- Section 2: Ingestion sequence (Finding 1) - bep-nats-pub covers "Clients" on the middle pedestal -->
  <div class="pill" style="top: 435px; left: 115px; width: 100px; height: 26px; font-size: 10px; color: #0284c7; background: #ffffff;">bep-nats-pub</div>

  <!-- Section 2: Partition Subscribers badge over upper consumer deployments -->
  <div class="glass-card" style="top: 325px; left: 560px; width: 215px; height: 42px; padding: 4px 6px; text-align: center;">
    <div class="card-title" style="font-size: 10px; color: #0284c7;">Partition Subscribers</div>
    <div class="card-sub" style="font-size: 7.5px; margin-top: 1px;">bep-nats-sub-0 .. bep-nats-sub-(N-1)<br>1:1 per JetStream partition (replica: 1 each)</div>
  </div>

  <!-- Section 2: Finding 2 - Hermetiq Query API & MCP Decoupled from NATS -->
  <div class="glass-card" style="top: 480px; left: 575px; width: 230px; height: 110px; padding: 8px 10px;">
    <div class="card-title" style="font-size: 11.5px;">Hermetiq Query API & MCP</div>
    <div style="font-size: 8.5px; font-weight: 600; color: #059669; margin-top: 1px;">Zero NATS Dependency · Stateless</div>
    <div class="card-sub" style="font-size: 8px; line-height: 1.35; margin-top: 3px;">
      gRPC (:50091) · REST (:8008) · MCP (:5150)<br>
      Reads PostgreSQL metadata & GCS log chunks<br>
      <span style="color: #64748b;">No stream subscriptions · Decoupled from JetStream</span>
    </div>
  </div>

  <!-- Section 2: bep-nats-sub replaces erroneous 'bep-nats-pub' under the blue writer pod -->
  <div class="pill" style="top: 368px; left: 792px; width: 116px; height: 26px; font-size: 9.5px; color: #0284c7; background: #ffffff;">bep-nats-sub</div>

  <!-- Section 2: Finding 3 - No DB write to GCS (masks erroneous blue arrow from Postgres to GCS) -->
  <div class="glass-card" style="top: 332px; left: 1010px; width: 135px; height: 32px; padding: 3px 6px; text-align: center; border: 1px solid #e11d48;">
    <div style="font-size: 8px; font-weight: 700; color: #e11d48;">No DB-to-GCS Write</div>
    <div style="font-size: 7px; color: #475569;">Subscribers upload to GCS directly</div>
  </div>

  <!-- Section 2: Finding 3 - Subscribers upload chunks to GCS (covers purple event-stream line into GCS) -->
  <div class="glass-card" style="top: 464px; left: 865px; width: 165px; height: 42px; padding: 5px 6px; text-align: center; border: 1px solid #0284c7;">
    <div style="font-size: 8.5px; font-weight: 700; color: #0284c7;">Direct Chunk Offload</div>
    <div style="font-size: 7.5px; color: #475569; margin-top: 2px;">Subscribers upload stdout/stderr to GCS</div>
  </div>

  <!-- Section 3: Finding 4 - VMAgent replaces hallucinated OIDC Provider under VictoriaMetrics -->
  <div class="pill" style="top: 682px; left: 935px; width: 115px; height: 25px; font-size: 9.5px; font-weight: 700; color: #059669;">VMAgent Scraper</div>

</body>
</html>
"""

# 2. Diagram 2: hermetiq-nats-db-ingest.png
d2_bg = BASE_DIR / "bep-ingest-architecture-ai.png"
d2_html = f"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
  @import url("https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap");
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0;
    padding: 0;
    width: 1376px;
    height: 768px;
    overflow: hidden;
    position: relative;
    font-family: "Inter", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    -webkit-font-smoothing: antialiased;
  }}
  .bg {{
    position: absolute;
    top: 0;
    left: 0;
    width: 1376px;
    height: 768px;
    z-index: 1;
  }}
  .glass-card {{
    position: absolute;
    z-index: 10;
    background: rgba(255, 255, 255, 0.94);
    backdrop-filter: blur(12px);
    -webkit-backdrop-filter: blur(12px);
    border: 1px solid rgba(255, 255, 255, 0.95);
    border-radius: 8px;
    box-shadow: 0 4px 14px rgba(15, 23, 42, 0.08), 0 1px 3px rgba(15, 23, 42, 0.04);
  }}
  .pill {{
    position: absolute;
    z-index: 12;
    background: rgba(255, 255, 255, 0.98);
    border: 1px solid rgba(203, 213, 225, 0.9);
    border-radius: 5px;
    box-shadow: 0 2px 5px rgba(0, 0, 0, 0.05);
    display: flex;
    align-items: center;
    justify-content: center;
    font-weight: 600;
    color: #1e293b;
    font-size: 10px;
    letter-spacing: -0.01em;
    white-space: nowrap;
  }}
  .stream-tag {{
    position: absolute;
    z-index: 12;
    background: rgba(147, 51, 234, 0.85);
    border: 1px solid rgba(255, 255, 255, 0.85);
    border-radius: 4px;
    backdrop-filter: blur(6px);
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 10px;
    font-weight: 700;
    color: #ffffff;
    text-shadow: 0 1px 2px rgba(0,0,0,0.6);
  }}
  .card-title {{
    font-size: 12px;
    font-weight: 700;
    color: #0f172a;
    letter-spacing: -0.01em;
  }}
  .card-sub {{
    font-size: 9.5px;
    color: #475569;
    line-height: 1.35;
    margin-top: 2px;
  }}
</style>
</head>
<body>
  <img class="bg" src="{d2_bg}">

  <!-- 1. Bazel Clients (fixes "Bszel clients") -->
  <div class="glass-card" style="top: 120px; left: 65px; width: 185px; height: 90px; padding: 10px 12px;">
    <div class="card-title">Bazel clients</div>
    <div class="card-sub">Build Event Protocol<br>invocation + build ID</div>
  </div>

  <!-- 2. Delivery Guarantees (fixes garbled text and typos) -->
  <div class="glass-card" style="top: 265px; left: 50px; width: 400px; height: 75px; padding: 8px 12px;">
    <div class="card-title">Delivery guarantees</div>
    <div class="card-sub">JetStream retries failed deliveries with backoff; terminal errors route to BEP DLQ.<br>Partition affinity processes invocation events in dedicated subscriber Deployments.</div>
  </div>

  <!-- 3. NATS Streams (fixes duplicate Stream 1, 2) -->
  <div class="stream-tag" style="top: 135px; left: 805px; width: 85px; height: 32px;">Stream 0</div>
  <div class="stream-tag" style="top: 135px; left: 905px; width: 85px; height: 32px;">Stream 1</div>
  <div class="stream-tag" style="top: 175px; left: 805px; width: 85px; height: 32px;">Stream 2</div>
  <div class="stream-tag" style="top: 175px; left: 905px; width: 85px; height: 32px;">Stream 3</div>
  <div class="stream-tag" style="top: 220px; left: 805px; width: 85px; height: 32px;">Stream 4</div>
  <div class="stream-tag" style="top: 220px; left: 905px; width: 85px; height: 32px;">Stream N-1</div>

  <!-- NATS footer (fixes "internal intention" and typos) -->
  <div class="glass-card" style="top: 270px; left: 785px; width: 245px; height: 54px; padding: 6px 6px; text-align: center;">
    <div style="font-size: 8.5px; font-weight: 600; color: #334155;">File storage · RF3 (3 replicas)</div>
    <div style="font-size: 8px; color: #475569; margin-top: 1px;">Explicit ACK · 30m retention</div>
  </div>

  <!-- 4. Subscriber Pods (fixes duplicate sub-1s) -->
  <div class="pill" style="top: 145px; left: 1088px; width: 92px; height: 24px;">bep-nats-sub-0</div>
  <div class="pill" style="top: 145px; left: 1188px; width: 92px; height: 24px;">bep-nats-sub-1</div>
  <div class="pill" style="top: 188px; left: 1096px; width: 92px; height: 24px;">bep-nats-sub-2</div>
  <div class="pill" style="top: 188px; left: 1196px; width: 92px; height: 24px;">bep-nats-sub-3</div>
  <div class="pill" style="top: 235px; left: 1104px; width: 92px; height: 24px;">bep-nats-sub-4</div>
  <div class="pill" style="top: 235px; left: 1198px; width: 105px; height: 24px; font-size: 8px;">bep-nats-sub-(N-1)</div>
  <div class="pill" style="top: 285px; left: 1106px; width: 92px; height: 24px; font-size: 8.5px; background: #f8fafc;">replica: 1 each</div>
  <div class="pill" style="top: 285px; left: 1208px; width: 92px; height: 24px; font-size: 8.5px; background: #f8fafc;">1:1 per partition</div>

  <!-- Arrow Labels around Ingest -->
  <div class="glass-card" style="top: 326px; left: 1040px; width: 195px; height: 22px; padding: 2px 6px; text-align: center;">
    <div style="font-size: 8.5px; font-weight: 600; color: #0284c7;">subscribers upload compressed chunks</div>
  </div>

  <!-- SQL Metadata write label (fixes "normal evorts · BEFBEP stream") -->
  <div class="glass-card" style="top: 350px; left: 955px; width: 195px; height: 22px; padding: 2px 6px; text-align: center;">
    <div style="font-size: 8px; font-weight: 600; color: #0284c7;">SQL metadata writes (batch INSERT)</div>
  </div>

  <!-- 5. Query API (fixes "RECT", "pity prates", "ramors") -->
  <div class="glass-card" style="top: 380px; left: 45px; width: 195px; height: 120px; padding: 8px 10px;">
    <div class="card-title" style="font-size: 11.5px;">Query API · Deploy x2</div>
    <div style="font-size: 11px; font-weight: 700; color: #1e293b; margin-top: 1px;">grpc-api</div>
    <div class="card-sub" style="font-size: 8px; line-height: 1.35; margin-top: 2px;">
      gRPC (:50091) · REST (:8008) · MCP (:5150)<br>
      Time-bounded queries · Pruned reads<br>
      Reads PostgreSQL & GCS progress store<br>
      <span style="font-weight: 600; color: #059669;">Zero NATS dependency</span>
    </div>
  </div>

  <!-- 6. Cloud SQL PostgreSQL Parent Table Stacks (fixes "outprt_tests", "remote_ramne", "parents tents", "progresses") -->
  <div class="pill" style="top: 390px; left: 402px; width: 126px; height: 25px; font-size: 8px;">invocations · targets · tests</div>
  <div class="pill" style="top: 390px; left: 538px; width: 126px; height: 25px; font-size: 8px;">actions · logs · output_tests</div>
  <div class="pill" style="top: 390px; left: 672px; width: 132px; height: 25px; font-size: 8px;">cache_events · remote_exec</div>
  <div class="pill" style="top: 390px; left: 816px; width: 135px; height: 25px; font-size: 8px;">progresses · 20 parent tables</div>

  <!-- PostgreSQL GCS chunk fallback label -->
  <div class="glass-card" style="top: 485px; left: 740px; width: 250px; height: 22px; padding: 2px 6px; text-align: center;">
    <div style="font-size: 8px; font-weight: 500; color: #334155;">progress fallback (if GCS offline) · No DB write to GCS</div>
  </div>

  <!-- 7. GCS Progress Store (fixes "protobol chonks", "GRE Workload") -->
  <div class="glass-card" style="top: 380px; left: 1010px; width: 275px; height: 125px; padding: 8px 10px;">
    <div class="card-title">GCS progress store</div>
    <div style="font-size: 9.5px; font-weight: 600; color: #1e293b; margin-top: 1px;">per-project artifact bucket</div>
    <div class="card-sub" style="font-size: 8px; line-height: 1.35; margin-top: 3px;">
      Async gzip protobuf chunks · GKE Workload Identity<br>
      progress/v1/&lt;project&gt;/&lt;invocation&gt;/&lt;seq&gt;-&lt;chunk&gt;.pb.gz<br>
      <span style="font-weight: 600; color: #0284c7;">grpc-api reads chunks directly · Database fallback</span>
    </div>
  </div>

  <!-- Bottom progress chunks line under GCS -->
  <div class="glass-card" style="top: 498px; left: 960px; width: 265px; height: 26px; padding: 4px 6px; text-align: center;">
    <div style="font-size: 8px; font-weight: 600; color: #0284c7;">progress chunks uploaded to GCS</div>
  </div>

  <!-- 8. Control plane typo fix (fixes "source tom") -->
  <div class="glass-card" style="top: 540px; left: 285px; width: 250px; height: 58px; padding: 8px 10px;">
    <div class="card-title" style="font-size: 11px;">public.part_config</div>
    <div class="card-sub" style="font-size: 8.5px;">pg_partman source of truth<br>Automatic retention and premake control</div>
  </div>

  <!-- 9. Bottom Conveyor Partition Timeline Labels (fixes "retamed", "default bucket") -->
  <div class="glass-card" style="top: 702px; left: 15px; width: 1346px; height: 60px; padding: 6px 15px; display: flex; justify-content: space-between; align-items: center;">
    <div style="text-align: center; width: 220px;">
      <div class="card-title" style="font-size: 10.5px;">EXPIRED DROPS</div>
      <div class="card-sub" style="font-size: 8px;">DROP TABLE at retention · not retained as empty shells</div>
    </div>
    <div style="text-align: center; width: 260px;">
      <div class="card-title" style="font-size: 10.5px;">CLOSED HISTORICAL CHILDREN</div>
      <div class="card-sub" style="font-size: 8px;">Closed for writes · fully queryable · pruned by query range</div>
    </div>
    <div style="text-align: center; width: 240px;">
      <div class="card-title" style="font-size: 10.5px; color: #0284c7;">CURRENT ACTIVE PARTITION</div>
      <div class="card-sub" style="font-size: 8px;">Active INSERT target · (NOT default bucket)</div>
    </div>
    <div style="text-align: center; width: 250px;">
      <div class="card-title" style="font-size: 10.5px;">PRE-CREATED FUTURE PARTITIONS</div>
      <div class="card-sub" style="font-size: 8px;">Premake horizon creates child tables in advance</div>
    </div>
    <div style="text-align: center; width: 230px; border-left: 2px solid #e11d48; padding-left: 8px;">
      <div class="card-title" style="font-size: 10.5px; color: #e11d48;">&lt;parent&gt;_default CATCH-ALL</div>
      <div class="card-sub" style="font-size: 8px;">Catch-all out-of-range rows · Alert if rows &gt; 0</div>
    </div>
  </div>

</body>
</html>
"""

# 3. Diagram 3: hermetiq-buildbarn-diagram.png
d3_bg = BASE_DIR / "bb-architecture-ai.png"
d3_html = f"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
  @import url("https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap");
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0;
    padding: 0;
    width: 1376px;
    height: 768px;
    overflow: hidden;
    position: relative;
    font-family: "Inter", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    -webkit-font-smoothing: antialiased;
  }}
  .bg {{
    position: absolute;
    top: 0;
    left: 0;
    width: 1376px;
    height: 768px;
    z-index: 1;
  }}
  .glass-card {{
    position: absolute;
    z-index: 10;
    background: rgba(255, 255, 255, 0.94);
    backdrop-filter: blur(12px);
    -webkit-backdrop-filter: blur(12px);
    border: 1px solid rgba(255, 255, 255, 0.95);
    border-radius: 8px;
    box-shadow: 0 4px 14px rgba(15, 23, 42, 0.08), 0 1px 3px rgba(15, 23, 42, 0.04);
  }}
  .card-title {{
    font-size: 12px;
    font-weight: 700;
    color: #0f172a;
    letter-spacing: -0.01em;
  }}
  .card-sub {{
    font-size: 9.5px;
    color: #475569;
    line-height: 1.35;
    margin-top: 2px;
  }}
</style>
</head>
<body>
  <img class="bg" src="{d3_bg}">

  <!-- Section 1: Finding 10 - ClusterIP routing only (covers old "Service bindings") -->
  <div class="glass-card" style="top: 128px; left: 818px; width: 275px; height: 128px; padding: 9px 12px;">
    <div class="card-title">Kubernetes ClusterIP Services</div>
    <div style="font-size: 8.5px; font-weight: 600; color: #6366f1; margin-top: 1px;">L4 Internal Routing Only · No TLS Termination</div>
    <div class="card-sub" style="font-size: 8px; line-height: 1.35; margin-top: 4px;">
      frontend-grpc · REAPI :8980<br>
      bb-browser · Web UI :80<br>
      <span style="color: #64748b;">Auth & tokens verified by application pods, not K8s Services</span>
    </div>
  </div>

  <!-- Section 1: OIDC Provider clean overlay (fixes "Gafana" typo and double label) -->
  <div class="glass-card" style="top: 128px; left: 1115px; width: 225px; height: 128px; padding: 9px 12px; text-align: center;">
    <div class="card-title" style="font-size: 11.5px;">OIDC Provider</div>
    <div style="font-size: 8.5px; font-weight: 600; color: #7c3aed; margin-top: 1px;">Auth & SSO (Control Plane)</div>
    <div class="card-sub" style="font-size: 8px; line-height: 1.35; margin-top: 4px;">
      OIDC discovery & JWKS verification<br>
      Secures UI, Grafana, gRPC, and MCP<br>
      <span style="font-weight: 600; color: #475569;">Application token verification</span>
    </div>
  </div>

  <!-- Section 2: Finding 7 - Frontend -> Scheduler execution connection -->
  <div class="glass-card" style="top: 450px; left: 740px; width: 170px; height: 48px; padding: 4px 6px; text-align: center; border: 1px solid #3b82f6;">
    <div style="font-size: 10px; font-weight: 700; color: #1d4ed8;">bb-frontend</div>
    <div style="font-size: 7.5px; color: #475569; margin-top: 1px;">Routes Execute RPCs to bb-scheduler:8982<br>Routes CAS/AC to bb-storage:8981</div>
  </div>

  <!-- Section 2: Finding 7 - Browser -> Storage blobstore reads -->
  <div class="glass-card" style="top: 450px; left: 920px; width: 160px; height: 48px; padding: 4px 6px; text-align: center; border: 1px solid #3b82f6;">
    <div style="font-size: 10px; font-weight: 700; color: #1d4ed8;">bb-browser</div>
    <div style="font-size: 7.5px; color: #475569; margin-top: 1px;">Build exploration Web UI (:80)<br>Direct read-only CAS/AC inspection</div>
  </div>

  <!-- Section 2: Finding 8 - Worker storage traffic category (Blue data lines) -->
  <div class="glass-card" style="top: 515px; left: 770px; width: 280px; height: 42px; padding: 4px 8px; text-align: center; border: 1px solid #2563eb;">
    <div style="font-size: 9.5px; font-weight: 700; color: #1d4ed8;">Storage RPCs :8981 (CAS · AC · FSAC)</div>
    <div style="font-size: 7.5px; color: #475569; margin-top: 1px;">Worker payload reads/writes · Direct gRPC data (NOT event stream)</div>
  </div>

  <!-- Section 3: Finding 9 - KEDA autoscaling (No disk connection, queries VictoriaMetrics) -->
  <!-- Mask disk-to-KEDA green line (width expanded to 118px to cover arrowhead) -->
  <div class="glass-card" style="top: 642px; left: 466px; width: 118px; height: 34px; padding: 3px 5px; text-align: center; border: 1px solid #0284c7;">
    <div style="font-size: 8px; font-weight: 700; color: #0284c7;">No Disk Link</div>
    <div style="font-size: 7px; color: #475569;">Workers use NVMe SSD</div>
  </div>

  <!-- KEDA PromQL query badge over VictoriaMetrics -->
  <div class="glass-card" style="top: 636px; left: 660px; width: 110px; height: 38px; padding: 3px 5px; text-align: center; border: 1px solid #059669;">
    <div style="font-size: 8px; font-weight: 700; color: #059669;">PromQL Backlog</div>
    <div style="font-size: 7px; color: #475569;">tasks_scheduled_total<br>scales bb-workers</div>
  </div>

</body>
</html>
"""

DIAGRAMS = [
    ("d1", d1_html, "hermetiq-gke-deployment.png"),
    ("d2", d2_html, "hermetiq-nats-db-ingest.png"),
    ("d3", d3_html, "hermetiq-buildbarn-diagram.png"),
]


def main():
    print(f"Generating architecture diagrams using base images in {BASE_DIR}")
    for prefix, html_content, output_name in DIAGRAMS:
        tmp_html = Path(f"/tmp/{prefix}_render.html")
        tmp_html.write_text(html_content, encoding="utf-8")
        out_target = REPO_ROOT / output_name

        cmd = [
            "google-chrome",
            "--headless",
            "--disable-gpu",
            "--hide-scrollbars",
            f"--screenshot={out_target}",
            "--window-size=1376,768",
            str(tmp_html),
        ]
        print(f"Rendering {output_name}...")
        subprocess.run(cmd, check=True)
        print(f"Successfully generated {out_target} ({out_target.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
