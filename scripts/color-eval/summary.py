import csv, sys, statistics as st, math
rows=list(csv.DictReader(open(sys.argv[1])))
import os, json
if len(sys.argv)>3:
    data=os.environ.get("HT_EVAL_DATA", os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../DeveloperMedia"))
    allf=sorted(f for f in os.listdir(os.path.join(data, "samples/photo/raw-890")) if f.lower().endswith((".png",".jpg",".jpeg")))
    keep={f for i,f in enumerate(allf) if (i%2==1)==(sys.argv[3]=="dev")}
    rows=[r for r in rows if r["image"] in keep]
by={}
for r in rows: by.setdefault(r["variant"],{})[r["image"]]=r
imgs=sorted(by["original"].keys()); n=len(imgs)
print(f"images={n}")
V=["original","grayworld","current","restoration","combined","uniform"]
f=lambda r,k: float(r[k])
print("\n| variant | PSNR mean | SSIM mean | ΔE mean |")
for v in V:
    print(f"| {v} | {st.mean(f(by[v][i],'psnr') for i in imgs):.2f} | {st.mean(f(by[v][i],'ssim') for i in imgs):.3f} | {st.mean(f(by[v][i],'deltaE') for i in imgs):.2f} |")
print("\n| comparison | ΔE better | ΔE worse |")
for a,b in [("current","original"),("combined","original"),("combined","current"),("restoration","original")]:
    better=sum(f(by[a][i],'deltaE')<f(by[b][i],'deltaE') for i in imgs)
    print(f"| {a} vs {b} | {better} ({better*100/n:.0f}%) | {n-better} ({(n-better)*100/n:.0f}%) |")
# Bands use OKLab hue when the CSV has it: CIELAB hue cannot tell azure, blue, indigo and violet apart.
HAS_OK = "farHueOK" in rows[0]
HK, CK = ("farHueOK", "farChromaOK") if HAS_OK else ("farHue", "farChroma")
def band(h,c=99):
    if HAS_OK:
        if c<0.02: return "neutral(C<8)"
        if h<180: return "green(<180)"
        if h<235: return "cyan(180-235)"
        if h<270: return "blue(235-265)"
        if h<282: return "indigo(270-282)"
        return "violet(>=265)"
    if c<8: return "neutral(C<8)"
    if h<180: return "green(<180)"
    if h<235: return "cyan(180-235)"
    if h<265: return "blue(235-265)"
    return "violet(>=265)"
B=["neutral(C<8)","green(<180)","cyan(180-235)","blue(235-265)","indigo(270-282)","violet(>=265)"]
print("\nFar-region hue band (count of images):")
print("| variant | "+" | ".join(B)+" | nearRG mean | contrast L* mean |")
for v in V+["reference"]:
    c={b:0 for b in B}
    for i in imgs: c[band(f(by[v][i],HK),f(by[v][i],CK))]+=1
    print(f"| {v} | "+" | ".join(str(c[b]) for b in B)+f" | {st.mean(f(by[v][i],'nearRG') for i in imgs):.3f} | {st.mean(f(by[v][i],'contrastL') for i in imgs):.2f} |")
# green-source subset
g=[i for i in imgs if f(by["original"][i],'farHue')<180]
print(f"\nGreen-water sources (original far hue <180): {len(g)}")
for v in V+["reference"]:
    c={b:0 for b in B}
    for i in g: c[band(f(by[v][i],HK),f(by[v][i],CK))]+=1
    print(f"  {v}: "+", ".join(f"{b}={c[b]}" for b in B)+(f", ΔE={st.mean(f(by[v][i],'deltaE') for i in g):.2f}" if v!="reference" else ""))
o=by["original"]
fb=sum(o[i]["fallback"]=="1" for i in imgs)
ok=[i for i in imgs if o[i]["fallback"]=="0"]
q=lambda k:[f(o[i],k) for i in ok]
def pct(xs,p): xs=sorted(xs); return xs[int((len(xs)-1)*p)]
print(f"\nPhysical path fallback: {fb}/{n}")
for k in ["confidence","depthConf","waterConf","recR","floorPct","gainPct","betaDR","betaDG","betaDB"]:
    xs=q(k); print(f"  {k}: min={min(xs):.3f} p10={pct(xs,.1):.3f} median={pct(xs,.5):.3f} p90={pct(xs,.9):.3f} max={max(xs):.3f}")

# Machine-readable scorecard
XTRA=["meanL","localContrast","farLocalContrast","farChroma"]
HAS_X="localContrast" in rows[0]
if HAS_X:
    print("\nBrightness, haze and water colour (means):")
    print("| variant | meanL (brightness) | localContrast (higher = less haze) | farLocalContrast | farChroma (water colour strength) |")
    for v in V+["reference"]:
        print(f"| {v} | "+" | ".join(f"{st.mean(f(by[v][i],k) for i in imgs):.2f}" for k in XTRA)+" |")
def mean(v,k): return st.mean(f(by[v][i],k) for i in imgs)
def bands(v, subset):
    c={b:0 for b in B}
    for i in subset: c[band(f(by[v][i],HK),f(by[v][i],CK))]+=1
    return c
cmb=by["combined"]
score={"images":n,
 "variants":{v:{"psnr":mean(v,'psnr'),"ssim":mean(v,'ssim'),"deltaE":mean(v,'deltaE'),"contrastL":mean(v,'contrastL'),"nearRG":mean(v,'nearRG'),"farBands":bands(v,imgs),**({k:mean(v,k) for k in XTRA} if HAS_X else {})} for v in V},
 "reference":{"contrastL":mean("reference",'contrastL'),"nearRG":mean("reference",'nearRG'),"farBands":bands("reference",imgs),**({k:mean("reference",k) for k in XTRA} if HAS_X else {})},
 "combinedBetterThanOriginalPct":100*sum(f(cmb[i],'deltaE')<f(by["original"][i],'deltaE') for i in imgs)/n,
 "greenSubset":{"count":len(g),"combinedStillGreen":bands("combined",g)["green(<180)"],"referenceStillGreen":bands("reference",g)["green(<180)"],"combinedDeltaE":st.mean(f(cmb[i],'deltaE') for i in g) if g else None,"uniformStillGreen":bands("uniform",g)["green(<180)"]},
 "confidenceMedian":pct(q("confidence"),.5) if ok else None,
 "gainPctMedian":pct(q("gainPct"),.5) if ok else None,
 "fallbackCount":fb}
if len(sys.argv)>2: json.dump(score,open(sys.argv[2],"w"),indent=1)
