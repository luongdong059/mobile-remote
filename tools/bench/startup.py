import random, socket, subprocess, threading, time
import bench as b
rows = []
for i in range(8):
    t = time.monotonic(); b.adb("push", b.JAR_LOCAL, b.JAR_REMOTE); push = time.monotonic() - t
    scid = f"{random.getrandbits(31):08x}"
    b.adb("forward", f"tcp:{b.PORT}", f"localabstract:scrcpy_{scid}")
    cmd = (f"CLASSPATH={b.JAR_REMOTE} app_process / com.genymobile.scrcpy.Server {b.VERSION} "
           f"scid={scid} log_level=info tunnel_forward=true audio=false control=true power_on=false")
    t0 = time.monotonic()
    srv = subprocess.Popen([b.ADB, "-s", b.SERIAL, "shell", cmd], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    marks = {}
    def logs():
        for l in srv.stdout:
            marks.setdefault("log", time.monotonic() - t0)
    threading.Thread(target=logs, daemon=True).start()
    first, tries = None, 0
    for _ in range(200):
        tries += 1
        s = socket.create_connection(("127.0.0.1", b.PORT), timeout=2)
        try:
            if s.recv(1):
                first = s; break
        except OSError:
            pass
        s.close(); time.sleep(0.05)
    marks["dummy"] = time.monotonic() - t0
    ctrl = socket.create_connection(("127.0.0.1", b.PORT), timeout=2)
    first.settimeout(1.0)
    stop = threading.Event(); out = dict(sessions=[], packets=[])
    threading.Thread(target=b.stream_reader, args=(first, out, stop, True), daemon=True).start()
    dl = time.monotonic() + 20
    while time.monotonic() < dl and not any(not p[2] for p in out["packets"]):
        time.sleep(0.002)
    fr = [p for p in out["packets"] if not p[2]]
    marks["frame"] = (fr[0][0] - t0) if fr else None
    stop.set(); time.sleep(0.3); first.close(); ctrl.close()
    try: srv.wait(timeout=6)
    except subprocess.TimeoutExpired: srv.kill()
    b.adb("forward", "--remove", f"tcp:{b.PORT}")
    print(f"lan {i+1}: push={push*1000:.0f}ms  log_dau={marks.get('log',0)*1000:.0f}ms  san_sang(dummy)={marks['dummy']*1000:.0f}ms  khung_dau={marks['frame']*1000 if marks['frame'] else -1:.0f}ms  so_lan_thu={tries}", flush=True)
    time.sleep(2)
print("con sot:", b.sh(f"ls {b.JAR_REMOTE} 2>&1; pgrep -f 'genymobil[e]'").strip())
