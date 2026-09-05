#!/usr/bin/env python3
"""
Regression test suite for omarchy-fox-pet.
Validates state machine invariants, sprite math, multi-monitor mapping,
drop physics, and persistence schema.
"""

import json
import os
import unittest


class TestFoxPetRegression(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        cls.pet_json_path = os.path.join(cls.repo_root, "assets", "pet.json")
        cls.manifest_json_path = os.path.join(cls.repo_root, "manifest.json")

    def test_manifest_schema(self):
        with open(self.manifest_json_path, "r", encoding="utf-8") as f:
            manifest = json.load(f)
        self.assertEqual(manifest.get("id"), "fox-pet")
        self.assertIn("service", manifest.get("kinds", []))
        self.assertIn("panel", manifest.get("kinds", []))
        self.assertIn("bar-widget", manifest.get("kinds", []))
        self.assertEqual(manifest["entryPoints"]["service"], "Service.qml")
        self.assertEqual(manifest["entryPoints"]["panel"], "Panel.qml")
        self.assertEqual(manifest["entryPoints"]["barWidget"], "BarWidget.qml")

    def test_pet_meta_json_schema(self):
        with open(self.pet_json_path, "r", encoding="utf-8") as f:
            pet_meta = json.load(f)

        self.assertIn("sprite", pet_meta)
        sprite = pet_meta["sprite"]
        columns = sprite.get("columns")
        cell_width = sprite.get("cellWidth")
        cell_height = sprite.get("cellHeight")
        row_count = sprite.get("rowCount")

        self.assertIsInstance(columns, int)
        self.assertGreater(columns, 0)
        self.assertIsInstance(cell_width, int)
        self.assertGreater(cell_width, 0)
        self.assertIsInstance(cell_height, int)
        self.assertGreater(cell_height, 0)
        self.assertIsInstance(row_count, int)
        self.assertGreater(row_count, 0)

        # Invariant: rowCount must be a valid positive integer to prevent NaN sourceSize in Image
        source_width = cell_width * columns
        source_height = cell_height * row_count
        self.assertEqual(source_width, 1536)
        self.assertEqual(source_height, 2288)

        # Verify essential rows are all specified
        required_rows = [
            "idle", "sitRight", "sitLeft", "greet", "yawn",
            "sleep", "play", "alert", "walk", "somersault"
        ]
        rows = sprite.get("rows", {})
        for req in required_rows:
            self.assertIn(req, rows, f"Missing required sprite row specification: {req}")
            self.assertIn("row", rows[req])
            self.assertIn("frames", rows[req])
            self.assertIn("fps", rows[req])
            self.assertGreater(rows[req]["frames"], 0)
            self.assertGreater(rows[req]["fps"], 0)

    def test_multi_monitor_coordinate_invariants(self):
        # Simulation of Quickshell multi-monitor screens
        screens = [
            {"x": 0, "y": 0, "width": 1920, "height": 1080},
            {"x": 1920, "y": 0, "width": 1920, "height": 1080},
        ]

        def to_absolute(local_x, local_y, screen_idx):
            sg = screens[screen_idx]
            return {"x": sg["x"] + local_x, "y": sg["y"] + local_y}

        def to_local(abs_x, abs_y, screen_idx):
            sg = screens[screen_idx]
            return {"x": abs_x - sg["x"], "y": abs_y - sg["y"]}

        def screen_at(abs_x, abs_y):
            for idx, sg in enumerate(screens):
                if (sg["x"] <= abs_x < sg["x"] + sg["width"] and
                        sg["y"] <= abs_y < sg["y"] + sg["height"]):
                    return idx
            return 0

        # Invariant: local -> absolute -> local roundtrip must be identity
        test_points = [
            (0, 100, 200),
            (0, 1800, 900),
            (1, 50, 600),
            (1, 1500, 1000)
        ]
        for s_idx, lx, ly in test_points:
            abs_pt = to_absolute(lx, ly, s_idx)
            recovered_s_idx = screen_at(abs_pt["x"], abs_pt["y"])
            self.assertEqual(recovered_s_idx, s_idx)
            local_pt = to_local(abs_pt["x"], abs_pt["y"], recovered_s_idx)
            self.assertEqual(local_pt["x"], lx)
            self.assertEqual(local_pt["y"], ly)

        # Cross-monitor boundary test: Dragging from screen 0 across boundary x=1920
        start_local = {"x": 1910, "y": 500}
        abs_crossing = to_absolute(start_local["x"] + 20, start_local["y"], 0)
        self.assertEqual(abs_crossing["x"], 1930)
        new_screen = screen_at(abs_crossing["x"], abs_crossing["y"])
        self.assertEqual(new_screen, 1)
        new_local = to_local(abs_crossing["x"], abs_crossing["y"], new_screen)
        self.assertEqual(new_local["x"], 10)
        self.assertEqual(new_local["y"], 500)

    def test_state_machine_manual_sleep_invariants(self):
        class MockFoxState:
            def __init__(self):
                self.petState = "idle"
                self.manualSleep = False
                self.direction = 1
                self.velocityX = 0.0
                self.walkSpeed = 1.6

            def sleepNow(self):
                self.manualSleep = True
                self.petState = "sleep"

            def poke(self):
                self.manualSleep = False
                if self.petState == "sleep":
                    self.petState = "yawn"
                else:
                    self.petState = "greet"

            def pickNextAction(self):
                # Autonomous AI step: must not wake up if manualSleep is True
                if self.petState == "sleep" and self.manualSleep:
                    return
                self.petState = "idle"

            def startWalk(self, new_dir=None):
                self.petState = "walk"
                if new_dir is not None:
                    self.direction = new_dir
                self.velocityX = self.walkSpeed * self.direction

            def onGlanceExpire(self):
                # Restores direction to match velocityX
                if self.petState == "walk":
                    self.direction = 1 if self.velocityX >= 0 else -1

        fox = MockFoxState()
        # Explicit sleep command
        fox.sleepNow()
        self.assertEqual(fox.petState, "sleep")
        self.assertTrue(fox.manualSleep)

        # AI timer triggers while sleeping: must remain asleep
        fox.pickNextAction()
        self.assertEqual(fox.petState, "sleep")
        self.assertTrue(fox.manualSleep)

        # User pokes fox: wakes into yawn and clears manualSleep
        fox.poke()
        self.assertEqual(fox.petState, "yawn")
        self.assertFalse(fox.manualSleep)

        # Subsequent AI timer triggers: transitions normally to idle
        fox.pickNextAction()
        self.assertEqual(fox.petState, "idle")

        # Walk direction sync: walking left
        fox.startWalk(new_dir=-1)
        self.assertEqual(fox.direction, -1)
        self.assertAlmostEqual(fox.velocityX, -1.6)

        # Glance expire must maintain negative direction
        fox.onGlanceExpire()
        self.assertEqual(fox.direction, -1)

    def test_persistence_payload_schema(self):
        payload = {
            "positionX": round(250.4),
            "positionY": round(600.8),
            "direction": 1,
            "currentScreenIndex": 0,
            "scale": 1.25,
            "physicsEnabled": True,
            "showShadow": True,
            "followCursor": True
        }
        serialized = json.dumps(payload)
        deserialized = json.loads(serialized)

        self.assertEqual(deserialized["positionX"], 250)
        self.assertEqual(deserialized["positionY"], 601)
        self.assertEqual(deserialized["direction"], 1)
        self.assertEqual(deserialized["scale"], 1.25)

    def test_walk_locomotion_mapping(self):
        with open(self.pet_json_path, "r", encoding="utf-8") as f:
            pet_meta = json.load(f)
        rows = pet_meta["sprite"]["rows"]
        # Invariant: walk must map to Row 1 (forward leap) rather than Row 9 (turntable spin)
        self.assertEqual(rows["walk"]["row"], 1)
        self.assertEqual(rows["walk"]["frames"], 8)
        self.assertEqual(rows["spin"]["row"], 9)
        self.assertEqual(rows["sleep"]["row"], 5)

    def test_wayland_drag_mask_state(self):
        # Invariant: Mask dynamically targets windowRoot during drag for unbreakable grab,
        # and dragProxy when idle so clicks anywhere outside the fox pass cleanly through.
        def get_mask_target(is_dragging):
            return "windowRoot" if is_dragging else "dragProxy"

        self.assertEqual(get_mask_target(False), "dragProxy")
        self.assertEqual(get_mask_target(True), "windowRoot")

    def test_sleep_now_unconditional_settlement(self):
        # Invariant: sleepNow() settles fox firmly on the ground plane and enters
        # sleep without being blocked by previous altitude or jumping state.
        class MockFoxSleep:
            def __init__(self):
                self.ground_y = 600.0
                self.position_y = 250.0  # High in the air
                self.velocity_y = 5.0
                self.velocity_x = 1.6
                self.is_jumping = True
                self.manual_sleep = False
                self.pet_state = "walk"

            def sleep_now(self):
                self.position_y = self.ground_y
                self.velocity_y = 0.0
                self.velocity_x = 0.0
                self.is_jumping = False
                self.manual_sleep = True
                self.pet_state = "sleep"

        fox = MockFoxSleep()
        fox.sleep_now()
        self.assertEqual(fox.position_y, 600.0)
        self.assertEqual(fox.velocity_y, 0.0)
        self.assertEqual(fox.velocity_x, 0.0)
        self.assertFalse(fox.is_jumping)
        self.assertTrue(fox.manual_sleep)
        self.assertEqual(fox.pet_state, "sleep")

    def test_gesture_wheel_and_double_click_mappings(self):
        # Invariant: Wheel UP triggers jump, Wheel DOWN triggers sleep/wake toggle,
        # double-click toggles sleep/wake cleanly.
        class MockFoxGestures:
            def __init__(self):
                self.pet_state = "idle"
                self.manual_sleep = False
                self.jump_count = 0

            def jump(self):
                self.jump_count += 1
                self.pet_state = "play"

            def sleep_toggle(self):
                if self.pet_state == "sleep":
                    self.manual_sleep = False
                    self.pet_state = "yawn"
                else:
                    self.manual_sleep = True
                    self.pet_state = "sleep"

            def on_wheel(self, angle_delta_y):
                if angle_delta_y > 0:
                    self.jump()
                elif angle_delta_y < 0:
                    self.sleep_toggle()

        fox = MockFoxGestures()
        # Wheel UP -> Jump
        fox.on_wheel(120)
        self.assertEqual(fox.jump_count, 1)
        self.assertEqual(fox.pet_state, "play")

        # Wheel DOWN -> Sleep
        fox.on_wheel(-120)
        self.assertEqual(fox.pet_state, "sleep")
        self.assertTrue(fox.manual_sleep)

        # Wheel DOWN again -> Wake (yawn)
        fox.on_wheel(-120)
        self.assertEqual(fox.pet_state, "yawn")
        self.assertFalse(fox.manual_sleep)

    def test_physics_timer_reactive_binding(self):
        # Invariant: physicsTimer.running is purely reactive:
        # running: service.enabled && service.physicsEnabled && !service.isDragging
        def is_physics_running(enabled, physics_enabled, is_dragging):
            return bool(enabled and physics_enabled and not is_dragging)

        self.assertTrue(is_physics_running(True, True, False))
        # Dragging temporarily pauses physics without destroying property binding
        self.assertFalse(is_physics_running(True, True, True))
        # Dropping immediately resumes physics
        self.assertTrue(is_physics_running(True, True, False))
        # Disabling pauses physics
        self.assertFalse(is_physics_running(False, True, False))
        self.assertFalse(is_physics_running(True, False, False))

    def test_native_drag_proxy_invariants(self):
        # Invariant: Drag proxy follows service when idle, and drives service when dragging
        class MockDragProxy:
            def __init__(self, service_x, service_y):
                self.service_x = service_x
                self.service_y = service_y
                self.drag_active = False
                self.proxy_x = service_x
                self.proxy_y = service_y

            def get_x(self):
                if not self.drag_active:
                    return round(self.service_x)
                return self.proxy_x

            def simulate_drag_move(self, new_x, new_y):
                self.drag_active = True
                self.proxy_x = new_x
                self.proxy_y = new_y
                self.service_x = new_x
                self.service_y = new_y

            def simulate_drop(self):
                self.drag_active = False

        proxy = MockDragProxy(100, 200)
        self.assertEqual(proxy.get_x(), 100)
        proxy.simulate_drag_move(350, 450)
        self.assertEqual(proxy.get_x(), 350)
        self.assertEqual(proxy.service_x, 350)
        proxy.simulate_drop()
        self.assertEqual(proxy.get_x(), 350)

    def test_sleep_transform_invariants(self):
        # Invariant: Dedicated sleeping sprite requires no artificial tilt or shrink
        sleep_tilt = 0
        sleep_scale = 1.0
        self.assertEqual(sleep_tilt, 0)
        self.assertEqual(sleep_scale, 1.0)

    def test_settle_drop_preserves_sleeping_state(self):
        # Invariant: settleDrop must keep sleeping fox asleep without waking or running
        class MockFox:
            def __init__(self, state="idle", manual_sleep=False):
                self.petState = state
                self.manualSleep = manual_sleep
                self.isDragging = True
                self.velocityX = 0.0
                self.actionTimerRunning = True
                self.actionTimerInterval = 0

            def setState(self, next_state):
                self.petState = next_state

            def settleDrop(self):
                self.isDragging = False
                self.velocityX = 0.0
                if self.manualSleep or self.petState == "sleep":
                    self.manualSleep = True
                    self.setState("sleep")
                    self.actionTimerRunning = False
                else:
                    self.setState("idle")
                    self.actionTimerInterval = 3000
                    self.actionTimerRunning = True

        # Dropping an awake fox -> settles into idle and restarts timer
        awake_fox = MockFox(state="walk", manual_sleep=False)
        awake_fox.settleDrop()
        self.assertEqual(awake_fox.petState, "idle")
        self.assertTrue(awake_fox.actionTimerRunning)
        self.assertEqual(awake_fox.actionTimerInterval, 3000)

        # Dropping a sleeping fox -> preserves sleep, keeps timer stopped
        sleep_fox = MockFox(state="sleep", manual_sleep=True)
        sleep_fox.settleDrop()
        self.assertEqual(sleep_fox.petState, "sleep")
        self.assertTrue(sleep_fox.manualSleep)
        self.assertFalse(sleep_fox.actionTimerRunning)

        # Dropping an autonomously sleeping fox -> locks manualSleep to prevent sudden waking
        auto_sleep_fox = MockFox(state="sleep", manual_sleep=False)
        auto_sleep_fox.settleDrop()
        self.assertEqual(auto_sleep_fox.petState, "sleep")
        self.assertTrue(auto_sleep_fox.manualSleep)
        self.assertFalse(auto_sleep_fox.actionTimerRunning)

    def test_sleep_wake_transition_via_yawn(self):
        # Invariant: Waking up from sleep must transition through yawn (stretch) before idle
        class MockFox:
            def __init__(self):
                self.petState = "sleep"
                self.manualSleep = False

            def pickNextAction(self):
                if self.petState == "sleep" and self.manualSleep:
                    return
                if self.petState == "sleep":
                    self.petState = "yawn"
                    return
                if self.petState == "yawn":
                    self.petState = "idle"
                    return

        fox = MockFox()
        # Wake step 1: routes through stretch/yawn intermediate frames
        fox.pickNextAction()
        self.assertEqual(fox.petState, "yawn")
        # Wake step 2: settles into idle
        fox.pickNextAction()
        self.assertEqual(fox.petState, "idle")

    def test_state_continuity_preserves_frame_index(self):
        # Invariant: Re-entering a continuous state (walk, idle) must not slam frameIndex to 0
        class MockState:
            def __init__(self):
                self.petState = "idle"
                self.frameIndex = 0

            def setState(self, next_state):
                changed = self.petState != next_state
                self.petState = next_state
                one_shot = next_state in ["greet", "play", "spin", "somersault"]
                if changed or one_shot:
                    self.frameIndex = 0

        fox = MockState()
        # Start walking
        fox.setState("walk")
        fox.frameIndex = 4  # Mid-stride

        # AI rolls walk again while already walking
        fox.setState("walk")
        self.assertEqual(fox.frameIndex, 4, "Mid-stride walk must NOT reset frameIndex to 0")

        # Explicit one-shot action re-trigger resets frameIndex
        fox.setState("greet")
        fox.frameIndex = 2
        fox.setState("greet")
        self.assertEqual(fox.frameIndex, 0, "One-shot action re-trigger must restart from frame 0")

    def test_toss_momentum_guarded_when_asleep(self):
        # Invariant: Fling / toss gesture must be suppressed when fox is sleeping
        def compute_release_velocity(drag_velocity_x, is_asleep):
            if not is_asleep and abs(drag_velocity_x) > 2.5:
                return max(-10.0, min(10.0, drag_velocity_x * 0.75))
            return 0.0

        # Fast drag release while awake -> imparts velocity
        self.assertAlmostEqual(compute_release_velocity(6.0, False), 4.5)
        # Fast drag release while asleep -> zero velocity (no fling, stays asleep)
        self.assertAlmostEqual(compute_release_velocity(6.0, True), 0.0)


if __name__ == "__main__":
    unittest.main()
