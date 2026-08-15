#!/usr/bin/env python3
"""Build a deterministic, non-customer Recorrido V16 Cloudflare canary fixture."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", re.I)
SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
COLORS = ("0x17324d", "0x29485f", "0x365d6d", "0x4a6f78", "0x5f7f80")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def run(command: list[str]) -> None:
    subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def build(root: Path, account_id: str, idempotency_key: str, job_name: str = "cloudflare-canary") -> tuple[Path, Path]:
    if not UUID.fullmatch(account_id) or not SAFE_ID.fullmatch(idempotency_key) or not SAFE_ID.fullmatch(job_name):
        raise ValueError("invalid canary identity")
    job = Path(root) / job_name
    v16 = job / "v16"
    for directory in (v16 / "stills", v16 / "maps", v16 / "clips"):
        directory.mkdir(parents=True, exist_ok=True)

    hero = v16 / "stills/001.jpg"
    map_image = v16 / "maps/amenities.png"
    run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=c=0x17324d:s=720x1280", "-frames:v", "1", str(hero)])
    run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=c=0xe8ecef:s=720x1280", "-frames:v", "1", str(map_image)])

    shots: list[dict] = []
    results: list[dict] = []
    timeline: list[dict] = [{"id": "intro", "kind": "brand_intro"}]
    for index, color in enumerate(COLORS, 1):
        shot_id = f"{index:02d}_canary"
        clip = v16 / "clips" / f"{shot_id}.mp4"
        run([
            "ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
            f"color=c={color}:s=720x1280:r=24:d=8", "-c:v", "libx264", "-preset", "ultrafast",
            "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(clip),
        ])
        shots.append({
            "id": shot_id,
            "room": f"Canary {index}",
            "animation_request": {
                "job_id": f"recorrido-{job_name}", "shot_id": shot_id, "operation": "image_to_video",
                "source_stills": ["stills/001.jpg"], "recurring_entities": [],
                "motion_brief": "Deterministic infrastructure canary with no customer property.",
                "camera_brief": "Static validation frame.",
                "negative_continuity_rules": ["no people", "no logos", "no address"],
                "duration": 8, "output": "720x1280",
            },
        })
        results.append({
            "id": shot_id, "room": f"Canary {index}", "status": "ready",
            "path": f"clips/{shot_id}.mp4", "requested_duration": 8, "actual_duration": 8,
            "model": "deterministic-canary", "sha256": sha256(clip),
        })
        timeline.append({
            "id": shot_id, "kind": "walkthrough", "room": f"Canary {index}",
            "overlay_detail": f"Infrastructure validation scene {index}; no customer listing data.",
        })

    generation = {
        "generator_contract": "video_studio.grok_animation.AnimationRequest",
        "source_contract": "deterministic_canary",
        "shots": shots,
    }
    production = {
        "job": job_name, "render_authorized": True,
        "listing": {
            "agent": "Recorrido Canary", "office": "Infrastructure Validation",
            "whatsapp": "+573000000099", "mls": "CANARY-000", "location": "Canary, CO",
        },
        "verified_facts": ["Synthetic validation media", "No customer property data"],
        "timeline": timeline + [{"id": "amenities_cta", "kind": "amenities_and_contact_close"}],
        "amenities": {
            "status": "verified_public_origin",
            "origin": {"label": "synthetic canary", "lat": 4.0, "lon": -74.0},
            "map_path": "maps/amenities.png",
            "disclosure": "Synthetic infrastructure validation; not a real residence.",
            "attribution": "Recorrido infrastructure canary",
            "items": [
                {"name": "Canary A", "category": "Test", "drive_minutes": 1, "road_distance_km": 0.1},
                {"name": "Canary B", "category": "Test", "drive_minutes": 2, "road_distance_km": 0.2},
                {"name": "Canary C", "category": "Test", "drive_minutes": 3, "road_distance_km": 0.3},
            ],
        },
    }
    (v16 / "generation_manifest.json").write_text(json.dumps(generation, indent=2, sort_keys=True) + "\n")
    (v16 / "generation_results.json").write_text(json.dumps({"shots": results}, indent=2, sort_keys=True) + "\n")
    (v16 / "production_plan.json").write_text(json.dumps(production, indent=2, sort_keys=True) + "\n")

    files = []
    prefix = f"accounts/{account_id}/jobs/{idempotency_key}/assets"
    for path in sorted(p for p in job.rglob("*") if p.is_file()):
        relative = path.relative_to(job).as_posix()
        files.append({"relative_path": relative, "key": f"{prefix}/{relative}", "sha256": sha256(path)})
    manifest = {
        "version": 1, "pipeline": "recorrido_v16", "job_name": job_name,
        "files": files,
    }
    manifest_path = Path(root) / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return job, manifest_path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--account-id", required=True)
    parser.add_argument("--idempotency-key", required=True)
    parser.add_argument("--job-name", default="cloudflare-canary")
    args = parser.parse_args()
    job, manifest = build(args.output, args.account_id, args.idempotency_key, args.job_name)
    print(json.dumps({"job": str(job), "manifest": str(manifest), "files": len(json.loads(manifest.read_text())["files"])}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
