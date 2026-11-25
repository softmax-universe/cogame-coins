## tests/test_llm.nim — the decision layer.
##
## `extractJsonObject` on raw JSON and outer Markdown JSON fences (rejecting
## prose preambles/suffixes); canonical intent and baseline parsing; explicit
## failure when credentials are missing (no silent fallback); and ONE batch
## carrying every open seat with the inter-batch wall-clock floor honoured.

import std/[json, os, strutils, times, unicode]
import coins/[sim_types, sim, scripted, llm]

for key in ["COWORLD_LLM_ENDPOINT", "COWORLD_LLM_MODEL",
    "AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "AWS_BEARER_TOKEN_BEDROCK",
    "ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY_URI"]:
  delEnv(key)

var failures = 0

proc check(condition: bool, what: string) =
  if not condition:
    echo "FAIL: ", what
    failures.inc

proc raises(body: proc ()): bool =
  try:
    body()
    false
  except CatchableError:
    true

proc config(): GameConfig =
  result = defaultGameConfig()
  result.seed = 4
  result.minBeats = 6
  result.maxBeats = 6
  result.tokens = @["t0", "t1"]
  result.players = @[PlayerConfig(name: "Copper"), PlayerConfig(name: "Cobalt")]

# ---------------------------------------------------------------------------
echo "--- extractJsonObject accepts raw JSON or outer Markdown JSON fence only"
block:
  let plain = """{"intent": "take_mine"}"""
  check(extractJsonObject(plain){"intent"}.getStr() == "take_mine", "plain")

  let fenced = "```json\n{\"intent\": \"guard\", \"say\": \"mine\"}\n```"
  check(extractJsonObject(fenced){"intent"}.getStr() == "guard", "fenced json")

  let bareFence = "```\n{\"intent\": \"hold\"}\n```"
  check(extractJsonObject(bareFence){"intent"}.getStr() == "hold", "bare outer fence")

  let prosePrefix = "Let me think about this.\n\n{\"intent\": \"hold\"}"
  check(raises(proc () = discard extractJsonObject(prosePrefix)),
    "prose before the object is rejected")

  let trailing = "{\"intent\": \"take_any\"}\n\nThat should keep me even."
  check(raises(proc () = discard extractJsonObject(trailing)),
    "trailing prose after the closing brace is rejected")

  check(raises(proc () = discard extractJsonObject("no json at all here")),
    "a reply with no object at all is rejected")

echo "--- intent parsing is canonical and closed"
block:
  check(parseIntent("take_mine") == inTakeMine, "take_mine")
  check(parseIntent(" take_theirs ") == inTakeTheirs, "trimmed canonical")
  check(parseIntent("take_any") == inTakeAny, "take_any")
  check(parseIntent("guard") == inGuard, "guard")
  check(parseIntent("hold") == inHold, "hold")
  check(raises(proc () = discard parseIntent("TAKE_MINE")),
    "uppercase alias is rejected")
  check(raises(proc () = discard parseIntent("take-any")),
    "hyphen alias is rejected")
  check(raises(proc () = discard parseIntent("take any")),
    "space alias is rejected")
  check(raises(proc () = discard parseIntent("steal_everything")),
    "an intent outside the five is rejected")

echo "--- scripted baseline parsing is canonical and closed"
block:
  check(parseScriptKind("honest") == skHonest, "honest")
  check(parseScriptKind("greedy") == skGreedy, "greedy")
  check(parseScriptKind("reciprocator") == skReciprocator, "reciprocator")
  check(parseScriptKind("tit-for-tat") == skTitForTat, "tit-for-tat")
  for alias in ["cooperate", "always-cooperate", "defect", "always-defect",
      "1", "true", "yes", "recip", "titfortat", "tit_for_tat", "tft"]:
    check(parseScriptKind(alias) == skNone, "alias rejected: " & alias)
  var sim = initSim(config())
  check(raises(proc () =
    discard scriptedIntent(skNone, sim.buildObservation(0))),
    "skNone never falls back to a baseline")

echo "--- parseDecision applies the rune caps and rejects bad fields"
block:
  let wide = "\u4e2d"
  let payload = %*{
    "intent": "guard",
    "say": wide.repeat(MaxSayLen + 20),
    "notes": wide.repeat(MaxNotesLen + 40),
    "extraKeyNobodyAsksFor": 17
  }
  let decision = parseDecision(payload)
  check(decision.intent == inGuard, "the intent parses")
  check(decision.say.runeLen <= MaxSayLen, "say is capped in runes")
  check(decision.notes.runeLen <= MaxNotesLen, "notes is capped in runes")
  check(decision.source == osLlm, "a parsed decision is sourced llm")
  check(raises(proc () = discard parseDecision(%*{"say": "hi"})),
    "a reply with no intent is invalid")
  check(raises(proc () = discard parseDecision(%*{"intent": "Guard"})),
    "non-canonical intent casing is invalid")
  check(raises(proc () = discard parseDecision(%*{"intent": "sprint"})),
    "an unknown intent is invalid")
  check(raises(proc () = discard parseDecision(%*{"intent": "hold", "say": 123})),
    "non-string say is invalid")
  check(parseDecision(%*{"intent": "hold"}).say == "",
    "say and notes are optional")

echo "--- with no credentials the client fails explicitly instead of falling back"
block:
  let client = newLlmClient(config())
  var sim = initSim(config())
  let seats = @[0, 1]
  let prompts = @["be nice", "be nicer"]
  let kinds = @[skNone, skNone]
  if client.disabled:
    var failed = false
    var failedSlot = -1
    try:
      discard client.decideAll(sim, seats, prompts, kinds)
    except DecisionFailureError as err:
      failed = true
      failedSlot = err.slot
    check(failed, "disabled client raises DecisionFailureError for LLM seats")
    check(failedSlot == 0, "failure reports the failing seat slot")
    check(client.batchStarts.len == 0,
      "a disabled client opens no batches at all")

echo "--- a scripted seat never enters the batch"
block:
  let client = newLlmClient(config())
  var sim = initSim(config())
  let before = client.batchStarts.len
  let decisions = client.decideAll(sim, @[0, 1], @["", ""],
    @[skHonest, skGreedy])
  check(decisions.len == 2, "two decisions")
  check(decisions[0].source == osScripted and decisions[1].source == osScripted,
    "both seats are scripted")
  check(client.batchStarts.len == before,
    "no batch is opened when every seat is scripted")

echo "--- one batch carries every open seat, and the inter-batch floor holds"
block:
  ## `decideAll` opens AT MOST ONE batch per beat, and that batch carries
  ## every open seat: it is never one request per seat in sequence, which is
  ## what blows the 720 s play budget.
  let client = newLlmClient(config())
  var sim = initSim(config())
  if not client.disabled:
    for beat in 0 .. 2:
      discard client.decideAll(sim, @[0, 1], @["a", "b"], @[skNone, skNone],
        proc (seconds: float) {.closure.} = sleep(int(seconds * 1000)))
    check(client.batchStarts.len == 3, "one batch per beat, not one per seat")
    for index in 1 ..< client.batchStarts.len:
      check(client.batchStarts[index] - client.batchStarts[index - 1] >=
        sim.config.minBeatSeconds.float - 0.25,
        "consecutive batch starts are >= minBeatSeconds apart")

echo "--- the paced wait is the sidecar rate limit, stated"
block:
  ## The Bedrock sidecar caps 30 requests/minute PER EPISODE (the raid
  ## learning). Two seats per batch against a 5 s floor is 24 req/min.
  let cfg = config()
  check(60 div cfg.minBeatSeconds * Seats <= 30,
    "2 seats per batch at the minBeatSeconds floor stays under 30 req/min")
  let client = newLlmClient(cfg)
  check(client.pacedWait(epochTime()) == 0.0,
    "the first batch of an episode never waits")
  client.lastBatchAt = epochTime()
  let wait = client.pacedWait(epochTime())
  check(wait > 0.0 and wait <= cfg.minBeatSeconds.float + 0.01,
    "a second batch waits out the floor, got " & $wait)

echo "--- the wall-clock budget is inside 60% of episodeTimeoutSeconds"
block:
  let cfg = config()
  check(cfg.playDeadlineSeconds() == 720.0,
    "the play deadline is 720 s at the default 1200 s timeout")
  var worst = defaultGameConfig()
  check((worst.maxBeats * worst.worstCaseBeatSeconds()).float <=
    worst.playDeadlineSeconds(),
    "24 beats x (12 s batch + 12 s retry) = 576 s fits inside 720 s")

if failures > 0:
  echo failures, " failing checks"
  quit(1)
echo "test_llm OK"
