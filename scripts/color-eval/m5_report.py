#!/usr/bin/env python3
"""m5-specific evaluation annotations, never read by the production correction pipeline.

Patch interiors follow the tilted chart, excluding borders and the occluded bottom edge.
The target is an appearance reference, not certified chart colour ground truth.
"""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw


def lab(rgb):
    c = np.asarray(rgb, dtype=float) / 255
    c = np.where(c <= .04045, c / 12.92, ((c + .055) / 1.055) ** 2.4)
    xyz = c @ np.array([[.4124564, .2126729, .0193339],
                        [.3575761, .7151522, .1191920],
                        [.1804375, .0721750, .9503041]]) / [.95047, 1, 1.08883]
    f = np.where(xyz > (6 / 29) ** 3, np.cbrt(xyz), xyz / (3 * (6 / 29) ** 2) + 4 / 29)
    return np.stack((116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]),
                     200 * (f[..., 1] - f[..., 2])), axis=-1)


def annotations(size):
    w, h = size
    corners = np.array([[977, 874], [1046, 862], [1067, 901], [991, 913]], dtype=float)
    corners *= [w / 1600, h / 1066]

    def point(u, v):
        return (1-v)*((1-u)*corners[0]+u*corners[1])+v*((1-u)*corners[3]+u*corners[2])

    patches = {}
    for row, (v0, v1) in enumerate(((.06, .20), (.31, .44), (.59, .76)), 1):
        for col in range(6):
            u0, u1 = (col + .25) / 6, (col + .75) / 6
            patches[f"panel_r{row}c{col+1}"] = [tuple(point(u, v)) for u, v in
                                                ((u0,v0),(u1,v0),(u1,v1),(u0,v1))]
    for name, box in {"sand": (.70,.88,.85,.98), "water": (.06,.04,.30,.30),
                      "coral": (.34,.19,.83,.73)}.items():
        x0,y0,x1,y1 = box
        patches[name] = [(x0*w,y0*h),(x1*w,y0*h),(x1*w,y1*h),(x0*w,y1*h)]
    return patches


def measure(rgb, target, patches):
    out = {}
    a, b = lab(rgb), lab(target)
    # Local high-pass chroma: a repeatable noise proxy, not a sensor-noise estimate.
    residual = a[1:-1,1:-1] - (a[:-2,1:-1]+a[2:,1:-1]+a[1:-1,:-2]+a[1:-1,2:])/4
    for name, polygon in patches.items():
        mask = Image.new("1", (rgb.shape[1], rgb.shape[0]))
        ImageDraw.Draw(mask).polygon(polygon, fill=1)
        mask = np.asarray(mask, dtype=bool)
        x, y = a[mask], b[mask]
        error = np.linalg.norm(x-y, axis=-1)
        out[name] = {"deltaE76": float(error.mean()), "p90": float(np.percentile(error,90)),
                     "L": float(x[:,0].mean()), "targetL": float(y[:,0].mean()),
                     "medianLab": np.median(x,axis=0).tolist(),
                     "chroma": float(np.linalg.norm(np.median(x,axis=0)[1:])),
                     "blackPct": float(np.mean(np.max(rgb[mask],axis=-1)<=3)*100),
                     "chromaNoise": float(np.median(np.linalg.norm(residual[mask[1:-1,1:-1]][:,1:],axis=-1))),
                     "detail": float(np.median(np.abs(residual[mask[1:-1,1:-1]][:,0])))}
    out["full"] = {"deltaE76": float(np.linalg.norm(a-b,axis=-1).mean()),
                   "L": float(a[...,0].mean()), "targetL": float(b[...,0].mean())}
    errors = [out[n]["deltaE76"] for n in patches if n.startswith("panel")]
    out["panel"] = {"deltaE76": float(np.mean(errors)), "worstPatch": float(np.max(errors))}
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("render", type=Path)
    parser.add_argument("--baseline", type=Path)
    args = parser.parse_args()
    target = Image.open(args.render / "m5__reference.png").convert("RGB")
    patches = annotations(target.size)
    annotated = target.copy()
    draw = ImageDraw.Draw(annotated)
    for polygon in patches.values():
        draw.polygon(polygon, outline="red", width=1)
    annotated.save(args.render / "m5_regions.png")
    results = {}
    for label, folder in [("baseline", args.baseline), ("candidate", args.render)]:
        if folder is None:
            continue
        results[label] = {}
        for variant in ("original", "current", "combined", "uniform"):
            im = Image.open(folder / f"m5__{variant}.png").convert("RGB")
            if im.size != target.size:
                raise ValueError("Baseline and candidate must have identical dimensions")
            results[label][variant] = measure(np.asarray(im), np.asarray(target), patches)
            metrics = results[label][variant]
            print(f"{label}/{variant}: " + " | ".join(f"{n} dE={metrics[n]['deltaE76']:.2f}"
                   for n in ("full", "panel", "sand", "coral", "water")))
    (args.render / "m5_metrics.json").write_text(json.dumps(results, indent=2)+"\n")
    print("\nPanel patches (CIE76 mean; not certified chart ground truth):")
    for name in patches:
        if not name.startswith("panel"):
            continue
        vals = [f"{label}={data['combined'][name]['deltaE76']:.2f}" for label,data in results.items()]
        print(f"{name}: " + " -> ".join(vals))
    if args.baseline:
        print("\nRegressions are reported individually; a lower average is not a full acceptance:")
        for variant in ("current", "combined", "uniform"):
            old, new = results["baseline"][variant], results["candidate"][variant]
            worse = [n for n in patches if n.startswith("panel") and new[n]["deltaE76"] > old[n]["deltaE76"] + 1]
            print(f"{variant}: panel patches worse by >1 dE: {', '.join(worse) or 'none'}")
            for region in ("sand", "water", "coral"):
                print(f"  {region}: chroma noise {old[region]['chromaNoise']:.3f}->{new[region]['chromaNoise']:.3f}; "
                      f"black % {old[region]['blackPct']:.2f}->{new[region]['blackPct']:.2f}")
    # Show both the complete photograph and the small chart at a readable scale.
    entries = [("original", args.render / "m5__original.png")]
    if args.baseline:
        entries.append(("baseline", args.baseline / "m5__combined.png"))
    entries += [("candidate", args.render / "m5__combined.png"), ("reference", args.render / "m5__reference.png")]
    sheet = Image.new("RGB", (640*len(entries), 640), "#202020")
    d = ImageDraw.Draw(sheet)
    for i,(label,path) in enumerate(entries):
        im=Image.open(path).convert("RGB")
        sheet.paste(im.resize((640,426)), (i*640,24))
        w,h=im.size
        chart=im.crop((int(.60*w),int(.795*h),int(.675*w),int(.87*h)))
        chart.thumbnail((320,180)); chart=chart.resize((270,180))
        sheet.paste(chart, (i*640+185,455))
        d.text((i*640+12,5),label,fill="white")
    sheet.save(args.render / "m5_comparison.png")


if __name__ == "__main__":
    main()
