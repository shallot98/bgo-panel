#!/usr/bin/env python3
"""bgo 监控面板（boh）。

纯标准库：http.server + sqlite3 + urllib。只绑 127.0.0.1，外部经 cloudflared 进来。
后台线程每 60s 执行房间模式规则（临时 N 小时 / 只录本场），每 5 分钟刷新日志统计等缓存。
"""
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import sqlite3
import subprocess
import sys
import threading
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from http import cookies as http_cookies
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = os.path.dirname(os.path.abspath(__file__))
BGO_ROOT = os.environ.get("BGO_ROOT", "/root/bililive-go")
BGO_API = os.environ.get("BGO_API", "http://127.0.0.1:8080/api")
SIDECAR = os.environ.get("BGO_SIDECAR", "http://127.0.0.1:18110")
SIDECAR_AUTH = "Basic YTph"
# 侧车只在容器内监听时（hwsg），用 `docker exec <容器> curl` 访问，例如 "docker exec bililive-go"
SIDECAR_EXEC = os.environ.get("BGO_SIDECAR_EXEC", "")
BIND = os.environ.get("PANEL_BIND", "127.0.0.1")
PORT = int(os.environ.get("PANEL_PORT", "8090"))
DB_PATH = os.path.join(BASE, "panel.db")
CONF_PATH = os.path.join(BASE, "panel.json")
INDEX_PATH = os.path.join(BASE, "index.html")
LOG_DIR = os.environ.get("BGO_LOG_DIR", BGO_ROOT)
VIDEO_DIR = os.environ.get("BGO_VIDEO_DIR", os.path.join(BGO_ROOT, "抖音"))
LOCAL_NAME = os.environ.get("PANEL_HOST_NAME", "boh")
# agent 模式：只接受 Bearer 密钥，不提供网页和密码登录；由 boh 上的面板（hub）汇总
AGENT_MODE = os.environ.get("PANEL_AGENT") == "1"
PROFILE = os.environ.get("PANEL_PROFILE", "boh")  # boh | docker

RULE_INTERVAL = 60
SESSION_OFFLINE_GRACE = 30 * 60  # 只录本场：下播持续 30 分钟判定本场结束（用户选 A）
COOKIE_NAME = "bgo_panel"
SESSION_TTL = 7 * 86400
DEFAULT_PASSWORD = "12"

# 本机请求一律不走环境变量里的代理（boh 上有 privoxy 类环境变量）
_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def log(*a):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), *a, flush=True)


# ---------------------------------------------------------------- 配置与密码

def hash_password(pw, salt=None):
    salt = salt or secrets.token_hex(16)
    dk = hashlib.pbkdf2_hmac("sha256", pw.encode(), bytes.fromhex(salt), 200_000)
    return salt, dk.hex()


def load_conf():
    if os.path.exists(CONF_PATH):
        with open(CONF_PATH) as f:
            return json.load(f)
    salt, h = hash_password(DEFAULT_PASSWORD)
    conf = {"pw_salt": salt, "pw_hash": h, "pw_is_default": True}
    save_conf(conf)
    log("panel.json 不存在，已用初始密码创建")
    return conf


def save_conf(conf):
    tmp = CONF_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(conf, f, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, CONF_PATH)


CONF = load_conf()
CONF_LOCK = threading.Lock()


def check_password(pw):
    _, h = hash_password(pw, CONF["pw_salt"])
    return hmac.compare_digest(h, CONF["pw_hash"])


def api_token():
    """给 iOS 快捷指令等脚本用的固定密钥（请求头 Authorization: Bearer <token>）。"""
    with CONF_LOCK:
        if not CONF.get("api_token"):
            CONF["api_token"] = "bgp_" + secrets.token_urlsafe(24)
            save_conf(CONF)
        return CONF["api_token"]


def rotate_api_token():
    with CONF_LOCK:
        CONF["api_token"] = "bgp_" + secrets.token_urlsafe(24)
        save_conf(CONF)
        return CONF["api_token"]


# ---------------------------------------------------------------- 数据库

_db_lock = threading.Lock()


def db():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    with _db_lock, db() as c:
        c.executescript("""
        CREATE TABLE IF NOT EXISTS managed_rooms (
            live_id TEXT PRIMARY KEY,
            url TEXT NOT NULL,
            mode TEXT NOT NULL,              -- temp | session
            state TEXT NOT NULL,             -- active | waiting | expiring | done | cancelled
            hours REAL,
            expires_at REAL,
            session_live_id TEXT,
            offline_since REAL,
            note TEXT DEFAULT '',
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            ended_at REAL
        );
        CREATE TABLE IF NOT EXISTS ops_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts REAL NOT NULL,
            actor TEXT NOT NULL,             -- user | rule
            action TEXT NOT NULL,
            live_id TEXT,
            host TEXT,
            detail TEXT,
            ok INTEGER NOT NULL DEFAULT 1
        );
        CREATE TABLE IF NOT EXISTS sessions (
            token TEXT PRIMARY KEY,
            created_at REAL NOT NULL,
            expires_at REAL NOT NULL,
            ip TEXT
        );
        """)


def migrate_db():
    """老库补列：录 N 场（D-007）。老的只录本场记录视为 1/1。"""
    with _db_lock, db() as c:
        cols = {r[1] for r in c.execute("PRAGMA table_info(managed_rooms)")}
        if "sessions_total" not in cols:
            c.execute("ALTER TABLE managed_rooms ADD COLUMN sessions_total INTEGER")
        if "sessions_left" not in cols:
            c.execute("ALTER TABLE managed_rooms ADD COLUMN sessions_left INTEGER")
        c.execute("UPDATE managed_rooms SET sessions_total=1 WHERE mode='session' AND sessions_total IS NULL")
        c.execute("UPDATE managed_rooms SET sessions_left=1 WHERE mode='session' AND sessions_left IS NULL")


def oplog(actor, action, live_id=None, host=None, detail="", ok=True):
    with _db_lock, db() as c:
        c.execute("INSERT INTO ops_log(ts,actor,action,live_id,host,detail,ok) VALUES(?,?,?,?,?,?,?)",
                  (time.time(), actor, action, live_id, host, detail, 1 if ok else 0))
    log(f"[{actor}] {action} {live_id or ''} {host or ''} {detail} ok={ok}")


def managed_get(live_id):
    with db() as c:
        r = c.execute("SELECT * FROM managed_rooms WHERE live_id=?", (live_id,)).fetchone()
        return dict(r) if r else None


def managed_all():
    with db() as c:
        return [dict(r) for r in c.execute("SELECT * FROM managed_rooms")]


def managed_update(live_id, **kw):
    kw["updated_at"] = time.time()
    cols = ",".join(f"{k}=?" for k in kw)
    with _db_lock, db() as c:
        c.execute(f"UPDATE managed_rooms SET {cols} WHERE live_id=?", (*kw.values(), live_id))


def managed_put(row):
    now = time.time()
    row.setdefault("created_at", now)
    row["updated_at"] = now
    keys = ",".join(row)
    with _db_lock, db() as c:
        c.execute(f"INSERT OR REPLACE INTO managed_rooms({keys}) VALUES({','.join('?' * len(row))})",
                  tuple(row.values()))


def managed_delete(live_id):
    with _db_lock, db() as c:
        c.execute("DELETE FROM managed_rooms WHERE live_id=?", (live_id,))


# ---------------------------------------------------------------- bgo / sidecar

class UpstreamError(Exception):
    pass


def http_json(url, method="GET", body=None, headers=None, timeout=15):
    data = None
    h = {"Accept": "application/json"}
    if headers:
        h.update(headers)
    if body is not None:
        data = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with _opener.open(req, timeout=timeout) as r:
            raw = r.read()
    except urllib.error.HTTPError as e:
        raise UpstreamError(f"{method} {url} -> HTTP {e.code}: {e.read()[:200].decode('utf-8', 'replace')}")
    except Exception as e:
        raise UpstreamError(f"{method} {url} -> {e}")
    try:
        return json.loads(raw) if raw else None
    except ValueError:
        raise UpstreamError(f"{method} {url} -> 非 JSON 响应: {raw[:200]!r}")


def bgo(path, method="GET", body=None, timeout=15):
    return http_json(BGO_API + path, method, body, timeout=timeout)


def bgo_lives():
    return bgo("/lives")


def bgo_stop(live_id):
    """运行中停止监听。2026-10-29 实测：立即生效并写回 config.yml 的 is_listening。"""
    return bgo(f"/lives/{live_id}/stop")


def bgo_start(live_id):
    return bgo(f"/lives/{live_id}/start")


def room_key(url):
    return urllib.parse.urlparse(url).path.strip("/").split("/")[0]


def sidecar_get(path, timeout=40):
    headers = {"Authorization": SIDECAR_AUTH}
    if not SIDECAR_EXEC:
        return http_json(SIDECAR + path, headers=headers, timeout=timeout)
    cmd = SIDECAR_EXEC.split() + ["curl", "-s", "-m", str(timeout - 5), "-H", "Authorization: " + SIDECAR_AUTH,
                                  "-w", "\n%{http_code}", SIDECAR + path]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except Exception as e:
        raise UpstreamError(f"侧车调用失败（{SIDECAR_EXEC}）：{e}")
    body, _, code = p.stdout.rpartition("\n")
    if p.returncode != 0 or code != "200":
        raise UpstreamError(f"侧车 {path} -> HTTP {code or '?'} rc={p.returncode}: {(body or p.stderr)[:200]}")
    try:
        return json.loads(body)
    except ValueError:
        raise UpstreamError(f"侧车 {path} -> 非 JSON 响应: {body[:200]!r}")


def sidecar_live_info(url):
    """返回 {living, liveId, title, owner, api}。liveId 为抖音场次 ID（只有部分通道带）。"""
    rid = urllib.parse.quote(room_key(url))
    d = sidecar_get(f"/bgo/live-info?platform=douyin&roomId={rid}&dev=1")
    dev = (d or {}).get("dev") or {}
    return {
        "living": bool(d.get("living")),
        "liveId": dev.get("liveId") or None,
        "title": d.get("title"),
        "owner": d.get("owner"),
        "api": dev.get("api"),
    }


# ---------------------------------------------------------------- 房间模式规则

def stop_room(live, reason, actor="rule"):
    lid = live["id"]
    try:
        if live.get("recording"):
            bgo(f"/lives/{lid}/stopRecord", "POST")  # bgo v0.8.3：必须 POST，GET 回 400 invalid Action
        bgo_stop(lid)
        oplog(actor, "停止监听", lid, live.get("host_name"), reason)
        return True
    except UpstreamError as e:
        oplog(actor, "停止监听失败", lid, live.get("host_name"), f"{reason}；{e}", ok=False)
        return False


def run_rules_once():
    rows = [r for r in managed_all() if r["state"] in ("active", "waiting", "expiring")]
    if not rows:
        return
    lives = {x["id"]: x for x in bgo_lives()}
    now = time.time()
    for r in rows:
        lid = r["live_id"]
        live = lives.get(lid)
        if live is None:
            managed_update(lid, state="cancelled", ended_at=now, note="房间已不在 bgo 列表中")
            oplog("rule", "取消托管", lid, None, "房间已从 bgo 删除")
            continue
        if not live["listening"]:
            # 用户在别处手动关掉了；以 bgo 实际状态为准，不反向覆盖
            managed_update(lid, state="cancelled", ended_at=now, note="监听已被手动关闭")
            oplog("rule", "取消托管", lid, live.get("host_name"), "监听已在别处被关闭")
            continue
        try:
            if r["mode"] == "temp":
                rule_temp(r, live, now)
            elif r["mode"] == "session":
                rule_session(r, live, now)
        except UpstreamError as e:
            managed_update(lid, note=f"本轮检查失败：{e}"[:300])
            log("rule error", lid, e)


def rule_temp(r, live, now):
    lid = r["live_id"]
    if now < r["expires_at"]:
        return
    if live.get("recording"):
        if r["state"] != "expiring":
            managed_update(lid, state="expiring", note="已到期，等本场录完再停")
            oplog("rule", "到期等待", lid, live.get("host_name"), "临时监控到期，正在录制，录完再停")
        return
    if stop_room(live, "临时监控到期（" + datetime.fromtimestamp(r["expires_at"]).strftime("%m-%d %H:%M") + "）"):
        managed_update(lid, state="done", ended_at=now, note="到期已停止监听")


def session_total(r):
    return int(r.get("sessions_total") or 1)


def session_left(r):
    v = r.get("sessions_left")
    return int(v if v is not None else 1)


def session_index(r, left=None):
    """当前是第几场（从 1 起）。left 默认用记录里的剩余数。"""
    left = session_left(r) if left is None else left
    return max(1, session_total(r) - left + 1)


def rule_session(r, live, now):
    lid = r["live_id"]
    info = sidecar_live_info(live["live_url"])
    if info["living"]:
        if not info["liveId"]:
            managed_update(lid, offline_since=None, note=f"拿不到场次 ID（通道 {info['api']}），本轮不判断")
            return
        if not r["session_live_id"]:
            managed_update(lid, state="active", session_live_id=info["liveId"], offline_since=None,
                           note="已锁定本场")
            oplog("rule", "锁定场次", lid, live.get("host_name"), f"liveId={info['liveId']}")
            return
        if info["liveId"] != r["session_live_id"]:
            left = session_left(r) - 1
            if left > 0:
                managed_update(lid, state="active", session_live_id=info["liveId"], offline_since=None,
                               sessions_left=left, note=f"上一场结束，已锁定新场次，还剩 {left} 场")
                oplog("rule", "下一场", lid, live.get("host_name"),
                      f"liveId={info['liveId']}；第 {session_index(r, left)}/{session_total(r)} 场")
                return
            if stop_room(live, f"检测到新场次 {info['liveId']}（锁定的是 {r['session_live_id']}），{session_total(r)} 场已录完"):
                managed_update(lid, state="done", ended_at=now, sessions_left=0, note="场次已录完，已停止监听")
            return
        managed_update(lid, offline_since=None, note=f"录制中：第 {session_index(r)}/{session_total(r)} 场")
        return
    # 未开播
    if not r["session_live_id"]:
        managed_update(lid, note="等待开播")
        return
    if not r["offline_since"]:
        managed_update(lid, offline_since=now, note="已下播，等待 30 分钟确认")
        return
    if now - r["offline_since"] < SESSION_OFFLINE_GRACE:
        return
    if live.get("recording"):
        return
    left = session_left(r) - 1
    if left > 0:
        managed_update(lid, state="waiting", session_live_id=None, offline_since=None, sessions_left=left,
                       note=f"上一场已结束，等下一场开播，还剩 {left} 场")
        oplog("rule", "一场结束", lid, live.get("host_name"), f"下播超过 30 分钟；还剩 {left} 场")
        return
    if stop_room(live, f"下播超过 30 分钟，{session_total(r)} 场已录完"):
        managed_update(lid, state="done", ended_at=now, sessions_left=0, note="场次已录完，已停止监听")


def rules_loop():
    while True:
        try:
            run_rules_once()
        except Exception:
            log("rules loop error\n" + traceback.format_exc())
        time.sleep(RULE_INTERVAL)


# ---------------------------------------------------------------- 统计缓存

CACHE = {}
CACHE_LOCK = threading.Lock()

LOG_RE = re.compile(r'^time="([^"]+)" level=(\w+) msg="((?:[^"\\]|\\.)*)"(.*)$')
KV_RE = re.compile(r'(\w+)=("(?:[^"\\]|\\.)*"|\S+)')


def parse_kv(rest):
    out = {}
    for k, v in KV_RE.findall(rest):
        if v.startswith('"'):
            v = v[1:-1].replace('\\"', '"')
        out[k] = v
    return out


ERR_CATS = ("room_fast", "room_deadline", "stream_fail")  # 备援判定"500 风暴"统计的类别


def classify(level, msg, rest):
    if msg.startswith("failed to load room info"):
        return "room_deadline" if "deadline exceeded" in rest else "room_fast"
    if msg.startswith("failed to get stream url"):
        return "stream_fail"
    if msg == "Live Start":
        return "live_start"
    if msg == "Live end":
        return "live_end"
    if msg.startswith("Record Start"):
        return "record_start"
    if msg == "Record End":
        return "record_end"
    if level == "error":
        return "other_error"
    return None


def refresh_log_stats():
    now = datetime.now()
    start = (now - timedelta(hours=23)).replace(minute=0, second=0, microsecond=0)
    hours = [(start + timedelta(hours=i)).strftime("%Y-%m-%d %H") for i in range(24)]
    buckets = {h: {} for h in hours}
    today = {}
    recent = []
    per_room = {}
    cutoff5 = (now - timedelta(minutes=5)).strftime("%Y-%m-%d %H:%M:%S")
    last5 = {}
    for day in sorted({start.date(), now.date()}):
        path = os.path.join(LOG_DIR, f"bililive-go-{day.isoformat()}.log")
        if not os.path.exists(path):
            continue
        with open(path, errors="replace") as f:
            for line in f:
                m = LOG_RE.match(line.rstrip("\n"))
                if not m:
                    continue
                ts, level, msg, rest = m.groups()
                cat = classify(level, msg, rest)
                if not cat:
                    continue
                hk = ts[:13]
                if hk in buckets:
                    buckets[hk][cat] = buckets[hk].get(cat, 0) + 1
                if ts[:10] == now.strftime("%Y-%m-%d"):
                    today[cat] = today.get(cat, 0) + 1
                if cat in ERR_CATS and ts >= cutoff5:
                    last5[cat] = last5.get(cat, 0) + 1
                if level in ("error", "warning") and ts >= start.strftime("%Y-%m-%d %H"):
                    kv = parse_kv(rest)
                    room = kv.get("room", "").lstrip("/")
                    if cat in ("room_fast", "room_deadline", "stream_fail"):
                        pr = per_room.setdefault(room, {})
                        pr[cat] = pr.get(cat, 0) + 1
                    recent.append({"ts": ts, "level": level, "cat": cat or "", "msg": msg,
                                   "room": room, "error": kv.get("error", "")[:300]})
    top_rooms = sorted(per_room.items(), key=lambda kv: -sum(kv[1].values()))[:10]
    with CACHE_LOCK:
        CACHE["logstats"] = {
            "updated": time.time(),
            "hours": [{"hour": h, **buckets[h]} for h in hours],
            "today": today,
            "recent": recent[-80:][::-1],
            "top_rooms": [{"room": k, **v} for k, v in top_rooms],
            "last5m": last5,
        }


def fix_session(s):
    """bgo 对进行中的场次返回 Go 零值时间 0001-01-01，统一改成 None。"""
    for k in ("start_time", "end_time"):
        if (s.get(k) or "").startswith("0001-"):
            s[k] = None
    return s


def refresh_sessions():
    lives = bgo_lives()
    items = []
    for x in lives:
        try:
            d = bgo(f"/lives/{x['id']}/sessions")
        except UpstreamError:
            continue
        for s in (d or {}).get("sessions") or []:
            fix_session(s)
            s["live_url"] = x["live_url"]
            items.append(s)
        time.sleep(0.05)
    items.sort(key=lambda s: s.get("start_time") or "", reverse=True)
    with CACHE_LOCK:
        CACHE["sessions"] = {"updated": time.time(), "items": items[:300]}


PROCS_BOH = [
    ("bgo", "bililive-go 主进程", r"external_tools/linux/amd64/bililive-go/.*bililive-linux-amd64"),
    ("sidecar", "biliLive-tools 侧车", r"node\.real \./index\.cjs server"),
    ("scheduler", "bililive-scheduler", r"bililive-scheduler"),
    ("cookie", "cookie 轮换 daemon", r"rotate-douyin-cookies\.py daemon"),
    ("cookie_wd", "cookie 轮换 watchdog", r"cookie-rotator-watchdog\.sh"),
    ("mover", "转码搬运 mover-loop", r"mover-loop\.sh"),
    ("bgo_wd", "bgo watchdog", r"bililive-go/ops/watchdog\.sh"),
    ("cloudflared", "cloudflared 隧道", r"cloudflared tunnel"),
    ("panel_wd", "面板 watchdog", r"ops/panel/watchdog\.sh"),
]
# bgo 跑在 Docker 里（hwsg）：容器内进程在宿主机 ps 里也能看到；容器自己由 Docker restart 策略保活
PROCS_DOCKER = [
    ("bgo", "bililive-go（容器）", r"/usr/bin/bililive-go -c"),
    ("sidecar", "biliLive-tools 侧车（容器内）", r"node \./index\.cjs server"),
    ("nginx", "nginx", r"nginx: master"),
    ("panel_wd", "面板 agent（systemd 保活）", r"/root/bgo-panel/panel\.py"),
]
PROCS = PROCS_DOCKER if PROFILE == "docker" else PROCS_BOH


def proc_status():
    try:
        out = subprocess.run(["ps", "-eo", "pid=,etimes=,args="], capture_output=True, text=True,
                             timeout=10).stdout
    except Exception as e:
        return [{"key": k, "name": n, "alive": None, "error": str(e)} for k, n, _ in PROCS]
    lines = []
    for ln in out.splitlines():
        parts = ln.strip().split(None, 2)
        if len(parts) == 3:
            lines.append(parts)
    me = str(os.getpid())
    res = []
    for key, name, pat in PROCS:
        rx = re.compile(pat)
        hit = [p for p in lines if rx.search(p[2]) and (p[0] != me or key == "panel_wd") and "grep" not in p[2]]
        res.append({"key": key, "name": name, "alive": bool(hit),
                    "pid": int(hit[0][0]) if hit else None,
                    "uptime": int(hit[0][1]) if hit else None})
    return res


def dir_size(path):
    total = files = 0
    newest = 0
    for root, _, fs in os.walk(path):
        for fn in fs:
            try:
                st = os.stat(os.path.join(root, fn))
            except OSError:
                continue
            total += st.st_size
            files += 1
            newest = max(newest, st.st_mtime)
    return total, files, newest


def refresh_storage():
    du = shutil.disk_usage(BGO_ROOT)
    streamers = []
    recent_files = []
    if os.path.isdir(VIDEO_DIR):
        for name in os.listdir(VIDEO_DIR):
            p = os.path.join(VIDEO_DIR, name)
            if not os.path.isdir(p):
                continue
            size, n, newest = dir_size(p)
            streamers.append({"name": name, "size": size, "files": n, "newest": newest})
            for fn in os.listdir(p):
                fp = os.path.join(p, fn)
                try:
                    st = os.stat(fp)
                except OSError:
                    continue
                if os.path.isfile(fp):
                    recent_files.append({"streamer": name, "file": fn, "size": st.st_size, "mtime": st.st_mtime})
    streamers.sort(key=lambda s: -s["size"])
    recent_files.sort(key=lambda f: -f["mtime"])

    def count_lines(p):
        try:
            with open(p, errors="replace") as f:
                return sum(1 for ln in f if ln.strip())
        except OSError:
            return None

    sd = os.path.join(BGO_ROOT, "scripts")
    with CACHE_LOCK:
        CACHE["storage"] = {
            "updated": time.time(),
            "disk": {"total": du.total, "used": du.used, "free": du.free},
            "video_total": sum(s["size"] for s in streamers),
            "streamers": streamers,
            "recent_files": recent_files[:30],
            "queue": {
                "pending": count_lines(os.path.join(sd, ".openlist-auto-move.pending")),
                "skipped": count_lines(os.path.join(sd, ".openlist-auto-move.skipped")),
                "failures": len(os.listdir(os.path.join(sd, ".flv-to-mp4-failures")))
                if os.path.isdir(os.path.join(sd, ".flv-to-mp4-failures")) else None,
            },
        }


def cookie_status():
    if not os.path.isdir(os.path.join(BGO_ROOT, "ops/cookie-pool")):
        return {"absent": True}
    st_path = os.path.join(BGO_ROOT, "ops/cookie-pool/state/rotator-state.json")
    pool_path = os.path.join(BGO_ROOT, "ops/cookie-pool/pool.json")
    res = {}
    try:
        with open(st_path) as f:
            st = json.load(f)
        last = st.get("last_used") or {}
        if last:
            name, ts = max(last.items(), key=lambda kv: kv[1])
            res["current"] = name
            res["current_since"] = ts
        res["known"] = len(last)
        res["failed"] = st.get("failed") or {}
    except (OSError, ValueError) as e:
        res["error"] = f"读取 rotator-state.json 失败：{e}"
    try:
        with open(pool_path) as f:
            pool = json.load(f)
        res["policy"] = {k: pool.get(k) for k in
                         ("rotate_strategy", "max_use_seconds", "error_threshold", "proactive_rotate",
                          "daemon_loop_seconds")}
    except (OSError, ValueError) as e:
        res["policy_error"] = str(e)
    cdir = os.path.join(BGO_ROOT, "ops/cookie-pool/cookies")
    res["pool_files"] = len(os.listdir(cdir)) if os.path.isdir(cdir) else None
    return res


def exit_health():
    d = os.path.join(BGO_ROOT, "ops/fix-500")
    try:
        logs = sorted(f for f in os.listdir(d) if f.startswith("health-") and f.endswith(".log"))
    except OSError:
        return None
    if not logs:
        return None
    p = os.path.join(d, logs[-1])
    with open(p, errors="replace") as f:
        lines = f.readlines()[-80:]
    summary = next((ln.strip() for ln in reversed(lines) if "汇总" in ln), None)
    rnd = next((ln.strip() for ln in reversed(lines) if ln.startswith("round ")), None)
    return {"file": logs[-1], "mtime": os.path.getmtime(p), "summary": summary, "round": rnd}


def bg_refresh_loop():
    tasks = [(refresh_log_stats, 300), (refresh_storage, 600), (refresh_sessions, 600)]
    last = {f: 0 for f, _ in tasks}
    while True:
        for fn, every in tasks:
            if time.time() - last[fn] >= every:
                try:
                    fn()
                except Exception:
                    log(f"{fn.__name__} error\n" + traceback.format_exc())
                last[fn] = time.time()
        time.sleep(15)


# ---------------------------------------------------------------- 业务 API

def merged_rooms():
    lives = bgo_lives()
    managed = {r["live_id"]: r for r in managed_all()}
    fo = {} if AGENT_MODE else {r["live_id"]: r for r in fo_all(("active", "releasing"))}
    out = []
    for x in lives:
        m = managed.get(x["id"])
        x = dict(x)
        x["host"] = LOCAL_NAME
        x["managed"] = m
        x["failover"] = fo.get(x["id"])
        x["mode"] = m["mode"] if m and m["state"] in ("active", "waiting", "expiring") else "permanent"
        out.append(x)
    return out


# ---------------------------------------------------------------- 多服务器（hub）

class AgentError(Exception):
    pass


def agents():
    return CONF.get("agents") or []


def agent_by_name(name):
    return next((a for a in agents() if a.get("name") == name), None)


AGENT_UA = "Mozilla/5.0 (bgo-panel hub)"  # Cloudflare 会拦 Python 默认 UA（实测 403）
# boh 的 Tailscale 是 userspace 模式，访问 100.x 地址要经它的本地 SOCKS5
TS_SOCKS = os.environ.get("PANEL_TS_SOCKS", "127.0.0.1:1055")


def socks5_http(url, method, headers, data, timeout):
    """经 SOCKS5 发一个明文 HTTP/1.1 请求（只给 Tailscale 内网地址用），返回 (状态码, 响应字节)。"""
    import socket
    import struct
    u = urllib.parse.urlparse(url)
    host, port = u.hostname, u.port or 80
    sh, sp = TS_SOCKS.rsplit(":", 1)
    s = socket.create_connection((sh, int(sp)), timeout=timeout)
    try:
        s.settimeout(timeout)
        s.sendall(b"\x05\x01\x00")
        if s.recv(2) != b"\x05\x00":
            raise OSError("SOCKS5 握手失败")
        hb = host.encode()
        s.sendall(b"\x05\x01\x00\x03" + bytes([len(hb)]) + hb + struct.pack(">H", port))
        rep = s.recv(4)
        if len(rep) < 2 or rep[1] != 0:
            raise OSError(f"SOCKS5 连接 {host}:{port} 失败（rep={rep[1:2].hex() or '?'}）")
        alen = {1: 4, 4: 16}.get(rep[3]) if len(rep) == 4 else None
        s.recv((alen if alen else s.recv(1)[0]) + 2)
        path = (u.path or "/") + ("?" + u.query if u.query else "")
        lines = [f"{method} {path} HTTP/1.1", f"Host: {u.netloc}", "Connection: close"]
        lines += [f"{k}: {v}" for k, v in headers.items()]
        if data is not None:
            lines.append(f"Content-Length: {len(data)}")
        s.sendall(("\r\n".join(lines) + "\r\n\r\n").encode() + (data or b""))
        buf = b""
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    finally:
        s.close()
    head, _, body = buf.partition(b"\r\n\r\n")
    status_line = head.split(b"\r\n", 1)[0].decode("latin-1")
    try:
        code = int(status_line.split()[1])
    except (IndexError, ValueError):
        raise OSError(f"无效 HTTP 响应：{status_line[:80]!r}")
    if b"transfer-encoding: chunked" in head.lower():
        out, rest = b"", body
        while rest:
            size_line, _, rest = rest.partition(b"\r\n")
            n = int(size_line.split(b";")[0] or b"0", 16)
            if n == 0:
                break
            out, rest = out + rest[:n], rest[n + 2:]
        body = out
    return code, body


def agent_call(agent, method, path_qs, body=None, timeout=20):
    """转发到 agent，返回 (HTTP 状态码, 响应字节)。agent 连不上时抛 AgentError。

    agent 可以登记多个地址（`urls`，按顺序尝试）：Tailscale 内网（http://100.x，经 SOCKS5）优先，
    公网域名备用。boh 出公网要过 Bohrium 网关（实测单次 2~7s，偶发 TLS 握手卡 25s）。
    写操作只在"连不上"时换下一个地址；拿到 HTTP 响应（包括 4xx/5xx）就直接返回，不重复提交。
    """
    urls = agent.get("urls") or [agent["url"]]
    data = json.dumps(body).encode() if body is not None else None
    h = {"Authorization": "Bearer " + agent["token"], "Accept": "application/json", "User-Agent": AGENT_UA}
    if data is not None:
        h["Content-Type"] = "application/json"
    errs = []
    for base in urls:
        url = base.rstrip("/") + path_qs
        tailnet = urllib.parse.urlparse(url).hostname.startswith("100.")
        try:
            if tailnet:
                return socks5_http(url, method, h, data, timeout=min(timeout, 15))
            req = urllib.request.Request(url, data=data, method=method, headers=h)
            with _opener.open(req, timeout=timeout) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()
        except Exception as e:
            errs.append(f"{'tailscale' if tailnet else urllib.parse.urlparse(url).hostname}: {e}")
            log(f"agent {agent['name']} {method} {path_qs} 经 {base} 失败：{e}")
    raise AgentError(f"{agent['name']} 连接失败：" + "；".join(errs))


def agent_json(agent, path_qs, timeout=30):
    code, raw = agent_call(agent, "GET", path_qs, timeout=timeout)
    try:
        d = json.loads(raw)
    except ValueError:
        raise AgentError(f"{agent['name']} 返回非 JSON（HTTP {code}）：{raw[:120]!r}")
    if code != 200:
        raise AgentError(f"{agent['name']}：{(d or {}).get('error') or 'HTTP ' + str(code)}")
    return d


def parallel(fns):
    """并发执行 {key: fn}，返回 {key: (结果, 错误)}。"""
    res = {}

    def run(k, fn):
        try:
            res[k] = (fn(), None)
        except Exception as e:
            res[k] = (None, str(e))

    ts = [threading.Thread(target=run, args=(k, fn), daemon=True) for k, fn in fns.items()]
    for t in ts:
        t.start()
    for t in ts:
        t.join(75)
    return {k: res.get(k, (None, "超时")) for k in fns}


def all_rooms():
    fns = {LOCAL_NAME: merged_rooms}
    for a in agents():
        fns[a["name"]] = (lambda a=a: agent_json(a, "/api/rooms"))
    rooms, errors = [], {}
    for name, (data, err) in parallel(fns).items():
        if err:
            errors[name] = err
            continue
        for x in data:
            x["host"] = name
            rooms.append(x)
    return {"rooms": rooms, "errors": errors}


_HOSTS_CACHE = {"ts": 0, "data": None}


_HOSTS_LOCK = threading.Lock()


def api_hosts():
    """有缓存就立刻返回（过期则后台刷新），避免某台 agent 慢时拖住网页启动。"""
    data, age = _HOSTS_CACHE["data"], time.time() - _HOSTS_CACHE["ts"]
    if data is not None and age < 20:
        return data
    if data is not None:
        if _HOSTS_LOCK.acquire(blocking=False):
            def bg():
                try:
                    compute_hosts()
                except Exception:
                    log("hosts refresh error\n" + traceback.format_exc())
                finally:
                    _HOSTS_LOCK.release()
            threading.Thread(target=bg, daemon=True).start()
        return data
    with _HOSTS_LOCK:
        return compute_hosts()


def compute_hosts():
    ar = all_rooms()
    out = []
    for name in [LOCAL_NAME] + [a["name"] for a in agents()]:
        rs = [r for r in ar["rooms"] if r["host"] == name]
        err = ar["errors"].get(name)
        out.append({"name": name, "local": name == LOCAL_NAME, "ok": err is None, "error": err,
                    "total": len(rs), "listening": sum(1 for r in rs if r["listening"]),
                    "living": sum(1 for r in rs if r["status"]), "recording": sum(1 for r in rs if r["recording"]),
                    "managed": sum(1 for r in rs if r["mode"] != "permanent")})
    _HOSTS_CACHE.update(ts=time.time(), data=out)
    return out


def api_overview():
    rooms = merged_rooms()
    with CACHE_LOCK:
        ls = CACHE.get("logstats") or {}
        sessions = (CACHE.get("sessions") or {}).get("items") or []
        storage = CACHE.get("storage") or {}
    today = datetime.now().strftime("%Y-%m-%d")
    today_sessions = [s for s in sessions if (s.get("start_time") or "").startswith(today)]
    dur = 0
    for s in today_sessions:
        try:
            st = datetime.fromisoformat(s["start_time"])
            en = datetime.fromisoformat(s["end_time"]) if s.get("end_time") else datetime.now(st.tzinfo)
            dur += max(0, (en - st).total_seconds())
        except (KeyError, ValueError, TypeError):
            pass
    info = {}
    try:
        info = bgo("/info")
    except UpstreamError as e:
        info = {"error": str(e)}
    return {
        "counts": {
            "total": len(rooms),
            "listening": sum(1 for r in rooms if r["listening"]),
            "living": sum(1 for r in rooms if r["status"]),
            "recording": sum(1 for r in rooms if r["recording"]),
            "temp": sum(1 for r in rooms if r["mode"] == "temp"),
            "session": sum(1 for r in rooms if r["mode"] == "session"),
        },
        "recording": [r for r in rooms if r["recording"]],
        "living_not_recording": [r for r in rooms if r["status"] and not r["recording"]],
        "today_sessions": len(today_sessions),
        "today_duration": dur,
        "logstats": ls,
        "procs": proc_status(),
        "disk": storage.get("disk"),
        "video_total": storage.get("video_total"),
        "bgo": {k: info.get(k) for k in ("app_version", "pid", "go_version", "platform", "error")},
        "pw_is_default": CONF.get("pw_is_default", False) and not AGENT_MODE,
        "failover": fo_summary(),
        "server_time": time.time(),
    }


URL_RE = re.compile(r"^https://[A-Za-z0-9.-]+\.[A-Za-z]{2,}/\S*$")
URL_IN_TEXT_RE = re.compile(r"https?://[A-Za-z0-9.-]+\.[A-Za-z]{2,}/[^\s\"'<>，。！？、]*")


def resolve_douyin_short(u):
    """v.douyin.com 分享短链 → live.douyin.com/{房间号}，经 sidecar 解析。"""
    d = sidecar_get(f"/bgo/channel-info?url={urllib.parse.quote(u, safe='')}")
    rid = (d or {}).get("id") if isinstance(d, dict) else None
    if not rid:
        raise ValueError(f"短链接解析失败：{u}")
    return f"https://live.douyin.com/{rid}"


def normalize_url(u):
    u = (u or "").strip()
    if re.fullmatch(r"[A-Za-z0-9_.-]{3,64}", u):
        # 只给了抖音房间号（旧 bgo 快捷指令的剪贴板用法）
        return f"https://live.douyin.com/{u}"
    if not URL_RE.match(u):
        # 抖音 App 分享出来的是一段文案，里面夹着短链接
        m = URL_IN_TEXT_RE.search(u)
        if not m:
            raise ValueError("没有找到直播间链接，例如 https://live.douyin.com/123456")
        u = m.group(0).replace("http://", "https://", 1)
    p = urllib.parse.urlparse(u)
    if p.hostname == "v.douyin.com":
        try:
            return resolve_douyin_short(u)
        except UpstreamError as e:
            raise ValueError(f"短链接解析失败：{e}")
    if p.hostname == "live.douyin.com":
        key = room_key(u)
        if not key:
            raise ValueError("抖音链接缺少房间号")
        return f"https://live.douyin.com/{key}"
    return u.split("#")[0]


def find_live_by_url(url):
    for x in bgo_lives():
        if x["live_url"].rstrip("/") == url.rstrip("/"):
            return x
    return None


def parse_sessions(v, default=1):
    if v in (None, ""):
        return default
    try:
        n = int(float(v))
    except (TypeError, ValueError):
        raise ValueError("场数必须是整数")
    if not 1 <= n <= 50:
        raise ValueError("场数需在 1~50 之间")
    return n


def apply_mode(live, mode, hours, actor="user", sessions=None):
    lid = live["id"]
    now = time.time()
    if mode == "permanent":
        if managed_get(lid):
            managed_delete(lid)
        oplog(actor, "设为永久", lid, live.get("host_name"))
        return
    if mode == "temp":
        hours = float(hours or 24)
        if not 0 < hours <= 24 * 30:
            raise ValueError("时长需在 0~720 小时之间")
        managed_put({"live_id": lid, "url": live["live_url"], "mode": "temp", "state": "active",
                     "hours": hours, "expires_at": now + hours * 3600, "session_live_id": None,
                     "offline_since": None, "note": "", "ended_at": None, "created_at": now})
        oplog(actor, f"设为临时 {hours:g} 小时", lid, live.get("host_name"),
              "到期 " + datetime.fromtimestamp(now + hours * 3600).strftime("%m-%d %H:%M"))
        return
    if mode == "session":
        if urllib.parse.urlparse(live["live_url"]).hostname != "live.douyin.com":
            raise ValueError("只录本场目前只支持抖音房间")
        sid, note, state = None, "等待开播", "waiting"
        try:
            info = sidecar_live_info(live["live_url"])
            if info["living"] and info["liveId"]:
                sid, note, state = info["liveId"], "已锁定本场", "active"
            elif info["living"]:
                note = f"正在直播但拿不到场次 ID（通道 {info['api']}），下一轮再试"
        except UpstreamError as e:
            note = f"查询场次失败，下一轮再试：{e}"[:300]
        n = parse_sessions(sessions)
        managed_put({"live_id": lid, "url": live["live_url"], "mode": "session", "state": state,
                     "hours": None, "expires_at": None, "session_live_id": sid, "offline_since": None,
                     "note": note, "ended_at": None, "created_at": now,
                     "sessions_total": n, "sessions_left": n})
        oplog(actor, "设为只录本场" if n == 1 else f"设为录 {n} 场", lid, live.get("host_name"),
              f"liveId={sid or '待定'}；{note}")
        return
    raise ValueError("未知模式")


def api_add_room(body):
    url = normalize_url(body.get("url"))
    mode = str(body.get("mode") or "permanent").strip()
    if re.fullmatch(r"\d+(\.\d+)?", mode):
        # 快捷指令菜单直接传小时数，例如 "24" = 临时 24 小时
        body["hours"] = float(mode)
        mode = "temp"
    live = find_live_by_url(url)
    existed = live is not None
    if live is None:
        bgo("/lives", "POST", [{"url": url, "listen": True}])
        bgo("/config", "PUT")  # 与 bgo 自带网页一致：增删房间后保存配置
        live = find_live_by_url(url)
        if live is None:
            raise UpstreamError("bgo 已接受添加请求，但房间列表里找不到该链接")
        oplog("user", "添加房间", live["id"], live.get("host_name"), url)
    elif not live["listening"]:
        bgo_start(live["id"])
        oplog("user", "开启监听", live["id"], live.get("host_name"), "添加时房间已存在")
    apply_mode(live, mode, body.get("hours"), sessions=body.get("sessions"))
    host = live.get("host_name") or room_key(url)
    if mode == "temp":
        desc = f"临时 {float(body.get('hours') or 24):g} 小时"
    elif mode == "session":
        n = parse_sessions(body.get("sessions"))
        desc = "只录本场" if n == 1 else f"录 {n} 场"
    else:
        desc = {"permanent": "永久"}.get(mode, mode)
    return {"id": live["id"], "existed": existed, "host_name": host, "mode": mode,
            "message": f"{'已存在，' if existed else ''}{host} · {desc}"}


def api_listen(live_id, on):
    live = next((x for x in bgo_lives() if x["id"] == live_id), None)
    if not live:
        raise ValueError("房间不存在")
    if on:
        bgo_start(live_id)
        m = managed_get(live_id)
        if m and m["state"] in ("done", "cancelled"):
            managed_delete(live_id)
        oplog("user", "开启监听", live_id, live.get("host_name"))
    else:
        bgo_stop(live_id)
        m = managed_get(live_id)
        if m and m["state"] in ("active", "waiting", "expiring"):
            managed_update(live_id, state="cancelled", ended_at=time.time(), note="手动关闭")
        oplog("user", "关闭监听", live_id, live.get("host_name"))


def api_set_mode(live_id, body):
    live = next((x for x in bgo_lives() if x["id"] == live_id), None)
    if not live:
        raise ValueError("房间不存在")
    if "expires_at" in body:
        m = managed_get(live_id)
        if not m or m["mode"] != "temp" or m["state"] not in ("active", "expiring"):
            raise ValueError("只有进行中的临时房间可以改到期时间")
        try:
            ts = float(body["expires_at"])
        except (TypeError, ValueError):
            raise ValueError("到期时间格式不对")
        now = time.time()
        if ts <= now + 60:
            raise ValueError("到期时间必须晚于现在至少 1 分钟；要马上停请直接关监听")
        if ts > now + 365 * 86400:
            raise ValueError("到期时间不能超过一年")
        managed_update(live_id, expires_at=ts, state="active", note="")
        oplog("user", "修改到期", live_id, live.get("host_name"),
              datetime.fromtimestamp(m["expires_at"]).strftime("%m-%d %H:%M") + " → "
              + datetime.fromtimestamp(ts).strftime("%m-%d %H:%M"))
        return
    if "sessions_left" in body:
        m = managed_get(live_id)
        if not m or m["mode"] != "session" or m["state"] not in ("active", "waiting"):
            raise ValueError("只有进行中的录 N 场房间可以改场数")
        left = parse_sessions(body["sessions_left"])
        done = session_total(m) - session_left(m)
        managed_update(live_id, sessions_left=left, sessions_total=done + left,
                       note=f"已改为还剩 {left} 场（含当前场）")
        oplog("user", "修改场数", live_id, live.get("host_name"),
              f"剩余 {session_left(m)} → {left} 场（含当前场；已录完 {done} 场）")
        return
    if body.get("extend"):
        m = managed_get(live_id)
        if not m or m["mode"] != "temp":
            raise ValueError("只有临时房间可以续期")
        add = float(body["extend"])
        base = max(m["expires_at"], time.time())
        managed_update(live_id, expires_at=base + add * 3600, state="active", hours=(m["hours"] or 0) + add,
                       note="")
        oplog("user", f"续期 {add:g} 小时", live_id, live.get("host_name"),
              "新到期 " + datetime.fromtimestamp(base + add * 3600).strftime("%m-%d %H:%M"))
        return
    if not live["listening"]:
        bgo_start(live_id)
        oplog("user", "开启监听", live_id, live.get("host_name"), "设置模式时自动开启")
    apply_mode(live, body.get("mode"), body.get("hours"), sessions=body.get("sessions"))


def api_oplog(limit=200):
    with db() as c:
        return [dict(r) for r in c.execute("SELECT * FROM ops_log ORDER BY id DESC LIMIT ?", (limit,))]


# ---------------------------------------------------------------- dyzb 评分

# dyzb（hdz）按主播汇总的 AI 衣着评分。panel.json 里配 "dyzb": {"url": "http://100.x:8096", "token": "..."}；
# 没配就不显示。按主播名匹配（去掉 emoji/标点后比较），dyzb 没有房间 ID。
SCORE_TTL = 300
_SCORES = {"ts": 0, "data": None, "error": None}
_SCORES_LOCK = threading.Lock()


def score_key(name):
    import unicodedata
    # 与 index.html 的 scoreKey 一致：只留字母（L*）、数字（N*）和下划线
    s = unicodedata.normalize("NFKC", name or "")
    return "".join(c for c in s if c == "_" or unicodedata.category(c)[0] in "LN").lower()


def dyzb_get(path_qs, timeout=20):
    conf = CONF.get("dyzb") or {}
    url = conf["url"].rstrip("/") + path_qs
    h = {"x-dyzb-internal-token": conf["token"], "Accept": "application/json", "User-Agent": AGENT_UA}
    if urllib.parse.urlparse(url).hostname.startswith("100."):
        code, raw = socks5_http(url, "GET", h, None, timeout=timeout)
    else:
        try:
            with _opener.open(urllib.request.Request(url, headers=h), timeout=timeout) as r:
                code, raw = r.status, r.read()
        except urllib.error.HTTPError as e:
            code, raw = e.code, e.read()
    if code != 200:
        raise UpstreamError(f"dyzb {path_qs.split('?')[0]} -> HTTP {code}: {raw[:120]!r}")
    return json.loads(raw)


def refresh_scores():
    items, page = {}, 1
    while True:
        d = dyzb_get(f"/api/ai/dashboard/summary?pageSize=100&page={page}")
        for it in d.get("items") or []:
            k = score_key(it.get("name"))
            if not k or (k in items and items[k]["scored"] >= it.get("scored", 0)):
                continue
            items[k] = {f: it.get(f) for f in ("name", "streamerId", "total", "scored", "pending", "failed", "todo",
                                                  "coverage", "avgScore", "maxScore", "distribution", "lastScoredAt")}
        if page * 100 >= (d.get("total") or 0):
            break
        page += 1
    _SCORES.update(ts=time.time(), data=items, error=None)


def api_scores():
    """有缓存就立刻返回，过期在后台刷新；dyzb 连不上时保留旧数据并带上错误。"""
    if not CONF.get("dyzb"):
        return {"enabled": False}

    def run():
        try:
            refresh_scores()
        except Exception as e:
            _SCORES.update(ts=time.time(), error=str(e))
            log(f"dyzb 评分刷新失败：{e}")
        finally:
            _SCORES_LOCK.release()

    stale = time.time() - _SCORES["ts"] >= SCORE_TTL
    if stale and _SCORES_LOCK.acquire(blocking=False):
        if _SCORES["data"] is None:
            run()
        else:
            threading.Thread(target=run, daemon=True).start()
    return {"enabled": True, "updated": _SCORES["ts"] if _SCORES["data"] is not None else None,
            "error": _SCORES["error"], "items": _SCORES["data"] or {}}



# ---------------------------------------------------------------- 备援录制（hub 侧规则 + agent 侧名单对齐）
#
# 用户 2026-11-02 决定：房间名单以 boh 为准，备援机（boh2）镜像同一份名单但平时不监听；
# 触发 = ① 单房间：boh 上在播、监听中、却持续未录制 ② 全局：boh 近 5 分钟 room-info/取流错误超阈值（500 风暴）；
# 接管 = 备援机开启该房间监听开始录，boh 不停、继续重试；
# 释放 = boh 稳定录制一段时间 / 主播下播 / boh 上该房间被关监听 → 备援机录完当前这场再关监听。

FO_DEFAULTS = {"enabled": False, "standby": "", "room_grace_sec": 300, "recover_sec": 600,
               "storm_window_sec": 300, "storm_min_events": 30, "storm_ratio": 0.3,
               "sync_interval_sec": 600, "remove_extra": False}
_FO_SEEN = {}  # boh 房间 id -> 首次看到"在播未录"的时刻
_FO_STATUS = {"last_run": 0, "standby_ok": None, "standby_error": None, "storm": False, "storm_detail": "",
              "last_sync": 0, "sync_result": None}
_FO_RUN_LOCK = threading.Lock()


def fo_conf():
    c = dict(FO_DEFAULTS)
    c.update(CONF.get("failover") or {})
    return c


def init_failover_db():
    with _db_lock, db() as c:
        c.execute("""CREATE TABLE IF NOT EXISTS failover_rooms (
            live_id TEXT PRIMARY KEY, url TEXT NOT NULL, host_name TEXT DEFAULT '',
            standby TEXT NOT NULL, standby_live_id TEXT,
            state TEXT NOT NULL,             -- active | releasing | done
            reason TEXT DEFAULT '', started_at REAL NOT NULL, recover_since REAL, released_at REAL,
            note TEXT DEFAULT '', updated_at REAL NOT NULL, saw_recording INTEGER DEFAULT 0)""")
        cols = [r[1] for r in c.execute("PRAGMA table_info(failover_rooms)")]
        if "saw_recording" not in cols:
            c.execute("ALTER TABLE failover_rooms ADD COLUMN saw_recording INTEGER DEFAULT 0")


def fo_all(states=None):
    with db() as c:
        rows = [dict(r) for r in c.execute("SELECT * FROM failover_rooms ORDER BY started_at DESC")]
    return [r for r in rows if not states or r["state"] in states]


def fo_get(live_id):
    with db() as c:
        r = c.execute("SELECT * FROM failover_rooms WHERE live_id=?", (live_id,)).fetchone()
    return dict(r) if r else None


def fo_put(row):
    row = dict(row)
    row["updated_at"] = time.time()
    cols, qs = ",".join(row), ",".join("?" * len(row))
    with _db_lock, db() as c:
        c.execute(f"INSERT OR REPLACE INTO failover_rooms({cols}) VALUES({qs})", tuple(row.values()))


def fo_update(live_id, **kw):
    kw["updated_at"] = time.time()
    with _db_lock, db() as c:
        c.execute("UPDATE failover_rooms SET " + ",".join(f"{k}=?" for k in kw) + " WHERE live_id=?",
                  (*kw.values(), live_id))


def fo_agent():
    c = fo_conf()
    return agent_by_name(c["standby"]) if (not AGENT_MODE and c["standby"]) else None


def fo_summary():
    if AGENT_MODE:
        return None
    c = fo_conf()
    if not c["standby"] and not c["enabled"]:
        return None
    rows = fo_all(("active", "releasing"))
    return {"enabled": bool(c["enabled"]), "standby": c["standby"], "standby_ok": _FO_STATUS["standby_ok"],
            "storm": _FO_STATUS["storm"], "active": sum(1 for r in rows if r["state"] == "active"),
            "releasing": sum(1 for r in rows if r["state"] == "releasing"), "last_run": _FO_STATUS["last_run"]}


def fo_storm(local_rooms):
    """近 5 分钟 room-info/取流错误数 ≥ max(下限, 比例 × 监听房数 × 5 轮) 视为 500 风暴。日志统计每 5 分钟刷新一次。"""
    c = fo_conf()
    with CACHE_LOCK:
        ls = CACHE.get("logstats") or {}
    if not ls.get("updated") or time.time() - ls["updated"] > 900:
        return False, "日志统计未就绪"
    last5 = ls.get("last5m") or {}
    n = sum(last5.get(k, 0) for k in ERR_CATS)
    listening = sum(1 for r in local_rooms if r["listening"])
    polls = max(1, listening) * max(1, int(c["storm_window_sec"]) // 60)
    thr = max(int(c["storm_min_events"]), int(float(c["storm_ratio"]) * polls))
    return n >= thr, f"近 5 分钟错误 {n}，阈值 {thr}（监听 {listening}）"


def fo_standby_rooms(agent):
    return agent_json(agent, "/api/rooms", timeout=30)


def fo_standby_match(remote, url):
    k = room_key(url)
    return next((x for x in remote if room_key(x["live_url"]) == k), None)


def fo_mirror_call(agent, body, timeout=120):
    code, raw = agent_call(agent, "POST", "/api/mirror", body, timeout=timeout)
    try:
        d = json.loads(raw) if raw else {}
    except ValueError:
        d = {}
    if code != 200:
        raise AgentError(f"{agent['name']}：{(d or {}).get('error') or 'HTTP ' + str(code)}")
    return d


def fo_takeover_many(agent, lives, reasons, actor="failover"):
    """备援机开启这些房间的监听（名单里没有的先加上）。一次 agent 调用。"""
    urls = [x["live_url"] for x in lives]
    try:
        d = fo_mirror_call(agent, {"urls": urls, "listen": True, "listen_urls": urls})
    except AgentError as e:
        for x in lives:
            oplog(actor, "备援接管失败", x["id"], x.get("host_name"), f"{reasons.get(x['id'], '')}；{e}", ok=False)
        return 0
    ids, now, n = d.get("ids") or {}, time.time(), 0
    for x in lives:
        sid = ids.get(room_key(x["live_url"]))
        reason = reasons.get(x["id"], "")
        if not sid:
            oplog(actor, "备援接管失败", x["id"], x.get("host_name"), f"{reason}；备援机名单里没有该房间", ok=False)
            continue
        fo_put({"live_id": x["id"], "url": x["live_url"], "host_name": x.get("host_name") or "", "standby": agent["name"],
                "standby_live_id": sid, "state": "active", "reason": reason, "started_at": now,
                "recover_since": None, "released_at": None, "note": "备援机已开始监听"})
        _FO_SEEN.pop(x["id"], None)
        oplog(actor, "备援接管", x["id"], x.get("host_name"), f"{agent['name']} 开始监听；{reason}")
        n += 1
    return n


def fo_release(agent, remote, row, why, actor="failover", force=False):
    """释放：备援机在录且不强制 → 标记待释放（录完这场再停）；否则关监听（强制时连录制一起停）。"""
    lid = row["live_id"]
    sb = next((x for x in remote if x["id"] == row["standby_live_id"]), None) or fo_standby_match(remote, row["url"])
    if sb and sb["recording"] and not force:
        if row["state"] != "releasing":
            fo_update(lid, state="releasing", note=f"{why}；备援机录制中，录完这场再停")
            oplog(actor, "备援待释放", lid, row.get("host_name"), f"{why}；{agent['name']} 录完当前场次再停")
        return False
    try:
        if sb is None or sb["listening"]:
            fo_mirror_call(agent, {"urls": [row["url"]], "listen": False, "listen_urls": [row["url"]],
                                   "stop_record": bool(force)})
        got = "；备援期间录到过素材" if row.get("saw_recording") else "；备援期间没有产生任何录像（备援机多半也取不到流）"
        fo_update(lid, state="done", released_at=time.time(), note=f"{why}；备援机已停止监听{got}")
        oplog(actor, "备援释放", lid, row.get("host_name"), f"{why}；{agent['name']} 已关闭监听" + ("（立即）" if force else "") + got)
        return True
    except AgentError as e:
        fo_update(lid, note=f"释放失败：{e}"[:300])
        oplog(actor, "备援释放失败", lid, row.get("host_name"), f"{why}；{e}", ok=False)
        return False


def run_failover_once():
    c = fo_conf()
    agent = fo_agent()
    _FO_STATUS["last_run"] = time.time()
    if not agent:
        _FO_STATUS.update(standby_ok=None, standby_error=None, storm=False, storm_detail="")
        return
    if not _FO_RUN_LOCK.acquire(blocking=False):
        return
    try:
        local = merged_rooms()
        try:
            remote = fo_standby_rooms(agent)
            _FO_STATUS.update(standby_ok=True, standby_error=None)
        except AgentError as e:
            _FO_STATUS.update(standby_ok=False, standby_error=str(e))
            log("failover: 备援机失联：", e)
            return
        now = time.time()
        storm, detail = fo_storm(local) if c["enabled"] else (False, "自动接管已关闭")
        _FO_STATUS.update(storm=storm, storm_detail=detail)
        by_id = {x["id"]: x for x in local}
        active = fo_all(("active", "releasing"))
        held = {r["live_id"] for r in active}
        # 1) 已接管的房间：看 boh 是否恢复、主播是否下播、用户是否在 boh 上关了监听
        for row in active:
            lid, live = row["live_id"], by_id.get(row["live_id"])
            if not row.get("saw_recording"):
                # 备援机在录 = 这次接管真的产生了素材；否则释放时如实说明（否则界面像"成功"）
                sb = next((x for x in remote if x["id"] == row["standby_live_id"]), None) or fo_standby_match(remote, row["url"])
                if sb and sb.get("recording"):
                    fo_update(lid, saw_recording=1)
                    row["saw_recording"] = 1
            if live is None:
                fo_release(agent, remote, row, "boh 已删除该房间", force=True)
            elif not live["listening"]:
                fo_release(agent, remote, row, "boh 上该房间监听已被关闭", force=True)
            elif live["recording"]:
                if not row["recover_since"]:
                    fo_update(lid, recover_since=now, note="boh 已恢复录制，观察中")
                elif now - row["recover_since"] >= int(c["recover_sec"]):
                    fo_release(agent, remote, row, f"boh 已稳定录制 {int(c['recover_sec']) // 60} 分钟")
            elif not live["status"]:
                if not (storm and str(row["reason"]).startswith("500 风暴")):  # 风暴期间 boh 看不到谁在播，保持接管
                    fo_release(agent, remote, row, "主播已下播")
            elif row["recover_since"] or row["state"] == "releasing":
                fo_update(lid, recover_since=None, state="active", note="boh 仍录不上，继续备援")
        if not c["enabled"]:
            return
        # 2) 新候选：风暴 → boh 全部监听房；否则在播、监听中、持续未录制 ≥ grace 的房间
        cands, reasons = [], {}
        for live in local:
            lid = live["id"]
            if lid in held or not live["listening"]:
                _FO_SEEN.pop(lid, None)
                continue
            if storm:
                cands.append(live)
                reasons[lid] = "500 风暴：" + detail
                continue
            if not (live["status"] and not live["recording"] and not live.get("initializing")):
                _FO_SEEN.pop(lid, None)
                continue
            first = _FO_SEEN.setdefault(lid, now)
            if now - first >= int(c["room_grace_sec"]):
                cands.append(live)
                reasons[lid] = f"在播但 {int((now - first) // 60)} 分钟未录制"
        if cands:
            fo_takeover_many(agent, cands, reasons)
    finally:
        _FO_RUN_LOCK.release()


def run_mirror_sync():
    """名单共用：把 boh 全部房间同步到备援机（缺的加上、不监听；多余的按设置删除）。"""
    agent = fo_agent()
    if not agent:
        return None
    c = fo_conf()
    urls = [x["live_url"] for x in bgo_lives()]
    d = fo_mirror_call(agent, {"urls": urls, "remove_extra": bool(c["remove_extra"])}, timeout=180)
    _FO_STATUS.update(last_sync=time.time(), sync_result=d)
    if d.get("added") or d.get("removed"):
        oplog("failover", "同步名单", None, None,
              f"{agent['name']}：新增 {d.get('added')}，删除 {d.get('removed')}，多余 {d.get('extra')}，共 {d.get('total')}")
    return d


def failover_loop():
    time.sleep(20)
    last_sync = 0
    while True:
        try:
            if fo_agent():
                run_failover_once()
                if time.time() - last_sync >= int(fo_conf()["sync_interval_sec"]):
                    last_sync = time.time()
                    try:
                        run_mirror_sync()
                    except AgentError as e:
                        log("failover: 同步名单失败：", e)
        except Exception:
            log("failover loop error\n" + traceback.format_exc())
        time.sleep(RULE_INTERVAL)


def api_mirror(body):
    """agent（备援机）：按 boh 名单对齐本机房间。urls 里缺的加上（不监听）；remove_extra 删多余；listen 对 listen_urls 开/关监听。"""
    urls = [str(u).strip() for u in (body.get("urls") or []) if u]
    lives = bgo_lives()
    have = {room_key(x["live_url"]): x for x in lives}
    want = {room_key(u): u for u in urls}
    missing = [u for k, u in want.items() if k and k not in have]
    added = removed = 0
    if missing:
        bgo("/lives", "POST", [{"url": u, "listen": False} for u in missing], timeout=120)
        added = len(missing)
    extra = [x for k, x in have.items() if k not in want]
    if body.get("remove_extra"):
        for x in extra:
            if x["recording"] or x["listening"]:
                continue  # 正在用的不动
            bgo(f"/lives/{x['id']}", "DELETE")
            removed += 1
    if added or removed:
        bgo("/config", "PUT")
        lives = bgo_lives()
        have = {room_key(x["live_url"]): x for x in lives}
    changed = []
    if body.get("listen") is not None:
        on = bool(body["listen"])
        for u in (body.get("listen_urls") or urls):
            x = have.get(room_key(u))
            if not x or bool(x["listening"]) == on:
                continue
            if on:
                bgo_start(x["id"])
            else:
                if x["recording"] and body.get("stop_record"):
                    bgo(f"/lives/{x['id']}/stopRecord", "POST")
                bgo_stop(x["id"])
            changed.append(x["id"])
        if changed:
            oplog("failover", "开启监听" if on else "关闭监听", None, None, f"hub 备援指令，{len(changed)} 个房间")
    return {"added": added, "removed": removed, "extra": len(extra) - removed, "total": len(have),
            "changed": len(changed), "ids": {k: x["id"] for k, x in have.items() if k in want}}


def api_failover():
    return {"conf": fo_conf(), "status": dict(_FO_STATUS), "rows": fo_all()[:300],
            "agents": [a["name"] for a in agents()]}


def api_failover_config(body):
    c = fo_conf()
    if "standby" in body:
        sb = str(body["standby"] or "")
        if sb and not agent_by_name(sb):
            raise ValueError(f"未知服务器：{sb}")
        c["standby"] = sb
    for k, lo, hi in (("room_grace_sec", 60, 3600), ("recover_sec", 60, 7200),
                      ("storm_min_events", 5, 5000), ("sync_interval_sec", 60, 86400)):
        if k in body:
            try:
                v = int(float(body[k]))
            except (TypeError, ValueError):
                raise ValueError(f"{k} 必须是数字")
            if not lo <= v <= hi:
                raise ValueError(f"{k} 需在 {lo}~{hi} 之间")
            c[k] = v
    if "storm_ratio" in body:
        try:
            v = float(body["storm_ratio"])
        except (TypeError, ValueError):
            raise ValueError("storm_ratio 必须是数字")
        if not 0.05 <= v <= 1:
            raise ValueError("storm_ratio 需在 0.05~1 之间")
        c["storm_ratio"] = v
    for k in ("enabled", "remove_extra"):
        if k in body:
            c[k] = bool(body[k])
    if c["enabled"] and not c["standby"]:
        raise ValueError("开启自动接管前先选择备援机")
    with CONF_LOCK:
        CONF["failover"] = c
        save_conf(CONF)
    oplog("user", "修改备援设置", None, None, json.dumps(c, ensure_ascii=False))
    return c


def api_failover_takeover(body):
    agent = fo_agent()
    if not agent:
        raise ValueError("未配置备援机")
    lid = str(body.get("live_id") or "")
    live = next((x for x in merged_rooms() if x["id"] == lid), None)
    if not live:
        raise ValueError("房间不存在")
    if fo_get(lid) and fo_get(lid)["state"] in ("active", "releasing"):
        raise ValueError("该房间已在备援中")
    n = fo_takeover_many(agent, [live], {lid: "手动接管"}, actor="user")
    if not n:
        raise UpstreamError("备援机接管失败，详见操作日志")
    return {"ok": True, "message": f"{agent['name']} 已开始监听 {live.get('host_name') or room_key(live['live_url'])}"}


def api_failover_release(body):
    agent = fo_agent()
    row = fo_get(str(body.get("live_id") or ""))
    if not agent or not row or row["state"] not in ("active", "releasing"):
        raise ValueError("没有这条备援记录")
    remote = fo_standby_rooms(agent)
    done = fo_release(agent, remote, row, "手动释放", actor="user", force=bool(body.get("force")))
    return {"ok": True, "message": "备援机已关闭监听" if done else "备援机正在录制，录完这场再停"}


# ---------------------------------------------------------------- HTTP

STATIC = {
    "/manifest.webmanifest": ("manifest.webmanifest", "application/manifest+json"),
    "/icon-180.png": ("icon-180.png", "image/png"),
    "/icon-512.png": ("icon-512.png", "image/png"),
}

LOGIN_FAILS = {}
LOGIN_LOCK = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    server_version = "bgo-panel"

    def log_message(self, fmt, *args):
        pass

    def client_ip(self):
        return self.headers.get("CF-Connecting-IP") or self.headers.get("X-Forwarded-For", "").split(",")[0] \
            or self.client_address[0]

    def send_json(self, obj, code=200, extra_headers=None):
        if isinstance(obj, dict) and "error" in obj and "message" not in obj:
            # 快捷指令只读 message，失败时也要能在通知里看到原因
            obj = {**obj, "message": "❌ " + str(obj["error"])}
        raw = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra_headers or []):
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def session_token(self):
        c = http_cookies.SimpleCookie(self.headers.get("Cookie", ""))
        return c[COOKIE_NAME].value if COOKIE_NAME in c else None

    def bearer_ok(self):
        h = self.headers.get("Authorization", "")
        if not h.startswith("Bearer "):
            return False
        return hmac.compare_digest(h[7:].strip().encode(), api_token().encode())

    def authed(self):
        if self.bearer_ok():
            return True
        return self.cookie_authed()

    def cookie_authed(self):
        tok = self.session_token()
        if not tok:
            return False
        with db() as c:
            r = c.execute("SELECT expires_at FROM sessions WHERE token=?",
                          (hashlib.sha256(tok.encode()).hexdigest(),)).fetchone()
        return bool(r and r["expires_at"] > time.time())

    def read_body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > 64 * 1024:
            raise ValueError("请求体过大")
        raw = self.rfile.read(n) if n else b""
        return json.loads(raw) if raw else {}

    def cookie_header(self, value, max_age):
        secure = "; Secure" if (self.headers.get("X-Forwarded-Proto") == "https"
                                or self.headers.get("CF-Visitor", "").find("https") >= 0) else ""
        return ("Set-Cookie", f"{COOKIE_NAME}={value}; Path=/; HttpOnly; SameSite=Strict; Max-Age={max_age}{secure}")

    def proxy_to_agent(self, method, body=None):
        """hub：请求带 ?host=xxx 且 xxx 是登记的 agent 时，原样转发过去。返回 True 表示已处理。"""
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        host = (q.pop("host", [None])[0] if "host" in q else None) or (body or {}).get("host")
        if AGENT_MODE or not host or host == LOCAL_NAME:
            return False
        agent = agent_by_name(host)
        if not agent:
            self.send_json({"error": f"未知服务器：{host}"}, 400)
            return True
        qs = urllib.parse.urlencode(q, doseq=True)
        if body is not None:
            body = {k: v for k, v in body.items() if k != "host"}
        try:
            code, raw = agent_call(agent, method, u.path + ("?" + qs if qs else ""), body)
        except AgentError as e:
            self.send_json({"error": str(e)}, 502)
            return True
        if method == "POST" and code == 200:
            _HOSTS_CACHE["ts"] = 0
            try:
                d = json.loads(raw)
                if isinstance(d, dict) and d.get("message"):
                    d["message"] = f"[{host}] {d['message']}"
                    raw = json.dumps(d, ensure_ascii=False).encode()
            except ValueError:
                pass
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
        return True

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if AGENT_MODE and not path.startswith("/api/"):
            return self.send_json({"error": "这是面板 agent，请从总面板访问"}, 404)
        if path in ("/", "/index.html"):
            with open(INDEX_PATH, "rb") as f:
                raw = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            # 主屏幕 Web App / Safari 会长时间复用旧页面，强制每次取新版
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
            self.send_header("Pragma", "no-cache")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return
        if path in STATIC:
            name, ctype = STATIC[path]
            try:
                with open(os.path.join(BASE, name), "rb") as f:
                    raw = f.read()
            except OSError:
                return self.send_json({"error": "not found"}, 404)
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Cache-Control", "public, max-age=86400")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return
        if path == "/api/me":
            return self.send_json({"authed": self.authed()})
        if not path.startswith("/api/"):
            return self.send_json({"error": "not found"}, 404)
        if not self.authed():
            return self.send_json({"error": "未登录"}, 401)
        if self.proxy_to_agent("GET"):
            return
        try:
            if path == "/api/hosts":
                if AGENT_MODE:
                    return self.send_json({"error": "not found"}, 404)
                return self.send_json(api_hosts())
            if path == "/api/overview":
                return self.send_json(api_overview())
            if path == "/api/scores":
                if AGENT_MODE:
                    return self.send_json({"error": "not found"}, 404)
                return self.send_json(api_scores())
            if path == "/api/rooms":
                q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                if not AGENT_MODE and q.get("host", [""])[0] == "all":
                    return self.send_json(all_rooms())
                return self.send_json(merged_rooms())
            m = re.fullmatch(r"/api/rooms/([0-9a-f]{32})/sessions", path)
            if m:
                d = bgo(f"/lives/{m.group(1)}/sessions") or {}
                for s in d.get("sessions") or []:
                    fix_session(s)
                return self.send_json(d)
            if path == "/api/sessions":
                with CACHE_LOCK:
                    return self.send_json(CACHE.get("sessions") or {"items": []})
            if path == "/api/health":
                with CACHE_LOCK:
                    ls = CACHE.get("logstats") or {}
                return self.send_json({"logstats": ls, "cookie": cookie_status(), "exits": exit_health(),
                                       "procs": proc_status()})
            if path == "/api/storage":
                with CACHE_LOCK:
                    return self.send_json(CACHE.get("storage") or {})
            if path == "/api/oplog":
                return self.send_json(api_oplog())
            if path == "/api/failover":
                if AGENT_MODE:
                    return self.send_json({"error": "not found"}, 404)
                return self.send_json(api_failover())
            if path == "/api/token":
                if AGENT_MODE or not self.cookie_authed():
                    return self.send_json({"error": "需要登录后查看"}, 403)
                return self.send_json({"token": api_token()})
            return self.send_json({"error": "not found"}, 404)
        except UpstreamError as e:
            return self.send_json({"error": f"bgo 请求失败：{e}"}, 502)

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        origin = self.headers.get("Origin")
        if origin and urllib.parse.urlparse(origin).netloc != self.headers.get("Host"):
            return self.send_json({"error": "来源不匹配"}, 403)
        try:
            body = self.read_body()
        except ValueError as e:
            return self.send_json({"error": str(e)}, 400)
        if AGENT_MODE and path in ("/api/login", "/api/logout", "/api/password", "/api/token/rotate"):
            return self.send_json({"error": "agent 不支持该操作"}, 404)
        if path == "/api/login":
            return self.login(body)
        if path == "/api/logout":
            tok = self.session_token()
            if tok:
                with _db_lock, db() as c:
                    c.execute("DELETE FROM sessions WHERE token=?", (hashlib.sha256(tok.encode()).hexdigest(),))
            return self.send_json({"ok": True}, extra_headers=[self.cookie_header("", 0)])
        if not self.authed():
            return self.send_json({"error": "未登录"}, 401)
        if not isinstance(body, dict):
            return self.send_json({"error": "请求体必须是 JSON 对象"}, 400)
        if path.startswith("/api/rooms") or path == "/api/rules/run":
            if self.proxy_to_agent("POST", body):
                return
        try:
            if path == "/api/rooms":
                return self.send_json(api_add_room(body))
            m = re.fullmatch(r"/api/rooms/([0-9a-f]{32})/(listen|mode)", path)
            if m and m.group(2) == "listen":
                api_listen(m.group(1), bool(body.get("on")))
                return self.send_json({"ok": True})
            if m and m.group(2) == "mode":
                api_set_mode(m.group(1), body)
                return self.send_json({"ok": True})
            if path in ("/api/password", "/api/token/rotate") and not self.cookie_authed():
                return self.send_json({"error": "需要登录后操作"}, 403)
            if path == "/api/password":
                return self.change_password(body)
            if path == "/api/token/rotate":
                tok = rotate_api_token()
                oplog("user", "重新生成 API 密钥", None, None, "旧密钥已失效")
                return self.send_json({"token": tok})
            if path == "/api/rules/run":
                run_rules_once()
                return self.send_json({"ok": True})
            if path == "/api/mirror":
                return self.send_json(api_mirror(body))
            if path.startswith("/api/failover/") and AGENT_MODE:
                return self.send_json({"error": "not found"}, 404)
            if path == "/api/failover/config":
                return self.send_json(api_failover_config(body))
            if path == "/api/failover/takeover":
                return self.send_json(api_failover_takeover(body))
            if path == "/api/failover/release":
                return self.send_json(api_failover_release(body))
            if path == "/api/failover/sync":
                d = run_mirror_sync()
                if d is None:
                    raise ValueError("未配置备援机")
                return self.send_json({"ok": True, "message": f"已同步：新增 {d.get('added')}，删除 {d.get('removed')}，多余 {d.get('extra')}，共 {d.get('total')}", **d})
            if path == "/api/failover/run":
                run_failover_once()
                return self.send_json({"ok": True, "message": "检查完成"})
            return self.send_json({"error": "not found"}, 404)
        except ValueError as e:
            return self.send_json({"error": str(e)}, 400)
        except AgentError as e:
            return self.send_json({"error": f"备援机请求失败：{e}"}, 502)
        except UpstreamError as e:
            oplog("user", "操作失败", None, None, f"{path}: {e}", ok=False)
            return self.send_json({"error": f"bgo 请求失败：{e}"}, 502)

    def login(self, body):
        ip = self.client_ip()
        now = time.time()
        with LOGIN_LOCK:
            fails = [t for t in LOGIN_FAILS.get(ip, []) if now - t < 60]
            LOGIN_FAILS[ip] = fails
            if len(fails) >= 5:
                return self.send_json({"error": "尝试次数过多，请 1 分钟后再试"}, 429)
        if not check_password(str(body.get("password", ""))):
            with LOGIN_LOCK:
                LOGIN_FAILS.setdefault(ip, []).append(now)
            return self.send_json({"error": "密码错误"}, 401)
        tok = secrets.token_urlsafe(32)
        with _db_lock, db() as c:
            c.execute("DELETE FROM sessions WHERE expires_at < ?", (now,))
            c.execute("INSERT INTO sessions(token,created_at,expires_at,ip) VALUES(?,?,?,?)",
                      (hashlib.sha256(tok.encode()).hexdigest(), now, now + SESSION_TTL, ip))
        oplog("user", "登录", None, None, f"ip={ip}")
        return self.send_json({"ok": True}, extra_headers=[self.cookie_header(tok, SESSION_TTL)])

    def change_password(self, body):
        old, new = str(body.get("old", "")), str(body.get("new", ""))
        if not check_password(old):
            return self.send_json({"error": "原密码错误"}, 400)
        if len(new) < 6:
            return self.send_json({"error": "新密码至少 6 位"}, 400)
        with CONF_LOCK:
            salt, h = hash_password(new)
            CONF.update({"pw_salt": salt, "pw_hash": h, "pw_is_default": False})
            save_conf(CONF)
        keep = hashlib.sha256((self.session_token() or "").encode()).hexdigest()
        with _db_lock, db() as c:
            c.execute("DELETE FROM sessions WHERE token != ?", (keep,))
        oplog("user", "修改密码", None, None, "其他已登录会话已失效")
        return self.send_json({"ok": True})


def main():
    init_db()
    migrate_db()
    init_failover_db()
    if AGENT_MODE:
        api_token()  # agent 首次启动生成密钥，供 hub 登记
    threading.Thread(target=rules_loop, daemon=True, name="rules").start()
    threading.Thread(target=bg_refresh_loop, daemon=True, name="refresh").start()
    if not AGENT_MODE:
        threading.Thread(target=failover_loop, daemon=True, name="failover").start()
    srv = ThreadingHTTPServer((BIND, PORT), Handler)
    srv.daemon_threads = True
    # 额外监听地址（hwsg：Tailscale 内网 IP，供 boh hub 走内网直连），逗号分隔
    for extra in filter(None, os.environ.get("PANEL_EXTRA_BIND", "").split(",")):
        try:
            x = ThreadingHTTPServer((extra.strip(), PORT), Handler)
        except OSError as e:
            log(f"额外监听 {extra}:{PORT} 失败：{e}")
            continue
        x.daemon_threads = True
        threading.Thread(target=x.serve_forever, daemon=True, name=f"http-{extra}").start()
        log(f"also listening on {extra}:{PORT}")
    log(f"bgo-panel {'agent ' if AGENT_MODE else ''}{LOCAL_NAME} listening on {BIND}:{PORT}")
    srv.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
