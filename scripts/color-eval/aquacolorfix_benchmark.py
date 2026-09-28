#!/usr/bin/env python3
"""Compare HydroTone and AquaColorFix exports made from the same source images.

The benchmark is descriptive: AquaColorFix is a product target, not ground truth.
Metrics therefore explain the visual gap; they do not declare either output correct.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
import tempfile
from dataclasses import asdict, dataclass
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageOps


REFERENCE_MAP = {4: "DeveloperMedia/market/ref/m6.png"}


@dataclass
class Metrics:
    mean_l: float
    p10_l: float
    median_l: float
    p90_l: float
    contrast_l: float
    local_contrast: float
    mean_ok_chroma: float
    water_hue: float
    water_chroma: float
    neutral_l: float
    neutral_chroma: float
    subject_a: float
    shadow_clip_pct: float
    highlight_clip_pct: float
    detail_energy: float


def load_rgb(path: Path, size: tuple[int, int]) -> np.ndarray:
    with Image.open(path) as image:
        image = ImageOps.exif_transpose(image).convert("RGB")
        if image.size != size:
            image = image.resize(size, Image.Resampling.LANCZOS)
        return np.asarray(image, dtype=np.float32) / 255.0


def srgb_to_linear(rgb: np.ndarray) -> np.ndarray:
    return np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)


def linear_to_lab(rgb: np.ndarray) -> np.ndarray:
    x = (0.4124 * rgb[..., 0] + 0.3576 * rgb[..., 1] + 0.1805 * rgb[..., 2]) / 0.95047
    y = 0.2126 * rgb[..., 0] + 0.7152 * rgb[..., 1] + 0.0722 * rgb[..., 2]
    z = (0.0193 * rgb[..., 0] + 0.1192 * rgb[..., 1] + 0.9505 * rgb[..., 2]) / 1.08883
    xyz = np.stack((x, y, z), axis=-1)
    f = np.where(xyz > 0.008856, np.cbrt(xyz), 7.787 * xyz + 16 / 116)
    return np.stack((116 * f[..., 1] - 16,
                     500 * (f[..., 0] - f[..., 1]),
                     200 * (f[..., 1] - f[..., 2])), axis=-1)


def linear_to_oklab(rgb: np.ndarray) -> np.ndarray:
    l = np.cbrt(np.maximum(0, 0.4122214708 * rgb[..., 0] + 0.5363325363 * rgb[..., 1]
                              + 0.0514459929 * rgb[..., 2]))
    m = np.cbrt(np.maximum(0, 0.2119034982 * rgb[..., 0] + 0.6806995451 * rgb[..., 1]
                              + 0.1073969566 * rgb[..., 2]))
    s = np.cbrt(np.maximum(0, 0.0883024619 * rgb[..., 0] + 0.2817188376 * rgb[..., 1]
                              + 0.6299787005 * rgb[..., 2]))
    return np.stack((0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                     1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                     0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s), axis=-1)


def watermark_mask(height: int, width: int) -> np.ndarray:
    mask = np.ones((height, width), dtype=bool)
    mask[int(height * 0.84):, int(width * 0.72):] = False
    return mask


def scene_masks(reference_srgb: np.ndarray, valid: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    linear = srgb_to_linear(reference_srgb)
    luminance = 0.2126 * linear[..., 0] + 0.7152 * linear[..., 1] + 0.0722 * linear[..., 2]
    lit = valid & (luminance > 0.015) & (luminance < 0.85)
    redness = linear[..., 0] / np.maximum(1e-4, linear[..., 1] + linear[..., 2])
    water_cut = np.percentile(redness[lit], 33) if np.any(lit) else 0
    water = lit & (redness <= water_cut)

    oklab = linear_to_oklab(linear)
    chroma = np.hypot(oklab[..., 1], oklab[..., 2])
    bright_cut = np.percentile(luminance[lit], 80) if np.any(lit) else 1
    water_chroma = float(np.mean(chroma[water])) if np.any(water) else 0.1
    neutral = lit & ~water & (luminance >= bright_cut) & (chroma <= min(0.2, water_chroma * 1.1))
    if np.count_nonzero(neutral) < max(16, np.count_nonzero(valid) // 1000):
        candidates = lit & ~water & (luminance >= bright_cut)
        if np.any(candidates):
            fallback = np.percentile(chroma[candidates], 40)
            neutral = candidates & (chroma <= fallback)
    subject = lit & ~water & ~neutral
    return water, neutral, subject


def block_contrast(lstar: np.ndarray, valid: np.ndarray, block: int = 24) -> float:
    values: list[float] = []
    height, width = lstar.shape
    for y in range(0, height - block + 1, block):
        for x in range(0, width - block + 1, block):
            mask = valid[y:y + block, x:x + block]
            if np.mean(mask) > 0.9:
                values.append(float(np.std(lstar[y:y + block, x:x + block][mask])))
    return float(np.mean(values)) if values else 0


def metrics(srgb: np.ndarray, valid: np.ndarray, water: np.ndarray,
            neutral: np.ndarray, subject: np.ndarray) -> Metrics:
    linear = srgb_to_linear(srgb)
    lab = linear_to_lab(linear)
    oklab = linear_to_oklab(linear)
    lstar = lab[..., 0]
    chroma = np.hypot(oklab[..., 1], oklab[..., 2])
    hue = (np.degrees(np.arctan2(oklab[..., 2], oklab[..., 1])) + 360) % 360
    shown = srgb.max(axis=-1)

    # Mean absolute Laplacian on L*: a combined detail/noise indicator, not a sharpness score.
    laplacian = np.zeros_like(lstar)
    laplacian[1:-1, 1:-1] = np.abs(4 * lstar[1:-1, 1:-1]
                                           - lstar[:-2, 1:-1] - lstar[2:, 1:-1]
                                           - lstar[1:-1, :-2] - lstar[1:-1, 2:])
    water_vector = np.mean(oklab[water, 1:3], axis=0) if np.any(water) else np.zeros(2)
    water_hue = (math.degrees(math.atan2(float(water_vector[1]), float(water_vector[0]))) + 360) % 360
    q10, median, q90 = np.percentile(lstar[valid], (10, 50, 90))
    return Metrics(
        mean_l=float(np.mean(lstar[valid])), p10_l=float(q10), median_l=float(median), p90_l=float(q90),
        contrast_l=float(np.std(lstar[valid])), local_contrast=block_contrast(lstar, valid),
        mean_ok_chroma=float(np.mean(chroma[valid])), water_hue=float(water_hue),
        water_chroma=float(np.linalg.norm(water_vector)),
        neutral_l=float(np.mean(lstar[neutral])) if np.any(neutral) else float("nan"),
        neutral_chroma=float(np.mean(chroma[neutral])) if np.any(neutral) else float("nan"),
        subject_a=float(np.mean(oklab[subject, 1])) if np.any(subject) else float("nan"),
        shadow_clip_pct=float(np.mean(shown[valid] <= 1 / 255) * 100),
        highlight_clip_pct=float(np.mean(shown[valid] >= 254 / 255) * 100),
        detail_energy=float(np.mean(laplacian[valid])),
    )


def median_channel_gain(source: np.ndarray, output: np.ndarray, valid: np.ndarray) -> list[float]:
    source_linear, output_linear = srgb_to_linear(source), srgb_to_linear(output)
    usable = valid & (source_linear.min(axis=-1) > 0.004) & (output_linear.max(axis=-1) < 0.98)
    gains = []
    for channel in range(3):
        ratio = output_linear[..., channel][usable] / np.maximum(0.004, source_linear[..., channel][usable])
        gains.append(float(np.median(ratio)) if len(ratio) else float("nan"))
    return gains


def global_mapping_rmse(source: np.ndarray, output: np.ndarray, valid: np.ndarray, seed: int) -> float:
    """Cross-validated error of a global quadratic RGB mapping, in 8-bit code values."""
    pixels = source.reshape(-1, 3)
    target = output.reshape(-1, 3)
    usable = valid.ravel() & (pixels.max(axis=1) > 0.02) & (pixels.min(axis=1) < 0.98)
    pixels, target = pixels[usable], target[usable]
    features = np.column_stack((np.ones(len(pixels)), pixels, pixels * pixels,
                                pixels[:, 0] * pixels[:, 1], pixels[:, 0] * pixels[:, 2],
                                pixels[:, 1] * pixels[:, 2]))
    generator = np.random.default_rng(seed)
    indices = generator.permutation(len(pixels))[:min(100_000, len(pixels))]
    cut = max(1, int(len(indices) * 0.7))
    train, test = indices[:cut], indices[cut:]
    coefficients = np.linalg.lstsq(features[train], target[train], rcond=None)[0]
    predicted = np.clip(features[test] @ coefficients, 0, 1)
    return float(np.sqrt(np.mean((predicted - target[test]) ** 2)) * 255)


def fit_size(path: Path, maximum: int) -> tuple[int, int]:
    with Image.open(path) as image:
        width, height = ImageOps.exif_transpose(image).size
    scale = min(1.0, maximum / max(width, height))
    return max(2, round(width * scale)), max(2, round(height * scale))


def find_export(folder: Path, prefix: str, number: int) -> Path:
    matches = sorted(path for path in folder.glob(f"{prefix}{number}.*") if path.suffix.lower() in {".jpg", ".jpeg"})
    if len(matches) != 1:
        raise RuntimeError(f"Expected one {prefix}{number} export, found: {matches}")
    return matches[0]


def heatmap(delta_e: np.ndarray, valid: np.ndarray) -> Image.Image:
    level = np.clip(delta_e / 35, 0, 1)
    rgb = np.stack((np.minimum(1, level * 2), np.clip(level * 2 - 0.5, 0, 1), np.zeros_like(level)), axis=-1)
    rgb[~valid] = 0
    return Image.fromarray(np.uint8(np.clip(rgb, 0, 1) * 255))


def cell(image: Image.Image | None, width: int = 360, height: int = 270) -> Image.Image:
    canvas = Image.new("RGB", (width, height), "#111111")
    if image is None:
        draw = ImageDraw.Draw(canvas)
        draw.text((12, 12), "Source unavailable", fill="white", font=ImageFont.load_default())
        return canvas
    image = image.copy().convert("RGB")
    image.thumbnail((width, height), Image.Resampling.LANCZOS)
    canvas.paste(image, ((width - image.width) // 2, (height - image.height) // 2))
    return canvas


def make_sheet(rows: list[tuple[int, Path | None, Path, Path, Image.Image]], output: Path) -> None:
    labels = ["Source", "HydroTone", "AquaColorFix", "DeltaE H vs A"]
    cell_width, cell_height, header, row_label = 360, 270, 28, 24
    sheet = Image.new("RGB", (cell_width * 4, header + len(rows) * (cell_height + row_label)), "white")
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.load_default()
    for index, label in enumerate(labels):
        draw.text((index * cell_width + 8, 8), label, fill="black", font=font)
    y = header
    for number, source_path, hydro_path, aqua_path, difference in rows:
        draw.text((8, y + 6), f"Pair {number}", fill="black", font=font)
        y += row_label
        paths = [source_path, hydro_path, aqua_path]
        for index, path in enumerate(paths):
            image = None if path is None else ImageOps.exif_transpose(Image.open(path)).convert("RGB")
            sheet.paste(cell(image, cell_width, cell_height), (index * cell_width, y))
            if image is not None:
                image.close()
        sheet.paste(cell(difference, cell_width, cell_height), (cell_width * 3, y))
        y += cell_height
    sheet.save(output, quality=92)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", type=Path, default=Path("DeveloperMedia/aquacolorfix"))
    parser.add_argument("--output", type=Path,
                        default=Path(tempfile.gettempdir()) / "hydrotone-aquacolorfix-benchmark")
    parser.add_argument("--max-dimension", type=int, default=960)
    parser.add_argument("--hydro-files", default=None,
                        help="Score these files instead of the H exports. A pattern with {n} for the pair number, "
                             "for example a harness sheet folder: /out/sheet/p{n}__combined.jpg")
    parser.add_argument("--label", default="HydroTone", help="Name of the candidate in the report")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    data = (repo / args.data).resolve() if not args.data.is_absolute() else args.data
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)

    records: list[dict[str, object]] = []
    sheet_rows: list[tuple[int, Path | None, Path, Path, Image.Image]] = []
    for number in range(1, 6):
        hydro_path = Path(args.hydro_files.format(n=number)) if args.hydro_files else find_export(data, "H", number)
        if not hydro_path.exists():
            raise RuntimeError(f"Candidate for pair {number} not found: {hydro_path}")
        aqua_path = find_export(data, "A", number)
        source_path = find_export(data, "O", number)
        size = fit_size(aqua_path, args.max_dimension)
        hydro, aqua = load_rgb(hydro_path, size), load_rgb(aqua_path, size)
        source = load_rgb(source_path, size)
        valid = watermark_mask(size[1], size[0])
        mask_reference = source if source is not None else (hydro + aqua) / 2
        water, neutral, subject = scene_masks(mask_reference, valid)
        hm, am = metrics(hydro, valid, water, neutral, subject), metrics(aqua, valid, water, neutral, subject)
        hydro_lab, aqua_lab = linear_to_lab(srgb_to_linear(hydro)), linear_to_lab(srgb_to_linear(aqua))
        delta = np.linalg.norm(hydro_lab - aqua_lab, axis=-1)
        record: dict[str, object] = {
            "pair": number, "source": str(source_path.relative_to(repo)),
            "hydro_file": hydro_path.name, "aqua_file": aqua_path.name,
            "mean_delta_e_h_to_a": float(np.mean(delta[valid])),
            "p90_delta_e_h_to_a": float(np.percentile(delta[valid], 90)),
            "hydro": asdict(hm), "aqua": asdict(am),
        }
        record["hydro_gain_rgb"] = median_channel_gain(source, hydro, valid)
        record["aqua_gain_rgb"] = median_channel_gain(source, aqua, valid)
        source_lab = linear_to_lab(srgb_to_linear(source))
        record["mean_delta_e_source_to_h"] = float(np.mean(np.linalg.norm(source_lab - hydro_lab, axis=-1)[valid]))
        record["mean_delta_e_source_to_a"] = float(np.mean(np.linalg.norm(source_lab - aqua_lab, axis=-1)[valid]))
        record["global_mapping_rmse_h"] = global_mapping_rmse(source, hydro, valid, number * 10 + 1)
        record["global_mapping_rmse_a"] = global_mapping_rmse(source, aqua, valid, number * 10 + 2)
        reference_path = repo / REFERENCE_MAP[number] if number in REFERENCE_MAP else None
        if reference_path and reference_path.exists():
            reference_lab = linear_to_lab(srgb_to_linear(load_rgb(reference_path, size)))
            record["mean_delta_e_reference_to_h"] = float(np.mean(np.linalg.norm(reference_lab - hydro_lab, axis=-1)[valid]))
            record["mean_delta_e_reference_to_a"] = float(np.mean(np.linalg.norm(reference_lab - aqua_lab, axis=-1)[valid]))
        records.append(record)
        sheet_rows.append((number, source_path, hydro_path, aqua_path, heatmap(delta, valid)))

    with (output / "benchmark.json").open("w", encoding="utf-8") as handle:
        json.dump(records, handle, ensure_ascii=False, indent=2, allow_nan=True)

    metric_names = list(asdict(Metrics(*([0] * 15))).keys())
    with (output / "benchmark.csv").open("w", encoding="utf-8", newline="") as handle:
        fields = ["pair", "source", "hydro_file", "aqua_file", "mean_delta_e_h_to_a", "p90_delta_e_h_to_a",
                  "mean_delta_e_source_to_h", "mean_delta_e_source_to_a", "global_mapping_rmse_h",
                  "global_mapping_rmse_a", "mean_delta_e_reference_to_h", "mean_delta_e_reference_to_a"]
        fields += [f"hydro_{name}" for name in metric_names] + [f"aqua_{name}" for name in metric_names]
        fields += ["hydro_gain_r", "hydro_gain_g", "hydro_gain_b", "aqua_gain_r", "aqua_gain_g", "aqua_gain_b"]
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for record in records:
            row = {key: record.get(key, "") for key in fields}
            for app in ("hydro", "aqua"):
                for name, value in record[app].items():
                    row[f"{app}_{name}"] = value
            for app in ("hydro", "aqua"):
                for channel, value in zip("rgb", record.get(f"{app}_gain_rgb", ["", "", ""])):
                    row[f"{app}_gain_{channel}"] = value
            writer.writerow(row)

    make_sheet(sheet_rows, output / "comparison.jpg")
    def mean(app: str, name: str) -> float:
        return float(np.mean([record[app][name] for record in records]))

    report = [
        "# AquaColorFix benchmark", "",
        "AquaColorFix is treated as a product-look target, not ground truth. Every pair contains the same",
        "full-resolution source (`On`), HydroTone output (`Hn`) and AquaColorFix output (`An`). The",
        "AquaColorFix watermark area is excluded from every image with the same mask.", "",
        "| Pair | mean ΔE H→A | mean L* H/A | neutral C H/A | water hue H/A | detail energy H/A |",
        "|---:|---:|---:|---:|---:|---:|",
    ]
    for record in records:
        h, a = record["hydro"], record["aqua"]
        report.append(f"| {record['pair']} | {record['mean_delta_e_h_to_a']:.2f} | "
                      f"{h['mean_l']:.1f}/{a['mean_l']:.1f} | {h['neutral_chroma']:.3f}/{a['neutral_chroma']:.3f} | "
                      f"{h['water_hue']:.0f}°/{a['water_hue']:.0f}° | {h['detail_energy']:.2f}/{a['detail_energy']:.2f} |")
    report += ["", "## Aggregate", "",
               f"- Mean output gap: ΔE76 {np.mean([r['mean_delta_e_h_to_a'] for r in records]):.2f}.",
               f"- AquaColorFix mean lightness is {mean('aqua', 'mean_l') - mean('hydro', 'mean_l'):+.1f} L* versus HydroTone.",
               f"- AquaColorFix neutral-candidate chroma is {(mean('aqua', 'neutral_chroma') / mean('hydro', 'neutral_chroma') - 1) * 100:+.1f}% versus HydroTone.",
               f"- AquaColorFix fine-detail/noise energy is {(mean('aqua', 'detail_energy') / mean('hydro', 'detail_energy') - 1) * 100:+.1f}% versus HydroTone.",
               "- Detail energy combines real detail, sharpening halos and noise; higher is not automatically better.",
               "- Bright-neutral and water masks come from the shared source where available and are heuristic.", ""]
    if "mean_delta_e_reference_to_h" in records[3]:
        pair = records[3]
        report += ["## Independent reference", "",
                   "Pair 4 also has the existing market reference `DeveloperMedia/market/ref/m6.png`.",
                   f"HydroTone is ΔE76 {pair['mean_delta_e_reference_to_h']:.2f} from it; "
                   f"AquaColorFix is {pair['mean_delta_e_reference_to_a']:.2f} from it.", ""]
    report += ["## Global mapping diagnostic", "",
               "A quadratic global RGB transform is fitted on 70% of source pixels and checked on the rest.",
               "An error around 5–8 code values means most of the output is explainable without a spatial or depth model.", "",
               "| Pair | HydroTone RMSE | AquaColorFix RMSE |", "|---:|---:|---:|"]
    for record in records:
        if "global_mapping_rmse_h" in record:
            report.append(f"| {record['pair']} | {record['global_mapping_rmse_h']:.2f} | {record['global_mapping_rmse_a']:.2f} |")
    report.append("")
    (output / "report.md").write_text("\n".join(report), encoding="utf-8")
    gate = [r for r in records if r["pair"] in (2, 4, 5)]
    print(f"{args.label}: mean dE H->A {np.mean([r['mean_delta_e_h_to_a'] for r in records]):.2f} | "
          f"gate pairs 2,4,5 {np.mean([r['mean_delta_e_h_to_a'] for r in gate]):.2f} | "
          + " ".join(f"p{r['pair']}={r['mean_delta_e_h_to_a']:.2f}" for r in records) + " | "
          f"neutral C {mean('hydro', 'neutral_chroma'):.3f} vs A {mean('aqua', 'neutral_chroma'):.3f} | "
          f"L* {mean('hydro', 'mean_l'):.1f} vs A {mean('aqua', 'mean_l'):.1f} | "
          f"water hue " + " ".join(f"{r['hydro']['water_hue']:.0f}/{r['aqua']['water_hue']:.0f}" for r in records))
    print(output)


if __name__ == "__main__":
    main()
