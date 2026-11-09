"""GPU workers: the laptop card plus Kaggle cards, all serving one queue.

Every worker runs the same FASHN server (gpu_server/fashn_server.py) with the /jobs API.
  laptop  FITME_REMOTE_AI_URL (http://127.0.0.1:7860), always tried first
  kaggle  the Kaggle notebook (KAGGLE/FitMe_Kaggle_GPU.ipynb) starts one server per GPU,
          opens a tunnel and posts the addresses to the private ntfy topic in data/kaggle.json;
          calls carry the secret x-gpu-key from the same file.

A try-on takes the first free online worker (laptop preferred); when none is free it waits.
"""
from __future__ import annotations

import json
import os
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import httpx

HEALTH_EVERY_S = 30
FORGET_AFTER_S = 15 * 60  # a Kaggle worker that stays unreachable this long is dropped


@dataclass
class Worker:
    name: str
    url: str
    kind: str  # laptop | kaggle
    key: str = ""
    online: bool = False
    busy: bool = False
    gpu: str = ""
    error: str | None = None
    last_ok: float = 0.0
    last_check: float = 0.0
    jobs_done: int = 0
    gpu_seconds: float = 0.0
    details: dict[str, Any] = field(default_factory=dict)
    added: float = field(default_factory=time.time)

    @property
    def headers(self) -> dict[str, str]:
        return {"x-gpu-key": self.key} if self.key else {}

    def public(self) -> dict[str, Any]:
        return {"name": self.name, "kind": self.kind, "online": self.online, "busy": self.busy, "gpu": self.gpu,
                "error": self.error, "jobs_done": self.jobs_done,
                "avg_seconds": round(self.gpu_seconds / self.jobs_done, 1) if self.jobs_done else None}


class Pool:
    def __init__(self) -> None:
        self.cond = threading.Condition()
        self.workers: dict[str, Worker] = {}
        self.data_dir: Path | None = None
        self.started = False

    # ---------------------------------------------------------------- setup
    def configure(self, data_dir: Path, laptop_url: str) -> None:
        self.data_dir = data_dir
        with self.cond:
            self.workers = {k: w for k, w in self.workers.items() if w.kind != "laptop"}
            if laptop_url:
                self.workers["laptop"] = Worker("laptop", laptop_url.rstrip("/"), "laptop")

    def kaggle_settings(self) -> dict[str, str]:
        topic = os.getenv("FITME_KAGGLE_TOPIC", "").strip()
        if topic:  # cloud hosting: secrets come as environment variables, not files
            return {"topic": topic, "key": os.getenv("FITME_KAGGLE_KEY", "").strip()}
        path = (self.data_dir or Path(".")) / "kaggle.json"
        if path.exists():
            try:
                return json.loads(path.read_text(encoding="utf-8"))
            except ValueError:
                pass
        return {}

    def add_worker(self, name: str, url: str, kind: str, key: str = "") -> Worker:
        with self.cond:
            w = self.workers.get(name)
            if w is None or w.url != url.rstrip("/"):
                w = Worker(name, url.rstrip("/"), kind, key)
                self.workers[name] = w
            w.key = key
            self.cond.notify_all()
            return w

    # ---------------------------------------------------------------- health
    def check(self, w: Worker, timeout: float = 8.0) -> bool:
        try:
            r = httpx.get(f"{w.url}/health", headers=w.headers, timeout=timeout, follow_redirects=True)
            ok = r.status_code == 200
            data = r.json() if ok else {}
            w.details = data
            w.gpu = str(data.get("gpu") or w.gpu)
            w.error = None if ok else f"HTTP {r.status_code}"
        except Exception as exc:
            ok = False
            w.error = f"{type(exc).__name__}: {str(exc)[:160]}"
        with self.cond:
            w.online, w.last_check = ok, time.time()
            if ok:
                w.last_ok = time.time()
            self.cond.notify_all()
        return ok

    def check_all(self) -> None:
        for w in list(self.workers.values()):
            self.check(w)
        with self.cond:  # forget Kaggle sessions that ended long ago
            for name, w in list(self.workers.items()):
                if w.kind == "kaggle" and not w.online and not w.busy and time.time() - (w.last_ok or w.added) > FORGET_AFTER_S:
                    self.workers.pop(name, None)

    def discover_kaggle(self) -> None:
        """Reads the newest message the Kaggle notebook posted to the private ntfy topic:
        {"urls": [...], "until": <unix time>} - repeated every 5 minutes while it runs,
        {"urls": []} when it stops. Kaggle cards that are no longer announced leave the pool."""
        cfg = self.kaggle_settings()
        topic, key = cfg.get("topic", ""), cfg.get("key", "")
        if not topic:
            return
        try:
            r = httpx.get(f"https://ntfy.sh/{topic}/json?poll=1&since=30m", timeout=10)
            r.raise_for_status()
        except Exception as exc:
            print(f"[FitMe] Kaggle discovery failed: {type(exc).__name__}: {exc}")
            return
        latest: dict[str, Any] = {}
        for line in r.text.splitlines():
            try:
                event = json.loads(line)
                if event.get("event") == "message":
                    latest = json.loads(event.get("message") or "{}")
            except ValueError:
                continue
        fresh = float(latest.get("until") or 0) > time.time()
        urls = [str(u).rstrip("/") for u in latest.get("urls", [])] if fresh else []
        for i, url in enumerate(urls):
            self.add_worker(f"kaggle-{i + 1}", url, "kaggle", key)
        with self.cond:
            for name, w in list(self.workers.items()):
                if w.kind == "kaggle" and w.url not in urls and not w.busy:
                    self.workers.pop(name, None)

    def _loop(self) -> None:
        tick = 0
        while True:
            try:
                if tick % 2 == 0:
                    self.discover_kaggle()
                self.check_all()
            except Exception as exc:
                print(f"[FitMe] worker check failed: {exc}")
            tick += 1
            time.sleep(HEALTH_EVERY_S)

    def start(self) -> None:
        if not self.started:
            self.started = True
            threading.Thread(target=self._loop, daemon=True, name="fitme-workers").start()

    # ---------------------------------------------------------------- scheduling
    def online(self) -> list[Worker]:
        return [w for w in self.workers.values() if w.online]

    def any_online(self, recheck: bool = True) -> bool:
        if self.online():
            return True
        if recheck:
            for w in list(self.workers.values()):
                self.check(w, timeout=6.0)
        return bool(self.online())

    def acquire(self, timeout: float = 30 * 60) -> Worker:
        """Blocks until a worker is free; the laptop is preferred (fastest, no tunnel)."""
        deadline = time.time() + timeout
        with self.cond:
            while True:
                free = [w for w in self.workers.values() if w.online and not w.busy]
                if free:
                    w = sorted(free, key=lambda x: (x.kind != "laptop", x.name))[0]
                    w.busy = True
                    return w
                left = deadline - time.time()
                if left <= 0:
                    raise RuntimeError("Нет свободной видеокарты — попробуйте позже")
                self.cond.wait(timeout=min(left, 5))

    def release(self, w: Worker, seconds: float | None = None, failed: bool = False) -> None:
        with self.cond:
            w.busy = False
            if seconds:
                w.jobs_done += 1
                w.gpu_seconds += seconds
            if failed:
                w.online = False
            self.cond.notify_all()

    def count(self) -> int:
        return max(1, len(self.online()))

    def snapshot(self) -> list[dict[str, Any]]:
        return [w.public() for w in sorted(self.workers.values(), key=lambda x: (x.kind != "laptop", x.name))]


POOL = Pool()
