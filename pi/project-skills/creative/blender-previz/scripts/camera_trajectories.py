#!/usr/bin/env python3
"""Reusable, Blender-independent camera trajectory primitives.

All functions are pure and return immutable tuple data. Blender scene scripts own
conversion to mathutils vectors and keyframe I/O.
"""

from __future__ import annotations

from dataclasses import dataclass
import math

Vec3 = tuple[float, float, float]


@dataclass(frozen=True)
class CameraSample:
    position: Vec3
    target: Vec3
    up: Vec3 = (0.0, 0.0, 1.0)


@dataclass(frozen=True)
class OrbitPassSpec:
    frame_count: int
    entry_frames: int
    orbit_frames: int
    exit_frames: int
    radius: float
    height: float
    below_surface_height: float
    target_height: float
    start_angle_radians: float = -math.pi / 2
    revolutions: float = 1.0

    def __post_init__(self) -> None:
        if self.frame_count < 3:
            raise ValueError("orbit pass requires at least three frames")
        if min(self.entry_frames, self.orbit_frames, self.exit_frames) < 2:
            raise ValueError("entry, orbit, and exit phases each require at least two frames")
        if self.entry_frames + self.orbit_frames + self.exit_frames != self.frame_count:
            raise ValueError("orbit phase lengths must exactly fill frame_count")
        if self.radius <= 0 or self.height <= self.target_height:
            raise ValueError("orbit radius must be positive and camera must remain above its target")
        if self.below_surface_height >= 0:
            raise ValueError("surface-transition endpoint must be below zero")
        if self.revolutions <= 0:
            raise ValueError("orbit must complete a positive revolution count")


@dataclass(frozen=True)
class OverheadOrbitSpec:
    frame_count: int
    radius: float
    target_height: float
    start_phase_radians: float = 0.0
    weighted_phase_radians: float = 0.85 * math.pi
    end_phase_radians: float = 1.35 * math.pi
    weight_split: float = 0.72
    plane_heading_radians: float = -math.pi / 2

    def __post_init__(self) -> None:
        if self.frame_count < 3:
            raise ValueError("overhead orbit requires at least three frames")
        if self.radius <= 0:
            raise ValueError("overhead orbit radius must be positive")
        if not self.start_phase_radians < self.weighted_phase_radians < self.end_phase_radians:
            raise ValueError("overhead orbit phases must be strictly increasing")
        if self.weighted_phase_radians <= math.pi / 2 or self.end_phase_radians <= math.pi:
            raise ValueError("overhead orbit must pass the apex and invert before its terminal dive")
        if not 0 < self.weight_split < 1:
            raise ValueError("overhead orbit weight split must be inside the pass")


@dataclass(frozen=True)
class VerticalRiseSpec:
    frame_count: int
    horizontal_offset: Vec3
    start_height: float
    end_height: float
    target_height: float
    middle_slowdown: float = 0.10

    def __post_init__(self) -> None:
        if self.frame_count < 2:
            raise ValueError("vertical rise requires at least two frames")
        if self.end_height <= self.start_height:
            raise ValueError("vertical rise end must be above its start")
        if not 0 <= self.middle_slowdown < 1 / math.tau:
            raise ValueError("middle slowdown must preserve monotonic upward travel")


@dataclass(frozen=True)
class RoboticArmHold:
    arrival_frame: int
    position: Vec3
    target: Vec3
    incoming_arc: Vec3 = (0.0, 0.0, 0.0)


@dataclass(frozen=True)
class RoboticArmSpec:
    first_frame: int
    entry_position: Vec3
    flight_frames: int
    holds: tuple[RoboticArmHold, ...]

    def __post_init__(self) -> None:
        if self.flight_frames < 2:
            raise ValueError("robotic-arm flights require at least two frame intervals")
        if not self.holds:
            raise ValueError("robotic-arm trajectory requires at least one hold")
        arrivals = tuple(hold.arrival_frame for hold in self.holds)
        if tuple(sorted(arrivals)) != arrivals or len(set(arrivals)) != len(arrivals):
            raise ValueError("robotic-arm hold arrivals must be unique and increasing")
        if arrivals[0] <= self.first_frame:
            raise ValueError("first hold must follow the entry frame")
        if any(b - a <= self.flight_frames for a, b in zip(arrivals, arrivals[1:])):
            raise ValueError("each robotic-arm hold must leave a nonzero static interval")


def _clamp01(value: float) -> float:
    return min(1.0, max(0.0, value))


def smoothstep(value: float) -> float:
    t = _clamp01(value)
    return t * t * (3.0 - 2.0 * t)


def _add(a: Vec3, b: Vec3) -> Vec3:
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])


def _lerp(a: Vec3, b: Vec3, t: float) -> Vec3:
    return tuple(x + (y - x) * t for x, y in zip(a, b, strict=True))  # type: ignore[return-value]


def _scale(value: Vec3, scalar: float) -> Vec3:
    return (value[0] * scalar, value[1] * scalar, value[2] * scalar)


def _cross(a: Vec3, b: Vec3) -> Vec3:
    return (
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


def translate(sample: CameraSample, origin: Vec3) -> CameraSample:
    return CameraSample(_add(origin, sample.position), _add(origin, sample.target), sample.up)


def sample_orbit_pass(spec: OrbitPassSpec, local_frame: int) -> CameraSample:
    """Sample entry, true horizontal orbit, then a separate vertical surface dive."""
    if not 0 <= local_frame < spec.frame_count:
        raise IndexError("orbit local_frame outside pass")

    orbit_start = spec.entry_frames
    exit_start = orbit_start + spec.orbit_frames
    angle = spec.start_angle_radians
    z = spec.height

    if local_frame < orbit_start:
        entry_t = smoothstep(local_frame / (spec.entry_frames - 1))
        z = spec.below_surface_height + (spec.height - spec.below_surface_height) * entry_t
    elif local_frame < exit_start:
        orbit_t = smoothstep((local_frame - orbit_start) / (spec.orbit_frames - 1))
        angle += math.tau * spec.revolutions * orbit_t
    else:
        angle += math.tau * spec.revolutions
        exit_t = smoothstep((local_frame - exit_start) / (spec.exit_frames - 1))
        z = spec.height + (spec.below_surface_height - spec.height) * exit_t

    position = (spec.radius * math.cos(angle), spec.radius * math.sin(angle), z)
    return CameraSample(position, (0.0, 0.0, spec.target_height))


def sample_overhead_orbit(spec: OverheadOrbitSpec, local_frame: int) -> CameraSample:
    """Sample a weighted ground-level orbit up, over, inverted, and down through the surface."""
    if not 0 <= local_frame < spec.frame_count:
        raise IndexError("overhead-orbit local_frame outside pass")

    t = local_frame / (spec.frame_count - 1)
    if t <= spec.weight_split:
        weighted = smoothstep(t / spec.weight_split)
        phase = spec.start_phase_radians + (
            spec.weighted_phase_radians - spec.start_phase_radians
        ) * weighted
    else:
        terminal = (t - spec.weight_split) / (1.0 - spec.weight_split)
        phase = spec.weighted_phase_radians + (
            spec.end_phase_radians - spec.weighted_phase_radians
        ) * terminal * terminal

    horizontal = (
        math.cos(spec.plane_heading_radians),
        math.sin(spec.plane_heading_radians),
        0.0,
    )
    vertical = (0.0, 0.0, 1.0)
    right = _cross(vertical, horizontal)
    radial = _add(_scale(horizontal, math.cos(phase)), _scale(vertical, math.sin(phase)))
    position = _add((0.0, 0.0, spec.target_height), _scale(radial, spec.radius))
    forward = _scale(radial, -1.0)
    up = _cross(right, forward)
    return CameraSample(position, (0.0, 0.0, spec.target_height), up)


def sample_vertical_rise(spec: VerticalRiseSpec, local_frame: int) -> CameraSample:
    if not 0 <= local_frame < spec.frame_count:
        raise IndexError("vertical-rise local_frame outside pass")
    t = local_frame / (spec.frame_count - 1)
    progress = t + spec.middle_slowdown * math.sin(math.tau * t)
    position = (
        spec.horizontal_offset[0],
        spec.horizontal_offset[1],
        spec.start_height + (spec.end_height - spec.start_height) * progress,
    )
    return CameraSample(position, (0.0, 0.0, spec.target_height))


def _sample_arc(a: Vec3, b: Vec3, arc: Vec3, t: float) -> Vec3:
    eased = smoothstep(t)
    return _add(_lerp(a, b, eased), _scale(arc, 4.0 * eased * (1.0 - eased)))


def sample_robotic_arm(spec: RoboticArmSpec, frame: int) -> CameraSample:
    if frame < spec.first_frame:
        raise IndexError("robotic-arm frame precedes trajectory")

    first = spec.holds[0]
    if frame <= first.arrival_frame:
        t = smoothstep((frame - spec.first_frame) / (first.arrival_frame - spec.first_frame))
        return CameraSample(_lerp(spec.entry_position, first.position, t), first.target)

    previous = first
    for hold in spec.holds[1:]:
        flight_start = hold.arrival_frame - spec.flight_frames
        if frame < flight_start:
            return CameraSample(previous.position, previous.target)
        if frame <= hold.arrival_frame:
            if frame == hold.arrival_frame:
                return CameraSample(hold.position, hold.target)
            t = (frame - flight_start) / spec.flight_frames
            return CameraSample(
                _sample_arc(previous.position, hold.position, hold.incoming_arc, t),
                _lerp(previous.target, hold.target, smoothstep(t)),
            )
        previous = hold

    return CameraSample(previous.position, previous.target)
