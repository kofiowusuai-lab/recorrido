from __future__ import annotations

import importlib.util
from pathlib import Path

import cv2
import numpy as np
import pytest

MODULE_PATH = Path(__file__).parents[1] / "scripts" / "build_recorrido_v16_motion_qa.py"


def load_module():
    spec = importlib.util.spec_from_file_location("build_recorrido_v16_motion_qa", MODULE_PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_requests_are_read_from_nested_generation_shots() -> None:
    m = load_module()
    manifest = {"shots": [{"id": "01_exterior", "animation_request": {"shot_id": "01_exterior", "source_stills": ["delivery_anchors/01_exterior.png"]}}]}
    requests = m.requests_by_shot(manifest)
    assert requests["01_exterior"]["source_stills"] == ["delivery_anchors/01_exterior.png"]


def test_supported_motion_canvas_accepts_native_vertical_and_horizontal_only() -> None:
    m = load_module()
    assert m.is_supported_motion_canvas(720, 1280) is True
    assert m.is_supported_motion_canvas(1280, 720) is True
    assert m.is_supported_motion_canvas(1080, 1920) is True
    assert m.is_supported_motion_canvas(1920, 1080) is True
    assert m.is_supported_motion_canvas(720, 720) is False
    assert m.is_supported_motion_canvas(1024, 768) is False


def _textured_frame() -> np.ndarray:
    rng = np.random.default_rng(42)
    frame = rng.integers(0, 256, (640, 360), dtype=np.uint8)
    cv2.rectangle(frame, (30, 80), (155, 540), 230, 5)
    cv2.circle(frame, (270, 230), 70, 20, 7)
    cv2.line(frame, (20, 600), (340, 500), 180, 5)
    return frame


def test_spatial_parallax_gate_rejects_global_digital_transform() -> None:
    m = load_module()
    source = _textured_frame()
    frames = []
    for step in range(17):
        matrix = cv2.getRotationMatrix2D((180, 320), 0, 1 + step * 0.0007)
        matrix[:, 2] += (step * 0.45, step * 0.15)
        frames.append(cv2.warpAffine(source, matrix, (360, 640), borderMode=cv2.BORDER_REFLECT))

    result = m.measure_spatial_parallax(frames)

    assert result["spatial_parallax_pass"] is False
    assert result["motion_class"] == "global_2d_transform"


def test_spatial_parallax_gate_accepts_differential_layer_motion() -> None:
    m = load_module()
    background = _textured_frame()
    rng = np.random.default_rng(7)
    foreground = rng.integers(0, 256, background.shape, dtype=np.uint8)
    mask = np.zeros_like(background, dtype=np.uint8)
    cv2.rectangle(mask, (25, 270), (185, 625), 1, -1)
    cv2.circle(mask, (105, 335), 48, 1, -1)
    frames = []
    for step in range(17):
        bg_matrix = np.float32([[1, 0, step * 1.0], [0, 1, 0]])
        fg_matrix = np.float32([[1, 0, step * 4.0], [0, 1, step * 0.4]])
        bg = cv2.warpAffine(background, bg_matrix, (360, 640), borderMode=cv2.BORDER_REFLECT)
        fg = cv2.warpAffine(foreground, fg_matrix, (360, 640))
        moved_mask = cv2.warpAffine(mask, fg_matrix, (360, 640)).astype(bool)
        bg[moved_mask] = fg[moved_mask]
        frames.append(bg)

    result = m.measure_spatial_parallax(frames)

    assert result["spatial_parallax_pass"] is True
    assert result["motion_class"] == "spatial_parallax"


def _quality_manifest(output_format: str = "9:16") -> dict:
    canvas = "720x1280" if output_format == "9:16" else "1280x720"
    return {
        "quality_floor": "recorrido-valley-brook-wide-v1",
        "output_format": output_format,
        "requires_spatial_parallax": True,
        "shots": [{
            "id": "01_exterior",
            "animation_request": {
                "shot_id": "01_exterior",
                "source_stills": ["delivery_anchors/01_exterior.png"],
                "output": canvas,
                "source_delivery_sha256": "a" * 64,
            },
        }],
    }


def test_quality_contract_accepts_only_valley_brook_native_wide_pipeline() -> None:
    m = load_module()
    assert m.quality_contract_errors(_quality_manifest("9:16")) == []
    assert m.quality_contract_errors(_quality_manifest("16:9")) == []

    missing = _quality_manifest()
    del missing["quality_floor"]
    assert "quality floor" in " ".join(m.quality_contract_errors(missing))

    converted = _quality_manifest("16:9")
    converted["shots"][0]["animation_request"]["output"] = "720x1280"
    assert "native canvas" in " ".join(m.quality_contract_errors(converted))

    no_parallax = _quality_manifest()
    no_parallax["requires_spatial_parallax"] = False
    assert "spatial parallax" in " ".join(m.quality_contract_errors(no_parallax))


def test_anchor_start_gate_rejects_center_crop_and_accepts_exact_anchor() -> None:
    m = load_module()
    anchor = np.zeros((360, 640, 3), dtype=np.uint8)
    for x in range(0, 640, 32):
        cv2.line(anchor, (x, 0), (x, 359), (x % 255, 180, 255 - x % 255), 3)
    cv2.rectangle(anchor, (10, 50), (630, 330), (220, 220, 220), 5)
    encoded = cv2.GaussianBlur(anchor, (3, 3), 0)
    exact = m.measure_anchor_start_fidelity(anchor, encoded)
    assert exact["pass"] is True

    tight = anchor[:, 160:480]
    tight = cv2.resize(tight, (640, 360))
    cropped = m.measure_anchor_start_fidelity(anchor, tight)
    assert cropped["pass"] is False


def test_framing_verdict_is_fail_closed_and_hash_bound() -> None:
    m = load_module()
    payload = {
        "schema": "recorrido-wide-framing-verdict-1",
        "status": "pass",
        "shot_id": "01_exterior",
        "output_format": "16:9",
        "anchor_sha256": "a" * 64,
        "clip_sha256": "b" * 64,
        "reviewer": "vision",
        "checks": {name: True for name in m.REQUIRED_FRAMING_CHECKS},
    }
    assert m.framing_verdict_errors(
        payload,
        shot_id="01_exterior",
        output_format="16:9",
        anchor_sha256="a" * 64,
        clip_sha256="b" * 64,
    ) == []

    payload["checks"]["whole_property_or_room_width_preserved"] = False
    assert "whole_property_or_room_width_preserved" in " ".join(
        m.framing_verdict_errors(
            payload,
            shot_id="01_exterior",
            output_format="16:9",
            anchor_sha256="a" * 64,
            clip_sha256="b" * 64,
        )
    )


def test_real_build_path_refuses_legacy_manifest_before_touching_motion(tmp_path: Path) -> None:
    m = load_module()
    v16 = tmp_path / "client-job" / "v16"
    v16.mkdir(parents=True)
    (v16 / "generation_results.json").write_text('{"shots": []}')
    (v16 / "generation_manifest.json").write_text('{"shots": []}')
    with pytest.raises(RuntimeError, match="release quality contract failed"):
        m.build_job(v16.parent)
