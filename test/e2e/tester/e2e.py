#!/usr/bin/env python3
"""Protocol-level checks against a deploy that exposes only wss://HOST/ws/{id,relay}.

Modes (first argument):
  e2e      registration, keepalive, punch hole, relay, session to the real client, long hold
  steady   keep a device and a relay session open while run.sh reloads the proxy
  recover  wait for the real client to be online again, then open a session to it
  load     RD_LOAD_DEVICES fake devices held past the server registration timeout
"""
import asyncio, hashlib, os, random, ssl, sys, time, urllib.error, urllib.request
from websockets.asyncio.client import connect
import rendezvous_pb2 as pb

HOST = os.environ.get("RD_HOST", "rd.test")
HOLD = int(os.environ.get("RD_HOLD_SECONDS", "100"))
LOAD = int(os.environ.get("RD_LOAD_DEVICES", "300"))
RECOVER = int(os.environ.get("RD_RECOVER_TIMEOUT", "120"))
RECOVER_MAX = int(os.environ.get("RD_RECOVER_MAX", "45"))
STEADY = int(os.environ.get("RD_STEADY_SECONDS", "30"))
STATUS_URL = os.environ.get("RD_STATUS_URL", "")
KEY = open("/keys/id_ed25519.pub").read().strip()
CTX = ssl.create_default_context(cafile="/certs/ca.crt")
ID_URL, RELAY_URL = f"wss://{HOST}/ws/id", f"wss://{HOST}/ws/relay"
OK = pb.RegisterPkResponse.OK
# A client must never be able to choose the address hbbs records for it.
SPOOF = {"X-Real-IP": "6.6.6.6", "X-Forwarded-For": "6.6.6.6"}
FAILED = []


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'}  {name}  {detail}", flush=True)
    if not ok:
        FAILED.append(name)


async def ws(url):
    # No library pings: like the real client, liveness relies on the server heartbeat.
    return await connect(url, ssl=CTX, open_timeout=10, ping_interval=None, max_size=None,
                         additional_headers=SPOOF)


async def send(conn, **kw):
    await conn.send(pb.RendezvousMessage(**kw).SerializeToString())


async def recv(conn, timeout=15):
    """Next rendezvous message; empty frames are server heartbeats and get echoed."""
    while True:
        data = await asyncio.wait_for(conn.recv(), timeout)
        if data:
            msg = pb.RendezvousMessage()
            msg.ParseFromString(data)
            return msg
        await conn.send(b"")


async def online(ids):
    out = []
    for i in range(0, len(ids), 200):
        chunk = ids[i:i + 200]
        conn = await ws(ID_URL)
        try:
            await send(conn, online_request=pb.OnlineRequest(id="e2etester", peers=chunk))
            states = (await recv(conn)).online_response.states
        finally:
            await conn.close()
        out += [bool(states[j // 8] & (1 << (7 - j % 8))) for j in range(len(chunk))]
    return out


class FakeDevice:
    """Controlled device at protocol level: registers over ws, answers punch holes with a relay."""

    def __init__(self, dev_id):
        self.id, self.uuid, self.pk = dev_id, os.urandom(16), os.urandom(32)
        self.punches, self.heartbeats = asyncio.Queue(), 0
        self.result = self.keep_alive = self.closed = self.conn = self.task = None

    async def start(self):
        self.closed, self.result = None, None
        self.conn = await ws(ID_URL)
        await send(self.conn, register_pk=pb.RegisterPk(id=self.id, uuid=self.uuid, pk=self.pk))
        resp = (await recv(self.conn)).register_pk_response
        self.result, self.keep_alive = resp.result, resp.keep_alive
        self.task = asyncio.create_task(self._loop())
        return self

    async def _loop(self):
        try:
            async for data in self.conn:
                if not data:
                    self.heartbeats += 1
                    await self.conn.send(b"")
                    continue
                msg = pb.RendezvousMessage()
                msg.ParseFromString(data)
                kind = msg.WhichOneof("union")
                if kind in ("punch_hole", "fetch_local_addr", "request_relay"):
                    self.punches.put_nowait(getattr(msg, kind))
            self.closed = "closed by peer"
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            self.closed = repr(exc)

    async def stop(self):
        if self.task:
            self.task.cancel()
        if self.conn:
            await self.conn.close()

    async def answer(self, punch, uuid):
        conn = await ws(ID_URL)
        try:
            await send(conn, relay_response=pb.RelayResponse(
                socket_addr=punch.socket_addr, uuid=uuid, relay_server=HOST, id=self.id, version="1.5.3"))
        finally:
            await conn.close()


async def relay(uuid):
    conn = await ws(RELAY_URL)
    await send(conn, request_relay=pb.RequestRelay(uuid=uuid, licence_key=KEY))
    return conn


async def punch(target, key=KEY):
    conn = await ws(ID_URL)
    await send(conn, punch_hole_request=pb.PunchHoleRequest(
        id=target, licence_key=key, nat_type=pb.SYMMETRIC, conn_type=pb.DEFAULT_CONN,
        version="1.5.3", force_relay=True))
    return conn


async def fake_session(dev, payload=b"", idle=0):
    """Controller -> hbbs -> device (ws queue) -> relay pair. Returns '' or the failure."""
    uuid = "e2e-" + os.urandom(8).hex()
    a = await punch(dev.id)
    conns = [a]
    try:
        try:
            p = await asyncio.wait_for(dev.punches.get(), 10)
        except asyncio.TimeoutError:
            return "punch hole not delivered to the ws device"
        await dev.answer(p, uuid)
        resp = await recv(a)
        if resp.relay_response.uuid != uuid:
            return f"no relay response to the controller ({resp.WhichOneof('union')})"
        ra, rb = await relay(uuid), await relay(uuid)
        conns += [ra, rb]
        await ra.send(b"ping-from-a")
        await rb.send(b"ping-from-b")
        if await asyncio.wait_for(rb.recv(), 10) != b"ping-from-a" or \
                await asyncio.wait_for(ra.recv(), 10) != b"ping-from-b":
            return "relay pipe corrupted"
        if idle:
            await asyncio.sleep(idle)
            await ra.send(b"after-idle")
            if await asyncio.wait_for(rb.recv(), 10) != b"after-idle":
                return "relay pipe dead after idle"
        if payload:
            want, got, t0 = hashlib.sha256(payload).digest(), hashlib.sha256(), time.time()

            async def pump():
                for i in range(0, len(payload), 16384):
                    await ra.send(payload[i:i + 16384])

            task, left = asyncio.create_task(pump()), len(payload)
            while left:
                chunk = await asyncio.wait_for(rb.recv(), 30)
                got.update(chunk)
                left -= len(chunk)
            await task
            if got.digest() != want:
                return "relay payload corrupted"
            return f"ok {len(payload) / 1048576 / (time.time() - t0):.1f} MiB/s"
        return ""
    except Exception as exc:
        return repr(exc)
    finally:
        for c in conns:
            await c.close()


async def real_session(real, quiet=False):
    """Opens a session to the real client; with quiet, failures are returned instead of recorded."""
    report = (lambda *a: None) if quiet else check
    a = await punch(real)
    try:
        resp = await recv(a, timeout=10 if quiet else 30)
        kind = resp.WhichOneof("union")
        ok = kind == "relay_response" and bool(resp.relay_response.uuid)
        report("real client answers punch hole with relay", ok,
               f"{kind} relay_server={resp.relay_response.relay_server!r}")
        if not ok:
            return False
        r = await relay(resp.relay_response.uuid)
        try:
            first = await asyncio.wait_for(r.recv(), 20)
            report("first session frame from real client through relay", len(first) > 0, f"{len(first)} bytes")
            return len(first) > 0
        finally:
            await r.close()
    except Exception as exc:
        report("session to real client", False, repr(exc))
        return False
    finally:
        await a.close()


def http_status(path, method="GET"):
    req = urllib.request.Request(f"https://{HOST}{path}", method=method)
    try:
        return urllib.request.urlopen(req, context=CTX, timeout=10).status
    except urllib.error.HTTPError as err:
        return err.code


def real_id():
    for _ in range(120):
        if os.path.exists("/shared/client_id") and open("/shared/client_id").read().strip():
            break
        time.sleep(1)
    real = open("/shared/client_id").read().strip() if os.path.exists("/shared/client_id") else ""
    check("real client produced an id", bool(real), real)
    return real


async def wait_online(ids, want, tries=30):
    st = None
    for _ in range(tries):
        try:
            st = await online(ids)
        except Exception as exc:
            st = repr(exc)
        if st == want:
            break
        await asyncio.sleep(2)
    return st


async def mode_e2e():
    real = real_id()
    check("non-rustdesk path is 404", http_status("/") == 404)
    check("/ws/id without upgrade is 404", http_status("/ws/id") == 404)
    check("/api/heartbeat is 404", http_status("/api/heartbeat", "POST") == 404)

    fake = await FakeDevice("e2e" + os.urandom(4).hex()).start()
    check("register_pk over wss accepted", fake.result == OK, f"result={fake.result} keep_alive={fake.keep_alive}")
    st = await wait_online([real, fake.id, "nonexistent99"], [True, True, False])
    check("real client and fake device online", st == [True, True, False], str(st))

    conn = await punch(fake.id, key="wrong-key")
    resp = await recv(conn)
    check("wrong key rejected", resp.punch_hole_response.failure == pb.PunchHoleResponse.LICENSE_MISMATCH)
    await conn.close()

    for n in (1, 2):
        res = await fake_session(fake)
        check(f"session #{n} to the ws device", res == "", res)
    res = await fake_session(fake, idle=20)
    check("relay pipe survives 20s idle", res == "", res)
    res = await fake_session(fake, payload=os.urandom(8 << 20))
    check("8 MiB through the relay intact", res.startswith("ok"), res)

    if real:
        await real_session(real)

    print(f"holding {HOLD}s to verify keepalive...", flush=True)
    await asyncio.sleep(HOLD)
    st = await online([real, fake.id])
    check(f"still online after {HOLD}s", st == [True, True], f"{st} heartbeats={fake.heartbeats}")
    check("device connection never dropped", fake.closed is None, fake.closed or "")
    check("server heartbeat every ~10s", fake.heartbeats >= HOLD // 10 - 1, str(fake.heartbeats))
    if real:
        await real_session(real)

    # hbbs allows 30 registrations per IP in a burst; devices it already knows are exempt,
    # so a site behind one NAT can reconnect all at once.
    devs = [FakeDevice(f"blk{os.urandom(3).hex()}{i:03d}") for i in range(45)]
    for d in devs:
        await d.start()
    known = [d for d in devs if d.result == OK]
    check("ip blocker limits new ids from one address", 25 <= len(known) < 45, f"{len(known)}/45 accepted")
    for d in devs:
        await d.stop()
    await asyncio.sleep(7)
    ids = [d.id for d in known[:8]]
    st = await wait_online(ids, [False] * len(ids), tries=1)
    check("device reported offline as soon as its connection closes", st == [False] * len(ids), f"{st}")
    await asyncio.gather(*(d.start() for d in known))
    back = sum(d.result == OK for d in known)
    check("known devices reconnect at once despite the ip blocker", back == len(known), f"{back}/{len(known)}")
    for d in known + [fake]:
        await d.stop()


async def mode_recover():
    # A client that lost its connection retries on a fixed 18s cycle: what matters is that
    # it is controllable again, by itself, within RD_RECOVER_MAX seconds.
    real, t0, ok = real_id(), time.time(), False
    while not ok and time.time() - t0 < RECOVER:
        try:
            ok = await real_session(real, quiet=True)
        except Exception:
            ok = False
        if not ok:
            await asyncio.sleep(1)
    took = time.time() - t0
    check("real client controllable again", ok, f"after {took:.0f}s")
    check(f"recovery within {RECOVER_MAX}s", ok and took <= RECOVER_MAX, f"{took:.0f}s")
    if ok:
        await real_session(real)


async def mode_steady():
    # run.sh reloads the proxy configuration after READY: nothing open may be cut.
    # Right after the e2e mode this address is still inside the 60 s ip blocker window.
    dev, t0 = FakeDevice(f"std{os.urandom(4).hex()}"), time.time()
    while True:
        try:
            await dev.start()
        except Exception as exc:
            dev.closed = repr(exc)
        if dev.result == OK or time.time() - t0 > 90:
            break
        await dev.stop()
        await asyncio.sleep(5)
    check("device registered", dev.result == OK, f"result={dev.result} {dev.closed or ''} after {time.time() - t0:.0f}s")
    if dev.result != OK:
        return
    print("READY", flush=True)
    err = await fake_session(dev, idle=STEADY)
    check("relay session survives the proxy reload", not err, err)
    check("device connection survives the proxy reload", dev.closed is None, f"{dev.closed}")
    check("heartbeats kept coming", dev.heartbeats >= STEADY // 10 - 1, f"{dev.heartbeats}")
    await dev.stop()


async def mode_load():
    run, sem = os.urandom(3).hex(), asyncio.Semaphore(50)
    devs = [FakeDevice(f"ld{run}{i:05d}") for i in range(LOAD)]

    async def up(d):
        async with sem:
            try:
                await d.start()
            except Exception as exc:
                d.closed = repr(exc)

    t0 = time.time()
    await asyncio.gather(*(up(d) for d in devs))
    ok = [d for d in devs if d.result == OK]
    bad = next((d.closed or f"result={d.result}" for d in devs if d.result != OK), "")
    check(f"{LOAD} devices registered", len(ok) == LOAD, f"{len(ok)}/{LOAD} in {time.time() - t0:.1f}s {bad}")

    print("holding 45s (server registration timeout is 30s)...", flush=True)
    await asyncio.sleep(45)
    alive = [d for d in ok if d.closed is None]
    check("no device connection dropped", len(alive) == len(ok), f"{len(alive)}/{len(ok)}")
    check("every device got heartbeats", all(d.heartbeats >= 3 for d in alive),
          f"min={min((d.heartbeats for d in alive), default=0)}")
    st = await online([d.id for d in ok])
    check("all devices online", all(st) and len(st) == len(ok), f"{sum(st)}/{len(ok)}")
    if STATUS_URL:
        try:
            body = urllib.request.urlopen(STATUS_URL, timeout=10).read().decode()
            print("INFO  proxy scoreboard  " + " ".join(
                line.replace(" ", "") for line in body.splitlines() if line.startswith(("BusyWorkers", "IdleWorkers"))),
                flush=True)
        except Exception as exc:
            print(f"INFO  proxy scoreboard unavailable {exc!r}", flush=True)

    sample = random.sample(alive, min(40, len(alive)))
    res = await asyncio.gather(*(fake_session(d) for d in sample))
    fails = [r for r in res if r]
    check(f"{len(sample)} concurrent sessions", not fails, str(fails[:3]))

    for d in ok:
        await d.stop()
    await asyncio.sleep(7)
    t0 = time.time()
    await asyncio.gather(*(up(d) for d in ok))
    back = sum(d.result == OK for d in ok)
    check("reconnect storm: every device back", back == len(ok), f"{back}/{len(ok)} in {time.time() - t0:.1f}s")
    st = await online([d.id for d in ok])
    check("all devices online after the storm", all(st) and len(st) == len(ok), f"{sum(st)}/{len(ok)}")
    for d in ok:
        await d.stop()


mode = sys.argv[1] if len(sys.argv) > 1 else "e2e"
asyncio.run({"e2e": mode_e2e, "recover": mode_recover, "steady": mode_steady, "load": mode_load}[mode]())
print(f"RESULT {mode}:", "FAILED " + ", ".join(FAILED) if FAILED else "ALL PASSED", flush=True)
sys.exit(1 if FAILED else 0)
