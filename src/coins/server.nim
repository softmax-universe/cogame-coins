## The Coins game server: the Coworld game contract over mummy.
##
## Forked from `coworld-ctf/src/ctf/server.nim`'s route/artifact/shutdown
## skeleton; the player protocol is bullwhip's JSON frames. Hosted
## certification probes exactly these routes BEFORE the player pods start
## (the lantern learning), so all of them answer from process start:
##
##   GET /healthz                    200 ok
##   GET /client/player?slot&token   the seat's HTML shell (never opens the
##                                   player websocket)
##   GET /client/global              the broadcast client
##   GET /client/<asset>             chrome_common.js, broadcast_core.js, art
##   WS  /player?slot=N&token=T      the seat socket
##   WS  /global                     live spectator: the sprite protocol plus
##                                   the chrome TextMessage
##
## Both `/client/` routes are registered BEFORE any catch-all asset route.
##
## Prompt adapters batch game-hosted model calls. External policies receive
## seat-private observations and submit ordinary intent actions.

import std/[json, locks, os, sequtils, sets, strutils, tables, times, unicode]
import bitworld/runtime
import bitworld/spriteprotocol
import curly
import mummy
import mummy/routers
import sim_types, sim, scripted, llm, broadcast, global, replays,
  wire_constants, training

const
  PlayerProtocol = "coins.player.v2"
  DoneBroadcastSeconds = 3.0

type
  ServerState = object
    trajectory: DecisionTrajectory
    prompts: seq[string]
    scripted: seq[ScriptKind]
    external: seq[bool]
    decisionId: int
    pendingActions: seq[JsonNode]
    pendingRejections: seq[string]
    policies: seq[string]
    registered: seq[bool]
    everRegistered: seq[bool]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    globalViewers: Table[WebSocket, ViewerState]
    seats: int
    finished: bool
    ## The last frame the EPISODE THREAD drew, published under `stateLock`.
    ## A spectator arriving on a mummy worker thread is served from here: the
    ## episode thread appends to `sim.frames`/`sim.coins` every tick without
    ## the lock, so reading `gameSim` from another thread is a read during a
    ## seq reallocation.
    lastFrame: Frame
    lastChrome: string
    published: bool

var
  stateLock: Lock
  shared: ServerState
  gameSim: Sim
  gameServer: Server
  clientRoot: string
  runtimeCfg: RuntimeConfig

initLock(stateLock)

proc clientDir(): string =
  if clientRoot.len > 0:
    return clientRoot
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      clientRoot = candidate
      return clientRoot
  clientRoot = "client"
  clientRoot

# ---------------------------------------------------------------------------
# artifacts
# ---------------------------------------------------------------------------

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError, "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc failEpisode(slot: int, message: string, providerFailure = false) {.noreturn.} =
  let failure = %*{"failed_policy_index": slot, "message": message}
  if providerFailure: failure["kind"] = %"episode_inconclusive"
  writeCogameEnv("COGAME_PLAYER_FAILURE_URI", $failure, "application/json")
  if not shared.trajectory.isNil:
    shared.trajectory.finish(esFailed, failure, newJObject())
    shared.trajectory.writeEventsToUri(getEnv(CogameSaveTrajectoryUriEnv))
  echo "coins: unscored player failure: ", message
  quit(1)

# ---------------------------------------------------------------------------
# broadcasting
# ---------------------------------------------------------------------------

proc pushGlobalLocked(events: JsonNode) =
  ## The board rides as a binary sprite packet, the chrome as a text frame —
  ## exactly what `client/broadcast_core.js` expects on either transport.
  ##
  ## Called from the EPISODE THREAD (and from the main thread before it
  ## starts) with `stateLock` held: it is the only place `gameSim`'s mutating
  ## state is read, and it PUBLISHES what it read so a spectator arriving on a
  ## worker thread never has to read it again.
  shared.lastFrame = gameSim.currentFrame()
  shared.lastChrome = liveChromeJson(gameSim, events)
  shared.published = true
  if shared.globalSockets.len == 0:
    return
  for socket in shared.globalSockets:
    var viewer = shared.globalViewers.getOrDefault(socket, initViewerState())
    var packet = buildBoardPacket(shared.lastFrame, viewer, events)
    packet.addChrome(shared.lastChrome)
    shared.globalViewers[socket] = viewer
    try:
      socket.send(blobFromBytes(packet), BinaryMessage)
    except CatchableError:
      discard

proc sendPublishedLocked(socket: WebSocket) =
  ## The arrival frame for a spectator that has just connected, built from the
  ## published snapshot rather than from `gameSim`. Runs on a mummy worker
  ## thread with `stateLock` held. The live board is pushed at beat closes, so
  ## this is the same frame the socket would have received anyway.
  if not shared.published:
    return
  var viewer = shared.globalViewers.getOrDefault(socket, initViewerState())
  var packet = buildBoardPacket(shared.lastFrame, viewer, newJArray())
  packet.addChrome(shared.lastChrome)
  shared.globalViewers[socket] = viewer
  try:
    socket.send(blobFromBytes(packet), BinaryMessage)
  except CatchableError:
    discard

proc pushStateFrames() =
  for slot, socket in shared.playerSockets:
    if slot < 0 or slot >= Seats:
      continue
    try:
      socket.send($gameSim.buildObservation(slot))
    except CatchableError:
      discard

proc broadcastFinal(results: JsonNode) =
  let scores = results{"scores"}
  var allowance = epochTime()
  for slot, socket in shared.playerSockets:
    allowance += DoneBroadcastSeconds
    if epochTime() > allowance:
      echo "coins: final broadcast past budget; skipping slot ", slot
      continue
    try:
      socket.send($ %*{
        "type": "final", "done": true, "slot": slot, "scores": scores,
        "names": [Aliases[0], Aliases[1]],
        "beats": gameSim.beatsPlayed, "reason": $gameSim.reason
      })
    except CatchableError as error:
      echo "coins: final frame to slot ", slot, " failed: ", error.msg

proc finishEpisode() =
  ## Shutdown order (bullwhip's `finishEpisode` plus lantern's grace):
  ## final frames -> last global frame -> 500 ms -> results.json -> the
  ## replay -> keep /healthz and /global answering for
  ## `shutdownGraceSeconds` -> quit(0).
  var results: JsonNode
  var replayData: string
  withLock stateLock:
    if shared.finished:
      return
    shared.finished = true
    results = gameSim.resultsJson()
    replayData = replayBytes(gameSim)
    shared.trajectory.finishNativeTrajectory(gameSim)
    broadcastFinal(results)
    pushGlobalLocked(newJArray())
  sleep(500)
  echo "coins: writing results and replay (", replayData.len, " bytes)"
  writeArtifact(runtimeCfg.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD")
  writeArtifact(runtimeCfg.replayUri, replayData, "application/json",
    "COGAME_SAVE_REPLAY_METHOD")
  echo "coins: episode complete (", gameSim.reason, ") after ",
    gameSim.tick, " ticks, ", gameSim.beatsPlayed, " beats, score ",
    gameSim.cogs[0].score, "-", gameSim.cogs[1].score

# ---------------------------------------------------------------------------
# the episode thread
# ---------------------------------------------------------------------------

proc runGame(cfg: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = gameSim.config
    let gameStart = epochTime()
    let connectDeadline =
      gameStart + config.playerConnectTimeoutSeconds.float
    while epochTime() < connectDeadline:
      var connected = 0
      withLock stateLock:
        connected = shared.playerSockets.len
      if connected >= shared.seats:
        break
      sleep(200)
    ## Give a connected-but-silent seat a moment to send its prompt frame.
    let registerDeadline = min(epochTime() + 3.0, connectDeadline + 3.0)
    while epochTime() < registerDeadline:
      var allRegistered = true
      withLock stateLock:
        for slot in 0 ..< shared.seats:
          if shared.playerSockets.hasKey(slot) and not shared.registered[slot]:
            allRegistered = false
      if allRegistered:
        break
      sleep(100)

    var connectedCount = 0
    var noShow = -1
    withLock stateLock:
      connectedCount = shared.playerSockets.len
      for slot in 0 ..< shared.seats:
        if not shared.everRegistered[slot]:
          if noShow < 0:
            noShow = slot
        gameSim.policyKinds[slot] =
          if shared.scripted[slot] != skNone: "scripted"
          elif shared.external[slot]: "external"
          else: "llm"
        if shared.policies[slot].len > 0:
          gameSim.policyNames[slot] = shared.policies[slot]
      echo "coins: starting with ", connectedCount, "/", shared.seats,
        " players connected"

    if connectedCount == 0 or noShow >= 0:
      let failedSlot = if noShow >= 0: noShow else: 0
      let message =
        if connectedCount == 0:
          "no seat connected within " &
            $config.playerConnectTimeoutSeconds & "s"
        else:
          "player slot " & $failedSlot & " never registered within " &
            $config.playerConnectTimeoutSeconds & "s"
      failEpisode(failedSlot, message)

    let client = newLlmClient(config)

    proc now(): float {.closure.} = epochTime() - gameStart

    var lastExternalAt = -1.0
    var captureViews: seq[JsonNode]
    var captureEvidence: seq[seq[DecisionAttempt]]
    var captureBeat = 0
    proc decide(view: Sim, seats: seq[int]): seq[Decision] {.closure.} =
      var prompts: seq[string]
      var kinds: seq[ScriptKind]
      var external: seq[bool]
      var decisionId: int
      withLock stateLock:
        prompts = shared.prompts
        kinds = shared.scripted
        external = shared.external
        for slot in 0 ..< Seats:
          if not shared.playerSockets.hasKey(slot) and
              kinds[slot] == skNone:
            let err = newException(DecisionFailureError,
              "player slot " & $slot & " disconnected")
            err.slot = slot
            raise err
      if external.anyIt(it):
        if lastExternalAt >= 0 and
            now() - lastExternalAt < config.minBeatSeconds.float:
          sleep(int((config.minBeatSeconds.float -
            (now() - lastExternalAt)) * 1000))
        lastExternalAt = now()
      withLock stateLock:
        inc shared.decisionId
        decisionId = shared.decisionId
        shared.pendingActions = newSeq[JsonNode](shared.seats)
        shared.pendingRejections = newSeq[string](shared.seats)
        for seat in seats:
          if external[seat] and shared.playerSockets.hasKey(seat):
            let observation = view.buildObservation(seat)
            let system = systemPrompt(observation, view.config)
            let user = userPrompt(observation, prompts[seat])
            observation["prompt_template"] = promptMetadata(view.config, system, user)
            shared.playerSockets[seat].send($ %*{
              "type": "observation", "id": decisionId, "observation": observation,
              "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}]})
      if not shared.trajectory.isNil:
        captureViews.setLen(0)
        captureBeat = view.beat
        for seat in 0 ..< Seats: captureViews.add(view.buildObservation(seat))
      result = newSeq[Decision](seats.len)
      var managedSeats: seq[int]
      var managedIndices: seq[int]
      for index, seat in seats:
        if not external[seat]:
          managedSeats.add(seat)
          managedIndices.add(index)
      if managedSeats.len > 0:
        let managed = client.decideAll(view, managedSeats, prompts, kinds,
          proc (seconds: float) {.closure.} = sleep(int(seconds * 1000.0)))
        for pos, index in managedIndices:
          result[index] = managed[pos]
      if not shared.trajectory.isNil:
        captureEvidence =
          if client.nativeAttempts.len == Seats: client.nativeAttempts
          else: newSeq[seq[DecisionAttempt]](Seats)
      if external.anyIt(it):
        let started = epochTime()
        let deadline = started + config.llmTimeoutSeconds.float
        while epochTime() < deadline:
          var ready = true
          withLock stateLock:
            for seat in seats:
              if external[seat] and shared.playerSockets.hasKey(seat) and
                  shared.pendingActions[seat].isNil:
                ready = false
          if ready:
            break
          sleep(20)
        for index, seat in seats:
          if external[seat]:
            var action: JsonNode
            var rejection: string
            withLock stateLock:
              action = shared.pendingActions[seat]
              rejection = shared.pendingRejections[seat]
            if action.isNil:
              let detail =
                if rejection.len > 0:
                  "external seat " & $seat & " failed: " & rejection
                else:
                  "external seat " & $seat & " did not submit a valid action"
              let err = newException(DecisionFailureError, detail)
              err.slot = seat
              raise err
            result[index] = parseDecision(action)
            result[index].source = osExternal
            result[index].latencyMs = int((epochTime() - started) * 1000)

    proc onBeat(view: Sim) {.closure.} =
      if not shared.trajectory.isNil:
        for seat in 0 ..< Seats:
          let cog = view.cogs[seat]
          let applied = Decision(intent: cog.intent, say: cog.say, notes: cog.notes,
            source: cog.source, latencyMs: cog.latencyMs)
          shared.trajectory.recordAppliedDecision(config, captureBeat, seat,
            view.policyNames[seat], captureViews[seat], applied, captureEvidence[seat])
      withLock stateLock:
        pushStateFrames()
        pushGlobalLocked(newJArray())
      echo "coins: beat ", view.beatsPlayed, " tick ", view.tick,
        " score ", view.cogs[0].score, "-", view.cogs[1].score,
        " thefts ", view.cogs[0].thefts, "/", view.cogs[1].thefts,
        " at ", int(now()), "s"

    try:
      runEpisode(gameSim, decide, now, onBeat)
    except DecisionFailureError as failure:
      echo "coins: player failure on seat ", failure.slot, ": ", failure.msg
      if not shared.trajectory.isNil and failure.slot >= 0 and
          failure.slot < captureViews.len:
        let evidence =
          if failure.slot < client.nativeAttempts.len:
            client.nativeAttempts[failure.slot]
          else:
            @[]
        shared.trajectory.recordFailedDecision(config, captureBeat,
          failure.slot, gameSim.policyNames[failure.slot],
          captureViews[failure.slot], evidence, failure.msg)
      failEpisode(failure.slot, failure.msg, failure.providerFailure)
    withLock stateLock:
      pushStateFrames()
    finishEpisode()
    ## Hosted certification pings the global websocket AFTER the player pods
    ## start, so keep answering for a bounded grace before exiting.
    echo "coins: holding /healthz and /global for ",
      config.shutdownGraceSeconds, "s"
    sleep(config.shutdownGraceSeconds * 1000)
    quit(0)

var gameThread: Thread[RuntimeConfig]

# ---------------------------------------------------------------------------
# routes
# ---------------------------------------------------------------------------

proc contentTypeFor(name: string): string =
  if name.endsWith(".js"): "application/javascript; charset=utf-8"
  elif name.endsWith(".css"): "text/css; charset=utf-8"
  elif name.endsWith(".html"): "text/html; charset=utf-8"
  elif name.endsWith(".png"): "image/png"
  elif name.endsWith(".jpg"): "image/jpeg"
  elif name.endsWith(".webp"): "image/webp"
  elif name.endsWith(".ttf"): "font/ttf"
  else: "application/octet-stream"

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = contentType
    request.respond(200, headers, readFile(path))
  else:
    request.respond(404)

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

const PlayerPage = staticRead("../../client/player.html")

## The broadcast client, EMBEDDED with staticRead and spliced at COMPILE
## TIME over its three markers — exactly what paintbot's server does. The
## certifier probes `GET /client/global` BEFORE the player pods start (the
## lantern learning), and a page assembled from disk at request time is one
## missing working directory away from a 404 there.
const GlobalPage = staticRead("../../client/replay_broadcast.html")
  .replace(WireConstantsMarker, "<script>" & WireConstantsJs & "</script>")
  .replace("<!-- CHROME_COMMON -->",
    "<script>" & staticRead("../../client/chrome_common.js") & "</script>")
  .replace("<!-- BROADCAST_CORE -->",
    "<script>" & staticRead("../../client/broadcast_core.js") & "</script>")

proc playerPageHandler(request: Request) {.gcsafe.} =
  ## The seat's HTML shell. It NEVER opens the player websocket — the
  ## certifier fetches this before the player pods start.
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html; charset=utf-8"
  request.respond(200, headers, PlayerPage)

proc globalPageHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html; charset=utf-8"
  request.respond(200, headers, GlobalPage)

proc clientAssetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    serveFile(request, clientDir() / name, contentTypeFor(name))

proc clientArtHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let dir = request.pathParams["dir"]
    let name = request.pathParams["name"]
    for part in [dir, name]:
      if "/" in part or "\\" in part or part.startsWith("."):
        request.respond(404)
        return
    serveFile(request, clientDir() / "art" / dir / name, contentTypeFor(name))

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    var slot = -1
    try:
      slot = parseInt(request.queryParams["slot"])
    except ValueError:
      discard
    let token = request.queryParams["token"]
    var authorized = false
    var duplicate = false
    withLock stateLock:
      authorized = slot >= 0 and slot < gameSim.config.tokens.len and
        gameSim.config.tokens[slot] == token
      duplicate = authorized and shared.playerSockets.hasKey(slot)
    if not authorized:
      ## A bad token is refused, never left hanging.
      request.respond(403)
      return
    if duplicate:
      request.respond(409)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      shared.playerSockets[slot] = websocket
      shared.socketSlots[websocket] = slot
      echo "coins: player slot ", slot, " connected (",
        shared.playerSockets.len, "/", shared.seats, ")"
      websocket.send($ %*{
        "type": "welcome", "protocol": PlayerProtocol, "slot": slot,
        "alias": Aliases[slot], "colour": $OwnColour[slot],
        "opponent": Aliases[otherSlot(slot)],
        "ticksPerBeat": gameSim.config.ticksPerBeat,
        "minBeats": gameSim.config.minBeats,
        "maxBeats": gameSim.config.maxBeats
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      shared.globalSockets.incl(websocket)
      shared.globalViewers[websocket] = initViewerState()
      sendPublishedLocked(websocket)

proc handleRegister(slot: int, payload: JsonNode) =
  var prompt = payload{"prompt"}.getStr()
  if prompt.runeLen > MaxPromptRunes:
    prompt = prompt.runeSubStr(0, MaxPromptRunes)
  let node = payload{"scripted"}
  var kind = skNone
  if node != nil and node.kind != JNull:
    if node.kind != JString:
      raise newException(CoinsError,
        "scripted must be one of " & $ScriptedNames)
    let raw = node.getStr().strip()
    if raw.len > 0:
      kind = parseScriptKind(raw)
      if kind == skNone:
        raise newException(CoinsError,
          "unknown scripted baseline \"" & raw & "\"; expected one of " &
          $ScriptedNames)
  var policy = payload{"policy"}.getStr()
  if policy.runeLen > MaxPolicyLabelRunes:
    policy = policy.runeSubStr(0, MaxPolicyLabelRunes)
  withLock stateLock:
    shared.prompts[slot] = prompt
    shared.scripted[slot] = kind
    shared.external[slot] = false
    if policy.len > 0:
      shared.policies[slot] = policy
    shared.registered[slot] = true
    shared.everRegistered[slot] = true
  echo "coins: slot ", slot, " registered (", prompt.len, " prompt chars",
    (if kind != skNone: ", scripted " & $kind else: ", llm"), ")"

proc websocketHandler(websocket: WebSocket, event: WebSocketEvent,
    message: Message) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application; the certifier pings
      ## /global to check the game is alive, so an unanswered ping fails
      ## certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind == BinaryMessage:
        withLock stateLock:
          if websocket in shared.globalViewers:
            var viewer = shared.globalViewers[websocket]
            viewer.applyGlobalViewerMessage(message.data)
            shared.globalViewers[websocket] = viewer
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = shared.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() == "register":
          if payload["control"].getStr() != "external":
            raise newException(CoinsError, "unknown player control")
          var policy = payload{"policy"}.getStr()
          if policy.runeLen > MaxPolicyLabelRunes:
            policy = policy.runeSubStr(0, MaxPolicyLabelRunes)
          withLock stateLock:
            shared.external[slot] = true
            if policy.len > 0:
              shared.policies[slot] = policy
            shared.registered[slot] = true
            shared.everRegistered[slot] = true
          return
        if payload{"type"}.getStr() == "action":
          let action = payload{"action"}
          try:
            discard parseDecision(action)
          except CatchableError as error:
            withLock stateLock:
              if shared.external[slot] and payload{"id"}.getInt(-1) ==
                  shared.decisionId:
                shared.pendingRejections[slot] = error.msg
            try:
              websocket.send($ %*{
                "type": "rejected",
                "id": payload{"id"},
                "error": error.msg
              })
            except CatchableError:
              discard
            return
          withLock stateLock:
            if shared.external[slot] and payload["id"].getInt() ==
                shared.decisionId and shared.pendingActions[slot].isNil:
              shared.pendingActions[slot] = action
          return
        if payload{"type"}.getStr() != "prompt":
          echo "coins: ignoring player frame of type ",
            payload{"type"}.getStr()
          return
        handleRegister(slot, payload)
      except CatchableError as error:
        echo "coins: rejecting bad player frame: ", error.msg
        try:
          websocket.send($ %*{"type": "rejected", "error": error.msg})
        except CatchableError:
          discard
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in shared.socketSlots:
          let slot = shared.socketSlots[websocket]
          shared.socketSlots.del(websocket)
          if shared.playerSockets.getOrDefault(slot) == websocket:
            shared.playerSockets.del(slot)
        shared.globalSockets.excl(websocket)
        shared.globalViewers.del(websocket)

proc buildRouter(): Router =
  ## Both `/client/` routes are registered BEFORE the catch-all asset route.
  result.get("/healthz", healthzHandler)
  result.get("/client/player", playerPageHandler)
  result.get("/client/global", globalPageHandler)
  result.get("/client/art/@dir/@name", clientArtHandler)
  result.get("/client/@name", clientAssetHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/player", playerUpgradeHandler)

proc stopServer*() =
  if gameServer != nil:
    gameServer.close()

proc runGameServer*(config: GameConfig, cfg: RuntimeConfig) =
  if config.tokens.len != config.numAgents:
    raise newException(CoinsError, "tokens must name exactly num_agents seats")
  runtimeCfg = cfg
  gameSim = initSim(config)
  shared.trajectory = initNativeTrajectory(config)
  shared.seats = config.numAgents
  shared.prompts = newSeq[string](shared.seats)
  shared.scripted = newSeq[ScriptKind](shared.seats)
  shared.external = newSeq[bool](shared.seats)
  shared.pendingActions = newSeq[JsonNode](shared.seats)
  shared.pendingRejections = newSeq[string](shared.seats)
  shared.policies = newSeq[string](shared.seats)
  shared.registered = newSeq[bool](shared.seats)
  shared.everRegistered = newSeq[bool](shared.seats)
  for slot in 0 ..< shared.seats:
    shared.policies[slot] = Aliases[slot]
  ## Publish the opening frame before any thread but this one exists, so a
  ## spectator that connects before the first beat close still gets a board.
  withLock stateLock:
    pushGlobalLocked(newJArray())
  let router = buildRouter()
  gameServer = newServer(router, websocketHandler, workerThreads = 4)
  createThread(gameThread, runGame, cfg)
  echo "coins: serving on ", cfg.host, ":", cfg.port
  gameServer.serve(Port(cfg.port), cfg.host)
