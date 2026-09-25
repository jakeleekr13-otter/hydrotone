import csv, json, sys, os, math
from PIL import Image, ImageDraw
import numpy as np
O = sys.argv[1]
def load(p):
    rows = {}
    for r in csv.DictReader(open(p)): rows.setdefault(r["image"], {})[r["variant"]] = r
    return rows
def f(r, k): return float(r[k])
def table(title, rows, names=None):
    print(f"\n== {title}")
    print("| image | dE orig -> ours (video path) | meanL ours/ref | localContrast ours/ref | Lab farHue ours/ref (orig) | farChroma ours/ref | nearRG ours/ref | OKLab water hue ours/ref (orig) |")
    for k in (names or sorted(rows)):
        if k not in rows or k.startswith("n_"): continue
        v = rows[k]; o, c, u, r = v["original"], v["combined"], v.get("uniform", v["combined"]), v["reference"]
        print(f"| {k} | {f(o,'deltaE'):.1f} -> {f(c,'deltaE'):.1f} ({f(u,'deltaE'):.1f}) | {f(c,'meanL'):.1f}/{f(r,'meanL'):.1f} | {f(c,'localContrast'):.2f}/{f(r,'localContrast'):.2f} | "
              f"{f(c,'farHue'):.0f}/{f(r,'farHue'):.0f} ({f(o,'farHue'):.0f}) | {f(c,'farChroma'):.1f}/{f(r,'farChroma'):.1f} | {f(c,'nearRG'):.2f}/{f(r,'nearRG'):.2f} |"
              + (f" {f(c,'farHueOK'):.0f}/{f(r,'farHueOK'):.0f} ({f(o,'farHueOK'):.0f}) |" if 'farHueOK' in c else ""))
def lab_chroma(p):
    a = np.asarray(Image.open(p).convert("RGB")).astype(np.float64) / 255
    lin = np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)
    M = np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]])
    xyz = lin @ M.T / np.array([0.95047, 1.0, 1.08883])
    fx = np.where(xyz > 0.008856, np.cbrt(xyz), 7.787 * xyz + 16 / 116)
    A = 500 * (fx[..., 0] - fx[..., 1]); B = 200 * (fx[..., 1] - fx[..., 2])
    return float(np.sqrt(A * A + B * B).max()), float(np.sqrt(A * A + B * B).mean())
def sheet(folder, names, cols, out, W=240):
    rows = []
    for n in names:
        stem = n.rsplit(".", 1)[0]
        ims = []
        for _, v in cols:
            p = f"{folder}/{stem}__{v}.jpg"
            if os.path.exists(p): ims.append(Image.open(p).convert("RGB"))
        if not ims: continue
        h = int(ims[0].height * W / ims[0].width); rows.append([i.resize((W, h)) for i in ims])
    if not rows: return
    H = sum(r[0].height for r in rows) + 18
    sh = Image.new("RGB", (W * len(cols), H), "white"); d = ImageDraw.Draw(sh)
    for i, (t, _) in enumerate(cols): d.text((i * W + 5, 3), t, fill="black")
    y = 18
    for r in rows:
        for i, im in enumerate(r): sh.paste(im, (i * W, y))
        y += r[0].height
    sh.save(out, quality=88)
cols = [("before", "original"), ("ours", "combined"), ("ours (video path)", "uniform"), ("target", "reference")]
m = load(f"{O}/market.csv"); b = load(f"{O}/bmw.csv")
table("MARKET target pairs (ref = market 'after'; m3 is a creative mood grade; m5 and m6 are Sea-thru results)", m, ["m1.png", "m2.png", "m3.png", "m4.png", "m5.png", "m6.png"])
bmw = [l.strip() for l in open(os.path.join(os.path.dirname(__file__), "bmw_names.txt")) if l.strip()]
table("UIEB best/middle/worst (ref = UIEB reference)", b, bmw)
if os.path.exists(f"{O}/real.csv"):
    rr = load(f"{O}/real.csv")
    print("\n== REAL user dive photos (no reference). r01-r13 are blue or deep-blue scenes. r14 and r15 are the user's GREEN/TEAL examples: r14 has teal sand under deep blue water, r15 is a diver in teal water; both must move toward clear cyan-blue water with natural skin/subject colour (the committed code leaves r15 almost unchanged and pushes r14's upper water to indigo, hue 292). Aim: water OKLab hue about 215-265 (cyan to blue; indigo 270-282 and violet >=282 are failures), water chroma natural (roughly 15-35, not neon), subject nearRG up toward 0.9-1.1. r04 has a real magenta anemone: keep it magenta. r10 is a bright backlit sun scene.")
    print("| image | water OKLab hue orig -> ours (video) [cyan <235, blue 235-270, indigo 270-282, violet >=282] | farChroma orig -> ours | nearRG orig -> ours | meanL orig -> ours | localContrast orig -> ours |")
    for k in sorted(rr):
        v = rr[k]; o, c, u = v["original"], v["combined"], v.get("uniform", v["combined"])
        ok = "farHueOK" in o
        hk = 'farHueOK' if ok else 'farHue'
        print(f"| {k} | {f(o,hk):.0f} -> {f(c,hk):.0f} ({f(u,hk):.0f}) | {f(o,'farChroma'):.1f} -> {f(c,'farChroma'):.1f} | {f(o,'nearRG'):.2f} -> {f(c,'nearRG'):.2f} | {f(o,'meanL'):.1f} -> {f(c,'meanL'):.1f} | {f(o,'localContrast'):.2f} -> {f(c,'localContrast'):.2f} |")
    sheet(f"{O}/real", sorted(rr), [("before", "original"), ("ours", "combined"), ("ours (video path)", "uniform")], f"{O}/real_sheet.jpg", W=300)
# Neutral surfaces: regions that should be colourless after correction (per-channel median in a fixed box).
def ok_chroma(rgb):
    a = np.asarray(rgb, dtype=np.float64) / 255
    lin = np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)
    l = np.cbrt(lin @ np.array([0.4122214708, 0.5363325363, 0.0514459929]))
    mm = np.cbrt(lin @ np.array([0.2119034982, 0.6806995451, 0.1073969566]))
    ss = np.cbrt(lin @ np.array([0.0883024619, 0.2817188376, 0.6299787005]))
    A = 1.9779984951 * l - 2.4285922050 * mm + 0.4505937099 * ss
    B = 0.0259040371 * l + 0.7827717662 * mm - 0.8086757660 * ss
    return float(np.hypot(A, B))
NEUTRAL = [("m5", "sand", (0.70, 0.88, 0.85, 0.98)), ("m5", "chart grey row (approx.)", (0.618, 0.839, 0.663, 0.849)),
           ("m6", "manta belly", (0.44, 0.38, 0.56, 0.50))]
if all(os.path.exists(f"{O}/market/{k}__original.jpg") for k, _, _ in NEUTRAL):
    print("\n== NEUTRAL SURFACES (OKLab chroma of the box median; 0 = colourless; Sea-thru = the market 'after')")
    print("| surface | original | ours | ours (video path) | Sea-thru |")
    for k, name, (x0, y0, x1, y1) in NEUTRAL:
        vals = []
        for v in ["original", "combined", "uniform", "reference"]:
            im = Image.open(f"{O}/market/{k}__{v}.jpg").convert("RGB"); w, h = im.size
            box = np.asarray(im.crop((int(x0 * w), int(y0 * h), int(x1 * w), int(y1 * h)))).reshape(-1, 3)
            vals.append(ok_chroma(np.median(box, axis=0)))
        print(f"| {k} {name} | " + " | ".join(f"{x:.3f}" for x in vals) + " |")
mx, mean = lab_chroma(f"{O}/market/n_grey__combined.jpg"); ux, umean = lab_chroma(f"{O}/market/n_grey__uniform.jpg")
print(f"\n== NEUTRAL grey ramp: max Lab chroma ours {mx:.2f} (mean {mean:.2f}), video path {ux:.2f} (mean {umean:.2f}). Must stay below about 3.")
d = json.load(open(f"{O}/scores.json")); c = d["variants"]["combined"]; u = d["variants"]["uniform"]
print(f"\n== DEV scorecard (40 images; commit f548c29 = dE 20.70 / uniform 20.16 / violet 12 / green left 1 of 6)")
print(f"dE {c['deltaE']:.2f} | uniform {u['deltaE']:.2f} | violet {c['farBands']['violet(>=265)']} indigo {c['farBands'].get('indigo(270-282)','n/a')} | green left {d['greenSubset']['combinedStillGreen']} of {d['greenSubset']['count']} | "
      f"meanL {c['meanL']:.1f} | localContrast {c['localContrast']:.2f} | farChroma {c['farChroma']:.1f} | beats original {d['combinedBetterThanOriginalPct']:.0f}%")
sheet(f"{O}/market", ["m1.png", "m2.png", "m3.png", "m4.png", "m5.png", "m6.png", "n_grey.png"], cols, f"{O}/market_sheet.jpg")
sheet(f"{O}/bmw", bmw, cols, f"{O}/bmw_sheet.jpg")
print(f"\nSheets: {O}/market_sheet.jpg, {O}/bmw_sheet.jpg, {O}/real_sheet.jpg, dev sheet images in {O}/dev/")
