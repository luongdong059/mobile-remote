#!/usr/bin/env python3
"""Throwaway benchmark: cost of running scrcpy-server v4.1 on the phone.

For each scenario: launch the server (forward tunnel), consume the v4.x video
stream, and snapshot per-process CPU on the device before/after a fixed window.
Screen motion comes from `cmd statusbar expand/collapse` so no touch is ever
injected into the foreground app.
"""
import json, os, random, re, socket, struct, subprocess, sys, threading, time

ADB = "adb"
HERE = os.path.dirname(os.path.abspath(__file__))
JAR_LOCAL = os.path.join(HERE, "..", "..", "Sources", "ScrcpyKit", "Resources", "scrcpy-server-v4.1")


def default_serial():
    lines = subprocess.run([ADB, "devices"], capture_output=True, text=True).stdout.splitlines()[1:]
    ready = [l.split()[0] for l in lines if l.strip().endswith("device")]
    if len(ready) != 1:
        sys.exit("set ANDROID_SERIAL: expected exactly one device, found %d" % len(ready))
    return ready[0]


SERIAL = os.environ.get("ANDROID_SERIAL") or default_serial()
JAR_REMOTE = "/data/local/tmp/scrcpy-server.jar"
VERSION = "4.1"
PORT = 27183
WARMUP = 3.0

SCENARIOS = [
    dict(name="nen_tinh", server=False, motion=False, window=10),
    dict(name="nen_chuyen_dong", server=False, motion=True, window=20),
    dict(name="macdinh_tinh", server=True, motion=False, window=12, opts={}),
    dict(name="macdinh_chuyen_dong", server=True, motion=True, window=20, opts={}),
    dict(name="60fps", server=True, motion=True, window=20, opts={"max_fps": "60"}),
    dict(name="1280px_60fps_4M", server=True, motion=True, window=20,
         opts={"max_fps": "60", "max_size": "1280", "video_bit_rate": "4000000"}),
    dict(name="h265_60fps", server=True, motion=True, window=20,
         opts={"max_fps": "60", "video_codec": "h265"}),
    dict(name="60fps_co_am_thanh", server=True, motion=True, window=20, audio=True,
         opts={"max_fps": "60"}),
]


def adb(*args, timeout=30):
    r = subprocess.run([ADB, "-s", SERIAL, *args], capture_output=True, text=True, timeout=timeout)
    return r.stdout + r.stderr


def sh(cmd, timeout=30):
    return adb("shell", cmd, timeout=timeout)


def recv_exact(sock, n, stop):
    buf = bytearray()
    while len(buf) < n:
        try:
            chunk = sock.recv(min(65536, n - len(buf)))
        except socket.timeout:
            if stop.is_set():
                return None
            continue
        except OSError:
            return None
        if not chunk:
            return None
        buf += chunk
    return bytes(buf)


def stream_reader(sock, out, stop, first_socket):
    """Parses the v4.x stream: [64B name] codec u32, then 12B headers."""
    if first_socket:
        name = recv_exact(sock, 64, stop)
        if name is None:
            return
        out["device_name"] = name.rstrip(b"\0").decode(errors="replace")
    codec = recv_exact(sock, 4, stop)
    if codec is None:
        return
    out["codec_raw"] = struct.unpack(">I", codec)[0]
    out["codec"] = codec.lstrip(b"\0").decode(errors="replace")
    while not stop.is_set():
        h = recv_exact(sock, 12, stop)
        if h is None:
            break
        if h[0] & 0x80:  # session packet (video only)
            w, hgt = struct.unpack(">II", h[4:12])
            out["sessions"].append((time.monotonic(), w, hgt))
            continue
        v, size = struct.unpack(">QI", h)
        payload = recv_exact(sock, size, stop)
        if payload is None:
            break
        out["packets"].append((time.monotonic(), size + 12, bool(v & (1 << 62)),
                               bool(v & (1 << 61)), v & ((1 << 61) - 1)))


def motion_loop(stop):
    expanded = False
    while not stop.is_set():
        sh("cmd statusbar " + ("collapse" if expanded else "expand-notifications"))
        expanded = not expanded
        stop.wait(0.45)
    sh("cmd statusbar collapse")


def parse_proc_stats(text):
    procs = {}
    for line in text.splitlines():
        rp = line.rfind(")")
        lp = line.find("(")
        if rp < 0 or lp < 0:
            continue
        try:
            pid = int(line[:lp].strip())
            rest = line[rp + 2:].split()
            procs[pid] = (line[lp + 1:rp], int(rest[11]) + int(rest[12]), int(rest[21]))
        except (ValueError, IndexError):
            continue
    return procs


def parse_total(text):
    cpu = uptime = None
    for line in text.splitlines():
        if line.startswith("cpu "):
            cpu = [int(x) for x in line.split()[1:9]]
        elif re.match(r"^\d+\.\d+ \d+\.\d+$", line.strip()):
            uptime = float(line.split()[0])
    return cpu, uptime


def snapshot(start):
    # Keep the /proc walk outside the measured window on both ends.
    if start:
        out = sh("cat /proc/[0-9]*/stat 2>/dev/null; echo =====; head -1 /proc/stat; cat /proc/uptime")
        procs_txt, total_txt = out.split("=====", 1)
    else:
        out = sh("head -1 /proc/stat; cat /proc/uptime; echo =====; cat /proc/[0-9]*/stat 2>/dev/null")
        total_txt, procs_txt = out.split("=====", 1)
    cpu, uptime = parse_total(total_txt)
    return dict(procs=parse_proc_stats(procs_txt), cpu=cpu, uptime=uptime)


def thermal():
    out = sh("dumpsys thermalservice")
    sect = out.split("Current temperatures from HAL", 1)[-1]
    temps = {}
    for m in re.finditer(r"Temperature\{mValue=([\d.]+), mType=\d+, mName=(\w+)", sect):
        temps.setdefault(m.group(2), float(m.group(1)))
    return {k: temps.get(k) for k in ("AP", "SKIN", "BAT")}


def scrcpy_procs():
    out = sh("for p in $(pgrep -f 'genymobil[e]'); do echo \"PID $p\"; tr '\\0' ' ' < /proc/$p/cmdline; echo; "
             "grep -E '^(Rss|Pss):' /proc/$p/smaps_rollup; grep -E '^Threads' /proc/$p/status; done")
    res = []
    for block in out.split("PID ")[1:]:
        lines = block.strip().splitlines()
        d = dict(pid=int(lines[0]), cmd=(lines[1] if len(lines) > 1 else "")[:70])
        for l in lines[2:]:
            m = re.match(r"(Rss|Pss|Threads):\s+(\d+)", l)
            if m:
                d[m.group(1)] = int(m.group(2))
        res.append(d)
    return res


def pct(sorted_vals, p):
    if not sorted_vals:
        return None
    return sorted_vals[min(len(sorted_vals) - 1, int(p / 100 * len(sorted_vals)))]


def video_stats(packets, t0, t1):
    fr = [p for p in packets if t0 <= p[0] <= t1 and not p[2]]
    dur = t1 - t0
    res = dict(frames=len(fr), fps=round(len(fr) / dur, 1),
               mbps=round(sum(p[1] for p in packets if t0 <= p[0] <= t1) * 8 / dur / 1e6, 2),
               keyframes=sum(1 for p in fr if p[3]))
    if len(fr) > 5:
        times = [p[0] for p in fr]
        peak, j = 0, 0
        for i in range(len(times)):
            while times[i] - times[j] > 1.0:
                j += 1
            peak = max(peak, i - j + 1)
        res["fps_dinh_1s"] = peak
        gaps = sorted((b - a) * 1000 for a, b in zip(times, times[1:]))
        res["khoang_cach_ms"] = dict(p50=round(pct(gaps, 50), 1), p95=round(pct(gaps, 95), 1),
                                     p99=round(pct(gaps, 99), 1))
        # arrival time minus device PTS, relative to the best case in the window
        delay = [(p[0] - fr[0][0]) * 1000 - (p[4] - fr[0][4]) / 1000 for p in fr]
        base = min(delay)
        ex = sorted(d - base for d in delay)
        res["tre_vuot_muc_ms"] = dict(p50=round(pct(ex, 50), 1), p95=round(pct(ex, 95), 1),
                                      p99=round(pct(ex, 99), 1), max=round(ex[-1], 1))
        sizes = sorted(p[1] for p in fr)
        res["kich_thuoc_khung_kB"] = dict(p50=round(pct(sizes, 50) / 1024, 1), max=round(sizes[-1] / 1024, 1))
    return res


def run_scenario(sc, clk_tck, ncpu):
    print(f"\n=== {sc['name']} ===", flush=True)
    res = dict(name=sc["name"])
    server = None
    socks = []
    stop = threading.Event()
    motion_stop = threading.Event()
    threads = []
    log_lines = []
    video = dict(sessions=[], packets=[])
    audio = dict(sessions=[], packets=[])
    try:
        if sc["server"]:
            t = time.monotonic()
            adb("push", JAR_LOCAL, JAR_REMOTE)
            res["push_ms"] = round((time.monotonic() - t) * 1000)
            scid = f"{random.getrandbits(31):08x}"
            adb("forward", f"tcp:{PORT}", f"localabstract:scrcpy_{scid}")
            opts = dict(scid=scid, log_level="info", tunnel_forward="true",
                        audio="true" if sc.get("audio") else "false", control="true", power_on="false")
            opts.update(sc["opts"])
            cmd = (f"CLASSPATH={JAR_REMOTE} app_process / com.genymobile.scrcpy.Server {VERSION} "
                   + " ".join(f"{k}={v}" for k, v in opts.items()))
            t_launch = time.monotonic()
            server = subprocess.Popen([ADB, "-s", SERIAL, "shell", cmd], stdout=subprocess.PIPE,
                                      stderr=subprocess.STDOUT, text=True)
            threading.Thread(target=lambda: [log_lines.append(l.rstrip()) for l in server.stdout],
                             daemon=True).start()
            first = None
            for _ in range(100):
                s = socket.create_connection(("127.0.0.1", PORT), timeout=2)
                try:
                    if s.recv(1):
                        first = s
                        break
                except OSError:
                    pass
                s.close()
                time.sleep(0.1)
            if first is None:
                raise RuntimeError("khong ket noi duoc server: " + " | ".join(log_lines[-5:]))
            socks.append(first)
            for _ in range(2 if sc.get("audio") else 1):
                socks.append(socket.create_connection(("127.0.0.1", PORT), timeout=2))
            for s in socks:
                s.settimeout(1.0)
            th = threading.Thread(target=stream_reader, args=(socks[0], video, stop, True), daemon=True)
            th.start(); threads.append(th)
            if sc.get("audio"):
                th = threading.Thread(target=stream_reader, args=(socks[1], audio, stop, False), daemon=True)
                th.start(); threads.append(th)
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and not any(not p[2] for p in video["packets"]):
                if server.poll() is not None:
                    raise RuntimeError("server thoat som: " + " | ".join(log_lines[-6:]))
                time.sleep(0.005)
            firsts = [p for p in video["packets"] if not p[2]]
            if not firsts:
                raise RuntimeError("khong nhan duoc khung hinh: " + " | ".join(log_lines[-6:]))
            res["khoi_dong_den_khung_dau_ms"] = round((firsts[0][0] - t_launch) * 1000)

        if sc["motion"]:
            th = threading.Thread(target=motion_loop, args=(motion_stop,), daemon=True)
            th.start()
        time.sleep(WARMUP)

        res["nhiet_truoc"] = thermal()
        s0 = snapshot(True)
        t0 = time.monotonic()
        time.sleep(sc["window"] / 2)
        freqs = sh("cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null").split()
        time.sleep(sc["window"] / 2)
        t1 = time.monotonic()
        s1 = snapshot(False)
        res["nhiet_sau"] = thermal()
        res["cpu_freq_MHz_giua_ky"] = [int(f) // 1000 for f in freqs if f.isdigit()]

        dur = s1["uptime"] - s0["uptime"]
        d = [b - a for a, b in zip(s0["cpu"], s1["cpu"])]
        busy = sum(d) - d[3] - d[4]
        res["thoi_luong_s"] = round(dur, 2)
        res["cpu_toan_may_pct_8nhan"] = round(100 * busy / sum(d), 1)
        res["cpu_toan_may_pct_1nhan"] = round(100 * busy / clk_tck / dur, 1)
        deltas = []
        for pid, (comm, ticks, rss) in s1["procs"].items():
            before = s0["procs"].get(pid)
            dt = ticks - (before[1] if before and before[0] == comm else 0)
            if dt > 0:
                deltas.append((round(100 * dt / clk_tck / dur, 1), comm, pid, rss * 4 // 1024))
        deltas.sort(reverse=True)
        res["top_tien_trinh"] = [dict(cpu_pct_1nhan=c, comm=n, pid=p, rss_MB=r) for c, n, p, r in deltas[:10]]

        if sc["server"]:
            sp = scrcpy_procs()
            for p in sp:
                hit = [x for x in deltas if x[2] == p["pid"]]
                p["cpu_pct_1nhan"] = hit[0][0] if hit else 0.0
            res["tien_trinh_scrcpy"] = sp
            res["video"] = video_stats(video["packets"], t0, t1)
            res["video"]["codec"] = video.get("codec")
            res["video"]["kich_thuoc"] = [s[1:] for s in video["sessions"]]
            if sc.get("audio"):
                ap = [p for p in audio["packets"] if t0 <= p[0] <= t1]
                res["audio"] = dict(codec=audio.get("codec"), goi_moi_giay=round(len(ap) / (t1 - t0), 1),
                                    kbps=round(sum(p[1] for p in ap) * 8 / (t1 - t0) / 1000, 1))
        res["man_hinh"] = (re.search(r"mWakefulness=(\w+)", sh("dumpsys power")) or [None, "?"])[1]
    except Exception as e:  # keep going with the other scenarios
        res["loi"] = str(e)
    finally:
        motion_stop.set()
        stop.set()
        time.sleep(0.6)
        for s in socks:
            try:
                s.close()
            except OSError:
                pass
        if server is not None:
            try:
                server.wait(timeout=6)
            except subprocess.TimeoutExpired:
                server.kill()
            adb("forward", "--remove", f"tcp:{PORT}")
        sh("cmd statusbar collapse")
        res["server_log"] = [l for l in log_lines if l.strip()][:14]
    print(json.dumps(res, ensure_ascii=False, indent=1), flush=True)
    return res


def main():
    clk_tck = int(sh("getconf CLK_TCK").strip() or 100)
    ncpu = int(sh("nproc").strip())
    print("CLK_TCK", clk_tck, "ncpu", ncpu, "| screen_off_timeout(ms):",
          sh("settings get system screen_off_timeout").strip(),
          "| stay_on_while_plugged_in:", sh("settings get global stay_on_while_plugged_in").strip())
    only = sys.argv[1:]
    results = []
    for sc in SCENARIOS:
        if only and sc["name"] not in only:
            continue
        results.append(run_scenario(sc, clk_tck, ncpu))
        time.sleep(3)
    left = sh(f"ls -l {JAR_REMOTE} 2>&1; pgrep -f 'genymobil[e]'").strip()
    print("\n--- con sot lai tren may:", left)
    with open(os.path.join(HERE, "results.json"), "w") as f:
        json.dump(results, f, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
