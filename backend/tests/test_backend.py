"""Backend tests with a fake GPU server.  Run:  python -m pytest backend/tests -q"""
import importlib
import io
import json
import sys
import time
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND))

OWNER = "owner@fitme.test"


def png(color, size=(300, 400)):
    buf = io.BytesIO()
    Image.new("RGB", size, color).save(buf, "PNG")
    return buf.getvalue()


def jpeg(color, size=(300, 400)):
    buf = io.BytesIO()
    Image.new("RGB", size, color).save(buf, "JPEG")
    return buf.getvalue()


def seg_png(size=(300, 400)):
    """Label map: a 'top' (3) in the middle, 'pants' (5) below it."""
    w, h = size
    seg = np.zeros((h, w), np.uint8)
    seg[h // 5: h // 2, w // 4: 3 * w // 4] = 3
    seg[h // 2: 9 * h // 10, w // 3: 2 * w // 3] = 5
    buf = io.BytesIO()
    Image.fromarray(seg).save(buf, "PNG")
    return buf.getvalue()


class FakeResp:
    def __init__(self, code=200, js=None, content=b"", ct="application/json"):
        self.status_code, self._js, self.content = code, js, content
        self.headers = {"content-type": ct}
        self.text = json.dumps(js)

    def json(self):
        return self._js


@pytest.fixture()
def mod(tmp_path, monkeypatch):
    monkeypatch.setenv("FITME_STORAGE_DIR", str(tmp_path))
    monkeypatch.setenv("FITME_REMOTE_AI_URL", "http://gpu.local")
    monkeypatch.setenv("FITME_AI_PROVIDER", "kaggle")
    monkeypatch.setenv("FITME_API_KEY", "secret123")
    monkeypatch.setenv("FITME_OWNER_EMAIL", OWNER)
    monkeypatch.setenv("FITME_SAMPLER", "0")
    monkeypatch.setenv("FITME_STORE", "memory")  # Firebase stand-in, see app/store.py
    from app.workers import POOL

    POOL.workers.clear()  # no Kaggle cards left over from another test
    import app.main as m

    m = importlib.reload(m)
    m.auth.forget()
    m.admin.profiles_changed()
    calls = []

    def fake_post(url, **kw):
        calls.append(("POST", url, kw.get("data")))
        if url.endswith("/segment"):
            return FakeResp(content=seg_png(), ct="image/png")
        return FakeResp(js={"job_id": f"r{len(calls)}"})

    def fake_get(url, **kw):
        if url.endswith("/health"):
            return FakeResp(js={"status": "ready"})
        if url.endswith("/result"):
            return FakeResp(content=png("red"), ct="image/png")
        if url.endswith("/segmentation"):
            return FakeResp(content=seg_png(), ct="image/png")
        return FakeResp(js={"status": "completed", "seconds": 12.5})

    monkeypatch.setattr(m.httpx, "post", fake_post)
    monkeypatch.setattr(m.httpx, "get", fake_get)
    m.test_calls = calls
    return m


def new_client(m, token=None):
    from fastapi.testclient import TestClient

    c = TestClient(m.app)
    c.headers.update({"X-FitMe-Key": "secret123"})
    if token:
        c.headers.update({"Authorization": f"Bearer {token}"})
    c.calls = m.test_calls
    return c


def uid_for(email):
    return "u" + "".join(ch for ch in email if ch.isalnum()).ljust(27, "x")[:27]


def signup(m, email, name="Тест"):
    """What the app does: Firebase sign-in gives a token, then /auth/session makes the profile."""
    token = f"test:{uid_for(email)}:{email}"
    r = new_client(m, token).post("/api/v1/auth/session")
    assert r.status_code == 200, r.text
    if name:
        assert new_client(m, token).patch("/api/v1/auth/me", json={"name": name}).status_code == 200
    return token, r.json()["user"]


@pytest.fixture()
def client(mod):
    token, user = signup(mod, OWNER, name="Создатель")
    assert user["role"] == "owner"
    return new_client(mod, token)


def wait_job(c, job_id):
    for _ in range(200):
        j = c.get(f"/api/v1/try-on/{job_id}").json()
        if j["status"] in ("completed", "failed"):
            return j
        time.sleep(0.05)
    raise AssertionError("job did not finish")


def try_on(c, color="navy"):
    r = c.post(
        "/api/v1/try-on/upload",
        data={"category": "upper_body"},
        files={"person_photo": ("p.jpg", png("gray"), "image/png"), "garment_photo": ("g.png", png(color), "image/png")},
    )
    assert r.status_code == 200, r.text
    return wait_job(c, r.json()["job_id"])


# ------------------------------------------------------------------ web version
@pytest.fixture()
def web_dir(tmp_path, monkeypatch):
    site = tmp_path / "site"
    site.mkdir()
    (site / "index.html").write_text("<title>FitMe web</title>", encoding="utf-8")
    (site / "main.dart.js").write_text("// app", encoding="utf-8")
    monkeypatch.setenv("FITME_WEB_APP_DIR", str(site))
    return site


def test_site_is_public_and_root_opens_it_for_browsers(web_dir, mod):
    from fastapi.testclient import TestClient

    c = TestClient(mod.app, follow_redirects=False)  # no access key, no account
    page = c.get("/app/")
    assert page.status_code == 200 and "FitMe web" in page.text
    assert page.headers["cache-control"] == "no-cache"
    assert c.get("/app/main.dart.js").headers["content-type"].startswith("text/javascript")

    opened = c.get("/?key=abc", headers={"accept": "text/html"})
    assert opened.status_code == 307 and opened.headers["location"] == "/app/?key=abc"
    assert c.get("/", headers={"accept": "application/json"}).json()["app"] == "FitMe AI"


def test_browser_can_read_rejections(mod):
    from fastapi.testclient import TestClient

    c = TestClient(mod.app)
    origin = {"Origin": "https://fitme.example.test"}
    refused = c.get("/api/v1/looks", headers=origin)
    assert refused.status_code == 401
    assert refused.headers["access-control-allow-origin"] == "*"

    preflight = c.options(
        "/api/v1/looks",
        headers=origin | {
            "Access-Control-Request-Method": "GET",
            "Access-Control-Request-Headers": "authorization,x-fitme-key",
        },
    )
    assert preflight.status_code == 200


# ------------------------------------------------------------------ cloud hosting
def test_firebase_key_can_come_from_environment(tmp_path, monkeypatch):
    from app import store

    monkeypatch.setenv("FITME_FIREBASE_CREDENTIALS_JSON", '{"project_id": "p1"}')
    assert json.loads(store.credentials_path(tmp_path).read_text(encoding="utf-8"))["project_id"] == "p1"


def test_kaggle_settings_can_come_from_environment(monkeypatch):
    from app.workers import Pool

    monkeypatch.setenv("FITME_KAGGLE_TOPIC", "t1")
    monkeypatch.setenv("FITME_KAGGLE_KEY", "k1")
    assert Pool().kaggle_settings() == {"topic": "t1", "key": "k1"}


# ------------------------------------------------------------------ access
def test_health_is_open_but_api_needs_key_and_account(mod, client):
    anon = new_client(mod)
    anon.headers.pop("X-FitMe-Key")
    health = anon.get("/health").json()
    assert health["api_key_required"] is True and health["accounts"] is True
    assert anon.get("/api/v1/catalog").status_code == 401  # no tunnel key
    keyed = new_client(mod)
    assert keyed.get("/api/v1/catalog").status_code == 401  # key but no account
    assert keyed.get("/api/v1/models").status_code == 200  # public
    assert client.get("/api/v1/catalog").status_code == 200


def test_unverified_email_and_bad_token_are_refused(mod, client):
    c = new_client(mod, "test:unew:new@b.kz:unverified")
    r = c.post("/api/v1/auth/session")
    assert r.status_code == 403 and r.json()["detail"]["code"] == "not_verified"
    assert c.get("/api/v1/catalog").status_code == 401
    assert new_client(mod, "garbage").get("/api/v1/catalog").status_code == 401
    me = client.get("/api/v1/auth/me").json()
    assert me["user"]["email"] == OWNER and me["user"]["role"] == "owner" and me["usage"]["tryons_total"] == 0


def test_closed_registration(mod, client):
    assert client.post("/api/v1/admin/settings", json={"registration_open": False}).status_code == 200
    r = new_client(mod, "test:ulate:late@b.kz").post("/api/v1/auth/session")
    assert r.status_code == 403


def test_second_account_is_client_and_data_is_private(mod, client):
    token, user = signup(mod, "client@fitme.test")
    assert user["role"] == "user" and isinstance(user["id"], str)
    other = new_client(mod, token)
    job = try_on(client)
    assert job["status"] == "completed", job["error"]
    # the client can see neither the owner's job nor its pictures nor its catalog
    assert other.get(f"/api/v1/try-on/{job['job_id']}").json()["status"] == "not_found"
    assert other.get(job["result_url"]).status_code == 404
    assert client.get(job["result_url"]).status_code == 200
    up = client.post("/api/v1/catalog/upload", data={"name": "Куртка", "category": "upper_body"},
                     files={"garment_photo": ("g.png", png("black"), "image/png")}).json()
    assert len(client.get("/api/v1/catalog").json()["items"]) == 1
    assert up["item"]["file_name"].startswith(uid_for(OWNER) + "_")
    assert client.get(up["item"]["image_url"]).status_code == 200
    assert other.get(up["item"]["image_url"]).status_code == 404
    assert other.get("/api/v1/catalog").json()["items"] == []
    assert other.delete(f"/api/v1/catalog/{up['item']['item_id']}").status_code == 404
    # and cannot open the admin panel
    assert other.get("/api/v1/admin/overview").status_code == 403


def test_single_try_on_and_save_look(client):
    r = client.post(
        "/api/v1/try-on/upload",
        data={"category": "upper_body", "garment_photo_type": "model", "num_steps": "30", "seed": "7"},
        files={"person_photo": ("p.jpg", png("gray"), "image/png"), "garment_photo": ("g.png", png("navy"), "image/png")},
    )
    assert r.status_code == 200, r.text
    job = wait_job(client, r.json()["job_id"])
    assert job["status"] == "completed", job["error"]
    data = client.calls[0][2]
    assert data["garment_photo_type"] == "model" and data["num_timesteps"] == "30" and data["seed"] == "7"
    assert data["guidance_scale"] == "2.5"
    assert job["gpu_seconds"] == 12.5
    assert client.get(job["result_url"]).status_code == 200
    saved = client.post("/api/v1/looks/save", json={"job_id": job["job_id"]}).json()
    assert saved["status"] == "saved" and saved["look"]["total_steps"] == 1
    assert client.post("/api/v1/looks/save", json={"job_id": job["job_id"]}).json()["status"] == "already_saved"
    assert len(client.get("/api/v1/looks").json()["items"]) == 1


def test_job_survives_backend_restart(mod, client):
    job = try_on(client)
    mod.JOBS.clear()  # what a restart does to the in-memory list
    again = client.get(f"/api/v1/try-on/{job['job_id']}").json()
    assert again["status"] == "completed" and again["result_url"] == job["result_url"]
    assert client.post("/api/v1/looks/save", json={"job_id": job["job_id"]}).json()["status"] == "saved"


def test_not_an_image_is_rejected(client):
    r = client.post(
        "/api/v1/try-on/upload",
        data={"category": "upper_body"},
        files={"person_photo": ("p.jpg", b"not a picture", "image/jpeg"), "garment_photo": ("g.png", png("navy"), "image/png")},
    )
    assert r.status_code == 422


def test_recolor_after_try_on(mod, client):
    job = try_on(client)
    palette = client.get("/api/v1/recolor/palette").json()["items"]
    assert len(palette) >= 12 and palette[0]["hex"].startswith("#")
    r = client.post(f"/api/v1/try-on/{job['job_id']}/recolor", json={"color": "#2f5bb5"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["part"] == "upper" and set(body["parts"]) == {"upper", "lower"}
    img = np.asarray(Image.open(io.BytesIO(client.get(body["url"]).content)).convert("RGB")).astype(int)
    top_pixel, bg_pixel = img[150, 150], img[10, 10]
    assert top_pixel[2] > top_pixel[0] + 40  # the red top became blue
    assert abs(bg_pixel - np.array([255, 0, 0])).max() < 25  # outside the garment nothing changed
    lower = client.post(f"/api/v1/try-on/{job['job_id']}/recolor", json={"color": "#1b1b1d", "part": "lower"}).json()
    assert lower["part"] == "lower"
    orig = client.post(f"/api/v1/try-on/{job['job_id']}/recolor", json={"color": "original"}).json()
    assert orig["url"] == job["result_url"]
    assert client.post(f"/api/v1/try-on/{job['job_id']}/recolor", json={"color": "blue"}).status_code == 422
    # the re-coloured variant can be saved as its own look
    saved = client.post("/api/v1/looks/save", json={"job_id": job["job_id"], "result_url": body["url"],
                                                    "color": "Синий"}).json()
    assert saved["status"] == "saved" and saved["look"]["result_url"] == body["url"]
    bad = client.post("/api/v1/looks/save", json={"job_id": job["job_id"], "result_url": "/generated/x.jpg"})
    assert bad.status_code == 422
    row = mod.db.one("SELECT recolors FROM tryon_jobs WHERE job_id = ?", (job["job_id"],))
    assert row["recolors"] == 2
    st = mod.store.get()
    assert st.tryons[job["job_id"]]["recolors"] == 2 and st.users[uid_for(OWNER)]["recolors"] == 2


def test_recolor_asks_gpu_for_segmentation_when_missing(mod, client):
    job = try_on(client)
    (mod.GENERATED_DIR / f"{job['job_id']}_seg.png").unlink()
    r = client.post(f"/api/v1/try-on/{job['job_id']}/recolor", json={"color": "#c0302b"})
    assert r.status_code == 200, r.text
    assert any(c[1].endswith("/segment") for c in client.calls)


def test_outfit_runs_bottoms_first_and_chains(client):
    items = [
        {"category": "upper_body", "photo_type": "flat-lay", "label": "Куртка", "upload_index": 0},
        {"category": "lower_body", "photo_type": "flat-lay", "label": "Джинсы", "upload_index": 1},
    ]
    r = client.post(
        "/api/v1/try-on/outfit",
        data={"items": json.dumps(items)},
        files=[
            ("person_photo", ("p.jpg", png("gray"), "image/png")),
            ("garment_photos", ("a.png", png("black"), "image/png")),
            ("garment_photos", ("b.png", png("blue"), "image/png")),
        ],
    )
    assert r.status_code == 200, r.text
    job = wait_job(client, r.json()["job_id"])
    assert job["status"] == "completed", job["error"]
    assert [it["label"] for it in job["items"]] == ["Джинсы", "Куртка"]
    assert job["total_steps"] == 2 and len(job["step_results"]) == 2
    cats = [c[2]["category"] for c in client.calls if c[0] == "POST"]
    assert cats == ["bottoms", "tops"]
    assert job["gpu_seconds"] == 25.0


def test_outfit_limits(client):
    too_many = [{"category": "upper_body", "upload_index": 0}] * 4
    r = client.post(
        "/api/v1/try-on/outfit",
        data={"items": json.dumps(too_many)},
        files=[("person_photo", ("p.jpg", png("gray"), "image/png")), ("garment_photos", ("a.png", png("black"), "image/png"))],
    )
    assert r.status_code == 422
    r = client.post(
        "/api/v1/try-on/outfit",
        data={"items": json.dumps([{"category": "upper_body", "upload_index": 3}])},
        files=[("person_photo", ("p.jpg", png("gray"), "image/png"))],
    )
    assert r.status_code == 422


def test_daily_limit_for_clients_only(mod, client):
    assert client.post("/api/v1/admin/settings", json={"daily_tryon_limit": 1}).status_code == 200
    token, _ = signup(mod, "limited@fitme.test")
    user = new_client(mod, token)
    assert try_on(user)["status"] == "completed"
    r = user.post(
        "/api/v1/try-on/upload",
        data={"category": "upper_body"},
        files={"person_photo": ("p.jpg", png("gray"), "image/png"), "garment_photo": ("g.png", png("navy"), "image/png")},
    )
    assert r.status_code == 429
    assert try_on(client)["status"] == "completed"  # the owner is never limited
    assert try_on(client)["status"] == "completed"


def test_jpeg_result_keeps_jpg_extension(client, monkeypatch):
    import app.main as m

    def fake_get(url, **kw):
        if url.endswith("/health"):
            return FakeResp(js={"status": "ready", "upscaler": True})
        if url.endswith("/result"):
            return FakeResp(content=jpeg("red"), ct="image/jpeg")
        if url.endswith("/segmentation"):
            return FakeResp(code=404, js={"detail": "old server"})
        return FakeResp(js={"status": "completed"})

    monkeypatch.setattr(m.httpx, "get", fake_get)
    job = try_on(client)
    assert job["status"] == "completed", job["error"]
    assert job["result_url"].endswith(".jpg")
    assert job["model"] == "fashn"


def test_models_list_and_old_model_ids(mod, client):
    data = client.get("/api/v1/models?refresh=true").json()
    assert [it["id"] for it in data["items"]] == ["fashn"]
    assert data["items"][0]["available"] is True
    items = [{"category": "upper_body", "upload_index": 0}]
    files = [("person_photo", ("p.jpg", png("gray"), "image/png")), ("garment_photos", ("a.png", png("black"), "image/png"))]
    # an old app still sends a removed Hugging Face model: it runs on our GPUs instead
    r = client.post("/api/v1/try-on/outfit", data={"items": json.dumps(items), "model": "leffa"}, files=files)
    assert r.status_code == 200, r.text
    assert wait_job(client, r.json()["job_id"])["status"] == "completed"
    r = client.post("/api/v1/try-on/outfit", data={"items": json.dumps(items), "model": "nope"}, files=files)
    assert r.status_code == 422


def test_two_gpus_work_in_parallel_and_kaggle_failover(mod, client, monkeypatch):
    """Laptop + Kaggle: two try-ons run at the same time; a Kaggle card that vanishes mid-job
    hands the job back to the queue and it finishes on the other card."""
    import threading

    from app.workers import POOL

    kaggle = POOL.add_worker("kaggle-1", "http://kaggle.test", "kaggle", "k3y")
    POOL.check_all()
    assert {w.name for w in POOL.online()} == {"laptop", "kaggle-1"}

    lock = threading.Lock()
    running, peak, seen_keys = set(), [0], []
    fail_kaggle = [False]
    real_post = mod.httpx.post

    def slow_post(url, **kw):
        if url.endswith("/jobs"):
            seen_keys.append((url.split("/")[2], (kw.get("headers") or {}).get("x-gpu-key")))
            if "kaggle" in url and fail_kaggle[0]:
                fail_kaggle[0] = False
                raise mod.httpx.ConnectError("tunnel closed")
            with lock:
                running.add(url)
                peak[0] = max(peak[0], len(running))
            time.sleep(0.4)
            with lock:
                running.discard(url)
        return real_post(url, **kw)

    monkeypatch.setattr(mod.httpx, "post", slow_post)
    items = [{"category": "upper_body", "upload_index": 0}]
    files = [("person_photo", ("p.jpg", png("gray"), "image/png")), ("garment_photos", ("a.png", png("black"), "image/png"))]

    def submit(n):
        ids = [client.post("/api/v1/try-on/outfit", data={"items": json.dumps(items)}, files=files).json()["job_id"]
               for _ in range(n)]
        return [wait_job(client, i) for i in ids]

    jobs = submit(2)
    assert all(j["status"] == "completed" for j in jobs), jobs
    assert peak[0] == 2  # both cards were busy at the same time
    assert ("kaggle.test", "k3y") in seen_keys  # the secret key goes to Kaggle
    assert ("gpu.local", None) in seen_keys
    assert {j["worker"] for j in jobs} == {"laptop", "kaggle-1"}

    fail_kaggle[0] = True
    jobs = submit(2)
    assert all(j["status"] == "completed" for j in jobs), jobs
    assert {j["worker"] for j in jobs} == {"laptop"}  # the lost job was redone on the laptop
    assert not kaggle.online  # the vanished card is offline until the next health check

    # the admin panel counts GPUs in the capacity model
    POOL.add_worker("kaggle-2", "http://kaggle2.test", "kaggle")
    POOL.check(POOL.workers["kaggle-2"])
    cap = client.get("/api/v1/admin/overview").json()["capacity"]
    assert cap["gpus"] == 2 and cap["per_hour"] > 100
    POOL.workers.pop("kaggle-2", None)


def test_admin_overview_users_and_roles(mod, client):
    try_on(client)
    token, user = signup(mod, "worker@fitme.test", name="Сотрудник")
    worker = new_client(mod, token)
    worker.get("/api/v1/catalog")
    mod.admin.flush_usage()

    ov = client.get("/api/v1/admin/overview").json()
    assert ov["users"]["total"] == 2 and ov["tryons"]["total"] == 1
    assert ov["capacity"]["avg_job_s"] == 12.5 and ov["capacity"]["per_hour"] == 288
    assert ov["capacity"]["table"][0]["users"] == 1
    assert ov["traffic_24h"]["requests"] > 0

    users = client.get("/api/v1/admin/users").json()["items"]
    by_email = {u["email"]: u for u in users}
    assert "password_hash" not in by_email[OWNER]
    assert by_email[OWNER]["tryons"] == 1 and by_email[OWNER]["gpu_minutes"] == round(12.5 / 60, 1)
    assert by_email["worker@fitme.test"]["name"] == "Сотрудник"
    st = mod.store.get()
    assert st.users[uid_for(OWNER)]["tryons"] == 1 and st.users[uid_for(OWNER)]["gpu_seconds"] == 12.5
    assert by_email["worker@fitme.test"]["requests"] >= 1

    csv_text = client.get("/api/v1/admin/users.csv").text
    assert "worker@fitme.test" in csv_text and "password" not in csv_text

    # client -> admin: now sees the panel but cannot change roles or delete
    assert client.post(f"/api/v1/admin/users/{user['id']}/role", json={"role": "admin"}).status_code == 200
    assert worker.get("/api/v1/admin/overview").status_code == 200
    owner_id = by_email[OWNER]["id"]
    assert worker.post(f"/api/v1/admin/users/{owner_id}/block", json={"blocked": True}).status_code == 400
    assert worker.delete(f"/api/v1/admin/users/{owner_id}").status_code == 403
    assert worker.post("/api/v1/admin/settings", json={"daily_tryon_limit": 3}).status_code == 403


def test_block_and_delete_user(mod, client):
    token, user = signup(mod, "bad@fitme.test")
    bad = new_client(mod, token)
    assert try_on(bad)["status"] == "completed"
    assert client.post(f"/api/v1/admin/users/{user['id']}/block", json={"blocked": True}).status_code == 200
    assert user["id"] in mod.store.get().disabled  # Firebase refuses sign-in as well
    assert bad.get("/api/v1/catalog").status_code == 401
    assert client.post(f"/api/v1/admin/users/{user['id']}/block", json={"blocked": False}).status_code == 200
    assert bad.get("/api/v1/catalog").status_code == 200
    files_before = list(mod.GENERATED_DIR.glob("*"))
    assert client.delete(f"/api/v1/admin/users/{user['id']}").status_code == 200
    assert mod.store.get().get_user(user["id"]) is None and user["id"] in mod.store.get().deleted_auth
    assert len(list(mod.GENERATED_DIR.glob("*"))) < len(files_before)


def test_self_delete(mod, client):
    token, user = signup(mod, "leaving@fitme.test")
    c = new_client(mod, token)
    assert c.post("/api/v1/auth/delete-account").status_code == 200
    assert mod.store.get().get_user(user["id"]) is None
    assert client.post("/api/v1/auth/delete-account").status_code == 400  # the owner cannot


def test_legacy_json_is_migrated_to_owner(tmp_path, monkeypatch):
    data = tmp_path / "data"
    data.mkdir()
    (tmp_path / "catalog").mkdir()
    (tmp_path / "catalog" / "abc.jpg").write_bytes(jpeg("white"))
    (data / "catalog.json").write_text(json.dumps([{"item_id": "abc", "name": "Старая вещь", "category": "upper_body",
                                                    "image_url": "/catalog/abc.jpg", "file_name": "abc.jpg"}]),
                                       encoding="utf-8")
    (data / "looks.json").write_text(json.dumps([{"look_id": "l1", "job_id": "old", "title": "Старый лук"}]),
                                     encoding="utf-8")
    monkeypatch.setenv("FITME_STORAGE_DIR", str(tmp_path))
    monkeypatch.setenv("FITME_OWNER_EMAIL", OWNER)
    monkeypatch.setenv("FITME_SAMPLER", "0")
    monkeypatch.setenv("FITME_STORE", "memory")
    monkeypatch.delenv("FITME_API_KEY", raising=False)
    import app.main as m

    m = importlib.reload(m)
    m.auth.forget()
    m.admin.profiles_changed()
    assert (data / "catalog.json").exists()  # waits for the creator's first sign-in
    token, _ = signup(m, OWNER)
    assert (data / "catalog.json.migrated").exists()
    c = new_client(m, token)
    assert [it["name"] for it in c.get("/api/v1/catalog").json()["items"]] == ["Старая вещь"]
    assert [it["title"] for it in c.get("/api/v1/looks").json()["items"]] == ["Старый лук"]
    assert c.get("/catalog/abc.jpg").status_code == 200


def test_product_link_to_internal_network_is_refused(mod):
    with pytest.raises(RuntimeError):
        mod.discover_product_image("http://127.0.0.1:7860/health")


def test_admin_web_page_is_served(mod):
    r = new_client(mod).get("/admin")
    assert r.status_code == 200 and "FitMe" in r.text
