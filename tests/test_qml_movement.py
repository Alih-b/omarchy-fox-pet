#!/usr/bin/env python3
"""Black-box movement tests against the real QML service.

The Python regression tests cover data contracts. This module starts one
headless Quickshell instance, calls Service.qml's deterministic physics step,
and asserts the observable state transitions. No movement logic is copied into
the test, so a change in Service.qml is what makes these tests fail or pass.
"""

import os
import selectors
import shutil
import subprocess
import tempfile
import textwrap
import time
import unittest
from pathlib import Path


HARNESS = textwrap.dedent(
    r'''
    import QtQuick
    import Quickshell

    Item {
      id: root
      Service { id: fox }

      function check(condition, label) {
        if (condition) console.log("HARNESS_PASS", label)
        else console.log("HARNESS_FAIL", label)
      }

      function closeEnough(actual, expected) {
        return Math.abs(actual - expected) < 0.0001
      }

      Component.onCompleted: {
        // Keep the scheduler out of these checks; each test advances the real
        // production step exactly once.
        fox.enabled = false
        fox.physicsEnabled = false
        fox.recomputeGround()

        fox.positionX = 200
        fox.positionY = 300
        fox.velocityX = 2
        fox.velocityY = 0
        fox.physicsStep()
        check(closeEnough(fox.positionX, 202), "step advances horizontal position")
        check(closeEnough(fox.positionY, 300.45), "step applies gravity")

        fox.positionX = 0
        fox.positionY = 300
        fox.velocityX = -4
        fox.velocityY = 0
        fox.direction = -1
        fox.physicsStep()
        check(fox.positionX === fox.edgeMargin, "left wall clamps to edge margin")
        check(fox.direction === 1 && closeEnough(fox.velocityX, fox.walkSpeed),
              "left wall reverses movement and facing")

        var screenGeometry = fox.screenGeometry(fox.currentScreen())
        var rightEdge = screenGeometry.width - fox.cellWidth * fox.scale - fox.edgeMargin
        fox.positionX = rightEdge + 2
        fox.positionY = 300
        fox.velocityX = 4
        fox.velocityY = 0
        fox.physicsStep()
        check(closeEnough(fox.positionX, rightEdge), "right wall clamps to edge margin")
        check(fox.direction === -1 && closeEnough(fox.velocityX, -fox.walkSpeed),
              "right wall reverses movement and facing")

        fox.positionX = 200
        fox.positionY = fox.groundY
        fox.velocityX = 0
        fox.velocityY = 4
        fox.physicsStep()
        check(fox.velocityY < 0, "fast landing bounces upward")
        check(fox.positionY < fox.groundY, "bounce advances above ground")

        fox.petState = fox.statePlay
        fox.isJumping = true
        fox.positionY = fox.groundY
        fox.velocityY = 0.5
        fox.physicsStep()
        check(!fox.isJumping, "soft landing ends jump")
        check(fox.positionY === fox.groundY && fox.velocityY === 0,
              "soft landing settles on ground")

        fox.petState = fox.stateIdle
        fox.positionX = 200
        fox.positionY = 300
        fox.velocityX = 0
        fox.velocityY = 0
        fox.jump()
        check(fox.isJumping && fox.petState === fox.statePlay,
              "jump enters play state")
        check(fox.velocityY === fox.jumpImpulse, "jump applies impulse")
        var jumpVelocity = fox.velocityY
        fox.jump()
        check(fox.velocityY === jumpVelocity, "second jump is ignored in flight")

        fox.petState = fox.stateIdle
        fox.velocityX = -2
        fox.setState(fox.stateWalk)
        check(fox.direction === -1 && fox.velocityX === -2,
              "walk preserves existing momentum direction")
        fox.setState(fox.stateIdle)
        check(fox.velocityX === 0, "non-walk state stops horizontal movement")

        fox.enabled = true
        fox.petState = fox.stateWalk
        fox.manualSleep = false
        fox.isDragging = true
        fox.positionY = 300
        fox.velocityX = 4
        fox.velocityY = 3
        fox.settleDrop(500)
        check(!fox.isDragging && fox.velocityX === 0, "drop ends drag and toss")
        check(fox.velocityY === 0 && fox.petState === fox.stateIdle,
              "awake drop settles into idle")

        fox.petState = fox.stateSleep
        fox.manualSleep = true
        fox.isDragging = true
        fox.positionY = 300
        fox.settleDrop(500)
        check(fox.petState === fox.stateSleep && fox.manualSleep,
              "sleeping drop preserves sleep")

        fox.disable()
        console.log("HARNESS_DONE")
      }
    }
    '''
)


class TestQmlMovement(unittest.TestCase):
    def test_real_service_movement(self):
        repo_root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(prefix="fox-pet-qml-test-") as temp:
            temp_root = Path(temp)
            shutil.copy2(repo_root / "Service.qml", temp_root / "Service.qml")

            # Service.qml imports the host's qs.Commons module. The movement
            # service does not use a Commons symbol, so a minimal local module
            # keeps this test independent of a full Omarchy installation.
            commons = temp_root / "Commons"
            commons.mkdir()
            (commons / "qmldir").write_text(
                "module qs.Commons\nUtil 1.0 Util.qml\n", encoding="utf-8"
            )
            (commons / "Util.qml").write_text(
                "import QtQml\nQtObject {}\n", encoding="utf-8"
            )
            harness_path = temp_root / "MovementHarness.qml"
            harness_path.write_text(HARNESS, encoding="utf-8")

            env = os.environ.copy()
            env["HOME"] = str(temp_root)
            env.pop("WAYLAND_DISPLAY", None)
            env["QT_QPA_PLATFORM"] = "offscreen"
            env["QT_QPA_PLATFORMTHEME"] = ""
            env["XDG_RUNTIME_DIR"] = str(temp_root)

            process = subprocess.Popen(
                ["quickshell", "-p", str(harness_path)],
                cwd=temp_root,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            output = []
            deadline = time.monotonic() + 8
            selector = selectors.DefaultSelector()
            selector.register(process.stdout, selectors.EVENT_READ)
            try:
                while time.monotonic() < deadline:
                    ready = selector.select(max(0, deadline - time.monotonic()))
                    if not ready:
                        break
                    line = process.stdout.readline()
                    if not line:
                        if process.poll() is not None:
                            break
                        continue
                    output.append(line)
                    if "HARNESS_DONE" in line:
                        break
                else:
                    self.fail("QML movement harness timed out\n" + "".join(output))
            finally:
                selector.close()
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=2)
                process.stdout.close()

            transcript = "".join(output)
            failures = [line for line in output if "HARNESS_FAIL" in line]
            self.assertTrue(
                "HARNESS_DONE" in transcript,
                "QML movement harness did not complete\n" + transcript,
            )
            self.assertFalse(
                failures,
                "\n".join(failures) + "\nFull output:\n" + transcript,
            )


if __name__ == "__main__":
    unittest.main()
