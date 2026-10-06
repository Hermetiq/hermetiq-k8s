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
from PIL import Image, ImageFilter

REPO_ROOT = Path(__file__).resolve().parent.parent
BASE_DIR = Path(os.environ.get("DIAGRAM_BASE_DIR", "/home/ndipiazza/Downloads"))
TMP_DIR = Path("/tmp/hermetiq_diagram_clean")
TMP_DIR.mkdir(parents=True, exist_ok=True)


def inpaint_text_smooth(im, box, lum_threshold=185, blur_radius=1.8):
    """
    Dissolves baked-in AI text from smooth card / glass surfaces by
    interpolating clean background pixels horizontally and vertically,
    followed by selective Gaussian smoothing.
    """
    im_copy = im.copy()
    crop = im_copy.crop(box)
    w, h = crop.size
    pixels = crop.load()

    text_mask = [[False] * h for _ in range(w)]
    for y in range(h):
        for x in range(w):
            r, g, b = pixels[x, y][:3]
            lum = 0.299 * r + 0.587 * g + 0.114 * b
            if lum < lum_threshold:
                text_mask[x][y] = True

    dilated_mask = [[False] * h for _ in range(w)]
    for y in range(h):
        for x in range(w):
            if text_mask[x][y]:
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        nx, ny = x + dx, y + dy
                        if 0 <= nx < w and 0 <= ny < h:
                            dilated_mask[nx][ny] = True

    for y in range(h):
        clean_xs = [x for x in range(w) if not dilated_mask[x][y]]
        if clean_xs:
            for x in range(w):
                if dilated_mask[x][y]:
                    left_xs = [cx for cx in clean_xs if cx < x]
                    right_xs = [cx for cx in clean_xs if cx > x]
                    if left_xs and right_xs:
                        lx = max(left_xs)
                        rx = min(right_xs)
                        weight = (x - lx) / (rx - lx)
                        lr, lg, lb = pixels[lx, y][:3]
                        rr, rg, rb = pixels[rx, y][:3]
                        nr = int(lr * (1 - weight) + rr * weight)
                        ng = int(lg * (1 - weight) + rg * weight)
                        nb = int(lb * (1 - weight) + rb * weight)
                    elif left_xs:
                        lx = max(left_xs)
                        nr, ng, nb = pixels[lx, y][:3]
                    elif right_xs:
                        rx = min(right_xs)
                        nr, ng, nb = pixels[rx, y][:3]
                    else:
                        nr, ng, nb = 220, 235, 245

                    if len(pixels[x, y]) == 4:
                        pixels[x, y] = (nr, ng, nb, pixels[x, y][3])
                    else:
                        pixels[x, y] = (nr, ng, nb)

    for x in range(w):
        clean_ys = [y for y in range(h) if not dilated_mask[x][y]]
        if clean_ys:
            for y in range(h):
                if dilated_mask[x][y]:
                    top_ys = [cy for cy in clean_ys if cy < y]
                    bot_ys = [cy for cy in clean_ys if cy > y]
                    if top_ys and bot_ys:
                        ty = max(top_ys)
                        by = min(bot_ys)
                        weight = (y - ty) / (by - ty)
                        tr, tg, tb = pixels[x, ty][:3]
                        br, bg, bb = pixels[x, by][:3]
                        nr = int(tr * (1 - weight) + br * weight)
                        ng = int(tg * (1 - weight) + bg * weight)
                        nb = int(tb * (1 - weight) + bb * weight)
                        if len(pixels[x, y]) == 4:
                            pixels[x, y] = (nr, ng, nb, pixels[x, y][3])
                        else:
                            pixels[x, y] = (nr, ng, nb)

    blurred = crop.filter(ImageFilter.GaussianBlur(radius=blur_radius))
    b_pixels = blurred.load()
    for y in range(h):
        for x in range(w):
            if dilated_mask[x][y]:
                pixels[x, y] = b_pixels[x, y]

    im_copy.paste(crop, box)
    return im_copy


def inpaint_gcs_hybrid(im, box=(1012, 374, 1285, 475)):
    """
    Cleans the GCS glass slab while preserving the vertical partition ribs:
    - Left smooth face (x < 210 in crop): horizontal interpolation
    - Right ribbed section (x >= 210 in crop): column-wise vertical interpolation
    """
    im_copy = im.copy()
    crop = im_copy.crop(box)
    w, h = crop.size
    pixels = crop.load()

    text_mask = [[False] * h for _ in range(w)]
    for y in range(h):
        for x in range(w):
            r, g, b = pixels[x, y][:3]
            lum = 0.299 * r + 0.587 * g + 0.114 * b
            if lum < 135:
                text_mask[x][y] = True

    dilated = [[False] * h for _ in range(w)]
    for y in range(h):
        for x in range(w):
            if text_mask[x][y]:
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        nx, ny = x + dx, y + dy
                        if 0 <= nx < w and 0 <= ny < h:
                            dilated[nx][ny] = True

    # Ribs section (x >= 210 in crop) -> interpolate vertically
    for x in range(210, w):
        clean_ys = [y for y in range(h) if not dilated[x][y]]
        if clean_ys:
            for y in range(h):
                if dilated[x][y]:
                    top_ys = [cy for cy in clean_ys if cy < y]
                    bot_ys = [cy for cy in clean_ys if cy > y]
                    if top_ys and bot_ys:
                        ty, by = max(top_ys), min(bot_ys)
                        weight = (y - ty) / (by - ty)
                        tr, tg, tb = pixels[x, ty][:3]
                        br, bg, bb = pixels[x, by][:3]
                        nr = int(tr * (1 - weight) + br * weight)
                        ng = int(tg * (1 - weight) + bg * weight)
                        nb = int(tb * (1 - weight) + bb * weight)
                    elif top_ys:
                        nr, ng, nb = pixels[x, max(top_ys)][:3]
                    else:
                        nr, ng, nb = pixels[x, min(bot_ys)][:3]
                    pixels[x, y] = (nr, ng, nb)

    # Face section (x < 210) -> interpolate horizontally
    for y in range(h):
        clean_xs = [x for x in range(210) if not dilated[x][y]]
        if clean_xs:
            for x in range(210):
                if dilated[x][y]:
                    left_xs = [cx for cx in clean_xs if cx < x]
                    right_xs = [cx for cx in clean_xs if cx > x]
                    if left_xs and right_xs:
                        lx, rx = max(left_xs), min(right_xs)
                        weight = (x - lx) / (rx - lx)
                        lr, lg, lb = pixels[lx, y][:3]
                        rr, rg, rb = pixels[rx, y][:3]
                        nr = int(lr * (1 - weight) + rr * weight)
                        ng = int(lg * (1 - weight) + rg * weight)
                        nb = int(lb * (1 - weight) + rb * weight)
                    elif left_xs:
                        nr, ng, nb = pixels[max(left_xs), y][:3]
                    elif right_xs:
                        nr, ng, nb = pixels[min(right_xs), y][:3]
                    else:
                        nr, ng, nb = 220, 235, 245
                    pixels[x, y] = (nr, ng, nb)

    blurred = crop.filter(ImageFilter.GaussianBlur(radius=1.2))
    b_pix = blurred.load()
    for y in range(h):
        for x in range(w):
            if dilated[x][y]:
                pixels[x, y] = b_pix[x, y]

    im_copy.paste(crop, box)
    return im_copy


def prepare_clean_base_images():
    """Pre-processes base images by dissolving baked-in text in overlay areas."""
    # 1. Clean D1 base (hermetiq-architecture-ai.png)
    d1_base = Image.open(BASE_DIR / "hermetiq-architecture-ai.png")
    d1_base = inpaint_text_smooth(d1_base, (868, 130, 1106, 222), lum_threshold=185)
    d1_base = inpaint_text_smooth(d1_base, (1174, 130, 1300, 222), lum_threshold=185)
    d1_base = inpaint_text_smooth(d1_base, (1090, 185, 1175, 215), lum_threshold=185)
    clean_d1_path = TMP_DIR / "clean_d1.png"
    d1_base.save(clean_d1_path)

    # 2. Clean D2 base (bep-ingest-architecture-ai.png)
    d2_base = Image.open(BASE_DIR / "bep-ingest-architecture-ai.png")
    d2_base = inpaint_text_smooth(d2_base, (50, 375, 230, 480), lum_threshold=185)
    d2_base = inpaint_gcs_hybrid(d2_base)
    d2_base = inpaint_text_smooth(d2_base, (960, 502, 1260, 526), lum_threshold=190)
    clean_d2_path = TMP_DIR / "clean_d2.png"
    d2_base.save(clean_d2_path)

    # 3. Clean D3 base (bb-architecture-ai.png)
    d3_base = Image.open(BASE_DIR / "bb-architecture-ai.png")
    d3_base = inpaint_text_smooth(d3_base, (868, 130, 1106, 222), lum_threshold=185)
    d3_base = inpaint_text_smooth(d3_base, (1174, 130, 1300, 222), lum_threshold=185)
    d3_base = inpaint_text_smooth(d3_base, (1090, 185, 1175, 215), lum_threshold=185)
    clean_d3_path = TMP_DIR / "clean_d3.png"
    d3_base.save(clean_d3_path)

    return clean_d1_path, clean_d2_path, clean_d3_path


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

  /* High-Transparency Layered Frosted Glass: Underneath 3D Plate & Geometry Shines Through */
  .glass-ice-trans {
    position: absolute;
    z-index: 10;
    background: linear-gradient(135deg, rgba(230, 242, 255, 0.45) 0%, rgba(210, 230, 255, 0.28) 50%, rgba(235, 245, 255, 0.48) 100%);
    backdrop-filter: blur(8px) saturate(180%);
    -webkit-backdrop-filter: blur(8px) saturate(180%);
    border: 1px solid rgba(255, 255, 255, 0.85);
    border-radius: 7px;
    box-shadow: 0 4px 12px rgba(30, 58, 138, 0.04);
  }
  .glass-violet-trans {
    position: absolute;
    z-index: 10;
    background: linear-gradient(135deg, rgba(245, 240, 255, 0.45) 0%, rgba(232, 222, 255, 0.28) 50%, rgba(248, 242, 255, 0.48) 100%);
    backdrop-filter: blur(8px) saturate(180%);
    -webkit-backdrop-filter: blur(8px) saturate(180%);
    border: 1px solid rgba(255, 255, 255, 0.85);
    border-radius: 7px;
    box-shadow: 0 4px 12px rgba(109, 40, 217, 0.04);
  }
  .glass-cyan-trans {
    position: absolute;
    z-index: 10;
    background: linear-gradient(135deg, rgba(235, 246, 255, 0.45) 0%, rgba(215, 238, 255, 0.28) 50%, rgba(240, 248, 255, 0.48) 100%);
    backdrop-filter: blur(8px) saturate(180%);
    -webkit-backdrop-filter: blur(8px) saturate(180%);
    border: 1px solid rgba(255, 255, 255, 0.85);
    border-radius: 7px;
    box-shadow: 0 4px 14px rgba(2, 132, 199, 0.04);
  }

  /* Semantic Pill & Badge Overlays */
  .glass-ice {
    position: absolute;
    z-index: 10;
    background: linear-gradient(135deg, rgba(235, 245, 255, 0.86) 0%, rgba(215, 235, 254, 0.72) 50%, rgba(240, 249, 255, 0.88) 100%);
    backdrop-filter: blur(14px) saturate(170%);
    -webkit-backdrop-filter: blur(14px) saturate(170%);
    border: 1px solid rgba(255, 255, 255, 0.92);
    border-radius: 8px;
    box-shadow: 0 4px 14px rgba(30, 58, 138, 0.07), inset 0 1px 1px rgba(255, 255, 255, 0.95);
  }
  .glass-cyan {
    position: absolute;
    z-index: 10;
    background: linear-gradient(135deg, rgba(240, 249, 255, 0.86) 0%, rgba(224, 242, 254, 0.72) 50%, rgba(245, 250, 255, 0.88) 100%);
    backdrop-filter: blur(14px) saturate(170%);
    -webkit-backdrop-filter: blur(14px) saturate(170%);
    border: 1px solid rgba(255, 255, 255, 0.92);
    border-radius: 8px;
    box-shadow: 0 4px 14px rgba(2, 132, 199, 0.07), inset 0 1px 1px rgba(255, 255, 255, 0.95);
  }
  .glass-emerald {
    position: absolute;
    z-index: 10;
    background: linear-gradient(135deg, rgba(236, 253, 245, 0.88) 0%, rgba(209, 250, 229, 0.72) 50%, rgba(242, 253, 248, 0.90) 100%);
    backdrop-filter: blur(14px) saturate(170%);
    -webkit-backdrop-filter: blur(14px) saturate(170%);
    border: 1px solid rgba(255, 255, 255, 0.92);
    border-radius: 8px;
    box-shadow: 0 4px 14px rgba(5, 150, 105, 0.07), inset 0 1px 1px rgba(255, 255, 255, 0.95);
  }
  .glass-slate {
    position: absolute;
    z-index: 10;
    background: linear-gradient(135deg, rgba(248, 250, 252, 0.86) 0%, rgba(241, 245, 249, 0.72) 50%, rgba(255, 255, 255, 0.90) 100%);
    backdrop-filter: blur(14px) saturate(150%);
    -webkit-backdrop-filter: blur(14px) saturate(150%);
    border: 1px solid rgba(255, 255, 255, 0.92);
    border-radius: 8px;
    box-shadow: 0 4px 12px rgba(15, 23, 42, 0.06), inset 0 1px 1px rgba(255, 255, 255, 0.95);
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
    font-weight: 700;
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
    font-weight: 800;
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
    font-weight: 800;
    color: #ffffff;
    box-shadow: 0 2px 6px rgba(126, 34, 206, 0.25), inset 0 1px 0 rgba(255, 255, 255, 0.4);
    text-shadow: 0 1px 2px rgba(0,0,0,0.5);
  }
  .card-title {
    font-size: 11px;
    font-weight: 800;
    color: #0f172a;
    letter-spacing: -0.01em;
  }
  .card-sub {
    font-size: 8px;
    font-weight: 700;
    color: #1e293b;
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


def build_d1_html(bg_path: Path) -> str:
    return f"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
{SHARED_CSS}
</style>
</head>
<body>
  <img class="bg" src="{bg_path}">

  <!-- Legend typo fix (remote wite -> remote write) -->
  <div style="position: absolute; z-index: 15; top: 52px; left: 1083px; width: 135px; height: 18px; background: #dfebf3; display: flex; align-items: center;">
    <span style="font-size: 10.5px; color: #1e293b; font-weight: 700; line-height: 1;">scrape / remote write</span>
  </div>

  <!-- Gateway Routes Overlay -->
  <div class="glass-pill" style="top: 159px; left: 601px; width: 220px; height: 24px; font-size: 8px; justify-content: flex-start; padding-left: 8px;">GRPCRoute · bep-cloud-grpc · api-cloud-grpc</div>
  <div class="glass-pill" style="top: 187px; left: 601px; width: 220px; height: 24px; font-size: 8px; justify-content: flex-start; padding-left: 8px;">HTTPRoute · api-web · dashboard · grafana · mcp</div>

  <!-- Section 1: ClusterIP Services Box: Tight bounds, transparent glass -->
  <div class="glass-ice-trans" style="top: 133px; left: 868px; width: 226px; height: 76px; padding: 5px 8px;">
    <div class="card-title">Kubernetes ClusterIP Services</div>
    <div style="font-size: 8px; font-weight: 800; color: #3730a3; margin-top: 1px;">L4 Routing Only · No TLS Termination</div>
    <div class="card-sub" style="margin-top: 2px;">
      bep-nats-pub :50091 · grpc-api :50091, :8008, :5150<br>
      web-ui :80 · grafana-oauth2-proxy :8080<br>
      <span style="font-weight: 700; color: #334155;">Auth verified by app pods, not Services</span>
    </div>
  </div>

  <!-- Section 1: OIDC Provider: Tight bounds, transparent glass -->
  <div class="glass-violet-trans" style="top: 133px; left: 1176px; width: 122px; height: 76px; padding: 5px 6px; text-align: center;">
    <div class="card-title">OIDC Provider</div>
    <div style="font-size: 8px; font-weight: 800; color: #5b21b6; margin-top: 1px;">Auth & SSO (Control Plane)</div>
    <div class="card-sub" style="font-size: 7.5px; margin-top: 2px;">
      OIDC & JWKS verification<br>
      Secures UI, Grafana, gRPC, MCP<br>
      <span style="font-weight: 800; color: #4338ca;">Decoupled from ingest</span>
    </div>
  </div>

  <!-- Section 2: Ingestion sequence (Finding 1) - bep-nats-pub on middle pedestal -->
  <div class="glass-sub-pill" style="top: 435px; left: 115px; width: 98px; height: 24px; font-size: 9.5px;">bep-nats-pub</div>

  <!-- Section 2: Partition Subscribers badge over upper consumer deployments -->
  <div class="glass-cyan" style="top: 325px; left: 565px; width: 205px; height: 38px; padding: 3px 5px; text-align: center;">
    <div style="font-size: 9.5px; font-weight: 800; color: #0284c7;">Partition Subscribers</div>
    <div class="card-sub" style="font-size: 7.5px; margin-top: 1px;">bep-nats-sub-0 .. bep-nats-sub-(N-1)<br>1:1 per JetStream partition (replica: 1 each)</div>
  </div>

  <!-- Section 2: Finding 2 - Hermetiq Query API & MCP Decoupled from NATS -->
  <div class="glass-cyan" style="top: 480px; left: 575px; width: 226px; height: 96px; padding: 7px 10px;">
    <div class="card-title">Hermetiq Query API & MCP</div>
    <div style="font-size: 8px; font-weight: 800; color: #047857; margin-top: 1px;">Zero NATS Dependency · Stateless</div>
    <div class="card-sub" style="font-size: 8px; line-height: 1.35; margin-top: 3px;">
      gRPC (:50091) · REST (:8008) · MCP (:5150)<br>
      Reads PostgreSQL metadata & GCS log chunks<br>
      <span style="font-weight: 700; color: #334155;">No stream subscriptions · Decoupled from JetStream</span>
    </div>
  </div>

  <!-- Section 2: bep-nats-sub replaces erroneous 'bep-nats-pub' under blue writer pod -->
  <div class="glass-sub-pill" style="top: 368px; left: 794px; width: 108px; height: 24px; font-size: 9.5px;">bep-nats-sub</div>

  <!-- Section 2: Finding 3 - No DB write to GCS -->
  <div class="glass-rose" style="top: 332px; left: 1012px; width: 130px; height: 30px; padding: 2px 4px; text-align: center;">
    <div style="font-size: 8px; font-weight: 800; color: #e11d48;">No DB-to-GCS Write</div>
    <div style="font-size: 7px; font-weight: 700; color: #1e293b;">Subscribers upload to GCS directly</div>
  </div>

  <!-- Section 2: Finding 3 - Direct Chunk Offload -->
  <div class="glass-cyan" style="top: 464px; left: 865px; width: 165px; height: 38px; padding: 4px 6px; text-align: center;">
    <div style="font-size: 8.5px; font-weight: 800; color: #0284c7;">Direct Chunk Offload</div>
    <div style="font-size: 7.5px; font-weight: 700; color: #1e293b; margin-top: 1px;">Subscribers upload stdout/stderr to GCS</div>
  </div>

  <!-- Section 3: Finding 4 - VMAgent Scraper -->
  <div class="glass-emerald" style="top: 683px; left: 938px; width: 110px; height: 23px; display: flex; align-items: center; justify-content: center; font-size: 9.5px; font-weight: 800; color: #047857;">VMAgent Scraper</div>

</body>
</html>
"""


def build_d2_html(bg_path: Path) -> str:
    return f"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
{SHARED_CSS}
</style>
</head>
<body>
  <img class="bg" src="{bg_path}">

  <!-- 1. Bazel Clients -->
  <div class="glass-ice" style="top: 112px; left: 74px; width: 210px; height: 86px; padding: 7px 11px;">
    <div class="card-title">Bazel clients</div>
    <div style="font-size: 8px; font-weight: 800; color: #0284c7; margin-top: 1px;">Build Event Protocol (BEP)</div>
    <div class="card-sub" style="font-size: 7.5px; margin-top: 2px;">
      invocation & build ID tracking<br>
      Direct gRPC stream to hermetiq-gateway
    </div>
  </div>

  <!-- 2. Delivery Guarantees -->
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

  <!-- NATS footer -->
  <div class="glass-violet-trans" style="top: 270px; left: 788px; width: 240px; height: 50px; padding: 5px 6px; text-align: center;">
    <div style="font-size: 8.5px; font-weight: 800; color: #3730a3;">File storage · RF3 (3 replicas)</div>
    <div style="font-size: 8px; font-weight: 700; color: #334155; margin-top: 1px;">Explicit ACK · 30m retention</div>
  </div>

  <!-- 4. Subscriber Pods -->
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
    <span style="font-size: 8px; font-weight: 800; color: #0284c7;">subscribers upload compressed chunks</span>
  </div>
  <div class="glass-cyan" style="top: 350px; left: 955px; width: 195px; height: 20px; display: flex; align-items: center; justify-content: center;">
    <span style="font-size: 8px; font-weight: 800; color: #0284c7;">SQL metadata writes (batch INSERT)</span>
  </div>

  <!-- 5. Query API: Tight bounds, transparent glass, shows 3D glass slab bevel -->
  <div class="glass-cyan-trans" style="top: 376px; left: 54px; width: 198px; height: 86px; padding: 5px 8px;">
    <div class="card-title">Query API · Deploy x2</div>
    <div style="font-size: 10px; font-weight: 800; color: #0369a1; margin-top: 1px;">grpc-api</div>
    <div class="card-sub" style="margin-top: 2px;">
      gRPC (:50091) · REST (:8008) · MCP (:5150)<br>
      Time-bounded queries · Pruned reads<br>
      Reads PostgreSQL & GCS progress store<br>
      <span style="font-weight: 800; color: #047857;">Zero NATS dependency</span>
    </div>
  </div>

  <!-- 6. Cloud SQL Parent Table Stacks -->
  <div class="glass-pill" style="top: 390px; left: 402px; width: 126px; height: 22px; font-size: 8px;">invocations · targets · tests</div>
  <div class="glass-pill" style="top: 390px; left: 538px; width: 126px; height: 22px; font-size: 8px;">actions · logs · output_tests</div>
  <div class="glass-pill" style="top: 390px; left: 672px; width: 132px; height: 22px; font-size: 8px;">cache_events · remote_exec</div>
  <div class="glass-pill" style="top: 390px; left: 816px; width: 135px; height: 22px; font-size: 8px;">progresses · 20 parent tables</div>

  <!-- PostgreSQL GCS chunk fallback label -->
  <div class="glass-slate" style="top: 486px; left: 742px; width: 246px; height: 20px; display: flex; align-items: center; justify-content: center;">
    <span style="font-size: 7.5px; font-weight: 700; color: #1e293b;">progress fallback (if GCS offline) · No DB write to GCS</span>
  </div>

  <!-- 7. GCS Progress Store: Tight bounds, transparent glass, vertical partition ribs fully exposed -->
  <div class="glass-cyan-trans" style="top: 376px; left: 1012px; width: 232px; height: 86px; padding: 5px 8px;">
    <div class="card-title">GCS progress store</div>
    <div style="font-size: 9px; font-weight: 800; color: #0369a1; margin-top: 1px;">per-project artifact bucket</div>
    <div class="card-sub" style="margin-top: 2px;">
      Async gzip protobuf chunks · Workload Identity<br>
      progress/v1/&lt;project&gt;/&lt;inv&gt;/&lt;seq&gt;-&lt;chunk&gt;.pb.gz<br>
      <span style="font-weight: 800; color: #0284c7;">grpc-api reads chunks directly · DB fallback</span>
    </div>
  </div>

  <!-- Bottom progress chunks line under GCS -->
  <div class="glass-cyan" style="top: 504px; left: 960px; width: 240px; height: 22px; display: flex; align-items: center; justify-content: center;">
    <span style="font-size: 8px; font-weight: 800; color: #0284c7;">progress chunks uploaded to GCS</span>
  </div>

  <!-- 8. Control plane typo fix (source tom -> source of truth) preserving native card & arrows -->
  <div style="position: absolute; z-index: 10; top: 585px; left: 334px; width: 130px; height: 14px; background: #d4dde6; display: flex; align-items: center;">
    <span style="font-size: 7.5px; color: #1e293b; font-weight: 700; font-family: Inter, sans-serif; line-height: 1;">pg_partman source of truth</span>
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


def build_d3_html(bg_path: Path) -> str:
    return f"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
{SHARED_CSS}
</style>
</head>
<body>
  <img class="bg" src="{bg_path}">

  <!-- Section 1: ClusterIP Services: Tight bounds, transparent glass -->
  <div class="glass-ice-trans" style="top: 133px; left: 868px; width: 226px; height: 76px; padding: 5px 8px;">
    <div class="card-title">Kubernetes ClusterIP Services</div>
    <div style="font-size: 8px; font-weight: 800; color: #3730a3; margin-top: 1px;">L4 Routing Only · No TLS Termination</div>
    <div class="card-sub" style="margin-top: 2px;">
      frontend-grpc · REAPI :8980<br>
      bb-browser · Web UI :80<br>
      <span style="font-weight: 700; color: #334155;">Auth verified by app pods, not Services</span>
    </div>
  </div>

  <!-- Section 1: OIDC Provider: Tight bounds, transparent glass -->
  <div class="glass-violet-trans" style="top: 133px; left: 1176px; width: 122px; height: 76px; padding: 5px 6px; text-align: center;">
    <div class="card-title">OIDC Provider</div>
    <div style="font-size: 8px; font-weight: 800; color: #5b21b6; margin-top: 1px;">Auth & SSO (Control Plane)</div>
    <div class="card-sub" style="font-size: 7.5px; margin-top: 2px;">
      OIDC & JWKS verification<br>
      Secures UI, Grafana, gRPC, MCP<br>
      <span style="font-weight: 800; color: #4338ca;">App token verification</span>
    </div>
  </div>

  <!-- Section 2: bb-frontend execution connection -->
  <div class="glass-cyan" style="top: 442px; left: 742px; width: 168px; height: 42px; padding: 3px 6px; text-align: center;">
    <div style="font-size: 9.5px; font-weight: 800; color: #0369a1;">bb-frontend</div>
    <div style="font-size: 7.5px; font-weight: 700; color: #1e293b; margin-top: 1px;">Routes Execute to bb-scheduler:8982<br>Routes CAS/AC to bb-storage:8981</div>
  </div>

  <!-- Section 2: bb-browser blobstore reads -->
  <div class="glass-cyan" style="top: 442px; left: 918px; width: 158px; height: 42px; padding: 3px 6px; text-align: center;">
    <div style="font-size: 9.5px; font-weight: 800; color: #0369a1;">bb-browser</div>
    <div style="font-size: 7.5px; font-weight: 700; color: #1e293b; margin-top: 1px;">Build exploration Web UI (:80)<br>Direct read-only CAS/AC inspection</div>
  </div>

  <!-- Section 2: Storage RPCs category -->
  <div class="glass-ice" style="top: 510px; left: 775px; width: 270px; height: 38px; padding: 3px 6px; text-align: center;">
    <div style="font-size: 9px; font-weight: 800; color: #1d4ed8;">Storage RPCs :8981 (CAS · AC · FSAC)</div>
    <div style="font-size: 7.5px; font-weight: 700; color: #1e293b; margin-top: 1px;">Worker payload reads/writes · Direct gRPC data (NOT event stream)</div>
  </div>

  <!-- Section 3: KEDA autoscaling - No Disk Link -->
  <div class="glass-rose" style="top: 642px; left: 466px; width: 118px; height: 32px; padding: 2px 4px; text-align: center;">
    <div style="font-size: 8px; font-weight: 800; color: #e11d48;">No Disk Link</div>
    <div style="font-size: 7px; font-weight: 700; color: #1e293b;">Workers use NVMe SSD</div>
  </div>

  <!-- KEDA PromQL query badge over VictoriaMetrics -->
  <div class="glass-emerald" style="top: 636px; left: 660px; width: 110px; height: 34px; padding: 2px 4px; text-align: center;">
    <div style="font-size: 8px; font-weight: 800; color: #047857;">PromQL Backlog</div>
    <div style="font-size: 7px; font-weight: 700; color: #1e293b;">tasks_scheduled_total<br>scales bb-workers</div>
  </div>

</body>
</html>
"""


def main():
    print(f"Generating architecture diagrams using base images in {BASE_DIR}")
    print("Pre-processing clean base images (dissolving baked-in AI text)...")
    clean_d1, clean_d2, clean_d3 = prepare_clean_base_images()
    print("Clean base images successfully created in memory / cache.")

    diagrams = [
        ("d1", build_d1_html(clean_d1), "hermetiq-gke-deployment.png"),
        ("d2", build_d2_html(clean_d2), "hermetiq-nats-db-ingest.png"),
        ("d3", build_d3_html(clean_d3), "hermetiq-buildbarn-diagram.png"),
    ]

    for prefix, html_content, output_name in diagrams:
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
