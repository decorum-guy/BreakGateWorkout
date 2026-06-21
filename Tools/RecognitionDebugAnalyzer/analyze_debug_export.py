#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import html
import json
import math
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import textwrap
import zipfile
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


SKELETON_EDGES = [
    ("leftShoulder", "rightShoulder"),
    ("leftShoulder", "leftElbow"),
    ("leftElbow", "leftWrist"),
    ("rightShoulder", "rightElbow"),
    ("rightElbow", "rightWrist"),
    ("leftShoulder", "leftHip"),
    ("rightShoulder", "rightHip"),
    ("leftHip", "rightHip"),
    ("leftHip", "leftKnee"),
    ("leftKnee", "leftAnkle"),
    ("rightHip", "rightKnee"),
    ("rightKnee", "rightAnkle"),
]

MOTION_KEYPOINTS = {
    "mountainClimbers": ["leftKnee", "rightKnee", "leftAnkle", "rightAnkle", "leftHip", "rightHip"],
    "pikePushUps": ["leftShoulder", "rightShoulder", "leftHip", "rightHip", "leftElbow", "rightElbow"],
    "lSitHold": ["leftHip", "rightHip", "leftKnee", "rightKnee", "leftAnkle", "rightAnkle", "leftWrist", "rightWrist"],
}

INCONSISTENT_POSE_HINTS = {
    "mountainClimbers": ["idle", "noPerson"],
    "pikePushUps": ["idle", "noPerson"],
    "lSitHold": ["idle", "noPerson"],
}


@dataclass
class RepEvent:
    event_id: str
    timestamp_seconds: float
    exercise_mode: str
    step_index: int
    previous_count: int
    new_count: int
    count_delta: int
    frame_index: int
    current_pose_state: str
    decision_reason: str
    confidence: float | None
    visible_keypoint_count: int | None
    average_keypoint_confidence: float | None
    critical_missing_for_exercise: bool
    critical_missing_reason: str | None
    missing_keypoints: list[str]
    body_line_angle: float | None
    brightness: float | None
    suspicious_reasons: list[str] = field(default_factory=list)
    linked_files: list[str] = field(default_factory=list)


@dataclass
class MissedCandidate:
    candidate_id: str
    exercise_mode: str
    step_index: int
    start_timestamp: float
    end_timestamp: float
    duration_seconds: float
    peak_motion_score: float
    average_motion_score: float
    rep_count_before: int
    rep_count_after: int
    hold_seconds_max: int
    likely_reason: str
    current_pose_state: str
    decision_reason: str
    confidence: float | None
    brightness_average: float | None
    linked_files: list[str] = field(default_factory=list)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Analyze BreakGateWorkout Recognition Debug exports and generate a local HTML/CSV/JSON report."
    )
    parser.add_argument("input_path", help="Recognition Debug export folder or .zip file")
    parser.add_argument("--out", required=True, help="Output report folder")
    parser.add_argument("--labels", help="Optional filled manual labels CSV")
    return parser.parse_args()


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, start=1):
            stripped = line.strip()
            if not stripped:
                continue
            try:
                rows.append(json.loads(stripped))
            except json.JSONDecodeError as exc:
                raise RuntimeError(f"Failed to parse JSONL line {line_no} in {path}: {exc}") from exc
    return rows


def ensure_input_folder(input_path: Path) -> tuple[Path, Path | None]:
    if input_path.is_dir():
        return input_path, None
    if input_path.suffix.lower() != ".zip":
        raise RuntimeError("Input must be a folder or a .zip Recognition Debug export.")
    temp_dir = Path(tempfile.mkdtemp(prefix="recognition_debug_analyzer_"))
    with zipfile.ZipFile(input_path, "r") as archive:
        archive.extractall(temp_dir)
    return temp_dir, temp_dir


def require_file(folder: Path, filename: str) -> Path:
    path = folder / filename
    if not path.exists():
        raise RuntimeError(f"Missing required file: {path}")
    return path


def safe_slug(value: str) -> str:
    cleaned = "".join(ch if ch.isalnum() else "-" for ch in value.strip())
    while "--" in cleaned:
        cleaned = cleaned.replace("--", "-")
    return cleaned.strip("-").lower() or "item"


def fmt_num(value: float | int | None, digits: int = 3) -> str:
    if value is None:
        return ""
    if isinstance(value, int):
        return str(value)
    return f"{value:.{digits}f}"


def avg(values: Iterable[float | None]) -> float | None:
    filtered = [value for value in values if value is not None]
    if not filtered:
        return None
    return sum(filtered) / len(filtered)


def ratio(numerator: int, denominator: int) -> float | None:
    if denominator == 0:
        return None
    return numerator / denominator


def duration_from_samples(samples: list[dict[str, Any]]) -> float:
    if len(samples) < 2:
        return 0.0
    return float(samples[-1]["timestampSeconds"]) - float(samples[0]["timestampSeconds"])


def compute_motion_score(previous: dict[str, Any], current: dict[str, Any], exercise_mode: str) -> float:
    pose_prev = previous.get("posePoints", {})
    pose_curr = current.get("posePoints", {})
    focus = MOTION_KEYPOINTS.get(exercise_mode)
    points = focus if focus else sorted(set(pose_prev) | set(pose_curr))
    deltas: list[float] = []
    for key in points:
        prev_point = pose_prev.get(key)
        curr_point = pose_curr.get(key)
        if not prev_point or not curr_point:
            continue
        dx = float(curr_point["x"]) - float(prev_point["x"])
        dy = float(curr_point["y"]) - float(prev_point["y"])
        deltas.append(math.sqrt(dx * dx + dy * dy))
    if not deltas:
        return 0.0
    return sum(deltas) / len(deltas)


def exercise_group(samples: list[dict[str, Any]]) -> dict[int, list[dict[str, Any]]]:
    grouped: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for sample in samples:
        grouped[int(sample.get("stepIndex", -1))].append(sample)
    return dict(sorted(grouped.items()))


def summarize_segment(step_index: int, step_samples: list[dict[str, Any]]) -> dict[str, Any]:
    exercise_mode = step_samples[0].get("exerciseMode", "unknown") if step_samples else "unknown"
    rep_values = [int(sample.get("repCount", 0)) for sample in step_samples]
    hold_values = [int(sample.get("holdSeconds", 0)) for sample in step_samples]
    valid_pose_count = sum(1 for sample in step_samples if sample.get("decision", {}).get("isPoseValid"))
    person_detected_count = sum(1 for sample in step_samples if sample.get("personDetected"))
    critical_missing_count = sum(1 for sample in step_samples if sample.get("metrics", {}).get("criticalMissingForExercise"))
    state_counts = Counter(sample.get("currentPoseState", "") for sample in step_samples)
    reason_counts = Counter(sample.get("decision", {}).get("reason", "") for sample in step_samples)
    brightness_values = [sample.get("averageBrightness") for sample in step_samples]
    visible_keypoints = [sample.get("metrics", {}).get("visibleKeypointCount") for sample in step_samples]
    confidences = [sample.get("confidence") for sample in step_samples]
    average_confidences = [sample.get("metrics", {}).get("averageKeypointConfidence") for sample in step_samples]
    increment_count = sum(
        1
        for previous, current in zip(step_samples, step_samples[1:])
        if int(current.get("repCount", 0)) > int(previous.get("repCount", 0))
    )
    return {
        "stepIndex": step_index,
        "exerciseMode": exercise_mode,
        "startTimestamp": float(step_samples[0].get("timestampSeconds", 0.0)),
        "endTimestamp": float(step_samples[-1].get("timestampSeconds", 0.0)),
        "durationSeconds": duration_from_samples(step_samples),
        "firstRepCount": rep_values[0] if rep_values else 0,
        "lastRepCount": rep_values[-1] if rep_values else 0,
        "maxRepCount": max(rep_values) if rep_values else 0,
        "repIncrements": increment_count,
        "holdTimeMax": max(hold_values) if hold_values else 0,
        "personDetectedRatio": ratio(person_detected_count, len(step_samples)),
        "validPoseRatio": ratio(valid_pose_count, len(step_samples)),
        "criticalMissingRatio": ratio(critical_missing_count, len(step_samples)),
        "averageVisibleKeypoints": avg(visible_keypoints),
        "averageConfidence": avg(confidences),
        "averageKeypointConfidence": avg(average_confidences),
        "mostCommonPoseStates": state_counts.most_common(5),
        "mostCommonDecisionReasons": reason_counts.most_common(5),
        "brightnessAverage": avg(brightness_values),
        "brightnessMin": min((v for v in brightness_values if v is not None), default=None),
        "brightnessMax": max((v for v in brightness_values if v is not None), default=None),
        "sampleCount": len(step_samples),
    }


def detect_rep_events(grouped_samples: dict[int, list[dict[str, Any]]]) -> list[RepEvent]:
    events: list[RepEvent] = []
    for step_index, step_samples in grouped_samples.items():
        previous_event_time: float | None = None
        previous_phase: str | None = None
        for previous, current in zip(step_samples, step_samples[1:]):
            prev_rep = int(previous.get("repCount", 0))
            new_rep = int(current.get("repCount", 0))
            if new_rep <= prev_rep:
                continue
            current_metrics = current.get("metrics", {})
            event = RepEvent(
                event_id=f"rep-{step_index}-{len(events)+1}",
                timestamp_seconds=float(current.get("timestampSeconds", 0.0)),
                exercise_mode=current.get("exerciseMode", "unknown"),
                step_index=step_index,
                previous_count=prev_rep,
                new_count=new_rep,
                count_delta=new_rep - prev_rep,
                frame_index=int(current.get("frameIndex", 0)),
                current_pose_state=current.get("currentPoseState", ""),
                decision_reason=current.get("decision", {}).get("reason", ""),
                confidence=current.get("confidence"),
                visible_keypoint_count=current_metrics.get("visibleKeypointCount"),
                average_keypoint_confidence=current_metrics.get("averageKeypointConfidence"),
                critical_missing_for_exercise=bool(current_metrics.get("criticalMissingForExercise")),
                critical_missing_reason=current_metrics.get("criticalMissingReason"),
                missing_keypoints=list(current_metrics.get("missingKeypoints", [])),
                body_line_angle=current_metrics.get("bodyLineAngle"),
                brightness=current.get("averageBrightness"),
            )
            event.suspicious_reasons = suspicious_reasons_for_event(
                event=event,
                previous_event_time=previous_event_time,
                previous_phase=previous_phase,
                previous_sample=previous,
                current_sample=current,
            )
            events.append(event)
            previous_event_time = event.timestamp_seconds
            previous_phase = current.get("currentPoseState")
    return events


def suspicious_reasons_for_event(
    event: RepEvent,
    previous_event_time: float | None,
    previous_phase: str | None,
    previous_sample: dict[str, Any],
    current_sample: dict[str, Any],
) -> list[str]:
    reasons: list[str] = []
    if event.count_delta > 1:
        reasons.append(f"count delta > 1 ({event.count_delta})")
    if previous_event_time is not None and event.timestamp_seconds - previous_event_time < 0.45:
        reasons.append("rep increment happened too soon after previous increment")
    if event.confidence is not None and event.confidence < 0.35:
        reasons.append(f"low pose confidence ({event.confidence:.3f})")
    if event.visible_keypoint_count is not None and event.visible_keypoint_count < 8:
        reasons.append(f"low visible keypoint count ({event.visible_keypoint_count})")
    if event.critical_missing_for_exercise:
        reasons.append("critical keypoints missing for exercise")
    if current_sample.get("personDetected") is False or previous_sample.get("personDetected") is False:
        reasons.append("person not detected near rep event")
    inconsistent_tokens = INCONSISTENT_POSE_HINTS.get(event.exercise_mode, [])
    if any(token and token in event.current_pose_state for token in inconsistent_tokens):
        reasons.append("current pose state is inconsistent with rep event")
    if event.exercise_mode == "mountainClimbers":
        required = {"leftKnee", "rightKnee", "leftWrist", "rightWrist", "leftShoulder", "rightShoulder", "leftHip", "rightHip"}
        missing = set(event.missing_keypoints)
        if missing & required:
            reasons.append("mountain climbers increment while critical joints are missing")
        if event.body_line_angle is not None and abs(float(event.body_line_angle)) < 15:
            reasons.append("body line angle no longer looks plank-like")
        phase = event.current_pose_state.lower()
        if "alternation" in phase:
            reasons.append("rep increment happened while system was waiting for alternation")
        if previous_phase and previous_phase == event.current_pose_state == "left knee drive":
            reasons.append("repeated increment without clear left/right alternation")
    return reasons


def detect_missed_candidates(grouped_samples: dict[int, list[dict[str, Any]]]) -> list[MissedCandidate]:
    candidates: list[MissedCandidate] = []
    for step_index, step_samples in grouped_samples.items():
        if len(step_samples) < 2:
            continue
        exercise_mode = step_samples[0].get("exerciseMode", "unknown")
        windows: list[dict[str, Any]] = []
        active_window: dict[str, Any] | None = None
        for previous, current in zip(step_samples, step_samples[1:]):
            motion_score = compute_motion_score(previous, current, exercise_mode)
            rep_unchanged = int(previous.get("repCount", 0)) == int(current.get("repCount", 0))
            confidence = current.get("confidence") or 0.0
            valid_pose = bool(current.get("decision", {}).get("isPoseValid"))
            near_valid = valid_pose or confidence >= 0.35
            if motion_score >= 0.03 and rep_unchanged and near_valid:
                if active_window is None:
                    active_window = {
                        "start": previous,
                        "end": current,
                        "scores": [motion_score],
                        "states": Counter([current.get("currentPoseState", "")]),
                        "reasons": Counter([current.get("decision", {}).get("reason", "")]),
                        "brightness": [current.get("averageBrightness")],
                    }
                else:
                    active_window["end"] = current
                    active_window["scores"].append(motion_score)
                    active_window["states"][current.get("currentPoseState", "")] += 1
                    active_window["reasons"][current.get("decision", {}).get("reason", "")] += 1
                    active_window["brightness"].append(current.get("averageBrightness"))
            elif active_window is not None:
                windows.append(active_window)
                active_window = None
        if active_window is not None:
            windows.append(active_window)

        for window in windows:
            start = window["start"]
            end = window["end"]
            duration = float(end.get("timestampSeconds", 0.0)) - float(start.get("timestampSeconds", 0.0))
            if duration < 0.5:
                continue
            scores = window["scores"]
            reason = infer_missed_candidate_reason(exercise_mode, window)
            candidates.append(
                MissedCandidate(
                    candidate_id=f"missed-{step_index}-{len(candidates)+1}",
                    exercise_mode=exercise_mode,
                    step_index=step_index,
                    start_timestamp=float(start.get("timestampSeconds", 0.0)),
                    end_timestamp=float(end.get("timestampSeconds", 0.0)),
                    duration_seconds=duration,
                    peak_motion_score=max(scores),
                    average_motion_score=sum(scores) / len(scores),
                    rep_count_before=int(start.get("repCount", 0)),
                    rep_count_after=int(end.get("repCount", 0)),
                    hold_seconds_max=max(int(start.get("holdSeconds", 0)), int(end.get("holdSeconds", 0))),
                    likely_reason=reason,
                    current_pose_state=window["states"].most_common(1)[0][0] if window["states"] else "",
                    decision_reason=window["reasons"].most_common(1)[0][0] if window["reasons"] else "",
                    confidence=end.get("confidence"),
                    brightness_average=avg(window["brightness"]),
                )
            )
    return candidates


def build_state_timeline_rows(samples: list[dict[str, Any]]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for sample in samples:
        metrics = sample.get("metrics", {})
        pike_attempt = sample.get("pikeAttemptMetrics", {})
        rows.append(
            {
                "timestampSeconds": fmt_num(sample.get("timestampSeconds")),
                "exerciseMode": sample.get("exerciseMode", ""),
                "repCount": sample.get("repCount", 0),
                "currentPoseState": sample.get("currentPoseState", ""),
                "decisionReason": sample.get("decision", {}).get("reason", ""),
                "confidence": fmt_num(sample.get("confidence")),
                "visibleKeypointCount": metrics.get("visibleKeypointCount"),
                "criticalMissingForExercise": metrics.get("criticalMissingForExercise"),
                "missingKeypoints": ",".join(metrics.get("missingKeypoints", [])),
                "brightness": fmt_num(sample.get("averageBrightness")),
                "pikeAttemptPhase": pike_attempt.get("phase", ""),
                "pikeBestSide": pike_attempt.get("bestSide", ""),
                "pikeCurrentElbowAngle": fmt_num(pike_attempt.get("currentElbowAngle")),
                "pikeElbowAngleDelta": fmt_num(pike_attempt.get("elbowAngleDelta")),
                "pikeReturnToTopDetected": pike_attempt.get("returnToTopDetected", ""),
                "pikeCountBlockedReason": pike_attempt.get("countBlockedReason", ""),
            }
        )
    return rows


def build_state_transition_rows(samples: list[dict[str, Any]]) -> list[dict[str, Any]]:
    if not samples:
        return []

    rows: list[dict[str, Any]] = []
    previous_state = samples[0].get("currentPoseState", "")
    previous_rep_count = samples[0].get("repCount", 0)
    previous_timestamp = float(samples[0].get("timestampSeconds", 0.0))

    for sample in samples[1:]:
        current_state = sample.get("currentPoseState", "")
        current_timestamp = float(sample.get("timestampSeconds", 0.0))
        if current_state == previous_state:
            continue
        rows.append(
            {
                "fromState": previous_state,
                "toState": current_state,
                "timestampSeconds": fmt_num(current_timestamp),
                "durationOfPreviousState": fmt_num(current_timestamp - previous_timestamp),
                "repCount": previous_rep_count,
                "exerciseMode": sample.get("exerciseMode", ""),
            }
        )
        previous_state = current_state
        previous_rep_count = sample.get("repCount", 0)
        previous_timestamp = current_timestamp

    return rows


def detect_pike_unconfirmed_cycles(samples: list[dict[str, Any]]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    grouped = exercise_group(samples)
    for step_index, step_samples in grouped.items():
        if not step_samples or step_samples[0].get("exerciseMode") != "pikePushUps":
            continue

        candidate_start: dict[str, Any] | None = None
        down_seen_sample: dict[str, Any] | None = None
        waiting_return_sample: dict[str, Any] | None = None

        for sample in step_samples:
            state = sample.get("currentPoseState", "")
            rep_count = int(sample.get("repCount", 0))

            if state == "pikeAttempt down seen":
                candidate_start = candidate_start or sample
                down_seen_sample = sample

            if candidate_start is not None and state == "pikeAttempt waiting return":
                waiting_return_sample = sample

            if candidate_start is None:
                continue

            if state in {"pikeAttempt counted", "pikeAttempt return top counted"} and rep_count > int(candidate_start.get("repCount", 0)):
                candidate_start = None
                down_seen_sample = None
                waiting_return_sample = None
                continue

            if state in {
                "pikeAttempt armed at top",
                "pikeAttempt return top no count: cooldown",
                "pikeAttempt return top no count: no real elbow bend",
                "pikeAttempt return top no count: lost too long",
                "pikeAttempt return top no count: invalid attempt",
            }:
                start_rep = int(candidate_start.get("repCount", 0))
                if rep_count <= start_rep and down_seen_sample is not None:
                    pike_attempt = sample.get("pikeAttemptMetrics", {})
                    metrics = sample.get("metrics", {})
                    rows.append(
                        {
                            "startTimestamp": fmt_num(candidate_start.get("timestampSeconds")),
                            "downSeenTimestamp": fmt_num(down_seen_sample.get("timestampSeconds")),
                            "returnTimestamp": fmt_num(sample.get("timestampSeconds")),
                            "repCountBefore": start_rep,
                            "repCountAfter": rep_count,
                            "fromState": down_seen_sample.get("currentPoseState", ""),
                            "toState": state,
                            "likelyReason": pike_attempt.get("countBlockedReason") or sample.get("decision", {}).get("reason", ""),
                            "confidence": fmt_num(sample.get("confidence")),
                            "visibleKeypointCount": metrics.get("visibleKeypointCount"),
                            "missingKeypoints": ",".join(metrics.get("missingKeypoints", [])),
                            "waitingReturnTimestamp": fmt_num(waiting_return_sample.get("timestampSeconds")) if waiting_return_sample else "",
                        }
                    )
                candidate_start = None
                down_seen_sample = None
                waiting_return_sample = None

    return rows


def infer_missed_candidate_reason(exercise_mode: str, window: dict[str, Any]) -> str:
    top_state = window["states"].most_common(1)[0][0] if window["states"] else ""
    top_reason = window["reasons"].most_common(1)[0][0] if window["reasons"] else ""
    if exercise_mode == "mountainClimbers":
        return f"High leg motion without rep increment; state='{top_state}' reason='{top_reason}'"
    if exercise_mode == "pikePushUps":
        return f"Upper-body motion without rep increment; likely stayed in strict state '{top_state}'"
    if exercise_mode == "lSitHold":
        return f"Near-valid hold window without hold progress; state='{top_state}' reason='{top_reason}'"
    return f"Motion window without rep increment; state='{top_state}' reason='{top_reason}'"


def aggregate_failure_reasons(grouped_samples: dict[int, list[dict[str, Any]]]) -> dict[str, Any]:
    by_exercise: dict[str, dict[str, Any]] = {}
    for step_samples in grouped_samples.values():
        if not step_samples:
            continue
        exercise_mode = step_samples[0].get("exerciseMode", "unknown")
        bucket = by_exercise.setdefault(
            exercise_mode,
            {
                "criticalMissingReasonCounts": Counter(),
                "missingKeypointCounts": Counter(),
                "decisionReasonCounts": Counter(),
                "currentPoseStateCounts": Counter(),
                "confidenceValues": [],
                "visibleKeypointValues": [],
            },
        )
        for sample in step_samples:
            metrics = sample.get("metrics", {})
            reason = metrics.get("criticalMissingReason")
            if reason:
                bucket["criticalMissingReasonCounts"][reason] += 1
            for keypoint in metrics.get("missingKeypoints", []):
                bucket["missingKeypointCounts"][keypoint] += 1
            bucket["decisionReasonCounts"][sample.get("decision", {}).get("reason", "")] += 1
            bucket["currentPoseStateCounts"][sample.get("currentPoseState", "")] += 1
            confidence = sample.get("confidence")
            if confidence is not None:
                bucket["confidenceValues"].append(confidence)
            visible = metrics.get("visibleKeypointCount")
            if visible is not None:
                bucket["visibleKeypointValues"].append(visible)
    normalized: dict[str, Any] = {}
    for exercise_mode, bucket in by_exercise.items():
        normalized[exercise_mode] = {
            "criticalMissingReasonCounts": bucket["criticalMissingReasonCounts"].most_common(),
            "missingKeypointCounts": bucket["missingKeypointCounts"].most_common(),
            "decisionReasonCounts": bucket["decisionReasonCounts"].most_common(),
            "currentPoseStateCounts": bucket["currentPoseStateCounts"].most_common(),
            "confidenceDistribution": describe_distribution(bucket["confidenceValues"]),
            "visibleKeypointDistribution": describe_distribution(bucket["visibleKeypointValues"]),
        }
    return normalized


def describe_distribution(values: list[float | int]) -> dict[str, float | int | None]:
    if not values:
        return {"count": 0, "min": None, "max": None, "mean": None, "median": None}
    return {
        "count": len(values),
        "min": min(values),
        "max": max(values),
        "mean": sum(values) / len(values),
        "median": statistics.median(values),
    }


def render_skeleton_svg(sample: dict[str, Any], output_path: Path, title: str) -> None:
    width = 640
    height = 640
    margin = 24
    pose_points = sample.get("posePoints", {})

    def xy(point: dict[str, Any]) -> tuple[float, float]:
        x = float(point.get("x", 0.0))
        y = float(point.get("y", 0.0))
        return margin + x * (width - margin * 2), height - (margin + y * (height - margin * 2))

    lines: list[str] = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        f'<rect x="0" y="0" width="{width}" height="{height}" fill="#0b1020" rx="18"/>',
        f'<text x="{margin}" y="32" fill="#f8fafc" font-size="20" font-family="Helvetica, Arial, sans-serif">{html.escape(title)}</text>',
        f'<text x="{margin}" y="{height - 12}" fill="#94a3b8" font-size="12" font-family="Helvetica, Arial, sans-serif">Vision origin: bottom-left</text>',
    ]
    for first, second in SKELETON_EDGES:
        if first in pose_points and second in pose_points:
            x1, y1 = xy(pose_points[first])
            x2, y2 = xy(pose_points[second])
            lines.append(
                f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" stroke="#60a5fa" stroke-width="4" stroke-linecap="round"/>'
            )
    for name, point in sorted(pose_points.items()):
        x, y = xy(point)
        confidence = float(point.get("confidence", 0.0))
        radius = 3.5 + confidence * 5.0
        lines.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{radius:.1f}" fill="#f97316" stroke="#fff7ed" stroke-width="1"/>')
        lines.append(
            f'<text x="{x + 6:.1f}" y="{y - 6:.1f}" fill="#e2e8f0" font-size="10" font-family="Helvetica, Arial, sans-serif">{html.escape(name)}</text>'
        )
    lines.append("</svg>")
    output_path.write_text("\n".join(lines), encoding="utf-8")


def choose_representative_samples(grouped_samples: dict[int, list[dict[str, Any]]]) -> dict[int, list[dict[str, Any]]]:
    selections: dict[int, list[dict[str, Any]]] = {}
    for step_index, samples in grouped_samples.items():
        if not samples:
            selections[step_index] = []
            continue
        indices = sorted({0, len(samples) // 2, len(samples) - 1})
        picks = [samples[index] for index in indices]
        best_pose = max(samples, key=lambda sample: sample.get("confidence") or 0.0)
        if best_pose not in picks:
            picks.append(best_pose)
        selections[step_index] = picks[:4]
    return selections


def maybe_probe_video(video_path: Path) -> dict[str, Any]:
    if not video_path.exists():
        return {"available": False, "reason": "video.mp4 is missing"}
    ffprobe = shutil.which("ffprobe")
    if not ffprobe:
        return {"available": False, "reason": "ffprobe is not installed"}
    cmd = [
        ffprobe,
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=avg_frame_rate,r_frame_rate,width,height,duration,nb_frames",
        "-of",
        "json",
        str(video_path),
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        data = json.loads(result.stdout)
        stream = (data.get("streams") or [{}])[0]
        return {"available": True, "stream": stream}
    except Exception as exc:
        return {"available": False, "reason": f"ffprobe failed: {exc}"}


def extract_video_frames(video_path: Path, events: list[RepEvent], frames_dir: Path) -> dict[str, list[str]]:
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        return {}
    frame_map: dict[str, list[str]] = {}
    for event in events:
        timestamps = [max(event.timestamp_seconds - 0.5, 0.0), event.timestamp_seconds, event.timestamp_seconds + 0.5]
        outputs: list[str] = []
        for idx, timestamp in enumerate(timestamps):
            filename = f"{safe_slug(event.event_id)}-{idx}.jpg"
            output_path = frames_dir / filename
            cmd = [
                ffmpeg,
                "-y",
                "-ss",
                f"{timestamp:.3f}",
                "-i",
                str(video_path),
                "-frames:v",
                "1",
                str(output_path),
            ]
            try:
                subprocess.run(cmd, capture_output=True, text=True, check=True)
            except Exception:
                continue
            outputs.append(f"frames/{filename}")
        if outputs:
            frame_map[event.event_id] = outputs
    return frame_map


def write_csv(path: Path, rows: list[dict[str, Any]], fieldnames: list[str]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def write_manual_labels_template(path: Path, events: list[RepEvent], candidates: list[MissedCandidate]) -> None:
    rows: list[dict[str, Any]] = []
    for event in events:
        rows.append(
            {
                "eventID": event.event_id,
                "exerciseMode": event.exercise_mode,
                "timestampSeconds": fmt_num(event.timestamp_seconds),
                "analyzerType": "suspiciousRep" if event.suspicious_reasons else "repEvent",
                "systemRepBefore": event.previous_count,
                "systemRepAfter": event.new_count,
                "suggestedReason": "; ".join(event.suspicious_reasons),
                "humanLabel": "",
                "humanComment": "",
            }
        )
    for candidate in candidates:
        rows.append(
            {
                "eventID": candidate.candidate_id,
                "exerciseMode": candidate.exercise_mode,
                "timestampSeconds": fmt_num(candidate.start_timestamp),
                "analyzerType": "missedCandidate",
                "systemRepBefore": candidate.rep_count_before,
                "systemRepAfter": candidate.rep_count_after,
                "suggestedReason": candidate.likely_reason,
                "humanLabel": "",
                "humanComment": "",
            }
        )
    write_csv(
        path,
        rows,
        [
            "eventID",
            "exerciseMode",
            "timestampSeconds",
            "analyzerType",
            "systemRepBefore",
            "systemRepAfter",
            "suggestedReason",
            "humanLabel",
            "humanComment",
        ],
    )


def analyze_labels(labels_path: Path) -> dict[str, Any]:
    with labels_path.open("r", encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle))
    counts = Counter(row.get("humanLabel", "") for row in rows if row.get("humanLabel"))
    tp = counts.get("correctRep", 0)
    fp = counts.get("falsePositive", 0)
    precision_like = tp / (tp + fp) if (tp + fp) else None
    by_exercise: dict[str, Counter[str]] = defaultdict(Counter)
    notes: dict[str, list[str]] = defaultdict(list)
    for row in rows:
        exercise = row.get("exerciseMode", "unknown")
        label = row.get("humanLabel", "")
        if label:
            by_exercise[exercise][label] += 1
        comment = (row.get("humanComment") or "").strip()
        if comment:
            notes[exercise].append(comment)
    return {
        "totalLabeled": sum(counts.values()),
        "confirmedTruePositives": counts.get("correctRep", 0),
        "confirmedFalsePositives": counts.get("falsePositive", 0),
        "confirmedMissedReps": counts.get("missedRep", 0),
        "unclearCount": counts.get("unclear", 0),
        "badFrameCount": counts.get("badFrame", 0),
        "precisionLikeScore": precision_like,
        "perExercise": {exercise: counter.most_common() for exercise, counter in by_exercise.items()},
        "notesPerExercise": {exercise: entries for exercise, entries in notes.items()},
    }


def generate_recommendations(
    metadata: dict[str, Any],
    reviews: list[dict[str, Any]],
    failure_reasons: dict[str, Any],
    rep_events: list[RepEvent],
    missed_candidates: list[MissedCandidate],
) -> list[str]:
    recommendations: list[str] = []
    if metadata.get("brightnessLevel") == "medium":
        recommendations.append("Brightness is medium, so lighting does not look like the main blocker in this session.")
    elif metadata.get("brightnessLevel") in {"dark", "dim"}:
        recommendations.append("Low brightness may have reduced keypoint stability; test a brighter room or stronger front lighting.")
    for review in reviews:
        exercise = review.get("exerciseMode", "unknown")
        detected = review.get("detectedResult")
        accuracy = review.get("recognitionAccuracyRating")
        if exercise == "mountainClimbers" and detected == 9:
            recommendations.append("Mountain climbers detected 9 reps; compare suspicious rep events near the end for false positives during variation changes.")
        if exercise == "lSitHold" and detected == 0:
            recommendations.append("L-sit hold stayed at 0; likely thresholds around hips, legs, or support are too strict for this camera angle.")
        if exercise == "pikePushUps" and detected == 0:
            recommendations.append("Pike push-ups stayed at 0; check whether the pose remained in 'pikeBroken' and whether the low/far camera angle hid shoulders or hips.")
        if accuracy == "partly":
            recommendations.append(f"{exercise}: user marked recognition as partly correct, so inspect suspicious events and missed candidates before changing heuristics.")
    for exercise, bucket in failure_reasons.items():
        missing = bucket.get("missingKeypointCounts", [])
        if missing:
            top_name, top_count = missing[0]
            if top_count:
                recommendations.append(f"{exercise}: many samples are missing {top_name}, which points to camera placement or occlusion problems.")
        reasons = bucket.get("decisionReasonCounts", [])
        if exercise == "pikePushUps" and reasons and reasons[0][0] == "pikeBroken":
            recommendations.append("Pike push-ups: pose stayed in pikeBroken for much of the step, which suggests either strict heuristic thresholds or low/far camera placement.")
    suspicious = [event for event in rep_events if event.suspicious_reasons]
    for event in suspicious[:5]:
        recommendations.append(
            f"{event.exercise_mode}: suspicious rep increment at {event.timestamp_seconds:.2f}s because {', '.join(event.suspicious_reasons[:2])}."
        )
    if missed_candidates:
        sample = missed_candidates[0]
        recommendations.append(
            f"{sample.exercise_mode}: found motion without rep progress around {sample.start_timestamp:.2f}s to {sample.end_timestamp:.2f}s, worth manual review."
        )
    return recommendations


def html_table(rows: list[dict[str, Any]], columns: list[str]) -> str:
    header = "".join(f"<th>{html.escape(column)}</th>" for column in columns)
    body_rows: list[str] = []
    for row in rows:
        cells = "".join(f"<td>{html.escape(str(row.get(column, '')))}</td>" for column in columns)
        body_rows.append(f"<tr>{cells}</tr>")
    return f"<table><thead><tr>{header}</tr></thead><tbody>{''.join(body_rows)}</tbody></table>"


def render_html_report(
    output_dir: Path,
    summary: dict[str, Any],
    session_summary_rows: list[dict[str, Any]],
    review_rows: list[dict[str, Any]],
    segment_rows: list[dict[str, Any]],
    rep_event_rows: list[dict[str, Any]],
    suspicious_rows: list[dict[str, Any]],
    missed_rows: list[dict[str, Any]],
    state_timeline_rows: list[dict[str, Any]],
    state_transition_rows: list[dict[str, Any]],
    pike_unconfirmed_rows: list[dict[str, Any]],
    failure_reasons: dict[str, Any],
    recommendations: list[str],
    skeleton_sections: list[str],
    video_notes: list[str],
    labels_summary: dict[str, Any] | None,
) -> None:
    styles = """
body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 24px; color: #0f172a; background: #f8fafc; }
h1, h2, h3 { color: #0f172a; }
section { background: white; border-radius: 16px; padding: 20px; margin: 0 0 20px 0; box-shadow: 0 8px 24px rgba(15,23,42,0.08); }
table { width: 100%; border-collapse: collapse; font-size: 14px; }
th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid #e2e8f0; vertical-align: top; }
th { background: #eff6ff; }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 14px; }
.card { padding: 14px; border-radius: 12px; background: #eff6ff; }
.muted { color: #475569; }
.warning { color: #b45309; }
.skeletons { display: flex; flex-wrap: wrap; gap: 16px; }
.skeletons img { width: 280px; border-radius: 12px; background: #0b1020; }
"""
    failure_json = html.escape(json.dumps(failure_reasons, ensure_ascii=False, indent=2))
    label_section = ""
    if labels_summary:
        label_section = f"""
        <section>
          <h2>Manual Labels</h2>
          <pre>{html.escape(json.dumps(labels_summary, ensure_ascii=False, indent=2))}</pre>
        </section>
        """
    html_text = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Recognition Debug Report</title>
  <style>{styles}</style>
</head>
<body>
  <h1>Recognition Debug Analysis Report</h1>
  <p class="muted">Generated {html.escape(datetime.now(timezone.utc).isoformat())}</p>
  <section>
    <h2>Session Summary</h2>
    {html_table(session_summary_rows, ["field", "value"])}
  </section>
  <section>
    <h2>Exercise Review Summary</h2>
    {html_table(review_rows, list(review_rows[0].keys()) if review_rows else ["exerciseMode"])}
  </section>
  <section>
    <h2>Timeline</h2>
    {html_table(segment_rows, list(segment_rows[0].keys()) if segment_rows else ["stepIndex"])}
  </section>
  <section>
    <h2>Rep Events</h2>
    {html_table(rep_event_rows, list(rep_event_rows[0].keys()) if rep_event_rows else ["eventID"])}
  </section>
  <section>
    <h2>Suspicious Moments</h2>
    {html_table(suspicious_rows, list(suspicious_rows[0].keys()) if suspicious_rows else ["eventID"])}
  </section>
  <section>
    <h2>Missed Movement Candidates</h2>
    {html_table(missed_rows, list(missed_rows[0].keys()) if missed_rows else ["candidateID"])}
  </section>
  <section>
    <h2>State Timeline</h2>
    {html_table(state_timeline_rows, list(state_timeline_rows[0].keys()) if state_timeline_rows else ["timestampSeconds"])}
  </section>
  <section>
    <h2>State Transitions</h2>
    {html_table(state_transition_rows, list(state_transition_rows[0].keys()) if state_transition_rows else ["fromState"])}
  </section>
  <section>
    <h2>Pike Unconfirmed Cycles</h2>
    {html_table(pike_unconfirmed_rows, list(pike_unconfirmed_rows[0].keys()) if pike_unconfirmed_rows else ["startTimestamp"])}
  </section>
  <section>
    <h2>Failure Reasons</h2>
    <pre>{failure_json}</pre>
  </section>
  <section>
    <h2>Brightness / Camera Conditions</h2>
    <div class="grid">
      <div class="card"><strong>Camera Source</strong><br>{html.escape(str(summary.get("cameraSourceMode")))}</div>
      <div class="card"><strong>Selected Camera</strong><br>{html.escape(str(summary.get("selectedCameraName")))}</div>
      <div class="card"><strong>Capture Resolution</strong><br>{html.escape(str(summary.get("captureResolution")))}</div>
      <div class="card"><strong>Brightness</strong><br>{html.escape(str(summary.get("brightness")))} </div>
    </div>
  </section>
  <section>
    <h2>Skeleton Snapshots</h2>
    {''.join(skeleton_sections)}
  </section>
  <section>
    <h2>Video Frame Review</h2>
    <ul>{''.join(f'<li>{html.escape(note)}</li>' for note in video_notes)}</ul>
  </section>
  <section>
    <h2>Recommendations</h2>
    <ul>{''.join(f'<li>{html.escape(item)}</li>' for item in recommendations)}</ul>
  </section>
  {label_section}
</body>
</html>
"""
    (output_dir / "index.html").write_text(html_text, encoding="utf-8")


def make_session_summary_rows(metadata: dict[str, Any]) -> list[dict[str, Any]]:
    pairs = [
        ("appName", metadata.get("appName")),
        ("appVersion", metadata.get("appVersion")),
        ("buildNumber", metadata.get("buildNumber")),
        ("cameraSourceMode", metadata.get("cameraSourceMode")),
        ("selectedCameraName", metadata.get("selectedCameraName")),
        ("captureResolution", metadata.get("captureResolution")),
        ("previewVideoSize", metadata.get("previewVideoSize")),
        ("sampleIntervalSeconds", metadata.get("sampleIntervalSeconds")),
        ("poseSampleCount", metadata.get("poseSampleCount")),
        ("videoRequested", metadata.get("videoRequested")),
        ("videoRecorded", metadata.get("videoRecorded")),
        ("brightnessAverage", metadata.get("averageBrightness")),
        ("brightnessMin", metadata.get("minBrightness")),
        ("brightnessMax", metadata.get("maxBrightness")),
        ("brightnessLevel", metadata.get("brightnessLevel")),
        ("selectedExercises", metadata.get("selectedExercises")),
        ("durationSeconds", metadata.get("durationSeconds")),
        ("createdAt", metadata.get("createdAt")),
        ("startedAt", metadata.get("startedAt")),
        ("endedAt", metadata.get("endedAt")),
    ]
    return [{"field": key, "value": json.dumps(value, ensure_ascii=False) if isinstance(value, (dict, list)) else value} for key, value in pairs]


def make_review_rows(reviews: list[dict[str, Any]]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for review in reviews:
        placement = review.get("cameraPlacement") or {}
        rows.append(
            {
                "exerciseMode": review.get("exerciseMode"),
                "stepIndex": review.get("stepIndex"),
                "detectedResult": review.get("detectedResult"),
                "userPerformanceRating": review.get("userPerformanceRating"),
                "recognitionAccuracyRating": review.get("recognitionAccuracyRating"),
                "userComment": review.get("userComment"),
                "angleDegrees": placement.get("angleDegrees"),
                "directionLabel": placement.get("directionLabel"),
                "height": placement.get("height"),
                "distance": placement.get("distance"),
                "bodyFraming": placement.get("bodyFraming"),
            }
        )
    return rows


def build_output_rows_for_segments(segments: list[dict[str, Any]]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for segment in segments:
        rows.append(
            {
                "stepIndex": segment["stepIndex"],
                "exerciseMode": segment["exerciseMode"],
                "startTimestamp": fmt_num(segment["startTimestamp"]),
                "endTimestamp": fmt_num(segment["endTimestamp"]),
                "durationSeconds": fmt_num(segment["durationSeconds"]),
                "firstRepCount": segment["firstRepCount"],
                "lastRepCount": segment["lastRepCount"],
                "maxRepCount": segment["maxRepCount"],
                "repIncrements": segment["repIncrements"],
                "holdTimeMax": segment["holdTimeMax"],
                "personDetectedRatio": fmt_num(segment["personDetectedRatio"]),
                "validPoseRatio": fmt_num(segment["validPoseRatio"]),
                "criticalMissingRatio": fmt_num(segment["criticalMissingRatio"]),
                "averageVisibleKeypoints": fmt_num(segment["averageVisibleKeypoints"]),
                "averageConfidence": fmt_num(segment["averageConfidence"]),
                "mostCommonPoseStates": "; ".join(f"{name}:{count}" for name, count in segment["mostCommonPoseStates"]),
                "mostCommonDecisionReasons": "; ".join(f"{name}:{count}" for name, count in segment["mostCommonDecisionReasons"]),
                "brightnessAverage": fmt_num(segment["brightnessAverage"]),
                "brightnessMin": fmt_num(segment["brightnessMin"]),
                "brightnessMax": fmt_num(segment["brightnessMax"]),
            }
        )
    return rows


def build_output_rows_for_events(events: list[RepEvent]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for event in events:
        rows.append(
            {
                "eventID": event.event_id,
                "timestampSeconds": fmt_num(event.timestamp_seconds),
                "exerciseMode": event.exercise_mode,
                "stepIndex": event.step_index,
                "previousCount": event.previous_count,
                "newCount": event.new_count,
                "countDelta": event.count_delta,
                "currentPoseState": event.current_pose_state,
                "decisionReason": event.decision_reason,
                "confidence": fmt_num(event.confidence),
                "visibleKeypointCount": event.visible_keypoint_count,
                "missingKeypoints": ",".join(event.missing_keypoints),
                "bodyLineAngle": fmt_num(event.body_line_angle),
                "brightness": fmt_num(event.brightness),
                "frameIndex": event.frame_index,
                "suspiciousReasons": "; ".join(event.suspicious_reasons),
                "linkedFiles": ", ".join(event.linked_files),
            }
        )
    return rows


def build_output_rows_for_candidates(candidates: list[MissedCandidate]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for candidate in candidates:
        rows.append(
            {
                "candidateID": candidate.candidate_id,
                "exerciseMode": candidate.exercise_mode,
                "stepIndex": candidate.step_index,
                "startTimestamp": fmt_num(candidate.start_timestamp),
                "endTimestamp": fmt_num(candidate.end_timestamp),
                "durationSeconds": fmt_num(candidate.duration_seconds),
                "peakMotionScore": fmt_num(candidate.peak_motion_score),
                "averageMotionScore": fmt_num(candidate.average_motion_score),
                "repCountBefore": candidate.rep_count_before,
                "repCountAfter": candidate.rep_count_after,
                "holdSecondsMax": candidate.hold_seconds_max,
                "likelyReason": candidate.likely_reason,
                "currentPoseState": candidate.current_pose_state,
                "decisionReason": candidate.decision_reason,
                "confidence": fmt_num(candidate.confidence),
                "brightnessAverage": fmt_num(candidate.brightness_average),
                "linkedFiles": ", ".join(candidate.linked_files),
            }
        )
    return rows


def create_skeleton_outputs(
    output_dir: Path,
    grouped_samples: dict[int, list[dict[str, Any]]],
    rep_events: list[RepEvent],
    missed_candidates: list[MissedCandidate],
) -> list[str]:
    frames_dir = output_dir / "frames"
    frames_dir.mkdir(parents=True, exist_ok=True)
    sections: list[str] = []
    representative = choose_representative_samples(grouped_samples)
    for step_index, samples in representative.items():
        if not samples:
            continue
        exercise_mode = samples[0].get("exerciseMode", "unknown")
        image_tags: list[str] = []
        for idx, sample in enumerate(samples):
            filename = f"step-{step_index}-{safe_slug(exercise_mode)}-rep-{idx}.svg"
            render_skeleton_svg(sample, frames_dir / filename, f"{exercise_mode} step {step_index} @ {sample.get('timestampSeconds', 0):.2f}s")
            image_tags.append(f'<img src="frames/{filename}" alt="{html.escape(filename)}">')
        sections.append(f"<h3>{html.escape(exercise_mode)} (step {step_index})</h3><div class='skeletons'>{''.join(image_tags)}</div>")

    sample_lookup = {
        (int(sample.get("stepIndex", -1)), int(sample.get("frameIndex", -1))): sample
        for step_samples in grouped_samples.values()
        for sample in step_samples
    }
    for event in rep_events:
        if not event.suspicious_reasons:
            continue
        sample = sample_lookup.get((event.step_index, event.frame_index))
        if not sample:
            continue
        filename = f"{safe_slug(event.event_id)}.svg"
        render_skeleton_svg(sample, frames_dir / filename, f"Suspicious rep {event.event_id} @ {event.timestamp_seconds:.2f}s")
        event.linked_files.append(f"frames/{filename}")
    for candidate in missed_candidates:
        step_samples = grouped_samples.get(candidate.step_index, [])
        sample = min(
            step_samples,
            key=lambda row: abs(float(row.get("timestampSeconds", 0.0)) - candidate.start_timestamp),
            default=None,
        )
        if not sample:
            continue
        filename = f"{safe_slug(candidate.candidate_id)}.svg"
        render_skeleton_svg(sample, frames_dir / filename, f"Missed candidate {candidate.candidate_id} @ {candidate.start_timestamp:.2f}s")
        candidate.linked_files.append(f"frames/{filename}")
    return sections


def ensure_clean_output(output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "plots").mkdir(exist_ok=True)
    (output_dir / "frames").mkdir(exist_ok=True)


def main() -> int:
    args = parse_args()
    input_path = Path(args.input_path).expanduser().resolve()
    output_dir = Path(args.out).expanduser().resolve()
    labels_path = Path(args.labels).expanduser().resolve() if args.labels else None
    extracted_dir: Path | None = None
    try:
        source_dir, extracted_dir = ensure_input_folder(input_path)
        ensure_clean_output(output_dir)

        metadata = load_json(require_file(source_dir, "metadata.json"))
        reviews_export = load_json(require_file(source_dir, "exercise-reviews.json"))
        reviews = list(reviews_export.get("reviews", []))
        samples = load_jsonl(require_file(source_dir, "pose-samples.jsonl"))
        grouped_samples = exercise_group(samples)
        segments = [summarize_segment(step_index, step_samples) for step_index, step_samples in grouped_samples.items()]
        rep_events = detect_rep_events(grouped_samples)
        suspicious_events = [event for event in rep_events if event.suspicious_reasons]
        missed_candidates = detect_missed_candidates(grouped_samples)
        failure_reasons = aggregate_failure_reasons(grouped_samples)

        skeleton_sections = create_skeleton_outputs(output_dir, grouped_samples, rep_events, missed_candidates)

        video_path = source_dir / "video.mp4"
        video_notes: list[str] = []
        video_probe = maybe_probe_video(video_path)
        if video_probe.get("available"):
            video_notes.append("Video detected and probed successfully.")
            event_frames = extract_video_frames(video_path, suspicious_events, output_dir / "frames")
            for event in suspicious_events:
                event.linked_files.extend(event_frames.get(event.event_id, []))
        else:
            video_notes.append(str(video_probe.get("reason")))
            video_notes.append("Pose-based analysis was generated without video.")

        session_summary_rows = make_session_summary_rows(metadata)
        review_rows = make_review_rows(reviews)
        segment_rows = build_output_rows_for_segments(segments)
        rep_event_rows = build_output_rows_for_events(rep_events)
        suspicious_rows = build_output_rows_for_events(suspicious_events)
        missed_rows = build_output_rows_for_candidates(missed_candidates)
        state_timeline_rows = build_state_timeline_rows(samples)
        state_transition_rows = build_state_transition_rows(samples)
        pike_unconfirmed_rows = detect_pike_unconfirmed_cycles(samples)

        summary = {
            "inputPath": str(input_path),
            "sessionID": metadata.get("sessionID"),
            "cameraSourceMode": metadata.get("cameraSourceMode"),
            "selectedCameraName": metadata.get("selectedCameraName"),
            "captureResolution": metadata.get("captureResolution"),
            "previewVideoSize": metadata.get("previewVideoSize"),
            "brightness": {
                "average": metadata.get("averageBrightness"),
                "min": metadata.get("minBrightness"),
                "max": metadata.get("maxBrightness"),
                "level": metadata.get("brightnessLevel"),
            },
            "poseSampleCount": len(samples),
            "exerciseCount": len(grouped_samples),
            "repEventCount": len(rep_events),
            "suspiciousRepEventCount": len(suspicious_events),
            "missedCandidateCount": len(missed_candidates),
            "pikeUnconfirmedCycleCount": len(pike_unconfirmed_rows),
            "video": {
                "requested": metadata.get("videoRequested"),
                "recorded": metadata.get("videoRecorded"),
                "videoFileExists": video_path.exists(),
                "probe": video_probe,
            },
        }

        write_csv(output_dir / "events.csv", rep_event_rows, list(rep_event_rows[0].keys()) if rep_event_rows else ["eventID"])
        write_csv(output_dir / "segments.csv", segment_rows, list(segment_rows[0].keys()) if segment_rows else ["stepIndex"])
        write_csv(output_dir / "suspicious-moments.csv", suspicious_rows, list(suspicious_rows[0].keys()) if suspicious_rows else ["eventID"])
        write_csv(output_dir / "missed-candidates.csv", missed_rows, list(missed_rows[0].keys()) if missed_rows else ["candidateID"])
        write_csv(output_dir / "state-timeline.csv", state_timeline_rows, list(state_timeline_rows[0].keys()) if state_timeline_rows else ["timestampSeconds"])
        write_csv(output_dir / "state-transitions.csv", state_transition_rows, list(state_transition_rows[0].keys()) if state_transition_rows else ["fromState"])
        write_csv(output_dir / "pike-unconfirmed-cycles.csv", pike_unconfirmed_rows, list(pike_unconfirmed_rows[0].keys()) if pike_unconfirmed_rows else ["startTimestamp"])
        write_csv(
            output_dir / "session-summary.csv",
            session_summary_rows,
            ["field", "value"],
        )
        write_manual_labels_template(output_dir / "manual-labels-template.csv", rep_events, missed_candidates)
        (output_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
        (output_dir / "failure-reasons.json").write_text(json.dumps(failure_reasons, ensure_ascii=False, indent=2), encoding="utf-8")

        labels_summary = analyze_labels(labels_path) if labels_path and labels_path.exists() else None
        if labels_summary:
            (output_dir / "labels-summary.json").write_text(json.dumps(labels_summary, ensure_ascii=False, indent=2), encoding="utf-8")

        recommendations = generate_recommendations(metadata, reviews, failure_reasons, rep_events, missed_candidates)
        render_html_report(
            output_dir=output_dir,
            summary=summary,
            session_summary_rows=session_summary_rows,
            review_rows=review_rows,
            segment_rows=segment_rows,
            rep_event_rows=rep_event_rows,
            suspicious_rows=suspicious_rows,
            missed_rows=missed_rows,
            state_timeline_rows=state_timeline_rows,
            state_transition_rows=state_transition_rows,
            pike_unconfirmed_rows=pike_unconfirmed_rows,
            failure_reasons=failure_reasons,
            recommendations=recommendations,
            skeleton_sections=skeleton_sections,
            video_notes=video_notes,
            labels_summary=labels_summary,
        )
        print(f"Recognition Debug report generated at: {output_dir}")
        return 0
    except Exception as exc:
        print(f"Analyzer failed: {exc}", file=sys.stderr)
        return 1
    finally:
        if extracted_dir and extracted_dir.exists():
            shutil.rmtree(extracted_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
