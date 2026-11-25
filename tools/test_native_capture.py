"""Exercise complete native server/player games and preserve all test artifacts."""

import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def make_provider(fail_beat=None, unavailable=False):
    calls = []

    class Provider(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def do_POST(self):
            raw = self.rfile.read(int(self.headers["Content-Length"]))
            body = json.loads(raw)
            user = body["messages"][0]["content"]
            beat = int(re.search(r"BEAT (\d+)", user)[1])
            slot = self.headers["X-Coworld-Player-Slot"]
            calls.append((beat, int(slot)))
            assert "PRIVATE_OPERATOR_" + slot in user
            assert "PRIVATE_OPERATOR_" + str(1 - int(slot)) not in user
            if unavailable:
                self.send_error(503)
                return
            if fail_beat is not None and beat == fail_beat:
                text = "invalid fixture reply"
            else:
                action = {"intent": "take_mine", "say": "", "notes": "PRIVATE_CAPTURE_" + slot}
                if beat == 2:
                    action["intent"] = "guard"
                    text = "My move:\n```json\n" + json.dumps(action) + "\n```"
                else:
                    if beat == 3:
                        action.update(notes="x" * 900, say="s" * 100)
                    text = json.dumps(action)
            response = json.dumps(
                {
                    "model": body["model"],
                    "stop_reason": "end_turn",
                    "content": [{"type": "text", "text": text}],
                    "usage": None if beat == 4 else {"input_tokens": 100, "output_tokens": 20},
                }
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response)))
            self.send_header("X-Softmax-Llm-Call-Id", str(uuid.uuid5(uuid.NAMESPACE_URL, raw.decode())))
            self.end_headers()
            self.wfile.write(response)

    return Provider, calls


def run(
    game,
    player,
    output,
    variant,
    capture,
    model_enabled=True,
    fail_beat=None,
    unavailable=False,
    seat1_scripted=None,
    label="",
):
    suffix = label or f"{variant['id']}-capture{capture}{'' if model_enabled else '-offline'}"
    root = output / suffix
    root.mkdir(mode=0o700)
    config = dict(variant["game_config"])
    seats = config["num_agents"]
    config.update(
        seed=42,
        minBeatSeconds=0,
        llmTimeoutSeconds=1,
        playerConnectTimeoutSeconds=5,
        episodeTimeoutSeconds=120,
        shutdownGraceSeconds=1,
        tokens=[f"fixture-{i}" for i in range(seats)],
    )
    (root / "config.json").write_text(json.dumps(config))
    with socket.socket() as candidate:
        candidate.bind(("127.0.0.1", 0))
        port = candidate.getsockname()[1]
    env = dict(os.environ)
    for key in (
        "COWORLD_LLM_ENDPOINT",
        "COWORLD_LLM_MODEL",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_API_KEY_URI",
        "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
        "AWS_BEARER_TOKEN_BEDROCK",
    ):
        env.pop(key, None)
    episode = f"coins-native-capture-fixture-{suffix}"
    env.update(
        COGAME_HOST="127.0.0.1",
        COGAME_PORT=str(port),
        COGAME_CONFIG_URI=(root / "config.json").as_uri(),
        COGAME_RESULTS_URI=(root / "results.json").as_uri(),
        COGAME_SAVE_REPLAY_URI=(root / "replay.json").as_uri(),
        COGAME_PLAYER_FAILURE_URI=(root / "player_failure.json").as_uri(),
        COGAME_SAVE_TRAJECTORY_URI=(root / "trajectory.jsonl").as_uri(),
        COWORLD_EPISODE_ID=episode,
        COWORLD_GAME_VERSION="identity-fixture",
        COWORLD_SOURCE_REVISION="a" * 40,
    )
    if not capture:
        env.pop("COGAME_SAVE_TRAJECTORY_URI")
    provider_cls, calls = make_provider(fail_beat=fail_beat, unavailable=unavailable)
    provider = ThreadingHTTPServer(("127.0.0.1", 0), provider_cls)
    thread = threading.Thread(target=provider.serve_forever, daemon=True)
    thread.start()
    if model_enabled:
        env["COWORLD_LLM_ENDPOINT"] = f"http://127.0.0.1:{provider.server_port}"
        env["COWORLD_LLM_MODEL"] = "native-capture-fixture"
    children = []
    streams = []
    try:
        log = (root / "game.log").open("wb")
        streams.append(log)
        server = subprocess.Popen([str(game)], env=env, stdout=log, stderr=subprocess.STDOUT)
        children.append(server)
        for _ in range(100):
            assert server.poll() is None, "game exited before readiness; see retained game.log"
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=1) as response:
                    assert response.status == 200
                break
            except (urllib.error.URLError, TimeoutError):
                time.sleep(0.05)
        else:
            raise TimeoutError("native game did not become ready")
        for seat in range(seats):
            log = (root / f"player-{seat}.log").open("wb")
            streams.append(log)
            player_env = dict(env, COWORLD_TIMEOUT_SECONDS="120")
            if seat == 1 and seat1_scripted:
                player_env["PLAYER_SCRIPTED"] = seat1_scripted
            else:
                player_env["PLAYER_PROMPT"] = f"PRIVATE_OPERATOR_{seat}"
            player_env["COWORLD_PLAYER_WS_URL"] = f"ws://127.0.0.1:{port}/player?slot={seat}&token=fixture-{seat}"
            children.append(subprocess.Popen([str(player)], env=player_env, stdout=log, stderr=subprocess.STDOUT))
        expect_failure = not model_enabled or unavailable or fail_beat is not None
        assert server.wait(timeout=120) == int(expect_failure)
        results_path = root / "results.json"
        failure_path = root / "player_failure.json"
        if expect_failure:
            assert not results_path.exists()
            failure = json.loads(failure_path.read_text())
            assert failure["failed_policy_index"] == 0
            assert failure.get("kind", "player_error") == ("player_error" if fail_beat else "episode_inconclusive")
            if capture:
                trace = root / "trajectory.jsonl"
                rows = [json.loads(line) for line in trace.read_text().splitlines()]
                assert trace.stat().st_mode & 0o077 == 0
                assert rows[-1]["status"] == "failed"
                assert rows[-1]["outcome"] == failure
                failed_row = rows[-2]
                assert failed_row["action_status"] == "rejected"
                assert failed_row["selected_attempt_id"] is None
                assert failed_row["executed_action"] is None
                assert failed_row["terminal"] is True
                if unavailable:
                    assert len(calls) == seats and len(failed_row["attempts"]) == 1
                    assert "503" in failure["message"]
                elif not model_enabled:
                    assert len(failed_row["attempts"]) == 1
                    assert failed_row["attempts"][0]["rejection_reason"] is not None
                else:
                    assert calls.count((fail_beat, 0)) == 1
                    assert len(failed_row["attempts"]) == 1
                    for attempt in failed_row["attempts"]:
                        assert not attempt["accepted"]
                        assert "invalid fixture reply" in attempt["raw_response"]
            return failure

        for child in children[1:]:
            assert child.wait(timeout=5) == 0
        results = json.loads(results_path.read_text())
        replay = json.loads((root / "replay.json").read_text())
        assert not failure_path.exists(), f"unexpected failure: {failure_path.read_text()}"
        assert results["reason"] in ("random_end", "beat_cap")
        assert config["minBeats"] <= results["beats"] <= config["maxBeats"]
        orders = [event for event in replay["events"] if event["k"] == "order"]
        assert all(event["source"] != "fallback" for event in orders)

        if seat1_scripted:
            assert calls, "model seat must call HTTP"
            assert all(slot == 0 for _, slot in calls), "only model seat should call HTTP"
            seat0_orders = [e for e in orders if e["seat"] == 0]
            seat1_orders = [e for e in orders if e["seat"] == 1]
            assert len(seat0_orders) == results["beats"]
            assert len(seat1_orders) == results["beats"]
            assert all(order["source"] == "llm" for order in seat0_orders)
            assert seat0_orders[1]["intent"] == "guard" and seat0_orders[1]["source"] == "llm"
            assert all(e["source"] == "scripted" for e in seat1_orders)
        elif capture:
            trace = root / "trajectory.jsonl"
            rows = [json.loads(line) for line in trace.read_text().splitlines()]
            assert trace.stat().st_mode & 0o077 == 0
            assert len(rows) == results["beats"] * seats + 1
            assert rows[-1]["status"] == "completed"
            assert rows[-1]["outcome"] == results
            for row in rows[:-1]:
                beat = row["observation"]["beat"]
                attempts = row["attempts"]
                assert row["action_status"] == "accepted"
                assert len(attempts) == 1 and attempts[0]["accepted"]
                assert row["selected_attempt_id"] == attempts[0]["attempt_id"]
                if beat == 2:
                    assert row["executed_action"]["intent"] == "guard"
                if beat == 3:
                    assert len(row["executed_action"]["notes"]) == 300
                    assert len(row["executed_action"]["say"]) == 48
                if beat == 4:
                    assert attempts[0]["input_tokens"] is None
                    assert attempts[0]["output_tokens"] is None
                for attempt in attempts:
                    assert attempt["prompt"][0]["content"] == attempt["request"]["system"]
                    assert attempt["platform_call_id"] is not None
                    assert attempt["behavior_logprobs"] is None
            assert len(orders) == len(rows) - 1
            for event, row in zip(orders, rows[:-1], strict=True):
                assert event["beat"] == row["observation"]["beat"]
                assert event["seat"] == int(row["seat"])
                assert {key: event[key] for key in ("intent", "say", "notes")} == row["executed_action"]
        for event in replay["events"]:
            event.pop("latencyMs", None)
        return results, replay
    finally:
        provider.shutdown()
        provider.server_close()
        thread.join(timeout=5)
        for child in children:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=5)
        for stream in streams:
            stream.close()


def main():
    game, player, destination = map(lambda value: Path(value).resolve(), sys.argv[1:])
    destination.mkdir(mode=0o700, exist_ok=False)
    manifest = json.loads((Path(__file__).resolve().parents[1] / "coworld_manifest_template.json").read_text())
    for variant in manifest["variants"]:
        captured = run(game, player, destination, variant, True)
        ordinary = run(game, player, destination, variant, False)
        assert captured == ordinary, "capture changed the native outcome or replay"
    run(
        game,
        player,
        destination,
        manifest["variants"][0],
        True,
        seat1_scripted="reciprocator",
        label="model-vs-reciprocator",
    )
    run(
        game,
        player,
        destination,
        manifest["variants"][0],
        True,
        fail_beat=2,
        label="invalid-reply-fails",
    )
    run(game, player, destination, manifest["variants"][0], True,
        unavailable=True, label="provider-unavailable")
    captured = run(
        game,
        player,
        destination,
        manifest["variants"][0],
        True,
        model_enabled=False,
        label="offline-no-creds-capture",
    )
    ordinary = run(
        game,
        player,
        destination,
        manifest["variants"][0],
        False,
        model_enabled=False,
        label="offline-no-creds-ordinary",
    )
    assert captured == ordinary, "capture changed the offline failure outcome or replay"
    print(
        "native games passed: physical replay parity, model-vs-baseline HTTP execution, "
        "one marked JSON action, normalization, explicit failure on invalid replies "
        "and missing credentials"
    )


if __name__ == "__main__":
    main()
