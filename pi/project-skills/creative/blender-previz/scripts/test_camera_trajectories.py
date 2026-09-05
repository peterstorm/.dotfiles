#!/usr/bin/env python3
from __future__ import annotations

import math
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).parent))

from camera_trajectories import (
    CameraSample,
    OrbitPassSpec,
    OverheadOrbitSpec,
    RoboticArmHold,
    RoboticArmSpec,
    VerticalRiseSpec,
    sample_orbit_pass,
    sample_overhead_orbit,
    sample_robotic_arm,
    sample_vertical_rise,
    translate,
)


class OrbitPassTests(unittest.TestCase):
    def setUp(self) -> None:
        self.spec = OrbitPassSpec(
            frame_count=80,
            entry_frames=5,
            orbit_frames=66,
            exit_frames=9,
            radius=9.0,
            height=9.0,
            below_surface_height=-2.2,
            target_height=1.25,
        )

    def test_orbit_phase_is_a_true_horizontal_circle(self) -> None:
        samples = [sample_orbit_pass(self.spec, frame) for frame in range(5, 71)]
        for sample in samples:
            x, y, z = sample.position
            self.assertAlmostEqual(math.hypot(x, y), self.spec.radius, places=9)
            self.assertAlmostEqual(z, self.spec.height, places=9)

    def test_exit_is_vertical_and_never_reverses_around_target(self) -> None:
        samples = [sample_orbit_pass(self.spec, frame) for frame in range(71, 80)]
        horizontal = {(round(sample.position[0], 9), round(sample.position[1], 9)) for sample in samples}
        self.assertEqual(len(horizontal), 1)
        self.assertTrue(all(a.position[2] >= b.position[2] for a, b in zip(samples, samples[1:])))
        self.assertLess(samples[-1].position[2], 0)

    def test_translation_reuses_identical_relative_curve(self) -> None:
        origin = (40.0, -3.0, 2.0)
        for frame in range(self.spec.frame_count):
            relative = sample_orbit_pass(self.spec, frame)
            translated = translate(relative, origin)
            self.assertEqual(
                translated,
                CameraSample(
                    tuple(a + b for a, b in zip(relative.position, origin, strict=True)),
                    tuple(a + b for a, b in zip(relative.target, origin, strict=True)),
                ),
            )

    def test_invalid_phase_partition_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "exactly fill"):
            OrbitPassSpec(80, 5, 65, 9, 9, 9, -2, 1.25)


class OverheadOrbitTests(unittest.TestCase):
    def setUp(self) -> None:
        self.spec = OverheadOrbitSpec(frame_count=80, radius=9.0, target_height=1.25)
        self.samples = [sample_overhead_orbit(self.spec, frame) for frame in range(80)]

    def test_path_starts_at_ground_level_and_goes_up_and_over(self) -> None:
        self.assertAlmostEqual(self.samples[0].position[2], self.spec.target_height, places=9)
        self.assertAlmostEqual(max(sample.position[2] for sample in self.samples), self.spec.target_height + self.spec.radius, places=2)
        self.assertLess(self.samples[-1].position[2], 0)
        self.assertTrue(all(abs(sample.position[0]) < 1e-9 for sample in self.samples))

    def test_camera_rig_becomes_upside_down_after_crossing_the_apex(self) -> None:
        far_side = max(self.samples, key=lambda sample: sample.position[1])
        self.assertLess(far_side.up[2], -0.99)

    def test_every_position_remains_on_one_vertical_orbit(self) -> None:
        target = (0.0, 0.0, self.spec.target_height)
        for sample in self.samples:
            radius = math.dist(sample.position, target)
            self.assertAlmostEqual(radius, self.spec.radius, places=9)

    def test_terminal_motion_accelerates_into_the_surface(self) -> None:
        distances = [
            math.dist(a.position, b.position)
            for a, b in zip(self.samples[-6:-1], self.samples[-5:])
        ]
        self.assertTrue(all(a < b for a, b in zip(distances, distances[1:])))


class VerticalRiseTests(unittest.TestCase):
    def test_rise_is_monotonic_with_fixed_horizontal_position(self) -> None:
        spec = VerticalRiseSpec(80, (0.0, -8.0, 0.0), 0.7, 7.7, 1.2)
        samples = [sample_vertical_rise(spec, frame) for frame in range(80)]
        self.assertTrue(all(sample.position[:2] == (0.0, -8.0) for sample in samples))
        self.assertTrue(all(a.position[2] <= b.position[2] for a, b in zip(samples, samples[1:])))


class RoboticArmTests(unittest.TestCase):
    def setUp(self) -> None:
        self.spec = RoboticArmSpec(
            first_frame=481,
            entry_position=(0.0, -3.2, -1.2),
            flight_frames=8,
            holds=(
                RoboticArmHold(490, (0.0, -3.2, 2.0), (0.0, 0.0, 1.65)),
                RoboticArmHold(528, (-2.6, -2.2, 2.0), (0.0, 0.0, 1.85), (-0.5, 0.0, 0.8)),
                RoboticArmHold(566, (0.8, -2.2, 5.0), (0.0, 0.0, 1.2), (0.0, -0.6, 1.1)),
            ),
        )

    def test_each_hold_is_dead_still_until_the_next_flight(self) -> None:
        first_hold = {sample_robotic_arm(self.spec, frame) for frame in range(490, 520)}
        second_hold = {sample_robotic_arm(self.spec, frame) for frame in range(528, 558)}
        final_hold = {sample_robotic_arm(self.spec, frame) for frame in range(566, 721)}
        self.assertEqual(len(first_hold), 1)
        self.assertEqual(len(second_hold), 1)
        self.assertEqual(len(final_hold), 1)

    def test_flights_land_exactly_on_declared_holds(self) -> None:
        for hold in self.spec.holds:
            self.assertEqual(sample_robotic_arm(self.spec, hold.arrival_frame), CameraSample(hold.position, hold.target))


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]])
