#!/usr/bin/env python3
"""Build per-job, source-bound contact sheets and technical QA for Recorrido V16 motion."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageOps

SAMPLE_FRACTIONS = (0.05, 0.25, 0.5, 0.75, 0.95)
PARALLAX_SAMPLE_COUNT = 17
THUMB = (160, 284)
QUALITY_FLOOR = "recorrido-valley-brook-wide-v1"
NATIVE_CANVASES = {"9:16": "720x1280", "16:9": "1280x720"}
REQUIRED_FRAMING_CHECKS = (
    "source_faithful_wide_anchor",
    "whole_property_or_room_width_preserved",
    "no_primary_architecture_cut",
    "no_squash_or_stretch",
    "no_center_crop_conversion",
    "no_push_in_or_zoom_only",
    "begins_on_exact_anchor",
    "native_aspect_ratio",
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def measure_spatial_parallax(gray_frames: list[np.ndarray]) -> dict:
    """Separate real differential scene motion from one global 2D transform."""
    pairs: list[dict] = []
    for first, second in zip(gray_frames, gray_frames[1:]):
        points = cv2.goodFeaturesToTrack(
            first, maxCorners=1000, qualityLevel=0.01, minDistance=6, blockSize=5,
        )
        if points is None:
            continue
        tracked, status, _ = cv2.calcOpticalFlowPyrLK(
            first, second, points, None, winSize=(31, 31), maxLevel=4,
            criteria=(cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, 40, 0.01),
        )
        if tracked is None or status is None:
            continue
        valid = status.reshape(-1) == 1
        source = points[valid].reshape(-1, 2)
        target = tracked[valid].reshape(-1, 2)
        if len(source) < 20:
            continue
        transform, _ = cv2.findHomography(source, target, cv2.RANSAC, 2.0)
        if transform is None:
            continue
        predicted = cv2.perspectiveTransform(source[:, None, :], transform).reshape(-1, 2)
        residual = np.linalg.norm(target - predicted, axis=1)
        flow = np.linalg.norm(target - source, axis=1)
        pairs.append({
            "tracks": int(len(source)),
            "median_flow_px": float(np.median(flow)),
            "p90_non_global_residual_px": float(np.percentile(residual, 90)),
            "non_global_track_ratio": float(np.mean(residual > 1.0)),
        })
    if len(pairs) < 4:
        return {
            "motion_class": "insufficient_track_evidence",
            "spatial_parallax_pass": False,
            "pair_count": len(pairs),
            "pairs": pairs,
        }
    median_flow = float(np.median([row["median_flow_px"] for row in pairs]))
    median_residual = float(np.median([row["p90_non_global_residual_px"] for row in pairs]))
    median_ratio = float(np.median([row["non_global_track_ratio"] for row in pairs]))
    non_global_evidence = median_residual >= 0.9 or median_ratio >= 0.05
    passed = median_flow >= 0.75 and non_global_evidence
    return {
        "motion_class": "spatial_parallax" if passed else "global_2d_transform",
        "spatial_parallax_pass": bool(passed),
        "pair_count": len(pairs),
        "median_flow_px": median_flow,
        "median_p90_non_global_residual_px": median_residual,
        "median_non_global_track_ratio": median_ratio,
        "thresholds": {
            "median_flow_px_min": 0.75,
            "non_global_evidence": "median_p90_non_global_residual_px >= 0.9 OR median_non_global_track_ratio >= 0.05",
        },
        "pairs": pairs,
    }


def is_supported_motion_canvas(width: int, height: int) -> bool:
    """Accept exact 9:16 or 16:9 motion canvases, in either orientation."""
    return width > 0 and height > 0 and (
        width * 16 == height * 9 or width * 9 == height * 16
    )


def quality_contract_errors(manifest: dict) -> list[str]:
    """Reject any route outside the approved Valley Brook production contract."""
    errors: list[str] = []
    if manifest.get("quality_floor") != QUALITY_FLOOR:
        errors.append(f"quality floor must be {QUALITY_FLOOR}")
    output_format = manifest.get("output_format")
    expected_canvas = NATIVE_CANVASES.get(output_format) if isinstance(output_format, str) else None
    if expected_canvas is None:
        errors.append("output format must be exactly 9:16 or 16:9")
    if manifest.get("requires_spatial_parallax") is not True:
        errors.append("spatial parallax must be required")
    shots = manifest.get("shots")
    if not isinstance(shots, list) or not shots:
        errors.append("quality contract requires shots")
        return errors
    for index, row in enumerate(shots, 1):
        request = row.get("animation_request") if isinstance(row, dict) else None
        if not isinstance(request, dict):
            errors.append(f"shot {index} lacks animation request")
            continue
        if expected_canvas is not None and request.get("output") != expected_canvas:
            errors.append(f"shot {index} native canvas must be {expected_canvas}")
        sources = request.get("source_stills")
        if not isinstance(sources, list) or len(sources) != 1:
            errors.append(f"shot {index} must animate exactly one approved wide anchor")
        source_hash = request.get("source_delivery_sha256")
        if not isinstance(source_hash, str) or len(source_hash) != 64:
            errors.append(f"shot {index} lacks source-bound anchor hash")
    return errors


def measure_anchor_start_fidelity(anchor_bgr: np.ndarray, first_frame_bgr: np.ndarray) -> dict:
    """Detect center crops, wrong starts, and aspect conversion at frame zero."""
    if anchor_bgr.ndim != 3 or first_frame_bgr.ndim != 3:
        return {"pass": False, "reason": "invalid image arrays"}
    ah, aw = anchor_bgr.shape[:2]
    fh, fw = first_frame_bgr.shape[:2]
    if aw <= 0 or ah <= 0 or fw <= 0 or fh <= 0 or aw * fh != fw * ah:
        return {"pass": False, "reason": "anchor and frame-zero aspect ratios differ"}
    size = (320, 180) if aw > ah else (180, 320)
    anchor = cv2.resize(cv2.cvtColor(anchor_bgr, cv2.COLOR_BGR2GRAY), size).astype(np.float32)
    frame = cv2.resize(cv2.cvtColor(first_frame_bgr, cv2.COLOR_BGR2GRAY), size).astype(np.float32)
    anchor_norm = (anchor - anchor.mean()) / max(float(anchor.std()), 1.0)
    frame_norm = (frame - frame.mean()) / max(float(frame.std()), 1.0)
    luminance_correlation = float(np.mean(anchor_norm * frame_norm))
    anchor_edges = cv2.Canny(anchor.astype(np.uint8), 60, 160).astype(np.float32)
    frame_edges = cv2.Canny(frame.astype(np.uint8), 60, 160).astype(np.float32)
    edge_union = float(np.count_nonzero((anchor_edges > 0) | (frame_edges > 0)))
    edge_overlap = float(np.count_nonzero((anchor_edges > 0) & (frame_edges > 0)))
    edge_iou = edge_overlap / edge_union if edge_union else 0.0
    passed = luminance_correlation >= 0.82 and edge_iou >= 0.35
    return {
        "pass": bool(passed),
        "luminance_correlation": luminance_correlation,
        "edge_iou": edge_iou,
        "thresholds": {"luminance_correlation_min": 0.82, "edge_iou_min": 0.35},
    }


def framing_verdict_errors(
    payload: dict,
    *,
    shot_id: str,
    output_format: str,
    anchor_sha256: str,
    clip_sha256: str,
) -> list[str]:
    """Require a vision-reviewed verdict bound to the exact anchor and clip bytes."""
    errors: list[str] = []
    expected = {
        "schema": "recorrido-wide-framing-verdict-1",
        "status": "pass",
        "shot_id": shot_id,
        "output_format": output_format,
        "anchor_sha256": anchor_sha256,
        "clip_sha256": clip_sha256,
    }
    for key, value in expected.items():
        if payload.get(key) != value:
            errors.append(f"framing verdict {key} mismatch")
    if payload.get("reviewer") not in {"vision", "human"}:
        errors.append("framing verdict requires vision or human reviewer")
    checks = payload.get("checks")
    if not isinstance(checks, dict):
        return errors + ["framing verdict checks missing"]
    for name in REQUIRED_FRAMING_CHECKS:
        if checks.get(name) is not True:
            errors.append(f"framing verdict failed: {name}")
    return errors


def analyze_clip(path: Path, *, require_spatial_parallax: bool = True) -> tuple[dict, list[Image.Image]]:
    cap = cv2.VideoCapture(str(path))
    if not cap.isOpened():
        raise RuntimeError(f"cannot open {path}")
    fps = float(cap.get(cv2.CAP_PROP_FPS))
    frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    duration = frames / fps if fps > 0 else 0
    samples: list[Image.Image] = []
    gray: list[np.ndarray] = []
    luminance: list[float] = []
    for fraction in SAMPLE_FRACTIONS:
        cap.set(cv2.CAP_PROP_POS_FRAMES, min(frames - 1, max(0, int(frames * fraction))))
        ok, frame = cap.read()
        if not ok:
            cap.release()
            raise RuntimeError(f"frame extraction failed: {path} at {fraction}")
        frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        samples.append(Image.fromarray(frame_rgb))
        g = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        sample_size = (320, 180) if width > height else (180, 320)
        gray.append(cv2.resize(g, sample_size))
        luminance.append(float(g.mean()))
    parallax_frames: list[np.ndarray] = []
    for frame_index in np.linspace(0, frames - 1, PARALLAX_SAMPLE_COUNT).astype(int):
        cap.set(cv2.CAP_PROP_POS_FRAMES, int(frame_index))
        ok, frame = cap.read()
        if not ok:
            cap.release()
            raise RuntimeError(f"parallax frame extraction failed: {path} at {frame_index}")
        gray_frame = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        parallax_size = (640, 360) if width > height else (360, 640)
        parallax_frames.append(cv2.resize(gray_frame, parallax_size))
    cap.release()
    deltas = [float(np.mean(cv2.absdiff(gray[i], gray[i + 1]))) for i in range(len(gray) - 1)]
    parallax = measure_spatial_parallax(parallax_frames)
    base_pass = is_supported_motion_canvas(width, height) and duration >= 7.0 and fps >= 23 and frames >= 160 and min(luminance) > 5 and max(deltas) >= 1.0
    technical_pass = base_pass and (parallax["spatial_parallax_pass"] or not require_spatial_parallax)
    return {
        "path": str(path), "sha256": sha256(path), "width": width, "height": height,
        "fps": fps, "frames": frames, "duration": duration, "sample_luminance": luminance,
        "adjacent_sample_deltas": deltas,
        "requires_spatial_parallax": require_spatial_parallax,
        "spatial_parallax": parallax,
        "technical_pass": technical_pass,
    }, samples


def requests_by_shot(manifest: dict) -> dict[str, dict]:
    requests: dict[str, dict] = {}
    for row in manifest.get("shots", []):
        request = row.get("animation_request")
        if not isinstance(request, dict) or not request.get("shot_id"):
            raise KeyError("invalid nested animation_request")
        requests[str(request["shot_id"])] = request
    if not requests:
        raise KeyError("generation manifest has no shots")
    return requests


def build_job(job: Path) -> dict:
    results = json.loads((job / "v16/generation_results.json").read_text())
    manifest = json.loads((job / "v16/generation_manifest.json").read_text())
    contract_errors = quality_contract_errors(manifest)
    if contract_errors:
        raise RuntimeError("release quality contract failed: " + "; ".join(contract_errors))
    output_format = str(manifest["output_format"])
    expected_canvas = NATIVE_CANVASES[output_format]
    expected_width, expected_height = (int(value) for value in expected_canvas.split("x"))
    requests = requests_by_shot(manifest)
    require_spatial_parallax = manifest.get("requires_spatial_parallax", True) is not False
    rows = results["shots"]
    qa_dir = job / "v16/clean_motion_qa"
    qa_dir.mkdir(parents=True, exist_ok=True)
    canvas = Image.new("RGB", (1080, 5 * 330 + 75), "#071326")
    draw = ImageDraw.Draw(canvas)
    draw.text((15, 16), f"{job.name} | anchor + 5 motion samples", fill="white")
    technical = []
    for index, row in enumerate(rows):
        shot_id = row["id"]
        request = requests[shot_id]
        anchor = job / "v16" / request["source_stills"][0]
        clip = job / "v16" / row["path"]
        if sha256(anchor) != request["source_delivery_sha256"]:
            raise RuntimeError(f"anchor hash mismatch: {job.name}/{shot_id}")
        if sha256(clip) != row["sha256"]:
            raise RuntimeError(f"clip hash mismatch: {job.name}/{shot_id}")
        clip_qa, samples = analyze_clip(clip, require_spatial_parallax=require_spatial_parallax)
        anchor_image = cv2.imread(str(anchor), cv2.IMREAD_COLOR)
        capture = cv2.VideoCapture(str(clip))
        first_ok, first_frame = capture.read()
        capture.release()
        if anchor_image is None or not first_ok or first_frame is None:
            raise RuntimeError(f"frame-zero extraction failed: {job.name}/{shot_id}")
        anchor_start = measure_anchor_start_fidelity(anchor_image, first_frame)

        verdict_relative = row.get("framing_qa_path")
        if not isinstance(verdict_relative, str) or not verdict_relative:
            raise RuntimeError(f"missing framing QA verdict: {job.name}/{shot_id}")
        v16_root = (job / "v16").resolve()
        verdict_path = (v16_root / verdict_relative).resolve()
        if v16_root not in verdict_path.parents or not verdict_path.is_file():
            raise RuntimeError(f"invalid framing QA verdict path: {job.name}/{shot_id}")
        verdict = json.loads(verdict_path.read_text())
        verdict_errors = framing_verdict_errors(
            verdict,
            shot_id=shot_id,
            output_format=output_format,
            anchor_sha256=sha256(anchor),
            clip_sha256=sha256(clip),
        )
        native_canvas_pass = (
            clip_qa["width"] == expected_width and clip_qa["height"] == expected_height
        )
        clip_qa["anchor_start_fidelity"] = anchor_start
        clip_qa["native_canvas_pass"] = native_canvas_pass
        clip_qa["framing_verdict_path"] = str(verdict_path)
        clip_qa["framing_verdict_errors"] = verdict_errors
        clip_qa["technical_pass"] = bool(
            clip_qa["technical_pass"]
            and anchor_start.get("pass") is True
            and native_canvas_pass
            and not verdict_errors
        )
        clip_qa.update({"shot_id": shot_id, "anchor_path": str(anchor), "anchor_sha256": sha256(anchor)})
        technical.append(clip_qa)
        y = 62 + index * 330
        draw.text((15, y), shot_id[:44], fill="white")
        images = [Image.open(anchor).convert("RGB")] + samples
        for col, image in enumerate(images):
            thumb = ImageOps.fit(image, THUMB, Image.Resampling.LANCZOS)
            canvas.paste(thumb, (15 + col * 176, y + 28))
    sheet = qa_dir / "contact_sheet_anchor_plus_motion.jpg"
    canvas.save(sheet, quality=96)
    payload = {"schema": "recorrido-v16-clean-motion-technical-qa-1", "job": job.name, "status": "pass" if all(r["technical_pass"] for r in technical) else "fail", "shots": technical, "contact_sheet": str(sheet)}
    (qa_dir / "technical.json").write_text(json.dumps(payload, indent=2) + "\n")
    return payload


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("jobs_root", type=Path)
    args = parser.parse_args()
    outputs = []
    for job in sorted(args.jobs_root.iterdir()):
        manifest = job / "v16/generation_manifest.json"
        results = job / "v16/generation_results.json"
        if not manifest.exists() or not results.exists():
            continue
        if json.loads(manifest.read_text()).get("generation_authorized") is not True:
            continue
        payload = build_job(job)
        outputs.append(payload)
        print(json.dumps({"job": job.name, "status": payload["status"], "shots": len(payload["shots"])}), flush=True)
    failed = [row["job"] for row in outputs if row["status"] != "pass"]
    print(json.dumps({"jobs": len(outputs), "shots": sum(len(row["shots"]) for row in outputs), "technical_failures": failed}, indent=2))
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
