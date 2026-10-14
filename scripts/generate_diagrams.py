#!/usr/bin/env python3
"""
Generate Customer-Facing 3D Isometric Architecture Diagrams
Using Frosted Glassmorphism Vector Overlay & Headless Chrome Rendering.

Ensures 100% adherence to the 3-Pass Verification Framework:
  Pass 1: Architecture & Flow Correctness (Issue #31 & #111 invariants)
  Pass 2: Visual Aesthetics & Bling (Direct container text, no redundant textboxes, exposed 3D glass)
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
                        nr, ng, nb = 240, 245, 252

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


def clean_upper_gcs_bucket(im):
    """
    Dissolves the hallucinated duplicate upper GCS bucket and phantom blue arrow
    from PostgreSQL in Diagram 1, restoring the pristine container background.
    """
    im_clean = im.copy()
    box = (1095, 260, 1338, 398)
    w = box[2] - box[0]
    h = box[3] - box[1]

    top_row = [im.getpixel((box[0] + x, 259))[:3] for x in range(w)]
    bottom_row = [im.getpixel((box[0] + x, 399))[:3] for x in range(w)]
    right_col = [im.getpixel((1338, box[1] + y))[:3] for y in range(h)]

    left_col = []
    for y in range(h):
        cur_y = box[1] + y
        if 336 <= cur_y <= 356:
            t_pix = im.getpixel((1095, 335))[:3]
            b_pix = im.getpixel((1095, 357))[:3]
            weight = (cur_y - 335) / (357 - 335)
            nr = int(t_pix[0] * (1 - weight) + b_pix[0] * weight)
            ng = int(t_pix[1] * (1 - weight) + b_pix[1] * weight)
            nb = int(t_pix[2] * (1 - weight) + b_pix[2] * weight)
            left_col.append((nr, ng, nb))
        else:
            left_col.append(im.getpixel((box[0], cur_y))[:3])

    canvas = Image.new("RGB", (w, h))
    cpix = canvas.load()
    for y in range(h):
        v_weight = y / (h - 1)
        for x in range(w):
            h_weight = x / (w - 1)
            lr, lg, lb = left_col[y]
            rr, rg, rb = right_col[y]
            hr = lr * (1 - h_weight) + rr * h_weight
            hg = lg * (1 - h_weight) + rg * h_weight
            hb = lb * (1 - h_weight) + rb * h_weight

            tr, tg, tb = top_row[x]
            br, bg, bb = bottom_row[x]
            vr = tr * (1 - v_weight) + br * v_weight
            vg = tg * (1 - v_weight) + bg * v_weight
            vb = tb * (1 - v_weight) + bb * v_weight

            r = int(0.5 * hr + 0.5 * vr)
            g = int(0.5 * hg + 0.5 * vg)
            b = int(0.5 * hb + 0.5 * vb)

            # Feather top and left borders to eliminate any seam at x=1095 or y=260
            cur_y = box[1] + y
            d_left = x if not (325 <= cur_y <= 360) else 999
            d_top = y
            d_right = w - 1 - x
            d = min(d_left, d_top, d_right)
            if d < 8:
                alpha = d / 8.0
                orig_p = im.getpixel((box[0] + x, cur_y))[:3]
                r = int(orig_p[0] * (1 - alpha) + r * alpha)
                g = int(orig_p[1] * (1 - alpha) + g * alpha)
                b = int(orig_p[2] * (1 - alpha) + b * alpha)

            cpix[x, y] = (r, g, b)

    im_clean.paste(canvas, (box[0], box[1]))

    # Clean arrow stub from postgres: x from 1069 to 1096, y from 336 to 356
    for y in range(336, 357):
        weight = (y - 335) / (357 - 335)
        for x in range(1069, 1096):
            tr, tg, tb = im.getpixel((x, 335))[:3]
            br, bg, bb = im.getpixel((x, 357))[:3]
            nr = int(tr * (1 - weight) + br * weight)
            ng = int(tg * (1 - weight) + bg * weight)
            nb = int(tb * (1 - weight) + bb * weight)
            im_clean.putpixel((x, y), (nr, ng, nb))

    return im_clean


def clean_d2_title_bar(im):
    """
    Dissolves the AI glass bar and baked-in title in Diagram 2,
    restoring pristine top canvas background matching Diagrams 1 & 3.
    """
    im_clean = im.copy()
    box = (40, 0, 880, 87)
    w = box[2] - box[0]
    h = box[3] - box[1]

    top_row = [im.getpixel((box[0] + x, 0))[:3] for x in range(w)]
    bottom_row = [im.getpixel((box[0] + x, 87))[:3] for x in range(w)]
    left_col = [im.getpixel((box[0], y))[:3] for y in range(h)]
    right_col = [im.getpixel((box[2] - 1, y))[:3] for y in range(h)]

    canvas = Image.new("RGB", (w, h))
    cpix = canvas.load()
    for y in range(h):
        v = y / (h - 1)
        for x in range(w):
            u = x / (w - 1)
            lr, lg, lb = left_col[y]
            rr, rg, rb = right_col[y]
            hr = lr * (1 - u) + rr * u
            hg = lg * (1 - u) + rg * u
            hb = lb * (1 - u) + rb * u

            tr, tg, tb = top_row[x]
            br, bg, bb = bottom_row[x]
            vr = tr * (1 - v) + br * v
            vg = tg * (1 - v) + bg * v
            vb = tb * (1 - v) + bb * v

            cpix[x, y] = (int(0.5 * hr + 0.5 * vr), int(0.5 * hg + 0.5 * vg), int(0.5 * hb + 0.5 * vb))

    im_clean.paste(canvas, (box[0], box[1]))
    return im_clean


def clean_d2_query_slab(im):
    """
    Dissolves the awkward AI-generated slanted blue glass slab under Query API,
    restoring the pristine light container background and docking into the red query line.
    """
    im_clean = im.copy()
    tl = (226, 228, 233)
    tr = (222, 225, 230)
    bl = (225, 227, 232)
    br = (220, 223, 229)

    y_start, y_end = 368, 526
    x_start = 50

    for y in range(y_start, y_end):
        v = (y - y_start) / (y_end - 1 - y_start)
        if 433 <= y <= 447:
            max_x = 278
        elif 423 <= y < 433:
            max_x = 283
        else:
            max_x = 287

        for x in range(x_start, max_x):
            u = (x - x_start) / (287 - x_start)
            r = int((1-u)*(1-v)*tl[0] + u*(1-v)*tr[0] + (1-u)*v*bl[0] + u*v*br[0])
            g = int((1-u)*(1-v)*tl[1] + u*(1-v)*tr[1] + (1-u)*v*bl[1] + u*v*br[1])
            b = int((1-u)*(1-v)*tl[2] + u*(1-v)*tr[2] + (1-u)*v*bl[2] + u*v*br[2])

            dist_top = y - y_start
            dist_bot = y_end - 1 - y
            dist_left = x - x_start
            dist_right = max_x - 1 - x
            min_dist = min(dist_top, dist_bot, dist_left, dist_right)
            
            if min_dist < 5:
                alpha = min_dist / 5.0
                orig = im.getpixel((x, y))[:3]
                r = int(orig[0] * (1 - alpha) + r * alpha)
                g = int(orig[1] * (1 - alpha) + g * alpha)
                b = int(orig[2] * (1 - alpha) + b * alpha)

            im_clean.putpixel((x, y), (r, g, b))

    return im_clean


def clean_gateway_tls_hop(im):
    """
    Dissolves the inaccurate 'TLS' text, raster arrow, and blue padlock between
    Gateway and Kubernetes ClusterIP Services using seamless vertical column interpolation
    so a crisp vector arrow and 'HTTP/2' label can be rendered across the gap.
    """
    im_clean = im.copy()
    pix = im_clean.load()
    orig = im.copy()
    opix = orig.load()

    y_top, y_bot = 132, 205

    for x in range(835, 876):
        ct = opix[x, y_top][:3]
        cb = opix[x, y_bot][:3]
        for y in range(133, 205):
            v = (y - y_top) / float(y_bot - y_top)
            r = int(round((1 - v) * ct[0] + v * cb[0]))
            g = int(round((1 - v) * ct[1] + v * cb[1]))
            b = int(round((1 - v) * ct[2] + v * cb[2]))
            pix[x, y] = (r, g, b)

    return im_clean


def clean_d3_legend(im):
    """
    Dissolves baked-in 'request / data' and 'event stream' legend labels and shifts
    the first legend column (blue arrow + green solid arrow + 'OTLP push') 36px left
    using seamless background-delta transfer so 'client request / REAPI' has generous spacing.
    """
    im_clean = im.copy()
    pix = im_clean.load()
    orig = im.copy()
    opix = orig.load()

    y_top, y_bot = 18, 72

    def bg_at(x, y):
        v = (y - y_top) / float(y_bot - y_top)
        ct = opix[x, y_top][:3]
        cb = opix[x, y_bot][:3]
        return (
            (1 - v) * ct[0] + v * cb[0],
            (1 - v) * ct[1] + v * cb[1],
            (1 - v) * ct[2] + v * cb[2],
        )

    # 1. Wipe old Column 1 (x in [900, 1028], y in [19, 71]) and 'event stream' (x in [1082, 1160], y in [24, 44])
    for x in range(900, 1029):
        for y in range(19, 72):
            b_r, b_g, b_b = bg_at(x, y)
            pix[x, y] = (int(round(b_r)), int(round(b_g)), int(round(b_b)))

    for x in range(1082, 1161):
        for y in range(24, 45):
            b_r, b_g, b_b = bg_at(x, y)
            pix[x, y] = (int(round(b_r)), int(round(b_g)), int(round(b_b)))

    # 2. Transfer blue arrow (y in [20, 45], src_x in [902, 952]) and
    # green solid arrow + 'OTLP push' (y in [46, 71], src_x in [902, 1010]) 36px left
    shift = 36
    for y in range(20, 72):
        src_x_max = 952 if y <= 45 else 1010
        for src_x in range(902, src_x_max + 1):
            dst_x = src_x - shift
            dst_bg = bg_at(dst_x, y)
            src_bg = bg_at(src_x, y)
            src_p = opix[src_x, y][:3]
            r = max(0, min(255, int(round(dst_bg[0] + (src_p[0] - src_bg[0])))))
            g = max(0, min(255, int(round(dst_bg[1] + (src_p[1] - src_bg[1])))))
            b = max(0, min(255, int(round(dst_bg[2] + (src_p[2] - src_bg[2])))))
            pix[dst_x, y] = (r, g, b)

    return im_clean



def clean_d3_scheduler_racks(im):
    """
    Dissolves glowing amber AI squiggles (8M·8V·8, v-x-2) across all 3 server
    racks in bb-scheduler, cloning clean dark perforated grill texture.
    """
    im_clean = im.copy()
    pix = im_clean.load()
    racks = [
        (156, 172, 401, 485),
        (207, 224, 373, 457),
        (258, 274, 344, 430),
    ]
    for ax0, ax1, y0, y1 in racks:
        for y in range(y0, y1):
            for x in range(ax0, ax1):
                r, g, b = im.getpixel((x, y))[:3]
                if r > 80 and g > 60 and (r - b) > 15:
                    src_x = x + 14
                    pix[x, y] = pix[src_x, y]
    return im_clean


def fill_bilinear_feathered(im, box, feather=5):
    """
    Fills a rectangular background patch with bilinear interpolation sampled
    from its 4 outer corners, smoothly feathered at the borders to eliminate
    any seams or visible boundaries.
    """
    x1, y1, x2, y2 = box
    w = x2 - x1
    h = y2 - y1
    pixels = im.load()

    c_tl = pixels[x1, y1][:3]
    c_tr = pixels[x2, y1][:3]
    c_bl = pixels[x1, y2][:3]
    c_br = pixels[x2, y2][:3]

    for y in range(y1, y2 + 1):
        v = (y - y1) / max(h, 1)
        for x in range(x1, x2 + 1):
            u = (x - x1) / max(w, 1)
            r = (1 - u) * (1 - v) * c_tl[0] + u * (1 - v) * c_tr[0] + (1 - u) * v * c_bl[0] + u * v * c_br[0]
            g = (1 - u) * (1 - v) * c_tl[1] + u * (1 - v) * c_tr[1] + (1 - u) * v * c_bl[1] + u * v * c_br[1]
            b = (1 - u) * (1 - v) * c_tl[2] + u * (1 - v) * c_tr[2] + (1 - u) * v * c_bl[2] + u * v * c_br[2]

            dx = min(x - x1, x2 - x)
            dy = min(y - y1, y2 - y)
            d = min(dx, dy)
            if d < feather:
                alpha = d / float(feather)
                orig_p = pixels[x, y][:3]
                r = orig_p[0] * (1 - alpha) + r * alpha
                g = orig_p[1] * (1 - alpha) + g * alpha
                b = orig_p[2] * (1 - alpha) + b * alpha

            pixels[x, y] = (int(r), int(g), int(b))
    return im


def clean_vm_cubes(im):
    """
    Softens harsh white matrix/number artifacts on vertical faces of the 4 green
    VictoriaMetrics cubes while perfectly preserving the 4 sharp top logos.
    """
    im_clean = im.copy()
    box = (700, 520, 880, 680)
    crop = im_clean.crop(box)
    w, h = crop.size

    logos = [
        (85, 27, 28, 18),
        (44, 62, 28, 18),
        (128, 62, 28, 18),
        (87, 98, 28, 18),
    ]

    def in_logo(x, y):
        for cx, cy, rx, ry in logos:
            if ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1.0:
                return True
        return False

    med = crop.filter(ImageFilter.MedianFilter(size=7))
    mpix = med.load()
    cpix = crop.load()
    for y in range(h):
        for x in range(w):
            if not in_logo(x, y):
                r, g, b = cpix[x, y][:3]
                lum = 0.299 * r + 0.587 * g + 0.114 * b
                if lum > 140 and r < 200 and g > 80:
                    cpix[x, y] = mpix[x, y]

    im_clean.paste(crop, box)
    return im_clean


def clean_vmagent_box(im):
    """
    Dissolves white numbers (1981-8181) and dots from the blue VMAgent Scraper box.
    """
    im_clean = im.copy()
    box_rim = (938, 626, 1022, 646)
    crop_rim = im_clean.crop(box_rim)
    med_rim = crop_rim.filter(ImageFilter.MedianFilter(size=9))

    mask = Image.new("L", crop_rim.size, 0)
    for y in range(crop_rim.size[1]):
        for x in range(crop_rim.size[0]):
            border_d = min(x, crop_rim.size[0] - 1 - x, y, crop_rim.size[1] - 1 - y)
            if border_d >= 3:
                mask.putpixel((x, y), 255)
            else:
                mask.putpixel((x, y), int(255 * (border_d / 3.0)))
    im_clean.paste(med_rim, box_rim, mask)

    box_dark = (938, 646, 1022, 662)
    crop_dark = im_clean.crop(box_dark)
    med_dark = crop_dark.filter(ImageFilter.MedianFilter(size=7))
    im_clean.paste(med_dark, box_dark)
    return im_clean


def clean_gateway_cube(im):
    """
    Dissolves fake IP/binary numbers on Hermetiq-gateway glowing rim and smooths the top chip.
    """
    im_clean = im.copy()
    crop_rim = im_clean.crop((478, 158, 554, 186))
    med_rim = crop_rim.filter(ImageFilter.MedianFilter(size=7))
    im_clean.paste(med_rim, (478, 158))

    crop_top = im_clean.crop((495, 140, 535, 168))
    med_top = crop_top.filter(ImageFilter.MedianFilter(size=9))
    im_clean.paste(med_top, (495, 140))
    return im_clean


def clean_d3_worker_pedestals(im):
    """
    Dissolves fake numbers like '-0 000 0' and '+0 .0' on the dark purple bevels
    of all 4 bb-worker pedestals.
    """
    im_clean = im.copy()
    boxes = [
        (582, 443, 634, 465),  # Front pedestal
        (506, 403, 538, 421),  # Left pedestal
        (665, 401, 724, 423),  # Right pedestal
        (586, 355, 630, 373),  # Top pedestal
    ]
    for box in boxes:
        crop = im_clean.crop(box)
        med = crop.filter(ImageFilter.MedianFilter(size=9))
        im_clean.paste(med, box)
    return im_clean


def clean_d3_baked_text(im):
    """
    Dissolves duplicate, misplaced, and hallucinated AI text in Diagram 3
    using bilinear background fills with seamless feathered blending.
    """
    im_clean = im.copy()
    # 1. Above frontend & browser cards (eliminates faint white 'bb-frontend' and 'bb-browser')
    im_clean = fill_bilinear_feathered(im_clean, (750, 382, 1040, 415), feather=4)

    # 2. Extraneous bb-worker label floating under worker platform
    im_clean = fill_bilinear_feathered(im_clean, (525, 520, 645, 550), feather=4)

    # 3. Hallucinated 3-shard glass storage cabinet caption under cabinet
    im_clean = fill_bilinear_feathered(im_clean, (1060, 515, 1340, 550), feather=4)

    # 4. Misplaced Section 3 labels
    # 'Worker Operator GitOps Control Plane' under VictoriaMetrics (preserving blue loop arrow at y<=708)
    im_clean = fill_bilinear_feathered(im_clean, (610, 710, 885, 742), feather=2)
    # 'VictoriaMetrics telemetry' under Grafana screens (preserving green telemetry arrow at x<=1100, y<=713)
    im_clean = fill_bilinear_feathered(im_clean, (1102, 706, 1315, 742), feather=2)
    # 'node-local NVMe SSD disk chassis' to the left of the chassis
    im_clean = fill_bilinear_feathered(im_clean, (195, 620, 335, 715), feather=4)
    # 'LVM Striped Storage' under the chassis
    im_clean = fill_bilinear_feathered(im_clean, (340, 695, 520, 742), feather=4)
    return im_clean


def clean_d1_gcs_bucket_rims(im):
    """
    Dissolves all 4 lines of baked-in black AI pseudo-letters on the right vertical face
    and bottom rim of the GCS bucket in Diagram 1 without affecting the floor text.
    """
    im_clean = im.copy()
    box = (1145, 420, 1205, 508)
    crop = im_clean.crop(box)
    med = crop.filter(ImageFilter.MedianFilter(size=7))
    im_clean.paste(med, box)
    return im_clean


def clean_d1_otel_bevel(im):
    """
    Dissolves pseudo-characters and binary digits on OpenTelemetry collector in Diagram 1.
    """
    im_clean = im.copy()
    crop_rim = im_clean.crop((372, 638, 458, 675))
    med_rim = crop_rim.filter(ImageFilter.MedianFilter(size=9))
    im_clean.paste(med_rim, (372, 638))
    return im_clean


def clean_d1_pub_bevel(im):
    """
    Dissolves pseudo-characters on the front bevel rim of bep-nats-pub in Diagram 1.
    """
    im_clean = im.copy()
    crop = im_clean.crop((182, 372, 218, 392))
    med = crop.filter(ImageFilter.MedianFilter(size=9))
    im_clean.paste(med, (182, 372))
    return im_clean


def clean_d2_partition_overlap(im):
    """
    Dissolves 'partition router' under the purple fan-out icon on the Cloud SQL table slab.
    """
    return inpaint_text_smooth(im, (840, 475, 950, 505), lum_threshold=180)


def clean_d2_red_pipe(im):
    """
    Dissolves white squiggly pseudo-characters on the red pipe coming out of the gateway in Diagram 2.
    """
    im_clean = im.copy()
    box = (520, 185, 595, 210)
    crop = im_clean.crop(box)
    med = crop.filter(ImageFilter.MedianFilter(size=7))
    im_clean.paste(med, box)
    return im_clean


def prepare_clean_base_images():
    """Pre-processes base images by dissolving baked-in text in overlay areas."""
    # Prefer pristine fixed-images if present
    d1_source = BASE_DIR / "fixed-images" / "hermetiq-architecture-ai.png"
    if not d1_source.exists():
        d1_source = BASE_DIR / "hermetiq-architecture-ai.png"

    # 1. Clean D1 base (hermetiq-architecture-ai.png)
    d1_base = Image.open(d1_source)
    # Clean gateway route pills interior in D1 (Direct Container Principle)
    d1_base = inpaint_text_smooth(d1_base, (604, 156, 822, 174), lum_threshold=220)
    d1_base = inpaint_text_smooth(d1_base, (604, 183, 822, 201), lum_threshold=220)
    # Clean ClusterIP Services inside card: (882, 128, 1106, 222) - starts at x=882 to preserve left card border & arrow tip
    d1_base = inpaint_text_smooth(d1_base, (882, 128, 1106, 222), lum_threshold=185)
    # Clean OIDC Provider inside card: (1180, 126, 1295, 200) - starts at x=1180 to preserve purple arrow tip (x=1173)
    d1_base = inpaint_text_smooth(d1_base, (1180, 126, 1295, 200), lum_threshold=216)
    # Remove hallucinated duplicate upper GCS bucket & phantom arrow from PostgreSQL
    d1_base = clean_upper_gcs_bucket(d1_base)
    # Dissolve misleading TLS text & padlock on internal gateway->services hop
    d1_base = clean_gateway_tls_hop(d1_base)
    # Dissolve misleading NATS OTLP Push text (NATS uses Prometheus exporter + VMPodScrape)
    d1_base = inpaint_text_smooth(d1_base, (429, 520, 490, 538), lum_threshold=180)
    # Dissolve hallucinated 'promistores' text without touching blue conduit at x>=921, y>=553
    d1_base = inpaint_text_smooth(d1_base, (848, 533, 916, 549), lum_threshold=180)
    # Dissolve duplicate/garbled 'queries / queries' text without touching blue conduits at x>=911, y>=452
    d1_base = inpaint_text_smooth(d1_base, (815, 430, 905, 448), lum_threshold=180)
    # Clean gateway cube glowing rim and top diamond chip
    d1_base = clean_gateway_cube(d1_base)
    # Dissolve AI gibberish on GCS bucket glass rims
    d1_base = clean_d1_gcs_bucket_rims(d1_base)
    # Dissolve pseudo-characters on OpenTelemetry collector and pub pod
    d1_base = clean_d1_otel_bevel(d1_base)
    d1_base = clean_d1_pub_bevel(d1_base)
    # Clean VM cubes and VMAgent box
    d1_base = clean_vm_cubes(d1_base)
    d1_base = clean_vmagent_box(d1_base)
    clean_d1_path = TMP_DIR / "clean_d1.png"
    d1_base.save(clean_d1_path)

    # 2. Clean D2 base (bep-ingest-architecture-ai.png)
    d2_base = Image.open(BASE_DIR / "bep-ingest-architecture-ai.png")
    # Dissolve 3D glass bar & baked title to restore clean keynote top canvas
    d2_base = clean_d2_title_bar(d2_base)
    # Dissolve awkward slanted blue glass slab under Query API
    d2_base = clean_d2_query_slab(d2_base)
    # Clean Bazel clients inside card (70, 118, 195, 164)
    d2_base = inpaint_text_smooth(d2_base, (70, 118, 195, 164), lum_threshold=185)
    # Clean Delivery guarantees inside card (74, 276, 485, 340)
    d2_base = inpaint_text_smooth(d2_base, (74, 276, 485, 340), lum_threshold=185)
    # Clean File storage native card under JetStream: (776, 274, 1025, 318)
    d2_base = inpaint_text_smooth(d2_base, (776, 274, 1025, 318), lum_threshold=185)
    # Clean GCS hybrid (slab face + ribs)
    d2_base = inpaint_gcs_hybrid(d2_base)
    # Dissolve erroneous 'Query' text + red arrow stub between PostgreSQL and GCS (x in [967, 1044], y in [418, 450])
    d2_pix = d2_base.load()
    for x in range(967, 1045):
        ct = d2_pix[x, 418][:3]
        cb = d2_pix[x, 450][:3]
        for y in range(419, 450):
            v = (y - 418) / float(450 - 418)
            d2_pix[x, y] = (
                int(round((1 - v) * ct[0] + v * cb[0])),
                int(round((1 - v) * ct[1] + v * cb[1])),
                int(round((1 - v) * ct[2] + v * cb[2])),
            )
    # Dissolve garbled 'disabled dlog or upload faload - - progresses chunks' above bottom blue arrow
    # while strictly preserving the blue arrow shaft (y>=518), left arrowhead (x<=977), and right stem (x>=1185)
    for x in range(978, 1185):
        ct = d2_pix[x, 500][:3]
        cb = d2_pix[x, 517][:3]
        for y in range(501, 517):
            v = (y - 500) / float(517 - 500)
            d2_pix[x, y] = (
                int(round((1 - v) * ct[0] + v * cb[0])),
                int(round((1 - v) * ct[1] + v * cb[1])),
                int(round((1 - v) * ct[2] + v * cb[2])),
            )
    # Dissolve 'partition router' under purple fanout icon on table slab
    d2_base = clean_d2_partition_overlap(d2_base)
    # Clean red pipe pseudo-characters
    d2_base = clean_d2_red_pipe(d2_base)
    # Dissolve random isometric floor artifact between gateway and partition router pedestals
    d2_base = inpaint_text_smooth(d2_base, (542, 240, 585, 270), lum_threshold=221, blur_radius=2)
    d2_base = inpaint_text_smooth(d2_base, (485, 265, 618, 335), lum_threshold=223, blur_radius=2)
    # Dissolve garbled 'public. part confia' and 'source tom' inside public.part_config card
    d2_base = inpaint_text_smooth(d2_base, (326, 558, 475, 600), lum_threshold=185)
    clean_d2_path = TMP_DIR / "clean_d2.png"
    d2_base.save(clean_d2_path)

    # 3. Clean D3 base (bb-architecture-ai.png)
    d3_base = Image.open(BASE_DIR / "bb-architecture-ai.png")
    # Patch clean OIDC region and clean native gateway pills from d1
    oidc_patch = d1_base.crop((1080, 100, 1310, 230))
    d3_base.paste(oidc_patch, (1080, 100))
    gw_pills_patch = d1_base.crop((598, 150, 833, 210))
    d3_base.paste(gw_pills_patch, (598, 150))
    # Inpaint ClusterIP on D3 - starts at x=882 to preserve left card border & arrow tip
    d3_base = inpaint_text_smooth(d3_base, (882, 128, 1106, 222), lum_threshold=185)
    # Dissolve misleading TLS text & padlock on internal gateway->services hop
    d3_base = clean_gateway_tls_hop(d3_base)
    # Dissolve contradictory legend text and shift column 1 left for clean spacing
    d3_base = clean_d3_legend(d3_base)
    # Dissolve glowing amber AI squiggles across all 3 bb-scheduler server racks
    d3_base = clean_d3_scheduler_racks(d3_base)
    # Dissolve white squiggles from vertical faces of VictoriaMetrics cubes
    d3_base = clean_vm_cubes(d3_base)
    # Dissolve numbers on VMAgent scraper and Hermetiq-gateway
    d3_base = clean_vmagent_box(d3_base)
    d3_base = clean_gateway_cube(d3_base)
    # Smooth worker pedestal bevels
    d3_base = clean_d3_worker_pedestals(d3_base)
    # Dissolve all duplicate, misplaced, and hallucinated AI text
    d3_base = clean_d3_baked_text(d3_base)
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

  /* Direct Container Text - Placed directly inside underlying 3D container with NO overlay textbox */
  .direct-card {
    position: absolute;
    z-index: 10;
    background: transparent;
    border: none;
    box-shadow: none;
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

  /* Keynote Header Title */
  .diagram-title-box {
    position: absolute;
    z-index: 15;
    top: 24px;
    left: 45px;
  }
  .diagram-title {
    font-size: 23px;
    font-weight: 800;
    color: #0f172a;
    letter-spacing: -0.02em;
    line-height: 1.15;
  }
  .diagram-subtitle {
    font-size: 11px;
    font-weight: 500;
    color: #475569;
    letter-spacing: -0.01em;
    margin-top: 4px;
  }

  /* Sleek 3D Frosted Glass Query API Node */
  .query-api-node {
    position: absolute;
    z-index: 12;
    top: 372px;
    left: 54px;
    width: 226px;
    background: linear-gradient(145deg, rgba(255, 255, 255, 0.92) 0%, rgba(240, 246, 254, 0.88) 45%, rgba(224, 238, 255, 0.82) 100%);
    backdrop-filter: blur(16px) saturate(180%);
    -webkit-backdrop-filter: blur(16px) saturate(180%);
    border: 1px solid rgba(186, 230, 253, 0.95);
    border-radius: 9px;
    padding: 8px 9px 7px 9px;
    box-shadow: 0 6px 18px rgba(15, 23, 42, 0.07), 0 1px 3px rgba(2, 132, 199, 0.08), inset 0 1px 1px rgba(255, 255, 255, 0.95);
  }
  .query-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding-bottom: 5px;
    border-bottom: 1px solid rgba(226, 232, 240, 0.8);
  }
  .query-title {
    font-size: 11px;
    font-weight: 800;
    color: #0f172a;
    letter-spacing: -0.01em;
    display: flex;
    align-items: center;
    gap: 5px;
  }
  .deploy-badge {
    background: linear-gradient(135deg, #0284c7 0%, #0369a1 100%);
    color: #ffffff;
    font-size: 7.5px;
    font-weight: 800;
    padding: 1.5px 5px;
    border-radius: 4px;
    letter-spacing: 0.02em;
    box-shadow: 0 1px 3px rgba(2, 132, 199, 0.25);
  }
  .pod-grid {
    display: flex;
    gap: 5px;
    margin-top: 6px;
  }
  .pod-card {
    flex: 1;
    background: rgba(255, 255, 255, 0.85);
    border: 1px solid rgba(203, 213, 225, 0.85);
    border-radius: 6px;
    padding: 3.5px 5px;
    box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
  }
  .pod-title {
    font-size: 8px;
    font-weight: 800;
    color: #0369a1;
    display: flex;
    align-items: center;
    justify-content: space-between;
  }
  .status-dot {
    width: 5px;
    height: 5px;
    background: #10b981;
    border-radius: 50%;
    box-shadow: 0 0 4px #10b981;
    display: inline-block;
  }
  .port-row {
    display: flex;
    gap: 3px;
    margin-top: 5px;
  }
  .port-chip {
    flex: 1;
    text-align: center;
    background: rgba(241, 245, 249, 0.9);
    border: 1px solid rgba(203, 213, 225, 0.7);
    border-radius: 4px;
    font-size: 7px;
    font-weight: 700;
    color: #334155;
    padding: 1.5px 0;
  }
  .query-meta {
    margin-top: 5px;
    font-size: 7.5px;
    line-height: 1.35;
    color: #1e293b;
  }
  .invariant-badge {
    font-size: 7.5px;
    font-weight: 800;
    color: #047857;
    display: flex;
    align-items: center;
    gap: 3px;
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

  <!-- Gateway Router Icon Overlay -->
  <div style="position: absolute; z-index: 12; top: 144px; left: 508px; width: 22px; height: 22px; display: flex; align-items: center; justify-content: center; pointer-events: none;">
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#ffffff" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M4 14h6m4 0h6m-6-4l3 4-3 4m-4-8l-3 4 3 4"/>
      <circle cx="12" cy="14" r="2" fill="#ffffff"/>
    </svg>
  </div>

  <!-- OpenTelemetry Collector Telescope Icon Overlay -->
  <div style="position: absolute; z-index: 12; top: 620px; left: 404px; width: 22px; height: 22px; display: flex; align-items: center; justify-content: center; pointer-events: none;">
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#ffffff" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M3 13l4-8h10l4 8-9 8-9-8z"/>
      <circle cx="12" cy="11" r="3" fill="#ffffff"/>
    </svg>
  </div>

  <!-- Legend typo fix (remote wite -> remote write) -->
  <div style="position: absolute; z-index: 15; top: 52px; left: 1083px; width: 135px; height: 18px; background: #dfebf3; display: flex; align-items: center;">
    <span style="font-size: 10.5px; color: #1e293b; font-weight: 700; line-height: 1;">scrape / remote write</span>
  </div>

  <!-- Gateway Routes Overlay (Direct Container Principle inside native pills) -->
  <div class="direct-card" style="top: 154px; left: 602px; width: 222px; height: 21px; display: flex; align-items: center; justify-content: center; font-size: 8.5px; font-weight: 700; color: #0f172a;">GRPCRoute · bep-cloud-grpc · api-cloud-grpc</div>
  <div class="direct-card" style="top: 181px; left: 602px; width: 222px; height: 21px; display: flex; align-items: center; justify-content: center; font-size: 8.5px; font-weight: 700; color: #0f172a;">HTTPRoute · api-web · dashboard · grafana · mcp</div>

  <!-- Gateway to ClusterIP HTTP/2 hop (crisp vector label + glowing SVG arrow) -->
  <div style="position: absolute; z-index: 15; top: 136px; left: 834px; width: 41px; height: 16px; display: flex; align-items: center; justify-content: center; background: transparent; pointer-events: none;">
    <span style="font-size: 9.5px; font-weight: 800; color: #0f172a; line-height: 1; letter-spacing: -0.02em;">HTTP/2</span>
  </div>
  <div style="position: absolute; z-index: 15; top: 153px; left: 833px; width: 43px; height: 24px; pointer-events: none;">
    <svg width="43" height="24" viewBox="0 0 43 24" fill="none" xmlns="http://www.w3.org/2000/svg">
      <defs>
        <filter id="cyan-glow-d1" x="-20%" y="-40%" width="140%" height="180%">
          <feDropShadow dx="0" dy="1" stdDeviation="2.2" flood-color="#38bdf8" flood-opacity="0.65"/>
        </filter>
        <linearGradient id="arrow-fill-d1" x1="0" y1="12" x2="41" y2="12" gradientUnits="userSpaceOnUse">
          <stop offset="0%" stop-color="#38bdf8"/>
          <stop offset="100%" stop-color="#0ea5e9"/>
        </linearGradient>
      </defs>
      <path d="M1 9.5 H26 V5 L40.5 12 L26 19 V14.5 H1 Z" fill="url(#arrow-fill-d1)" stroke="#0369a1" stroke-width="1.35" stroke-linejoin="round" filter="url(#cyan-glow-d1)"/>
      <line x1="2.5" y1="12" x2="27" y2="12" stroke="#bae6fd" stroke-width="1.4" stroke-dasharray="2.5 1.5" stroke-linecap="round"/>
    </svg>
  </div>

  <!-- Section 1: ClusterIP Services Box: Directly in native container, no textbox -->
  <div class="direct-card" style="top: 136px; left: 882px; width: 220px;">
    <div class="card-title">Kubernetes ClusterIP Services</div>
    <div style="font-size: 8px; font-weight: 800; color: #3730a3; margin-top: 1px;">L4 Routing Only · No TLS Termination</div>
    <div class="card-sub" style="margin-top: 2px;">
      bep-nats-pub :50091 · grpc-api :50091, :80, :5150<br>
      web-ui :80 · grafana-oauth2-proxy :8080<br>
      <span style="font-weight: 700; color: #334155;">Auth verified by app pods, not Services</span>
    </div>
  </div>

  <!-- Section 1: OIDC Provider: Directly in native container, no textbox -->
  <div class="direct-card" style="top: 136px; left: 1176px; width: 120px; text-align: center;">
    <div class="card-title" style="text-align: center;">OIDC Provider</div>
    <div style="font-size: 8px; font-weight: 800; color: #5b21b6; margin-top: 1px; text-align: center;">Auth & SSO (Control Plane)</div>
    <div class="card-sub" style="font-size: 7.5px; margin-top: 2px; text-align: center;">
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
      gRPC (:50091) · REST (:80 / target:8008) · MCP (:5150)<br>
      Reads PostgreSQL metadata & GCS log chunks<br>
      <span style="font-weight: 700; color: #334155;">No stream subscriptions · Decoupled from JetStream</span>
    </div>
  </div>

  <!-- Section 2: bep-nats-sub replaces erroneous 'bep-nats-pub' under blue writer pod -->
  <div class="glass-sub-pill" style="top: 368px; left: 794px; width: 108px; height: 24px; font-size: 9.5px;">bep-nats-sub</div>

  <!-- Section 2: Direct Chunk Offload -->
  <div class="glass-cyan" style="top: 464px; left: 865px; width: 165px; height: 38px; padding: 4px 6px; text-align: center;">
    <div style="font-size: 8.5px; font-weight: 800; color: #0284c7;">Direct Chunk Offload</div>
    <div style="font-size: 7.5px; font-weight: 700; color: #1e293b; margin-top: 1px;">Subscribers upload stdout/stderr to GCS</div>
  </div>

  <!-- Section 2: Managed Persistence & Artifact Store card in upper-right data tier -->
  <div class="glass-cyan" style="top: 274px; left: 1098px; width: 234px; height: 104px; padding: 7px 10px;">
    <div class="card-title">Managed Persistence &amp; Storage</div>
    <div style="font-size: 8px; font-weight: 800; color: #0369a1; margin-top: 1px;">Cloud SQL (pg_partman) · GCS Artifact Store</div>
    <div class="card-sub" style="font-size: 7.5px; line-height: 1.38; margin-top: 3px;">
      <strong style="color: #0f172a;">PostgreSQL:</strong> 20 time-partitioned parent tables<br>
      Batch SQL metadata writes · No DB-to-GCS path<br>
      <strong style="color: #0f172a;">GCS Bucket:</strong> <code style="font-size: 7px;">progress/v1/&lt;proj&gt;/&lt;inv&gt;/*.pb.gz</code><br>
      <span style="font-weight: 700; color: #047857;">GKE Workload Identity · DB progress fallback</span>
    </div>
  </div>

  <!-- Section 2: Metadata queries to PostgreSQL replacing garbled 'queries / queries' -->
  <div style="position: absolute; z-index: 15; top: 430px; left: 815px;">
    <span style="font-size: 9px; font-weight: 800; color: #0284c7;">Metadata queries</span>
  </div>

  <!-- Section 3: NATS Telemetry via Prometheus exporter scraped by VMPodScrape -->
  <div class="glass-emerald" style="top: 520px; left: 432px; width: 142px; height: 22px; display: flex; align-items: center; justify-content: center; font-size: 7.5px; font-weight: 800; color: #047857;">Prometheus exporter (VMPodScrape)</div>

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

  <!-- 0. Redone Title Box: Clean Keynote Typography matching D1 and D3 -->
  <div class="diagram-title-box">
    <div class="diagram-title">Hermetiq BEP Ingest & PostgreSQL Partitioning Pipeline</div>
    <div class="diagram-subtitle">Partition-routed JetStream ingestion, 1:1 subscriber Deployments, 20 parent table sets, and GCS progress store</div>
  </div>

  <!-- 1. Bazel Clients: Directly in native container, no textbox -->
  <div class="direct-card" style="top: 118px; left: 78px; width: 195px;">
    <div class="card-title">Bazel clients</div>
    <div style="font-size: 8px; font-weight: 800; color: #0284c7; margin-top: 1px;">Build Event Protocol (BEP)</div>
    <div class="card-sub" style="font-size: 7.5px; margin-top: 2px;">
      invocation & build ID tracking<br>
      Direct gRPC stream to hermetiq-gateway
    </div>
  </div>

  <!-- 2. Delivery Guarantees: Directly in native container, no textbox -->
  <div class="direct-card" style="top: 284px; left: 78px; width: 415px;">
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

  <!-- NATS footer: Directly in native card container, no overlay textbox -->
  <div class="direct-card" style="top: 290px; left: 775px; width: 250px; text-align: center;">
    <div style="font-size: 9.5px; font-weight: 800; color: #3730a3;">File storage · RF3 (3 replicas)</div>
    <div style="font-size: 8.5px; font-weight: 700; color: #1e293b; margin-top: 2px;">Explicit ACK · 30m retention</div>
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

  <!-- 5. Redone Query API Node: Sleek 3D Frosted Glass Container with Dual Pod Replicas -->
  <div class="query-api-node">
    <div class="query-header">
      <div class="query-title">
        <span>Query API</span>
        <span style="font-size: 8.5px; font-weight: 700; color: #64748b;">· grpc-api</span>
      </div>
      <div class="deploy-badge">Deploy x2</div>
    </div>

    <!-- Dual Pod Replica Tier -->
    <div class="pod-grid">
      <div class="pod-card">
        <div class="pod-title">
          <span>grpc-api-0</span>
          <span class="status-dot"></span>
        </div>
        <div style="font-size: 6.5px; color: #64748b; margin-top: 1px;">Replica 1 · Ready</div>
      </div>
      <div class="pod-card">
        <div class="pod-title">
          <span>grpc-api-1</span>
          <span class="status-dot"></span>
        </div>
        <div style="font-size: 6.5px; color: #64748b; margin-top: 1px;">Replica 2 · Ready</div>
      </div>
    </div>

    <!-- Protocols & Ports -->
    <div class="port-row">
      <div class="port-chip">gRPC :50091</div>
      <div class="port-chip">REST :80 (:8008)</div>
      <div class="port-chip">MCP :5150</div>
    </div>

    <!-- Invariants & Responsibilities -->
    <div class="query-meta">
      <div class="invariant-badge">
        <span style="display: inline-block; width: 4px; height: 4px; background: #059669; border-radius: 50%;"></span>
        <span>Zero NATS dependency · Stateless tier</span>
      </div>
      <div style="color: #475569; font-weight: 600; margin-top: 2px;">
        Partition-pruned reads · PostgreSQL & GCS progress
      </div>
    </div>
  </div>

  <!-- 6. Cloud SQL Parent Table Stacks -->
  <div class="glass-pill" style="top: 390px; left: 402px; width: 126px; height: 22px; font-size: 8px;">invocations · targets · tests</div>
  <div class="glass-pill" style="top: 390px; left: 538px; width: 126px; height: 22px; font-size: 8px;">actions · logs · output_files</div>
  <div class="glass-pill" style="top: 390px; left: 672px; width: 132px; height: 22px; font-size: 8px;">cache_events · remote_exec</div>
  <div class="glass-pill" style="top: 390px; left: 816px; width: 135px; height: 22px; font-size: 8px;">progresses · 20 parent tables</div>

  <!-- 7. GCS Progress Store: Directly on native glass slab, seated down & right, ribs fully visible, no textbox -->
  <div class="direct-card" style="top: 391px; left: 1056px; width: 200px;">
    <div style="font-size: 11.5px; font-weight: 800; color: #0f172a; letter-spacing: -0.01em;">GCS progress store</div>
    <div style="font-size: 10px; font-weight: 800; color: #0369a1; margin-top: 5px;">per-project artifact bucket</div>
    <div style="font-size: 8.5px; line-height: 1.38; font-weight: 700; color: #1e293b; margin-top: 3px;">
      <span style="white-space: nowrap;">Async gzip protobuf chunks · Workload Identity</span><br>
      <code style="font-size: 7.5px; color: #0f172a; letter-spacing: -0.02em; white-space: nowrap;"><strong style="color: #0369a1;">progress/v1/</strong>&lt;project&gt;/&lt;inv&gt;/&lt;seq&gt;-&lt;chunk&gt;.pb.gz</code><br>
      <span style="font-weight: 800; color: #0284c7; white-space: nowrap;">grpc-api reads chunks directly · DB fallback</span>
    </div>
  </div>

  <!-- Clean label directly above the bottom blue fallback arrow (no oversized box) -->
  <div style="position: absolute; z-index: 15; top: 500px; left: 985px; width: 195px; text-align: center; background: transparent; pointer-events: none;">
    <span style="font-size: 8.5px; font-weight: 800; color: #0369a1; letter-spacing: -0.01em;">DB fallback (if GCS offline)</span>
  </div>

  <!-- 8. Control plane clean vector title and subtitle on native container -->
  <div style="position: absolute; z-index: 10; top: 563px; left: 334px; width: 130px; display: flex; flex-direction: column;">
    <span style="font-size: 10px; font-weight: 800; color: #0f172a; font-family: Inter, sans-serif; line-height: 1.2;">public.part_config</span>
    <span style="font-size: 7.5px; color: #334155; font-weight: 600; font-family: Inter, sans-serif; margin-top: 2px;">pg_partman source of truth</span>
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

  <!-- Gateway Router Icon Overlay -->
  <div style="position: absolute; z-index: 12; top: 144px; left: 508px; width: 22px; height: 22px; display: flex; align-items: center; justify-content: center; pointer-events: none;">
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#ffffff" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M4 14h6m4 0h6m-6-4l3 4-3 4m-4-8l-3 4 3 4"/>
      <circle cx="12" cy="14" r="2" fill="#ffffff"/>
    </svg>
  </div>

  <!-- Legend overrides: cyan = client request / REAPI, magenta = storage RPCs / data -->
  <div style="position: absolute; z-index: 15; top: 26px; left: 918px; height: 18px; display: flex; align-items: center; pointer-events: none;">
    <span style="font-size: 10px; color: #1e293b; font-weight: 700; line-height: 1; letter-spacing: -0.01em; white-space: nowrap;">client request / REAPI</span>
  </div>
  <div style="position: absolute; z-index: 15; top: 26px; left: 1086px; height: 18px; display: flex; align-items: center; pointer-events: none;">
    <span style="font-size: 10px; color: #1e293b; font-weight: 700; line-height: 1; letter-spacing: -0.01em; white-space: nowrap;">storage RPCs / data</span>
  </div>

  <!-- Gateway Routes Overlay (Direct Container Principle inside native pills) -->
  <div class="direct-card" style="top: 154px; left: 602px; width: 222px; height: 21px; display: flex; align-items: center; justify-content: center; font-size: 8.5px; font-weight: 700; color: #0f172a;">GRPCRoute · frontend-grpc :8980 (REAPI)</div>
  <div class="direct-card" style="top: 181px; left: 602px; width: 222px; height: 21px; display: flex; align-items: center; justify-content: center; font-size: 8.5px; font-weight: 700; color: #0f172a;">HTTPRoute · bb-browser (Web UI)</div>

  <!-- Gateway to ClusterIP HTTP/2 hop (crisp vector label + glowing SVG arrow) -->
  <div style="position: absolute; z-index: 15; top: 136px; left: 834px; width: 41px; height: 16px; display: flex; align-items: center; justify-content: center; background: transparent; pointer-events: none;">
    <span style="font-size: 9.5px; font-weight: 800; color: #0f172a; line-height: 1; letter-spacing: -0.02em;">HTTP/2</span>
  </div>
  <div style="position: absolute; z-index: 15; top: 153px; left: 833px; width: 43px; height: 24px; pointer-events: none;">
    <svg width="43" height="24" viewBox="0 0 43 24" fill="none" xmlns="http://www.w3.org/2000/svg">
      <defs>
        <filter id="cyan-glow-d3" x="-20%" y="-40%" width="140%" height="180%">
          <feDropShadow dx="0" dy="1" stdDeviation="2.2" flood-color="#38bdf8" flood-opacity="0.65"/>
        </filter>
        <linearGradient id="arrow-fill-d3" x1="0" y1="12" x2="41" y2="12" gradientUnits="userSpaceOnUse">
          <stop offset="0%" stop-color="#38bdf8"/>
          <stop offset="100%" stop-color="#0ea5e9"/>
        </linearGradient>
      </defs>
      <path d="M1 9.5 H26 V5 L40.5 12 L26 19 V14.5 H1 Z" fill="url(#arrow-fill-d3)" stroke="#0369a1" stroke-width="1.35" stroke-linejoin="round" filter="url(#cyan-glow-d3)"/>
      <line x1="2.5" y1="12" x2="27" y2="12" stroke="#bae6fd" stroke-width="1.4" stroke-dasharray="2.5 1.5" stroke-linecap="round"/>
    </svg>
  </div>

  <!-- Section 1: ClusterIP Services: Directly in native container, no textbox -->
  <div class="direct-card" style="top: 136px; left: 882px; width: 220px;">
    <div class="card-title">Kubernetes ClusterIP Services</div>
    <div style="font-size: 8px; font-weight: 800; color: #3730a3; margin-top: 1px;">L4 Routing Only · No TLS Termination</div>
    <div class="card-sub" style="margin-top: 2px;">
      frontend-grpc · REAPI :8980<br>
      bb-browser · Web UI :80<br>
      <span style="font-weight: 700; color: #334155;">Auth verified by app pods, not Services</span>
    </div>
  </div>

  <!-- Section 1: OIDC Provider: Directly in native container, no textbox -->
  <div class="direct-card" style="top: 136px; left: 1176px; width: 120px; text-align: center;">
    <div class="card-title" style="text-align: center;">OIDC Provider</div>
    <div style="font-size: 8px; font-weight: 800; color: #5b21b6; margin-top: 1px; text-align: center;">Auth & SSO (Control Plane)</div>
    <div class="card-sub" style="font-size: 7.5px; margin-top: 2px; text-align: center;">
      OIDC & JWKS verification<br>
      Secures UI, Grafana, gRPC, MCP<br>
      <span style="font-weight: 800; color: #4338ca;">App token verification</span>
    </div>
  </div>

  <!-- Section 2: bb-frontend execution connection -->
  <div class="glass-cyan" style="top: 444px; left: 742px; width: 166px; height: 36px; padding: 2px 6px; text-align: center; display: flex; flex-direction: column; justify-content: center;">
    <div style="font-size: 10px; font-weight: 800; color: #0369a1;">bb-frontend</div>
    <div style="font-size: 9px; font-weight: 700; color: #1e293b; margin-top: 2px;">Execute :8982 · CAS/AC :8981</div>
  </div>

  <!-- Section 2: bb-browser blobstore reads -->
  <div class="glass-cyan" style="top: 444px; left: 918px; width: 162px; height: 36px; padding: 2px 6px; text-align: center; display: flex; flex-direction: column; justify-content: center;">
    <div style="font-size: 10px; font-weight: 800; color: #0369a1;">bb-browser</div>
    <div style="font-size: 9px; font-weight: 700; color: #1e293b; margin-top: 2px;">Web UI :80 · Read-only CAS/AC</div>
  </div>

  <!-- Section 2: Storage RPCs category -->
  <div class="glass-ice" style="top: 510px; left: 785px; width: 250px; height: 36px; padding: 2px 6px; text-align: center; display: flex; flex-direction: column; justify-content: center;">
    <div style="font-size: 9.5px; font-weight: 800; color: #1d4ed8;">Storage RPCs :8981 (CAS · AC · FSAC)</div>
    <div style="font-size: 9px; font-weight: 700; color: #1e293b; margin-top: 2px;">Worker payloads · Direct gRPC data</div>
  </div>

  <!-- Section 2: bb-storage 3-shard cluster label replacing AI hallucinated caption -->
  <div style="position: absolute; z-index: 15; top: 524px; left: 1075px; width: 250px; text-align: center;">
    <div style="font-size: 11px; font-weight: 800; color: #0f172a; letter-spacing: -0.01em;">bb-storage (3-shard cluster)</div>
    <div style="font-size: 8px; font-weight: 700; color: #475569; margin-top: 2px;">CAS · AC · FSAC · Initial Size Class Cache (ISCC)</div>
  </div>

  <!-- Section 3: Worker Storage -->
  <div class="glass-rose" style="top: 641px; left: 450px; width: 122px; height: 32px; padding: 2px 4px; text-align: center; display: flex; flex-direction: column; justify-content: center;">
    <div style="font-size: 8px; font-weight: 800; color: #e11d48;">No Storage Pod Link</div>
    <div style="font-size: 6.5px; font-weight: 700; color: #1e293b; line-height: 1.2;">NVMe SSD or boot emptyDir</div>
  </div>

  <!-- Section 3: Worker Local Storage label -->
  <div style="position: absolute; z-index: 15; top: 658px; left: 195px; width: 135px; text-align: right;">
    <div style="font-size: 10px; font-weight: 800; color: #0f172a;">Worker Local Storage</div>
    <div style="font-size: 8px; font-weight: 700; color: #475569; margin-top: 1px;">NVMe SSD or boot emptyDir</div>
  </div>

  <!-- KEDA PromQL query badge over VictoriaMetrics -->
  <div class="glass-emerald" style="top: 636px; left: 660px; width: 110px; height: 34px; padding: 2px 4px; text-align: center;">
    <div style="font-size: 8px; font-weight: 800; color: #047857;">PromQL Backlog</div>
    <div style="font-size: 7px; font-weight: 700; color: #1e293b;">tasks_scheduled_total<br>scales bb-workers</div>
  </div>

  <!-- Section 3: VictoriaMetrics TSDB cluster label -->
  <div style="position: absolute; z-index: 15; top: 708px; left: 705px; width: 180px; text-align: center; background: transparent; pointer-events: none;">
    <div style="font-size: 10.5px; font-weight: 800; color: #0f172a;">VictoriaMetrics</div>
    <div style="font-size: 8px; font-weight: 700; color: #047857; margin-top: 1px;">TSDB cluster · REAPI metrics</div>
  </div>

  <!-- Section 3: Grafana dashboards label -->
  <div style="position: absolute; z-index: 15; top: 708px; left: 1100px; width: 220px; text-align: center; background: transparent; pointer-events: none;">
    <div style="font-size: 10.5px; font-weight: 800; color: #0f172a;">Grafana monitoring dashboards</div>
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
