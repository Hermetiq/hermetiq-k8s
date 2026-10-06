#!/usr/bin/env python3
"""
Generate Customer-Facing 3D Isometric Architecture Diagrams
Using Frosted Glassmorphism Vector Overlay & Headless Chrome Rendering.

Ensures 100% adherence to the 3-Pass Verification Framework:
  Pass 1: Architecture & Flow Correctness (Issue #31 & #111 invariants)
  Pass 2: Visual Aesthetics & Bling (Layered frosted glass, textured blending, tight boxes)
  Pass 3: Typography & Label Zero-Hallucination (Pixel-perfect vector typography)
"""

import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
BASE_DIR = Path(os.environ.get("DIAGRAM_BASE_DIR", "/home/ndipiazza/Downloads"))

SHARED_CSS = """
  @import url("https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap");
  * { box-sizing: border-box; }
  body {
    margin: 0;
    padding: 0;
    width: 1376px;
    height: 768px;
    overflow: hidden;
    position: relative;
    font-family: "Inter", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    -webkit-font-smoothing: antialiased;
  }
  .bg {
    position: absolute;
    top: 0;
    left: 0;
    width: 1376px;
    height: 768px;
    z-index: 1;
  }

  /* Semantic Layered Frosted Glass Styles */
  .glass-ice {
    position: absolute;
    z-index: 10;
    background: linear-gradient(135deg, rgba(235, 245, 255, 0.86) 0%, rgba(215, 235, 254, 0.72) 50%, rgba(240, 249, 255, 0.88) 100%);
    backdrop-filter: blur(14px) saturate(170%);
    -webkit-backdrop-filter: blur(14px) saturate(170%);
    border: 1px solid rgba(255, 255, 255, 0.92);
    border-radius: 8px;
    box-shadow: 0 4px 14px rgba(30, 58, 138, 0.07), 0 1px 3px rgba(30, 58, 138, 0.03), inset 0 1px 1px rgba(255, 255, 255, 0.95);
  }
  .glass-violet {
    position: absolute;
    z-index: 10;
    background: linear-gradient(135deg, rgba(248, 244, 255, 0.88) 0%, rgba(237, 233, 254, 0.72) 50%, rgba(250, 245, 255, 0.90) 100%);
    backdrop-filter: blur(14px) saturate(170%);
    -webkit-backdrop-filter: blur(14px) saturate(170%);
    border: 1px solid rgba(255, 255, 255, 0.92);
    border-radius: 8px;
    box-shadow: 0 4px 14px rgba(109, 40, 217, 0.07), 0 1px 3px rgba(109, 40, 217, 0.03), inset 0 1px 1px rgba(255, 255, 255, 0.95);
  }
  .glass-cyan {
    position: absolute;
    z-index: 10;
    background: linear-gradient(135deg, rgba(240, 249, 255, 0.86) 0%, rgba(224, 242, 254, 0.72) 50%, rgba(245, 250, 255, 0.88) 100%);
    backdrop-filter: blur(14px) saturate(170%);
    -webkit-backdrop-filter: blur(14px) saturate(170%);
    border: 1px solid rgba(255, 255, 255, 0.92);
    border-radius: 8px;
    box-shadow: 0 4px 14px rgba(2, 132, 199, 0.07), 0 1px 3px rgba(2, 132, 199, 0.03), inset 0 1px 1px rgba(255, 255, 255, 0.95);
  }
  .glass-emerald {
    position: absolute;
    z-index: 10;
    background: linear-gradient(135deg, rgba(236, 253, 245, 0.88) 0%, rgba(209, 250, 229, 0.72) 50%, rgba(242, 253, 248, 0.90) 100%);
    backdrop-filter: blur(14px) saturate(170%);
    -webkit-backdrop-filter: blur(14px) saturate(170%);
    border: 1px solid rgba(255, 255, 255, 0.92);
    border-radius: 8px;
    box-shadow: 0 4px 14px rgba(5, 150, 105, 0.07), 0 1px 3px rgba(5, 150, 105, 0.03), inset 0 1px 1px rgba(255, 255, 255, 0.95);
  }
  .glass-slate {
    position: absolute;
    z-index: 10;
    background: linear-gradient(135deg, rgba(248, 250, 252, 0.86) 0%, rgba(241, 245, 249, 0.72) 50%, rgba(255, 255, 255, 0.90) 100%);
    backdrop-filter: blur(14px) saturate(150%);
    -webkit-backdrop-filter: blur(14px) saturate(150%);
    border: 1px solid rgba(255, 255, 255, 0.92);
    border-radius: 8px;
    box-shadow: 0 4px 12px rgba(15, 23, 42, 0.06), 0 1px 3px rgba(15, 23, 42, 0.03), inset 0 1px 1px rgba(255, 255, 255, 0.95);
  }
  .glass-rose {
    position: absolute;
    z-index: 10;
    background: linear-gradient(135deg, rgba(255, 241, 242, 0.88) 0%, rgba(254, 226, 226, 0.74) 50%, rgba(255, 245, 246, 0.90) 100%);
    backdrop-filter: blur(14px);
    -webkit-backdrop-filter: blur(14px);
    border: 1px solid rgba(244, 63, 94, 0.45);
    border-radius: 6px;
    box-shadow: 0 4px 12px rgba(225, 29, 72, 0.07), inset 0 1px 1px rgba(255, 255, 255, 0.95);
  }
  .glass-pill {
    position: absolute;
    z-index: 12;
    background: linear-gradient(180deg, rgba(255, 255, 255, 0.90) 0%, rgba(241, 245, 249, 0.80) 100%);
    backdrop-filter: blur(10px);
    -webkit-backdrop-filter: blur(10px);
    border: 1px solid rgba(203, 213, 225, 0.85);
    border-radius: 5px;
    box-shadow: 0 2px 5px rgba(0, 0, 0, 0.04), inset 0 1px 0 rgba(255, 255, 255, 0.95);
    display: flex;
    align-items: center;
    justify-content: center;
    font-weight: 600;
    color: #1e293b;
    letter-spacing: -0.01em;
    white-space: nowrap;
  }
  .glass-sub-pill {
    position: absolute;
    z-index: 12;
    background: linear-gradient(180deg, rgba(240, 249, 255, 0.92) 0%, rgba(224, 242, 254, 0.82) 100%);
    backdrop-filter: blur(10px);
    -webkit-backdrop-filter: blur(10px);
    border: 1px solid rgba(186, 230, 253, 0.90);
    border-radius: 5px;
    box-shadow: 0 2px 5px rgba(2, 132, 199, 0.08), inset 0 1px 0 rgba(255, 255, 255, 0.95);
    display: flex;
    align-items: center;
    justify-content: center;
    font-weight: 700;
    color: #0369a1;
    letter-spacing: -0.01em;
    white-space: nowrap;
  }
  .stream-tag {
    position: absolute;
    z-index: 12;
    background: linear-gradient(135deg, rgba(147, 51, 234, 0.88) 0%, rgba(126, 34, 206, 0.92) 100%);
    border: 1px solid rgba(255, 255, 255, 0.90);
    border-radius: 5px;
    backdrop-filter: blur(8px);
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 10px;
    font-weight: 700;
    color: #ffffff;
    box-shadow: 0 2px 6px rgba(126, 34, 206, 0.25), inset 0 1px 0 rgba(255, 255, 255, 0.4);
    text-shadow: 0 1px 2px rgba(0,0,0,0.5);
  }
  .card-title {
    font-size: 11.5px;
    font-weight: 700;
    color: #0f172a;
    letter-spacing: -0.01em;
  }
  .card-sub {
    font-size: 8px;
    color: #475569;
    line-height: 1.35;
    margin-top: 2px;
  }
  .conveyor-dock {
    position: absolute;
    z-index: 10;
    top: 702px;
    left: 15px;
    width: 1346px;
    height: 56px;
    padding: 4px 16px;
    display: flex;
    justify-content: space-between;
    align-items: center;
    background: linear-gradient(180deg, rgba(243, 246, 251, 0.88) 0%, rgba(228, 236, 247, 0.80) 100%);
    backdrop-filter: blur(14px) saturate(140%);
    -webkit-backdrop-filter: blur(14px) saturate(140%);
    border: 1px solid rgba(255, 255, 255, 0.92);
    border-radius: 8px;
    box-shadow: 0 4px 14px rgba(15, 23, 42, 0.05), inset 0 1px 1px rgba(255, 255, 255, 0.95);
  }
"""

# 1. Diagram 1: hermetiq-gke-deployment.png
d1_bg = BASE_DIR / "hermetiq-architecture-ai.png"
d1_html = f"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
{SHARED_CSS}
</style>
</head>
<body>
  <img class="bg" src="{d1_bg}">

  <!-- Legend typo fix (remote wite -> remote write) -->
  <div style="position: absolute; z-index: 15; top: 52px; left: 1083px; width: 135px; height: 18px; background: #dfebf3; display: flex; align-items: center;">
    <span style="font-size: 10.5px; color: #1e293b; font-weight: 600; line-height: 1;">scrape / remote write</span>
  </div>

  <!-- Gateway Routes Overlay (fixes 'pisfens' hallucination and route list) -->
  <div class="glass-pill" style="top: 159px; left: 601px; width: 220px; height: 24px; font-size: 8px; justify-content: flex-start; padding-left: 8px;">GRPCRoute · bep-cloud-grpc · api-cloud-grpc</div>
  <div class="glass-pill" style="top: 187px; left: 601px; width: 220px; height: 24px; font-size: 8px; justify-content: flex-start; padding-left: 8px;">HTTPRoute · api-web · dashboard · grafana · mcp</div>

  <!-- Section 1: ClusterIP Services Box (tightly aligned over base card: left=846, width=260, height=104) -->
  <div class="glass-ice" style="top: 122px; left: 846px; width: 260px; height: 104px; padding: 7px 10px;">
    <div class="card-title">Kubernetes ClusterIP Services</div>
    <div style="font-size: 8px; font-weight: 700; color: #4338ca; margin-top: 1px;">L4 Routing Only · No TLS Termination</div>
    <div class="card-sub" style="font-size: 8px; margin-top: 2px;">
      bep-nats-pub :50091 · grpc-api :50091, :8008, :5150<br>
      web-ui :80 · grafana-oauth2-proxy :8080<br>
      <span style="color: #64748b;">Auth & tokens verified by app pods, not Services</span>
    </div>
  </div>

  <!-- Patch to cover stray 'UI, Grafan' label under purple key -->
  <div style="position: absolute; z-index: 5; top: 188px; left: 1110px; width: 62px; height: 26px; background: #e6eff6;"></div>

  <!-- Section 1: OIDC Provider clean overlay (tightly aligned over base card: left=1172, width=142, height=104) -->
  <div class="glass-violet" style="top: 122px; left: 1172px; width: 142px; height: 104px; padding: 7px 8px; text-align: center;">
    <div class="card-title">OIDC Provider</div>
    <div style="font-size: 8px; font-weight: 700; color: #6d28d9; margin-top: 1px;">Auth & SSO (Control Plane)</div>
    <div class="card-sub" style="font-size: 7.5px; margin-top: 3px;">
      OIDC & JWKS verification<br>
      Secures UI, Grafana, gRPC, MCP<br>
      <span style="font-weight: 600; color: #475569;">Decoupled from ingest</span>
    </div>
  </div>

  <!-- Section 2: Ingestion sequence (Finding 1) - bep-nats-pub on middle pedestal -->
  <div class="glass-sub-pill" style="top: 435px; left: 115px; width: 98px; height: 24px; font-size: 9.5px;">bep-nats-pub</div>

  <!-- Section 2: Partition Subscribers badge over upper consumer deployments -->
  <div class="glass-cyan" style="top: 325px; left: 565px; width: 205px; height: 38px; padding: 3px 5px; text-align: center;">
    <div style="font-size: 9.5px; font-weight: 700; color: #0284c7;">Partition Subscribers</div>
    <div class="card-sub" style="font-size: 7.5px; margin-top: 1px;">bep-nats-sub-0 .. bep-nats-sub-(N-1)<br>1:1 per JetStream partition (replica: 1 each)</div>
  </div>

  <!-- Section 2: Finding 2 - Hermetiq Query API & MCP Decoupled from NATS -->
  <div class="glass-cyan" style="top: 480px; left: 575px; width: 226px; height: 96px; padding: 7px 10px;">
    <div class="card-title">Hermetiq Query API & MCP</div>
    <div style="font-size: 8px; font-weight: 700; color: #059669; margin-top: 1px;">Zero NATS Dependency · Stateless</div>
    <div class="card-sub" style="font-size: 8px; line-height: 1.35; margin-top: 3px;">
      gRPC (:50091) · REST (:8008) · MCP (:5150)<br>
      Reads PostgreSQL metadata & GCS log chunks<br>
      <span style="color: #64748b;">No stream subscriptions · Decoupled from JetStream</span>
    </div>
  </div>

  <!-- Section 2: bep-nats-sub replaces erroneous 'bep-nats-pub' under blue writer pod -->
  <div class="glass-sub-pill" style="top: 368px; left: 794px; width: 108px; height: 24px; font-size: 9.5px;">bep-nats-sub</div>

  <!-- Section 2: Finding 3 - No DB write to GCS -->
  <div class="glass-rose" style="top: 332px; left: 1012px; width: 130px; height: 30px; padding: 2px 4px; text-align: center;">
    <div style="font-size: 8px; font-weight: 700; color: #e11d48;">No DB-to-GCS Write</div>
    <div style="font-size: 7px; color: #475569;">Subscribers upload to GCS directly</div>
  </div>

  <!-- Section 2: Finding 3 - Direct Chunk Offload -->
  <div class="glass-cyan" style="top: 464px; left: 865px; width: 165px; height: 38px; padding: 4px 6px; text-align: center;">
    <div style="font-size: 8.5px; font-weight: 700; color: #0284c7;">Direct Chunk Offload</div>
    <div style="font-size: 7.5px; color: #475569; margin-top: 1px;">Subscribers upload stdout/stderr to GCS</div>
  </div>

  <!-- Section 3: Finding 4 - VMAgent Scraper -->
  <div class="glass-emerald" style="top: 683px; left: 938px; width: 110px; height: 23px; display: flex; align-items: center; justify-content: center; font-size: 9.5px; font-weight: 700; color: #059669;">VMAgent Scraper</div>

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
{SHARED_CSS}
</style>
</head>
<body>
  <img class="bg" src="{d2_bg}">

  <!-- 1. Bazel Clients: top: 112px covers original card completely with tight rich content -->
  <div class="glass-ice" style="top: 112px; left: 74px; width: 210px; height: 86px; padding: 7px 11px;">
    <div class="card-title">Bazel clients</div>
    <div style="font-size: 8px; font-weight: 700; color: #0284c7; margin-top: 1px;">Build Event Protocol (BEP)</div>
    <div class="card-sub" style="font-size: 7.5px; margin-top: 2px;">
      invocation & build ID tracking<br>
      Direct gRPC stream to hermetiq-gateway
    </div>
  </div>

  <!-- 2. Delivery Guarantees: tightened height: 64px, frosted glass-slate -->
  <div class="glass-slate" style="top: 278px; left: 68px; width: 428px; height: 64px; padding: 6px 12px;">
    <div class="card-title">Delivery guarantees</div>
    <div class="card-sub" style="font-size: 8px; line-height: 1.35; margin-top: 2px;">
      JetStream retries failed deliveries with backoff; terminal errors route to BEP DLQ.<br>
      Partition affinity processes invocation events in dedicated subscriber Deployments.
    </div>
  </div>

  <!-- 3. NATS Streams -->
  <div class="stream-tag" style="top: 135px; left: 805px; width: 85px; height: 32px;">Stream 0</div>
  <div class="stream-tag" style="top: 135px; left: 905px; width: 85px; height: 32px;">Stream 1</div>
  <div class="stream-tag" style="top: 175px; left: 805px; width: 85px; height: 32px;">Stream 2</div>
  <div class="stream-tag" style="top: 175px; left: 905px; width: 85px; height: 32px;">Stream 3</div>
  <div class="stream-tag" style="top: 220px; left: 805px; width: 85px; height: 32px;">Stream 4</div>
  <div class="stream-tag" style="top: 220px; left: 905px; width: 85px; height: 32px;">Stream N-1</div>

  <!-- NATS footer: tightened to 42px height -->
  <div class="glass-violet" style="top: 270px; left: 788px; width: 240px; height: 50px; padding: 5px 6px; text-align: center;">
    <div style="font-size: 8.5px; font-weight: 700; color: #4338ca;">File storage · RF3 (3 replicas)</div>
    <div style="font-size: 8px; color: #64748b; margin-top: 1px;">Explicit ACK · 30m retention</div>
  </div>

  <!-- 4. Subscriber Pods: sleek frosted cyan pills -->
  <div class="glass-sub-pill" style="top: 146px; left: 1088px; width: 92px; height: 22px; font-size: 9.5px;">bep-nats-sub-0</div>
  <div class="glass-sub-pill" style="top: 146px; left: 1188px; width: 92px; height: 22px; font-size: 9.5px;">bep-nats-sub-1</div>
  <div class="glass-sub-pill" style="top: 189px; left: 1096px; width: 92px; height: 22px; font-size: 9.5px;">bep-nats-sub-2</div>
  <div class="glass-sub-pill" style="top: 189px; left: 1196px; width: 92px; height: 22px; font-size: 9.5px;">bep-nats-sub-3</div>
  <div class="glass-sub-pill" style="top: 236px; left: 1104px; width: 92px; height: 22px; font-size: 9.5px;">bep-nats-sub-4</div>
  <div class="glass-sub-pill" style="top: 236px; left: 1198px; width: 105px; height: 22px; font-size: 8px;">bep-nats-sub-(N-1)</div>
  <div class="glass-pill" style="top: 285px; left: 1106px; width: 92px; height: 20px; font-size: 8px;">replica: 1 each</div>
  <div class="glass-pill" style="top: 285px; left: 1208px; width: 92px; height: 20px; font-size: 8px;">1:1 per partition</div>

  <!-- Arrow Labels around Ingest -->
  <div class="glass-cyan" style="top: 326px; left: 1040px; width: 195px; height: 20px; display: flex; align-items: center; justify-content: center;">
    <span style="font-size: 8px; font-weight: 700; color: #0284c7;">subscribers upload compressed chunks</span>
  </div>
  <div class="glass-cyan" style="top: 350px; left: 955px; width: 195px; height: 20px; display: flex; align-items: center; justify-content: center;">
    <span style="font-size: 8px; font-weight: 700; color: #0284c7;">SQL metadata writes (batch INSERT)</span>
  </div>

  <!-- 5. Query API: height: 122px covers the entire glass slab text -->
  <div class="glass-cyan" style="top: 376px; left: 45px; width: 195px; height: 122px; padding: 7px 10px;">
    <div class="card-title" style="font-size: 11px;">Query API · Deploy x2</div>
    <div style="font-size: 10.5px; font-weight: 700; color: #0369a1; margin-top: 1px;">grpc-api</div>
    <div class="card-sub" style="font-size: 8px; line-height: 1.35; margin-top: 2px;">
      gRPC (:50091) · REST (:8008) · MCP (:5150)<br>
      Time-bounded queries · Pruned reads<br>
      Reads PostgreSQL & GCS progress store<br>
      <span style="font-weight: 700; color: #059669;">Zero NATS dependency</span>
    </div>
  </div>

  <!-- 6. Cloud SQL Parent Table Stacks -->
  <div class="glass-pill" style="top: 390px; left: 402px; width: 126px; height: 22px; font-size: 8px;">invocations · targets · tests</div>
  <div class="glass-pill" style="top: 390px; left: 538px; width: 126px; height: 22px; font-size: 8px;">actions · logs · output_tests</div>
  <div class="glass-pill" style="top: 390px; left: 672px; width: 132px; height: 22px; font-size: 8px;">cache_events · remote_exec</div>
  <div class="glass-pill" style="top: 390px; left: 816px; width: 135px; height: 22px; font-size: 8px;">progresses · 20 parent tables</div>

  <!-- PostgreSQL GCS chunk fallback label -->
  <div class="glass-slate" style="top: 486px; left: 742px; width: 246px; height: 20px; display: flex; align-items: center; justify-content: center;">
    <span style="font-size: 7.5px; font-weight: 600; color: #334155;">progress fallback (if GCS offline) · No DB write to GCS</span>
  </div>

  <!-- 7. GCS Progress Store: width: 275px covers base text while glass-cyan texture shines through -->
  <div class="glass-cyan" style="top: 376px; left: 1008px; width: 275px; height: 122px; padding: 7px 10px;">
    <div class="card-title" style="font-size: 11.5px;">GCS progress store</div>
    <div style="font-size: 9.5px; font-weight: 700; color: #0369a1; margin-top: 1px;">per-project artifact bucket</div>
    <div class="card-sub" style="font-size: 8px; line-height: 1.35; margin-top: 3px;">
      Async gzip protobuf chunks · GKE Workload Identity<br>
      progress/v1/&lt;project&gt;/&lt;invocation&gt;/&lt;seq&gt;-&lt;chunk&gt;.pb.gz<br>
      <span style="font-weight: 700; color: #0284c7;">grpc-api reads chunks directly · Database fallback</span>
    </div>
  </div>

  <!-- Bottom progress chunks line under GCS -->
  <div class="glass-cyan" style="top: 504px; left: 960px; width: 240px; height: 22px; display: flex; align-items: center; justify-content: center;">
    <span style="font-size: 8px; font-weight: 700; color: #0284c7;">progress chunks uploaded to GCS</span>
  </div>

  <!-- 8. Control plane typo fix: height: 56px covers 'source tom' -->
  <div class="glass-slate" style="top: 540px; left: 285px; width: 220px; height: 56px; padding: 6px 9px;">
    <div class="card-title" style="font-size: 10.5px;">public.part_config</div>
    <div class="card-sub" style="font-size: 8px; margin-top: 2px;">pg_partman source of truth<br>Automatic retention and premake control</div>
  </div>

  <!-- 9. Bottom Conveyor Partition Timeline Dock -->
  <div class="conveyor-dock">
    <div style="text-align: center; width: 220px;">
      <div class="card-title" style="font-size: 10px;">EXPIRED DROPS</div>
      <div class="card-sub" style="font-size: 7.5px;">DROP TABLE at retention · not retained as shells</div>
    </div>
    <div style="text-align: center; width: 260px;">
      <div class="card-title" style="font-size: 10px;">CLOSED HISTORICAL CHILDREN</div>
      <div class="card-sub" style="font-size: 7.5px;">Closed for writes · fully queryable · pruned by range</div>
    </div>
    <div style="text-align: center; width: 240px;">
      <div class="card-title" style="font-size: 10px; color: #0284c7;">CURRENT ACTIVE PARTITION</div>
      <div class="card-sub" style="font-size: 7.5px;">Active INSERT target · (NOT default bucket)</div>
    </div>
    <div style="text-align: center; width: 250px;">
      <div class="card-title" style="font-size: 10px;">PRE-CREATED FUTURE PARTITIONS</div>
      <div class="card-sub" style="font-size: 7.5px;">Premake horizon creates child tables in advance</div>
    </div>
    <div style="text-align: center; width: 230px; border-left: 2px solid #e11d48; padding-left: 8px;">
      <div class="card-title" style="font-size: 10px; color: #e11d48;">&lt;parent&gt;_default CATCH-ALL</div>
      <div class="card-sub" style="font-size: 7.5px;">Catch-all out-of-range rows · Alert if rows &gt; 0</div>
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
{SHARED_CSS}
</style>
</head>
<body>
  <img class="bg" src="{d3_bg}">

  <!-- Section 1: ClusterIP Services: perfectly aligned with base card (left=846, width=260, height=104) -->
  <div class="glass-ice" style="top: 122px; left: 846px; width: 260px; height: 104px; padding: 7px 10px;">
    <div class="card-title">Kubernetes ClusterIP Services</div>
    <div style="font-size: 8px; font-weight: 700; color: #4338ca; margin-top: 1px;">L4 Routing Only · No TLS Termination</div>
    <div class="card-sub" style="font-size: 8px; margin-top: 2px;">
      frontend-grpc · REAPI :8980<br>
      bb-browser · Web UI :80<br>
      <span style="color: #64748b;">Auth & tokens verified by app pods, not Services</span>
    </div>
  </div>

  <!-- Section 1: OIDC Provider clean overlay (left=1172, width=142, height=104) -->
  <div class="glass-violet" style="top: 122px; left: 1172px; width: 142px; height: 104px; padding: 7px 8px; text-align: center;">
    <div class="card-title">OIDC Provider</div>
    <div style="font-size: 8px; font-weight: 700; color: #6d28d9; margin-top: 1px;">Auth & SSO (Control Plane)</div>
    <div class="card-sub" style="font-size: 7.5px; margin-top: 3px;">
      OIDC & JWKS verification<br>
      Secures UI, Grafana, gRPC, MCP<br>
      <span style="font-weight: 600; color: #475569;">App token verification</span>
    </div>
  </div>

  <!-- Section 2: bb-frontend execution connection -->
  <div class="glass-cyan" style="top: 442px; left: 742px; width: 168px; height: 42px; padding: 3px 6px; text-align: center;">
    <div style="font-size: 9.5px; font-weight: 700; color: #0369a1;">bb-frontend</div>
    <div style="font-size: 7.5px; color: #475569; margin-top: 1px;">Routes Execute to bb-scheduler:8982<br>Routes CAS/AC to bb-storage:8981</div>
  </div>

  <!-- Section 2: bb-browser blobstore reads -->
  <div class="glass-cyan" style="top: 442px; left: 918px; width: 158px; height: 42px; padding: 3px 6px; text-align: center;">
    <div style="font-size: 9.5px; font-weight: 700; color: #0369a1;">bb-browser</div>
    <div style="font-size: 7.5px; color: #475569; margin-top: 1px;">Build exploration Web UI (:80)<br>Direct read-only CAS/AC inspection</div>
  </div>

  <!-- Section 2: Storage RPCs category: sleek frosted ice glass over storage streams -->
  <div class="glass-ice" style="top: 510px; left: 775px; width: 270px; height: 38px; padding: 3px 6px; text-align: center;">
    <div style="font-size: 9px; font-weight: 700; color: #1d4ed8;">Storage RPCs :8981 (CAS · AC · FSAC)</div>
    <div style="font-size: 7.5px; color: #475569; margin-top: 1px;">Worker payload reads/writes · Direct gRPC data (NOT event stream)</div>
  </div>

  <!-- Section 3: KEDA autoscaling - No Disk Link -->
  <div class="glass-rose" style="top: 642px; left: 466px; width: 118px; height: 32px; padding: 2px 4px; text-align: center;">
    <div style="font-size: 8px; font-weight: 700; color: #e11d48;">No Disk Link</div>
    <div style="font-size: 7px; color: #475569;">Workers use NVMe SSD</div>
  </div>

  <!-- KEDA PromQL query badge over VictoriaMetrics -->
  <div class="glass-emerald" style="top: 636px; left: 660px; width: 110px; height: 34px; padding: 2px 4px; text-align: center;">
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
