#!/usr/bin/env bash
# Raw-Docker one-episode smoke for a Coworld game repo.
#
# Goes to:  tools/ci/docker_smoke.sh  in the coworld repo (chmod +x).
# Substitute: coins, cogame-coins, 2.
#
#   tools/ci/docker_smoke.sh [image]
#
# Starts ONE game container plus one player container per seat on a shared
# user-defined docker network, driving them with the certification fixture out
# of coworld_manifest_template.json (same seat mix the certifier will use), and
# asserts the game exits 0 having written results.json and a replay.
#
# It is the containerised twin of the local tmp/run_e2e.sh: same COGAME_*
# contract, same one-player-process-per-slot shape, but every process runs in
# the production image so a broken entrypoint or a missing runtime library
# fails here instead of in hosted certification.
#
# env:
#   SMOKE_IMAGE                image, if not given as $1        (cogame-coins:ci)
#   SMOKE_SLUG                 game slug                        (coins)
#   SMOKE_GAME_BIN             game entrypoint                  (/bin/coins)
#   SMOKE_PLAYER_BIN           player entrypoint                (/bin/coins-player)
#   SMOKE_MANIFEST             manifest template path           (coworld_manifest_template.json)
#   SMOKE_SEATS                seat-count CROSS-CHECK           (2)
#                              must agree with the manifest fixture; it is
#                              not a fallback -- a missing or inconsistent
#                              num_agents is a hard failure
#   SMOKE_PORT                 game port inside the network     (8080)
#   SMOKE_TIMEOUT              seconds to wait for the episode  (900)
#   SMOKE_REQUIRE_REPLAY_JSON  1 = replay must parse as JSON    (1)
#                              set 0 for binary replay formats
#   SMOKE_EXTRA_ENV            extra "K=V K=V" for every player (empty)
#   SMOKE_REPLAY_OUT           where to COPY the replay this smoke produced,
#                              so it outlives the scratch dir the trap deletes
#                              (dist/smoke/replay.json). ci.yml uploads it as
#                              the `smoke-replay` artifact and the wasm-viewer
#                              job loads it in a real browser -- that is the
#                              only replay in CI that is known to be readable
#                              by this game's own viewer.
#   COWORLD_LLM_ENDPOINT       if set, forwarded to the game; otherwise if
#                              ANTHROPIC_API_KEY is also unset, this script
#                              starts a deterministic local HTTP /v1/messages
#                              model fixture so seat 0 (coins-player) executes
#                              real HTTP model moves against seat 1
#                              (coins-reciprocator).
#   ANTHROPIC_API_KEY          if set (and COWORLD_LLM_ENDPOINT is unset),
#                              forwarded to the game so the Anthropic path is
#                              exercised.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "${script_dir}/../.." && pwd)"

image="${1:-${SMOKE_IMAGE:-cogame-coins:ci}}"
slug="${SMOKE_SLUG:-coins}"
game_bin="${SMOKE_GAME_BIN:-/bin/${slug}}"
player_bin="${SMOKE_PLAYER_BIN:-/bin/${slug}-player}"
manifest="${SMOKE_MANIFEST:-${repo_dir}/coworld_manifest_template.json}"
seats_expected="${SMOKE_SEATS:-2}"
port="${SMOKE_PORT:-8080}"
timeout_s="${SMOKE_TIMEOUT:-900}"
require_replay_json="${SMOKE_REQUIRE_REPLAY_JSON:-1}"
replay_out="${SMOKE_REPLAY_OUT:-${repo_dir}/dist/smoke/replay.json}"

run_id="$$"
prefix="${slug}-smoke-${run_id}"
# Per-run network, created and removed by this script. A shared fixed-name
# network (e.g. "coworld-local") collides with the one `coworld play` manages
# and leaks after every local run; on a CI runner it merely never gets cleaned.
network="${prefix}-net"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/${slug}-smoke.XXXXXX")"
seats=0
mock_pid=""

cleanup() {
  if [ -n "${mock_pid}" ]; then
    kill "${mock_pid}" >/dev/null 2>&1 || true
    wait "${mock_pid}" >/dev/null 2>&1 || true
  fi
  docker ps -aq --filter "name=${prefix}" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker network rm "${network}" >/dev/null 2>&1 || true
  rm -rf "${work_dir}"
}
trap cleanup EXIT

dump_logs() {
  echo "---- game container logs (tail 120) ----" >&2
  docker logs "${prefix}-game" 2>&1 | tail -120 >&2 || true
  local slot
  for ((slot = 0; slot < seats; slot++)); do
    echo "---- player ${slot} container logs (tail 40) ----" >&2
    docker logs "${prefix}-p${slot}" 2>&1 | tail -40 >&2 || true
  done
  echo "---- work dir ----" >&2
  ls -la "${work_dir}" >&2 || true
}

test -f "${manifest}" || { echo "manifest not found: ${manifest}" >&2; exit 1; }

# --------------------------------------------------------------------------
# Episode config + per-seat launch args, derived from the cert fixture.
# --------------------------------------------------------------------------
python3 - "${manifest}" "${work_dir}" "${player_bin}" "${seats_expected}" <<'PY'
import json
import os
import shlex
import sys

manifest_path, work, player_bin, seats_expected = sys.argv[1:5]
manifest = json.load(open(manifest_path))
game = manifest.get("game") or {}
cert = manifest.get("certification") or {}
config = dict(cert.get("game_config") or {})
cert_players = list(cert.get("players") or [])

# The seat count comes from ONE place: certification.game_config.num_agents.
# It is never inferred and never guessed. A smoke that quietly picks a seat
# count and goes green is a green signal derived from the wrong game -- worse
# than a red one, because nothing downstream re-checks it.
declared = config.get("num_agents")
if declared is None:
    raise SystemExit(
        f"SEAT-COUNT FAIL: certification.game_config.num_agents is missing from "
        f"{manifest_path}.\n"
        "  The seat count must be declared in the certification fixture (and in "
        "every variant).\n"
        '  Add a "num_agents" integer to certification.game_config and re-run.'
    )
if not isinstance(declared, bool) and isinstance(declared, int) and declared >= 1:
    seats = declared
else:
    raise SystemExit(
        "SEAT-COUNT FAIL: certification.game_config.num_agents must be a "
        f"positive integer, got {declared!r}"
    )

# Every other seat-count declaration in the fixture must agree with it. These
# are free cross-checks on a manifest that was edited in one place only.
if cert_players and len(cert_players) != seats:
    raise SystemExit(
        f"SEAT-COUNT FAIL: certification.game_config.num_agents is {seats} but "
        f"certification.players names {len(cert_players)} seats. The fixture "
        "must seat exactly num_agents players."
    )
fixture_players = list(config.get("players") or [])
if fixture_players and len(fixture_players) != seats:
    raise SystemExit(
        f"SEAT-COUNT FAIL: certification.game_config.num_agents is {seats} but "
        f"certification.game_config.players names {len(fixture_players)} seats."
    )
# SMOKE_SEATS is an independent second declaration, substituted into this file
# at scaffold time from the design note. It is a CROSS-CHECK, not a fallback: if
# it disagrees with the manifest, one of the two was edited alone. A
# non-numeric value means the placeholder was never substituted, which the
# phase-20 placeholder gate catches separately -- ignore it here.
if str(seats_expected).isdigit() and int(seats_expected) != seats:
    raise SystemExit(
        f"SEAT-COUNT FAIL: the manifest fixture declares {seats} seats but "
        f"SMOKE_SEATS says {seats_expected}. The design note and the "
        "manifest disagree; fix whichever is wrong."
    )

players = list(fixture_players)
while len(players) < seats:
    players.append({"name": f"smoke-{len(players)}"})
config["players"] = players[:seats]
config["tokens"] = [f"token-{i}" for i in range(seats)]

with open(os.path.join(work, "config.json"), "w") as fh:
    json.dump(config, fh, indent=2)

by_id = {p.get("id"): p for p in (manifest.get("player") or [])}
extra_env = [kv for kv in (os.environ.get("SMOKE_EXTRA_ENV") or "").split() if "=" in kv]

for slot in range(seats):
    player_id = cert_players[slot].get("player_id") if slot < len(cert_players) else None
    entry = by_id.get(player_id) or {}
    env_args = []
    for key, value in (entry.get("env") or {}).items():
        env_args += ["-e", f"{key}={value}"]
    for kv in extra_env:
        env_args += ["-e", kv]
    argv = list(entry.get("run") or [player_bin])
    with open(os.path.join(work, f"env-{slot}.args"), "w") as fh:
        fh.write(" ".join(shlex.quote(a) for a in env_args))
    with open(os.path.join(work, f"cmd-{slot}.args"), "w") as fh:
        fh.write(" ".join(shlex.quote(a) for a in argv))
    print(f"slot {slot}: player_id={player_id or '(default)'} run={argv} env={len(env_args) // 2}")

with open(os.path.join(work, "seats"), "w") as fh:
    fh.write(str(seats))
print(f"game={game.get('name')} seats={seats} config={json.dumps(config)[:400]}")
PY

seats="$(cat "${work_dir}/seats")"
chmod 777 "${work_dir}"

# --------------------------------------------------------------------------
# Launch.
# --------------------------------------------------------------------------
docker network create "${network}" >/dev/null

game_env=()
used_mock_llm=0
if [ -n "${COWORLD_LLM_ENDPOINT:-}" ]; then
  game_env+=(-e "COWORLD_LLM_ENDPOINT=${COWORLD_LLM_ENDPOINT}")
  if [ -n "${COWORLD_LLM_MODEL:-}" ]; then
    game_env+=(-e "COWORLD_LLM_MODEL=${COWORLD_LLM_MODEL}")
  fi
  echo "COWORLD_LLM_ENDPOINT present: using caller-supplied LLM endpoint"
elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  game_env+=(-e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}")
  echo "ANTHROPIC_API_KEY present: the Anthropic LLM path will be exercised"
else
  used_mock_llm=1
  python3 - "${work_dir}/mock_llm.port" "${work_dir}/mock_llm.calls.jsonl" <<'PY' &
import json
import re
import sys
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port_file, calls_file = sys.argv[1], sys.argv[2]

class FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        if self.path != "/v1/messages":
            self.send_response(404)
            self.end_headers()
            return
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        body = json.loads(raw)
        user = body["messages"][0]["content"]
        beat = int(re.search(r"BEAT (\d+)", user)[1])
        slot = int(self.headers.get("X-Coworld-Player-Slot", "-1"))
        if beat == 2:
            action = {"intent": "guard", "say": "guarding copper", "notes": "beat 2 guard"}
        else:
            action = {"intent": "take_mine", "say": "keeping mine", "notes": f"beat {beat}"}
        with open(calls_file, "a") as fh:
            fh.write(json.dumps({"beat": beat, "slot": slot, "intent": action["intent"]}) + "\n")
        response = json.dumps({
            "model": body.get("model", "docker-smoke-fixture"),
            "stop_reason": "end_turn",
            "content": [{"type": "text", "text": json.dumps(action)}],
            "usage": {"input_tokens": 100, "output_tokens": 20},
        }).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.send_header("X-Softmax-Llm-Call-Id", str(uuid.uuid5(uuid.NAMESPACE_URL, raw.decode())))
        self.end_headers()
        self.wfile.write(response)

server = ThreadingHTTPServer(("0.0.0.0", 0), FixtureHandler)
with open(port_file, "w") as fh:
    fh.write(str(server.server_port))
server.serve_forever()
PY
  mock_pid="$!"
  for _ in $(seq 1 50); do
    if [ -s "${work_dir}/mock_llm.port" ]; then break; fi
    sleep 0.1
  done
  if [ ! -s "${work_dir}/mock_llm.port" ]; then
    echo "FAIL: deterministic local HTTP model fixture failed to start" >&2
    exit 1
  fi
  mock_port="$(cat "${work_dir}/mock_llm.port")"
  game_env+=(-e "COWORLD_LLM_ENDPOINT=http://host.docker.internal:${mock_port}")
  game_env+=(-e "COWORLD_LLM_MODEL=docker-smoke-fixture")
  echo "started deterministic local HTTP model fixture on port ${mock_port}"
fi

echo "starting game container (${image} ${game_bin}) ..."
docker run -d --name "${prefix}-game" \
  --network "${network}" --network-alias "${prefix}-game" \
  --add-host=host.docker.internal:host-gateway \
  -e COGAME_HOST=0.0.0.0 \
  -e COGAME_PORT="${port}" \
  -e COGAME_CONFIG_URI=file:///coworld/config.json \
  -e COGAME_RESULTS_URI=file:///coworld/results.json \
  -e COGAME_SAVE_REPLAY_URI=file:///coworld/replay.json \
  -e COGAME_PLAYER_FAILURE_URI=file:///coworld/player_failure.json \
  ${game_env[@]+"${game_env[@]}"} \
  -v "${work_dir}:/coworld:rw" \
  "${image}" "${game_bin}" >/dev/null

for ((slot = 0; slot < seats; slot++)); do
  eval "penv=( $(cat "${work_dir}/env-${slot}.args") )"
  eval "pcmd=( $(cat "${work_dir}/cmd-${slot}.args") )"
  docker run -d --name "${prefix}-p${slot}" --network "${network}" \
    -e COWORLD_PLAYER_WS_URL="ws://${prefix}-game:${port}/player?slot=${slot}&token=token-${slot}" \
    ${penv[@]+"${penv[@]}"} \
    "${image}" ${pcmd[@]+"${pcmd[@]}"} >/dev/null
done

# --------------------------------------------------------------------------
# Wait for the game container to exit.
# --------------------------------------------------------------------------
echo "waiting for the episode (game container exit, up to ${timeout_s}s) ..."
deadline=$((SECONDS + timeout_s))
while docker ps -q --filter "name=${prefix}-game" | grep -q .; do
  if (( SECONDS > deadline )); then
    echo "FAIL: game container did not exit within ${timeout_s}s" >&2
    dump_logs
    exit 1
  fi
  sleep 3
done

exit_code="$(docker inspect -f '{{.State.ExitCode}}' "${prefix}-game")"
if [ "${exit_code}" != "0" ]; then
  echo "FAIL: game container exited ${exit_code}" >&2
  dump_logs
  exit 1
fi

# Every PLAYER container must exit 0 too (the raid learning): whisky's
# receiveMessage RAISES on a close frame, and mummy's send only queues, so the
# game's quit(0) can outrun the flushed final frame. Hosted certification
# checks this; the starter smoke only checked the game, which is how the race
# passed one dispatch and failed the next.
for ((slot = 0; slot < seats; slot++)); do
  deadline=$((SECONDS + 60))
  while docker ps -q --filter "name=${prefix}-p${slot}" | grep -q .; do
    if (( SECONDS > deadline )); then
      echo "FAIL: player ${slot} did not exit within 60s of the game" >&2
      dump_logs
      exit 1
    fi
    sleep 2
  done
  player_code="$(docker inspect -f '{{.State.ExitCode}}' "${prefix}-p${slot}")"
  if [ "${player_code}" != "0" ]; then
    echo "FAIL: player ${slot} container exited ${player_code}" >&2
    dump_logs
    exit 1
  fi
done
echo "all ${seats} player containers exited 0"

# --------------------------------------------------------------------------
# Assert the artifacts.
# --------------------------------------------------------------------------
if ! python3 - "${work_dir}" "${seats}" "${require_replay_json}" "${used_mock_llm}" <<'PY'
import json
import sys
from pathlib import Path

work = Path(sys.argv[1])
seats = int(sys.argv[2])
require_replay_json = sys.argv[3] not in ("0", "", "false", "no")
used_mock_llm = sys.argv[4] == "1"

failure = work / "player_failure.json"
if failure.exists():
    raise SystemExit(f"player failure reported: {failure.read_text()[:1000]}")

results_path = work / "results.json"
if not results_path.exists() or results_path.stat().st_size == 0:
    raise SystemExit("results.json missing or empty")
raw = results_path.read_bytes()
try:
    results = json.loads(raw.decode("utf-8"))
except Exception as exc:
    raise SystemExit(f"results.json is not valid UTF-8 JSON: {exc}") from exc
if not isinstance(results, dict) or not results:
    raise SystemExit(f"results.json is not a non-empty object: {results!r}")

for key in ("names", "scores"):
    if key in results:
        if len(results[key]) != seats:
            raise SystemExit(f"results.{key} has {len(results[key])} entries, expected {seats}")
    else:
        print(f"WARNING: results.json has no '{key}' key")

reason = results.get("reason") or results.get("end_reason")
if reason is not None:
    print(f"episode end reason: {reason}")
if reason not in ("random_end", "beat_cap"):
    raise SystemExit(f"unexpected episode end reason: {reason!r}")

replay_path = work / "replay.json"
if not replay_path.exists() or replay_path.stat().st_size == 0:
    raise SystemExit("replay missing or empty (COGAME_SAVE_REPLAY_URI was file:///coworld/replay.json)")
replay = None
if require_replay_json:
    try:
        replay = json.loads(replay_path.read_bytes().decode("utf-8"))
    except Exception as exc:
        raise SystemExit(
            f"replay is not valid UTF-8 JSON: {exc} "
            "(set SMOKE_REQUIRE_REPLAY_JSON=0 for a binary replay format)"
        ) from exc

if used_mock_llm:
    calls_path = work / "mock_llm.calls.jsonl"
    if not calls_path.exists():
        raise SystemExit("deterministic local HTTP model fixture received zero requests")
    calls = [json.loads(line) for line in calls_path.read_text().splitlines() if line.strip()]
    beats = int(results.get("beats", 0))
    if len(calls) != beats:
        raise SystemExit(f"expected {beats} HTTP model calls for seat 0, got {len(calls)}")
    if any(c["slot"] != 0 for c in calls):
        raise SystemExit(f"expected HTTP model calls only for seat 0, got {calls}")
    orders = [e for e in (replay or {}).get("events", []) if e.get("k") == "order"]
    seat0 = [e for e in orders if e.get("seat") == 0]
    seat1 = [e for e in orders if e.get("seat") == 1]
    if len(seat0) != beats or len(seat1) != beats:
        raise SystemExit(f"unexpected order counts: seat0={len(seat0)} seat1={len(seat1)} beats={beats}")
    if any(e.get("source") != "llm" for e in seat0):
        raise SystemExit(f"seat 0 did not apply HTTP llm moves: {[e.get('source') for e in seat0]}")
    if seat0[1].get("intent") != "guard" or seat0[1].get("say") != "guarding copper":
        raise SystemExit(f"seat 0 beat 2 did not apply returned HTTP move: {seat0[1]}")
    if any(e.get("source") != "scripted" for e in seat1):
        raise SystemExit(f"seat 1 did not stay scripted: {[e.get('source') for e in seat1]}")
    print(f"verified {len(calls)} HTTP /v1/messages calls applied on seat 0 vs scripted seat 1")

print(
    f"smoke OK: seats={seats} results={results_path.stat().st_size}B "
    f"replay={replay_path.stat().st_size}B reason={reason}"
)
PY
then
  dump_logs
  exit 1
fi

# --------------------------------------------------------------------------
# Keep the replay. `work_dir` is a mktemp the EXIT trap removes, so without
# this the only replay CI ever produced is deleted seconds after it is
# validated -- and the wasm-viewer job has nothing real to load. ci.yml
# uploads this copy as the `smoke-replay` artifact.
# --------------------------------------------------------------------------
mkdir -p "$(dirname "${replay_out}")"
cp "${work_dir}/replay.json" "${replay_out}"
if [ -f "${work_dir}/results.json" ]; then
  cp "${work_dir}/results.json" "$(dirname "${replay_out}")/results.json"
fi
echo "replay saved for the viewer smoke: ${replay_out} ($(wc -c < "${replay_out}" | tr -d ' ') bytes)"
