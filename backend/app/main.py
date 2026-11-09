from __future__ import annotations

import io
import ipaddress
import json
import mimetypes
import os
import re
import socket
import threading
import time
import uuid
from datetime import datetime, timezone
from html import unescape
from pathlib import Path
from typing import Any
from urllib.parse import urljoin, urlparse

import httpx
import numpy as np
from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.concurrency import run_in_threadpool
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from PIL import Image, ImageChops, ImageEnhance, ImageFilter, ImageOps
from pydantic import BaseModel

from . import admin, auth, db, store
from . import recolor as recolor_mod
from .workers import POOL, Worker

BASE_DIR = Path(
    os.getenv("FITME_STORAGE_DIR") or Path(__file__).resolve().parent.parent
)
UPLOAD_DIR = BASE_DIR / "uploads"
GENERATED_DIR = BASE_DIR / "generated"
CATALOG_DIR = BASE_DIR / "catalog"
DATA_DIR = BASE_DIR / "data"
LOOKS_FILE = DATA_DIR / "looks.json"  # before v4: migrated into the database once
CATALOG_FILE = DATA_DIR / "catalog.json"
REMOTE_URL_FILE = DATA_DIR / "remote_ai_url.txt"
DB_FILE = DATA_DIR / "fitme.db"
WEB_DIR = Path(__file__).resolve().parent / "web"
# The Flutter Web build (BUILD_WEB.bat copies it here); the site is served at /app/.
WEB_APP_DIR = Path(os.getenv("FITME_WEB_APP_DIR") or Path(__file__).resolve().parent / "web_app")
WEB_APP_PATH = "/app"
# The Windows registry can map these to text/plain, and browsers then refuse to run them.
mimetypes.add_type("text/javascript", ".js")
mimetypes.add_type("text/javascript", ".mjs")
mimetypes.add_type("application/wasm", ".wasm")
mimetypes.add_type("application/vnd.android.package-archive", ".apk")

for path in (UPLOAD_DIR, GENERATED_DIR, CATALOG_DIR, DATA_DIR):
    path.mkdir(parents=True, exist_ok=True)

ENGINE = "FASHN VTON 1.5"
APP_VERSION = "4.0.0"
FASHN_STEPS = max(10, min(int(os.getenv("FITME_FASHN_STEPS", "20")), 50))
# The v4 lab (8 photo pairs) measured guidance 2.5 closer to the garment photo than 1.5
# (similarity 0.827 vs 0.805) at the same speed.
FASHN_GUIDANCE = max(1.0, min(float(os.getenv("FITME_GUIDANCE", "2.5")), 3.0))
VALID_CATEGORIES = {"upper_body", "lower_body", "dresses"}
MAX_UPLOAD_BYTES = 20 * 1024 * 1024


# One model on our own GPUs: the laptop card plus Kaggle cards (see workers.py). The free
# Hugging Face ZeroGPU models (a few minutes a day) were removed in v5.
MODEL_CATALOG: list[dict[str, Any]] = [
    {"id": "fashn", "title": "FASHN VTON 1.5", "where": "Ноутбук",
     "categories": ["upper_body", "lower_body", "dresses"], "license": "Apache-2.0",
     "limit": "без лимита", "note": "Основная модель: лучшая детализация + улучшение качества"},
]
MODEL_IDS = {m["id"] for m in MODEL_CATALOG}
REMOVED_MODELS = {"fashn_cloud", "leffa", "fitdit", "idm", "ootd"}


def model_info(model_id: str) -> dict[str, Any]:
    return next((m for m in MODEL_CATALOG if m["id"] == model_id), MODEL_CATALOG[0])


app = FastAPI(
    title="FitMe AI",
    version=APP_VERSION,
    description="FitMe: Flutter -> FastAPI -> FASHN VTON 1.5 on your own GPU, with accounts and analytics",
)

# ---------------------------------------------------------------- database
db.init(DB_FILE)
auth.configure(DATA_DIR)
store.init(DATA_DIR)


def claim_legacy_files(owner_uid: str) -> None:
    """v3 kept the catalog and looks in JSON files without owners; they go to the creator."""
    st = store.get()
    for path, kind in ((CATALOG_FILE, "catalog"), (LOOKS_FILE, "looks")):
        if not path.exists():
            continue
        try:
            items = json.loads(path.read_text(encoding="utf-8"))
        except ValueError:
            items = []
        added, size = 0, 0
        for it in items if isinstance(items, list) else []:
            if kind == "catalog" and it.get("item_id") and it.get("file_name"):
                file_path = CATALOG_DIR / str(it["file_name"])
                item = {
                    "item_id": str(it["item_id"]), "name": it.get("name") or "Вещь",
                    "category": it.get("category") or "upper_body", "description": it.get("description") or "",
                    "image_url": it.get("image_url") or f"/catalog/{it['file_name']}", "file_name": it["file_name"],
                    "source_name": it.get("source_name") or "", "source_url": it.get("source_url") or "",
                    "bytes": file_path.stat().st_size if file_path.exists() else 0,
                    "created_at": it.get("created_at") or utc_now_iso(),
                }
                st.add_catalog(owner_uid, item)
                added, size = added + 1, size + item["bytes"]
            elif kind == "looks" and it.get("look_id"):
                st.add_look(owner_uid, dict(it) | {"created_at": it.get("created_at") or utc_now_iso()})
                added += 1
        if kind == "catalog":
            st.increment_user(owner_uid, {"catalog_count": added, "catalog_bytes": size})
        else:
            st.increment_user(owner_uid, {"looks_count": added})
        path.rename(path.with_suffix(".json.migrated"))


def _migrate_if_owner_known() -> None:
    if not store.available() or not (CATALOG_FILE.exists() or LOOKS_FILE.exists()):
        return
    try:
        owner = store.get().get_config().get("owner_uid")
        if owner:
            claim_legacy_files(owner)
    except Exception as exc:
        print(f"[FitMe] moving old catalog/looks failed: {exc}")


# ---------------------------------------------------------------- access control
API_KEY = (os.getenv("FITME_API_KEY") or "").strip()
OPEN_PATHS = {"/", "/health", "/docs", "/openapi.json", "/admin", "/admin/", "/favicon.ico"}
PUBLIC_API = {"/api/v1/ai/status", "/api/v1/models", "/api/v1/recolor/palette"}  # + /api/v1/auth/*
STATIC_PREFIXES = ("/uploads/", "/generated/", "/catalog/")


def _file_owner_allowed(path: str, user: dict[str, Any]) -> bool:
    """Pictures are private: the owner of the job / catalog item, or an admin."""
    if user["role"] in ("admin", "owner"):
        return True
    name = path.rsplit("/", 1)[-1]
    if path.startswith("/catalog/"):
        return name.startswith(f"{user['id']}_")  # catalog files are named <uid>_<item>.jpg
    job_id = name.split("_", 1)[0]
    row = db.one("SELECT user_id FROM tryon_jobs WHERE job_id = ?", (job_id,))
    return bool(row) and row["user_id"] == user["id"]


def _json_error(status: int, detail: str) -> Response:
    return Response(content=json.dumps({"detail": detail}, ensure_ascii=False), status_code=status,
                    media_type="application/json")


@app.middleware("http")
async def access_and_usage(request: Request, call_next):
    """1) the tunnel access key (FITME_API_KEY), 2) the account token, 3) usage statistics."""
    started = time.perf_counter()
    path = request.url.path
    request.state.user = None
    if request.method == "OPTIONS":
        return await call_next(request)
    if path == WEB_APP_PATH or path.startswith(f"{WEB_APP_PATH}/"):
        # The site's own files are public: they hold no data, and the key is only known after they load.
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-cache"  # a new build must not be stuck in browser caches
        return response
    if API_KEY and path not in OPEN_PATHS:
        supplied = request.headers.get("x-fitme-key") or request.query_params.get("key") or ""
        if supplied != API_KEY:
            return _json_error(401, "Invalid or missing FitMe key")

    user = await run_in_threadpool(auth.resolve_user, request)
    request.state.user = user
    if path.startswith(STATIC_PREFIXES):
        if user is None:
            return _json_error(401, "Войдите в аккаунт")
        if not await run_in_threadpool(_file_owner_allowed, path, user):
            return _json_error(404, "Not found")
    elif (path.startswith("/api/") and path not in PUBLIC_API and not path.startswith("/api/v1/auth/")
          and user is None):
        return _json_error(401, "Войдите в аккаунт")

    response = await call_next(request)
    if path not in ("/health",):
        admin.record_request(
            user["id"] if user else None, request.method, path, response.status_code,
            (time.perf_counter() - started) * 1000,
            int(request.headers.get("content-length") or 0),
            int(response.headers.get("content-length") or 0),
        )
    return response


# Added after access_and_usage so that it wraps it: a browser must be able to read the 401 answers too.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.mount("/uploads", StaticFiles(directory=str(UPLOAD_DIR)), name="uploads")
app.mount("/generated", StaticFiles(directory=str(GENERATED_DIR)), name="generated")
app.mount("/catalog", StaticFiles(directory=str(CATALOG_DIR)), name="catalog")
if (WEB_APP_DIR / "index.html").is_file():
    app.mount(WEB_APP_PATH, StaticFiles(directory=str(WEB_APP_DIR), html=True), name="web_app")

JOBS: dict[str, dict[str, Any]] = {}
JOBS_LOCK = threading.Lock()

_REMBG_SESSION = None
_REMBG_LOCK = threading.Lock()


def _get_human_cutout_session():
    global _REMBG_SESSION
    if _REMBG_SESSION is not None:
        return _REMBG_SESSION

    with _REMBG_LOCK:
        if _REMBG_SESSION is None:
            try:
                from rembg import new_session
            except Exception as exc:
                raise RuntimeError(
                    "rembg is not installed. Run the Python 3.14 cutout fix first"
                ) from exc
            _REMBG_SESSION = new_session("u2net_human_seg")
    return _REMBG_SESSION


def _trim_transparent_person(png_bytes: bytes) -> bytes:
    image = Image.open(io.BytesIO(png_bytes)).convert("RGBA")
    alpha = image.getchannel("A")
    bbox = alpha.getbbox()
    if bbox is None:
        return png_bytes

    left, top, right, bottom = bbox
    person_w = max(1, right - left)
    person_h = max(1, bottom - top)
    margin_x = max(12, int(person_w * 0.05))
    margin_y = max(12, int(person_h * 0.035))
    crop_box = (
        max(0, left - margin_x),
        max(0, top - margin_y),
        min(image.width, right + margin_x),
        min(image.height, bottom + margin_y),
    )
    image = image.crop(crop_box)

    output = io.BytesIO()
    image.save(output, format="PNG", optimize=True)
    return output.getvalue()


class SaveLookPayload(BaseModel):
    job_id: str
    title: str | None = None
    gender: str | None = None
    size: str | None = None
    fit: str | None = None
    color: str | None = None
    # A re-coloured variant of the result (from /recolor); default = the original result.
    result_url: str | None = None


class ImportUrlPayload(BaseModel):
    source_url: str
    category: str = "upper_body"


class RecolorPayload(BaseModel):
    color: str  # "#RRGGBB" or "original"
    part: str = "auto"  # upper / lower / dress / auto


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def new_id() -> str:
    return uuid.uuid4().hex[:16]


def normalize_remote_url(raw: str) -> str:
    value = (raw or "").strip()
    if not value:
        return ""

    match = re.search(r"https?://[^\s\"']+", value, flags=re.IGNORECASE)
    if match:
        value = match.group(0)
    else:
        value = value.strip().strip("\"'")
        if value.lower().startswith("set "):
            value = value[4:].strip().strip("\"'")
        if "=" in value:
            left, right = value.split("=", 1)
            if "url" in left.lower():
                value = right.strip().strip("\"'")
        value = value.strip().rstrip("/")
        if value and not value.lower().startswith(("http://", "https://")):
            value = "https://" + value

    return value.strip().strip("\"'").rstrip("/")


def get_remote_url() -> str:
    env_value = normalize_remote_url(os.getenv("FITME_REMOTE_AI_URL", ""))
    if env_value:
        return env_value

    if REMOTE_URL_FILE.exists():
        return normalize_remote_url(
            REMOTE_URL_FILE.read_text(encoding="utf-8", errors="ignore")
        )

    return ""


def safe_filename(name: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "_", name or "image.jpg")
    return cleaned[:120] or "image.jpg"


def suffix_for(upload: UploadFile) -> str:
    suffix = Path(safe_filename(upload.filename or "image.jpg")).suffix.lower()
    return suffix if suffix in {".jpg", ".jpeg", ".png", ".webp"} else ".jpg"


async def read_image_upload(upload: UploadFile, what: str) -> bytes:
    """Reads an uploaded picture and checks that it really is one (and not too big)."""
    data = await upload.read()
    if not data:
        raise HTTPException(status_code=400, detail=f"{what}: пустой файл")
    if len(data) > MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail=f"{what}: файл больше 20 МБ")
    try:
        with Image.open(io.BytesIO(data)) as probe:
            probe.verify()
    except Exception as exc:
        raise HTTPException(status_code=422, detail=f"{what}: это не картинка") from exc
    return data


def image_mime(path: Path) -> str:
    guessed, _ = mimetypes.guess_type(path.name)
    return guessed or "image/jpeg"


def fashn_category(category: str) -> str:
    return {
        "upper_body": "tops",
        "lower_body": "bottoms",
        "dresses": "one-pieces",
    }.get(category, "tops")


def resolve_provider(timeout: float = 8.0) -> tuple[str, bool, dict[str, Any], str | None]:
    """Returns (provider, online, details, error) for the GPU pool (laptop + Kaggle)."""
    online = POOL.any_online(recheck=True)
    workers = POOL.online()
    details = dict(workers[0].details) if workers else {}
    details["workers"] = POOL.snapshot()
    details["gpus_online"] = len(workers)
    error = None if online else "; ".join(f"{w.name}: {w.error}" for w in POOL.workers.values()) or "нет видеокарт"
    return "remote_fashn", online, details, error


# ---------------------------------------------------------------- product links
def _public_host_only(request: httpx.Request) -> None:
    """Product links come from users: never let them reach the laptop or the home network
    (e.g. http://127.0.0.1:7860 = the GPU server). Checked again on every redirect."""
    host = request.url.host or ""
    try:
        infos = socket.getaddrinfo(host, request.url.port or (443 if request.url.scheme == "https" else 80))
    except socket.gaierror as exc:
        raise RuntimeError(f"Не удалось найти сайт {host}") from exc
    for info in infos:
        address = ipaddress.ip_address(info[4][0])
        if not address.is_global:
            raise RuntimeError("Ссылка ведёт во внутреннюю сеть — такие адреса не открываются")


def browser_headers() -> dict[str, str]:
    return {
        "User-Agent": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 (KHTML, like Gecko) "
            "Chrome/126.0 Safari/537.36"
        ),
        "Accept-Language": "ru-RU,ru;q=0.9,en;q=0.8",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
    }


def _first_meta(content: str, patterns: list[str]) -> str | None:
    for pattern in patterns:
        match = re.search(pattern, content, flags=re.IGNORECASE | re.DOTALL)
        if match:
            value = unescape(match.group(1)).strip()
            if value:
                return value
    return None


def discover_product_image(source_url: str) -> tuple[str, str, str]:
    url = source_url.strip()
    if not url.startswith(("http://", "https://")):
        url = "https://" + url

    with httpx.Client(
        headers=browser_headers(),
        follow_redirects=True,
        event_hooks={"request": [_public_host_only]},
        timeout=httpx.Timeout(20.0, read=30.0),
    ) as client:
        response = client.get(url)
        response.raise_for_status()

        content_type = response.headers.get("content-type", "").lower()

        if content_type.startswith("image/"):
            host = urlparse(str(response.url)).netloc
            return str(response.url), host, host or "Источник"

        html = response.text[:2_000_000]
        final_url = str(response.url)

        image_url = _first_meta(
            html,
            [
                r'<meta[^>]+property=["\\\']og:image(?::secure_url)?["\\\'][^>]+content=["\\\']([^"\\\']+)["\\\']',
                r'<meta[^>]+content=["\\\']([^"\\\']+)["\\\'][^>]+property=["\\\']og:image(?::secure_url)?["\\\']',
                r'<meta[^>]+name=["\\\']twitter:image(?::src)?["\\\'][^>]+content=["\\\']([^"\\\']+)["\\\']',
                r'<meta[^>]+content=["\\\']([^"\\\']+)["\\\'][^>]+name=["\\\']twitter:image(?::src)?["\\\']',
                r'<link[^>]+rel=["\\\']image_src["\\\'][^>]+href=["\\\']([^"\\\']+)["\\\']',
            ],
        )

        if not image_url:
            # Common JSON-LD / embedded product schema.
            image_url = _first_meta(
                html,
                [
                    r'"image"\s*:\s*"([^"]+)"',
                    r'"image"\s*:\s*\[\s*"([^"]+)"',
                ],
            )

        if not image_url:
            # Last-resort first large-looking image URL.
            candidates = re.findall(
                r'<img[^>]+(?:src|data-src)=["\\\']([^"\\\']+)["\\\']',
                html,
                flags=re.IGNORECASE,
            )
            for candidate in candidates:
                low = candidate.lower()
                if any(x in low for x in ("logo", "icon", "avatar", "sprite")):
                    continue
                image_url = candidate
                break

        if not image_url:
            raise RuntimeError("На странице не найдено фото товара")

        image_url = urljoin(final_url, unescape(image_url))

        title = _first_meta(
            html,
            [
                r'<meta[^>]+property=["\\\']og:title["\\\'][^>]+content=["\\\']([^"\\\']+)["\\\']',
                r'<title[^>]*>(.*?)</title>',
            ],
        ) or "Товар по ссылке"
        title = re.sub(r"\s+", " ", unescape(title)).strip()[:120]

        host = urlparse(final_url).netloc.replace("www.", "")
        source_name = host.split(".")[0].capitalize() if host else "Источник"

        return image_url, title, source_name


def download_product_image(image_url: str, destination: Path) -> None:
    with httpx.Client(
        headers=browser_headers(),
        follow_redirects=True,
        event_hooks={"request": [_public_host_only]},
        timeout=httpx.Timeout(20.0, read=60.0),
    ) as client:
        response = client.get(image_url)
        response.raise_for_status()
        content_type = response.headers.get("content-type", "").lower()
        if "image" not in content_type:
            raise RuntimeError(f"Ссылка на фото вернула {content_type or 'неизвестный тип'}")
        if len(response.content) > 15 * 1024 * 1024:
            raise RuntimeError("Фото товара слишком большое")
        destination.write_bytes(response.content)


COLOR_RGB: dict[str, tuple[int, int, int]] = {
    "Чёрный": (24, 24, 24),
    "Белый": (238, 238, 238),
    "Серый": (126, 126, 126),
    "Синий": (52, 88, 170),
    "Красный": (190, 53, 53),
    "Жёлтый": (213, 173, 50),
    "Зелёный": (65, 139, 91),
    "Бежевый": (204, 171, 129),
}

SIZE_SCALE: dict[str, float] = {
    "XS": 0.92,
    "S": 0.96,
    "M": 1.00,
    "L": 1.04,
    "XL": 1.08,
    "XXL": 1.12,
}

FIT_WIDTH_SCALE: dict[str, float] = {
    "Slim": 0.92,
    "Regular": 1.00,
    "Oversize": 1.12,
}

FIT_HEIGHT_SCALE: dict[str, float] = {
    "Slim": 0.98,
    "Regular": 1.00,
    "Oversize": 1.06,
}


def _average_corner_color(image: Image.Image) -> tuple[int, int, int]:
    rgb = image.convert("RGB")
    w, h = rgb.size
    sample = max(6, min(w, h) // 24)

    boxes = [
        (0, 0, sample, sample),
        (w - sample, 0, w, sample),
        (0, h - sample, sample, h),
        (w - sample, h - sample, w, h),
    ]

    values: list[tuple[int, int, int]] = []
    for box in boxes:
        crop = rgb.crop(box).resize((1, 1), Image.Resampling.BOX)
        values.append(crop.getpixel((0, 0)))

    return tuple(
        int(sum(value[channel] for value in values) / len(values))
        for channel in range(3)
    )


def _garment_mask(image: Image.Image) -> tuple[Image.Image, tuple[int, int, int]]:
    rgba = image.convert("RGBA")
    rgb = rgba.convert("RGB")
    background = _average_corner_color(rgb)

    bg = Image.new("RGB", rgb.size, background)
    difference = ImageChops.difference(rgb, bg)

    # Max RGB difference is more reliable than average grayscale difference
    # for coloured garments on white/neutral product backgrounds.
    r, g, b = difference.split()
    max_diff = ImageChops.lighter(ImageChops.lighter(r, g), b)
    hard = max_diff.point(lambda p: 255 if p >= 22 else 0)

    alpha = rgba.getchannel("A")
    if alpha.getextrema()[0] < 250:
        alpha_hard = alpha.point(lambda p: 255 if p >= 16 else 0)
        hard = ImageChops.lighter(hard, alpha_hard)

    # Clean small holes/noise and use a soft border for nicer recolouring.
    hard = hard.filter(ImageFilter.MaxFilter(5)).filter(ImageFilter.MinFilter(3))
    soft = hard.filter(ImageFilter.GaussianBlur(1.2))
    return soft, background


def _recolor_preserving_shading(
    rgb: Image.Image,
    mask: Image.Image,
    color_name: str,
) -> Image.Image:
    target = COLOR_RGB.get(color_name)
    if target is None:
        return rgb

    gray = ImageOps.grayscale(rgb)
    gray = ImageEnhance.Contrast(gray).enhance(0.85)

    if color_name == "Чёрный":
        dark = (6, 6, 6)
        light = (88, 88, 88)
    elif color_name == "Белый":
        dark = (105, 105, 105)
        light = (250, 250, 250)
    else:
        dark = tuple(max(0, int(channel * 0.22)) for channel in target)
        light = tuple(
            min(255, int(channel + (255 - channel) * 0.36))
            for channel in target
        )

    coloured = ImageOps.colorize(gray, black=dark, white=light)
    return Image.composite(coloured, rgb, mask)


def prepare_garment_for_tryon(
    source_path: Path,
    destination_path: Path,
    *,
    selected_color: str,
    selected_size: str,
    selected_fit: str,
) -> tuple[Path, dict[str, Any]]:
    """
    MVP visual controls:
    - colour: real pixel recolouring while preserving light/shadow;
    - size/fit: approximate flat-lay silhouette scaling before FASHN.

    This is intentionally described as approximate. It is not a brand sizing engine.
    """
    selected_color = (selected_color or "Как на фото").strip()
    selected_size = (selected_size or "M").strip().upper()
    selected_fit = (selected_fit or "Regular").strip().title()

    if (
        selected_color == "Как на фото"
        and selected_size == "M"
        and selected_fit == "Regular"
    ):
        return source_path, {
            "preprocessed": False,
            "color_applied": False,
            "size_scale": 1.0,
            "fit_width_scale": 1.0,
            "fit_height_scale": 1.0,
        }

    source = ImageOps.exif_transpose(Image.open(source_path)).convert("RGBA")
    rgb = source.convert("RGB")
    mask, background = _garment_mask(source)

    bbox = mask.point(lambda p: 255 if p >= 64 else 0).getbbox()
    if bbox is None:
        # If segmentation failed, do not destroy the garment image.
        source.convert("RGB").save(destination_path, quality=95)
        return destination_path, {
            "preprocessed": True,
            "mask_found": False,
            "color_applied": False,
            "size_scale": 1.0,
            "fit_width_scale": 1.0,
            "fit_height_scale": 1.0,
        }

    edited = _recolor_preserving_shading(rgb, mask, selected_color)

    size_scale = SIZE_SCALE.get(selected_size, 1.0)
    fit_width = FIT_WIDTH_SCALE.get(selected_fit, 1.0)
    fit_height = FIT_HEIGHT_SCALE.get(selected_fit, 1.0)

    width_scale = size_scale * fit_width
    height_scale = size_scale * fit_height

    # Keep the edited object inside the same canvas.
    w, h = edited.size
    x0, y0, x1, y1 = bbox
    crop = edited.crop(bbox)
    crop_mask = mask.crop(bbox)

    target_w = max(1, int(crop.width * width_scale))
    target_h = max(1, int(crop.height * height_scale))

    max_w = max(1, int(w * 0.94))
    max_h = max(1, int(h * 0.94))
    fit_inside = min(1.0, max_w / target_w, max_h / target_h)
    target_w = max(1, int(target_w * fit_inside))
    target_h = max(1, int(target_h * fit_inside))

    crop = crop.resize((target_w, target_h), Image.Resampling.LANCZOS)
    crop_mask = crop_mask.resize((target_w, target_h), Image.Resampling.LANCZOS)

    canvas = Image.new("RGB", (w, h), background)

    original_center_x = (x0 + x1) // 2
    original_center_y = (y0 + y1) // 2
    paste_x = max(0, min(w - target_w, original_center_x - target_w // 2))
    paste_y = max(0, min(h - target_h, original_center_y - target_h // 2))

    canvas.paste(crop, (paste_x, paste_y), crop_mask)
    canvas.save(destination_path, format="PNG", optimize=True)

    return destination_path, {
        "preprocessed": True,
        "mask_found": True,
        "color_applied": selected_color in COLOR_RGB,
        "selected_color": selected_color,
        "selected_size": selected_size,
        "selected_fit": selected_fit,
        "size_scale": size_scale,
        "fit_width_scale": fit_width,
        "fit_height_scale": fit_height,
        "final_width_scale": round(width_scale, 3),
        "final_height_scale": round(height_scale, 3),
    }


# --------------------------------------------------------------------------- #
# Generation: one FASHN call = one garment. An outfit is a chain of calls where
# each next garment is put on the previous result.
# --------------------------------------------------------------------------- #
OUTFIT_ORDER = {"lower_body": 0, "dresses": 1, "upper_body": 2}
MAX_OUTFIT_ITEMS = 3
GARMENT_PHOTO_TYPES = {"flat-lay", "model", "auto"}


def order_outfit(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Bottoms first, then dresses, then tops/outerwear (stable inside a category)."""
    return sorted(items, key=lambda it: OUTFIT_ORDER.get(it["category"], 9))


def generate_remote(
    worker: Worker,
    person_path: Path,
    garment_path: Path,
    category: str,
    photo_type: str,
    steps: int,
    seed: int,
) -> tuple[bytes, dict[str, Any]]:
    """FASHN on Kaggle or on the local GPU server (same async /jobs API).
    The local server returns a full-resolution JPEG (crop + paste-back + upscale) and,
    since v4, the human-parser map of the result (for re-colouring)."""
    remote_url, headers = worker.url, worker.headers
    with person_path.open("rb") as person_file, garment_path.open("rb") as garment_file:
        create = httpx.post(
            f"{remote_url}/jobs",
            headers=headers,
            data={
                "category": fashn_category(category),
                "garment_photo_type": photo_type,
                "num_timesteps": str(steps),
                "guidance_scale": str(FASHN_GUIDANCE),
                "seed": str(seed),
                "segmentation_free": "true",
            },
            files={
                "person_photo": (person_path.name, person_file, image_mime(person_path)),
                "garment_photo": (garment_path.name, garment_file, image_mime(garment_path)),
            },
            timeout=httpx.Timeout(connect=30.0, read=45.0, write=120.0, pool=30.0),
            follow_redirects=True,
        )
    if create.status_code not in {200, 201, 202}:
        raise RuntimeError(f"GPU job create HTTP {create.status_code}")
    remote_job_id = str(create.json().get("job_id") or "")
    if not remote_job_id:
        raise RuntimeError("GPU server did not return job_id")

    deadline = time.time() + 12 * 60
    while time.time() < deadline:
        poll = httpx.get(f"{remote_url}/jobs/{remote_job_id}", headers=headers, timeout=20.0, follow_redirects=True)
        if poll.status_code != 200:
            raise RuntimeError(f"GPU status HTTP {poll.status_code}")
        state = poll.json()
        remote_status = str(state.get("status") or "unknown")
        if remote_status == "completed":
            result = httpx.get(
                f"{remote_url}/jobs/{remote_job_id}/result",
                headers=headers,
                timeout=httpx.Timeout(connect=20.0, read=120.0, write=30.0, pool=20.0),
                follow_redirects=True,
            )
            content_type = result.headers.get("content-type", "").lower()
            if result.status_code != 200 or "image" not in content_type:
                raise RuntimeError(f"GPU result HTTP {result.status_code}")
            info: dict[str, Any] = {"gpu_seconds": float(state.get("seconds") or 0)}
            try:
                seg = httpx.get(f"{remote_url}/jobs/{remote_job_id}/segmentation", headers=headers, timeout=30.0,
                                follow_redirects=True)
                if seg.status_code == 200 and "image" in seg.headers.get("content-type", ""):
                    info["segmentation"] = seg.content
            except Exception:
                pass  # older GPU server / Kaggle: re-colouring will ask /segment later
            return result.content, info
        if remote_status == "failed":
            raise RuntimeError(str(state.get("error") or "FASHN generation failed")[:500])
        time.sleep(1.5)
    raise RuntimeError("GPU generation timeout after 12 minutes")


def uses_laptop_gpu(provider: str) -> bool:
    """Jobs that go through our GPU pool (all of them since v5)."""
    return provider == "remote_fashn"


def queue_counts() -> tuple[int, int]:
    with JOBS_LOCK:
        local = [j for j in JOBS.values() if uses_laptop_gpu(j["provider"])]
    return (sum(j["status"] == "processing" for j in local), sum(j["status"] == "queued" for j in local))


def queue_position(job: dict[str, Any]) -> int:
    """How many try-ons are ahead of this one (0 = it starts as soon as a card is free).
    With several GPUs (laptop + Kaggle) only the queued jobs ahead count, plus one when all cards are busy."""
    if job["status"] != "queued" or not uses_laptop_gpu(job["provider"]):
        return 0
    with JOBS_LOCK:
        ahead = sum(1 for j in JOBS.values() if uses_laptop_gpu(j["provider"]) and j["status"] == "queued"
                    and j["created_ts"] < job["created_ts"])
        busy = sum(1 for j in JOBS.values() if uses_laptop_gpu(j["provider"]) and j["status"] == "processing")
    return ahead + (1 if busy >= POOL.count() else 0)


def persist_job(job: dict[str, Any]) -> None:
    data = {k: v for k, v in job.items() if not k.startswith("_")}
    db.execute(
        "INSERT INTO tryon_jobs(job_id, user_id, created_at, started_at, finished_at, status, model, provider, "
        "items, steps, gpu_seconds, bytes_in, bytes_out, recolors, error, data) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) "
        "ON CONFLICT(job_id) DO UPDATE SET started_at = excluded.started_at, finished_at = excluded.finished_at, "
        "status = excluded.status, gpu_seconds = excluded.gpu_seconds, bytes_in = excluded.bytes_in, "
        "bytes_out = excluded.bytes_out, recolors = excluded.recolors, error = excluded.error, data = excluded.data",
        (job["job_id"], job["user_id"], job["created_ts"], job.get("_started_ts"), job.get("_finished_ts"),
         job["status"], job["model"], job["provider"], job["total_steps"], job["num_timesteps"],
         job.get("gpu_seconds", 0.0), job.get("_bytes_in", 0), job.get("_bytes_out", 0), job.get("recolors", 0),
         job.get("error"), json.dumps(data, ensure_ascii=False)),
    )


def _mirror(action) -> None:
    """Best-effort copy into Firestore (the console shows try-ons); never fails a try-on."""
    if not store.available():
        return
    try:
        action(store.get())
    except Exception as exc:
        print(f"[FitMe] Firestore update failed: {type(exc).__name__}: {exc}")


def mirror_job(job: dict[str, Any], final: bool = False) -> None:
    summary = {
        "uid": job.get("user_id"), "status": job["status"], "model": job["model"], "items": job["total_steps"],
        "steps": job["num_timesteps"], "created_at": job["created_ts"], "started_at": job.get("_started_ts"),
        "finished_at": job.get("_finished_ts"), "gpu_seconds": job.get("gpu_seconds", 0.0),
        "queue_seconds": job.get("queue_seconds"), "error": job.get("error"), "recolors": job.get("recolors", 0),
        "title": job.get("garment_description"),
    }

    def write(st: store.Store) -> None:
        st.save_tryon(job["job_id"], summary)
        if final and job.get("user_id"):
            st.increment_user(job["user_id"], {"tryons": 1, "gpu_seconds": float(job.get("gpu_seconds") or 0)})

    _mirror(write)


def load_job(job_id: str) -> dict[str, Any] | None:
    with JOBS_LOCK:
        job = JOBS.get(job_id)
    if job is not None:
        return job
    row = db.one("SELECT data, user_id FROM tryon_jobs WHERE job_id = ?", (job_id,))
    if row is None:
        return None
    job = json.loads(row["data"])
    job["user_id"] = row["user_id"]
    if job.get("status") in ("queued", "processing"):  # the server restarted in the middle
        job["status"] = "failed"
        job["error"] = "Сервер перезапускался во время примерки — запустите её ещё раз."
    return job


class WorkerLost(RuntimeError):
    """A Kaggle card disappeared (session ended / tunnel dropped) in the middle of a job."""


def run_outfit_job(
    job_id: str,
    provider: str,
    person_path: Path,
    items: list[dict[str, Any]],
    steps: int,
    seed: int,
) -> None:
    job = JOBS[job_id]
    try:
        for attempt in range(2):  # a lost Kaggle card -> the job goes back to the queue once
            worker = POOL.acquire()
            try:
                _run_on_worker(job, worker, person_path, items, steps, seed)
                POOL.release(worker, seconds=job.get("gpu_seconds"))
                break
            except WorkerLost as exc:
                POOL.release(worker, failed=True)
                if attempt == 1:
                    raise RuntimeError(f"видеокарта {worker.name} пропала: {exc}") from exc
                job.update(status="queued", step=0, step_results=[], gpu_seconds=0.0)
            except BaseException:
                POOL.release(worker)
                raise
        job["status"] = "completed"
        job["result_url"] = job["step_results"][-1]
        job["completed_at"] = utc_now_iso()
    except Exception as exc:
        job["status"] = "failed"
        step = job.get("step") or 1
        job["error"] = f"{job.get('engine') or ENGINE}, шаг {step}: {type(exc).__name__}: {str(exc)[:600]}"
    finally:
        job["_finished_ts"] = time.time()
        try:
            persist_job(job)
        except Exception as exc:
            print(f"[FitMe] could not save job {job_id}: {exc}")
        mirror_job(job, final=True)
        _forget_old_jobs()


def _run_on_worker(job: dict[str, Any], worker: Worker, person_path: Path, items: list[dict[str, Any]],
                   steps: int, seed: int) -> None:
    job_id = job["job_id"]
    job["status"] = "processing"
    job["worker"] = worker.name
    job["started_at"] = utc_now_iso()
    job["_started_ts"] = time.time()
    job["queue_seconds"] = round(job["_started_ts"] - job["created_ts"], 1)
    persist_job(job)
    current_person = person_path
    for index, item in enumerate(items):
        job["step"] = index + 1
        job["step_label"] = item.get("label") or categoryRu_py(item["category"])
        job["step_started_at"] = utc_now_iso()
        step_started = time.time()
        try:
            png, info = generate_remote(worker, current_person, item["prepared_path"],
                                        item["category"], item["photo_type"], steps, seed)
        except (httpx.TransportError, httpx.TimeoutException) as exc:
            if worker.kind != "laptop":
                raise WorkerLost(f"{type(exc).__name__}: {exc}") from exc
            raise
        job["gpu_seconds"] = round(job.get("gpu_seconds", 0.0)
                                   + (info.get("gpu_seconds") or (time.time() - step_started)), 1)
        ext = ".jpg" if png[:3] == b"\xff\xd8\xff" else ".png"
        step_path = GENERATED_DIR / f"{job_id}_step{index + 1}{ext}"
        step_path.write_bytes(png)
        job["_bytes_out"] = job.get("_bytes_out", 0) + len(png)
        if info.get("segmentation"):
            (GENERATED_DIR / f"{job_id}_seg.png").write_bytes(info["segmentation"])
        job["step_results"].append(f"/generated/{step_path.name}")
        current_person = step_path


def _forget_old_jobs(keep: int = 200) -> None:
    """Finished jobs stay in the database; memory keeps only the newest ones."""
    with JOBS_LOCK:
        finished = [j for j in JOBS.values() if j["status"] in ("completed", "failed")]
        for old in sorted(finished, key=lambda j: j["created_ts"])[:-keep]:
            JOBS.pop(old["job_id"], None)


def categoryRu_py(category: str) -> str:
    return {"upper_body": "Верх", "lower_body": "Низ", "dresses": "Платье"}.get(category, "Вещь")


def _delete_user_files(user_id: str) -> None:
    """Called before an account is deleted: its catalog photos and try-on pictures go too."""
    for item in store.get().list_catalog(user_id):
        (CATALOG_DIR / str(item.get("file_name"))).unlink(missing_ok=True)
    job_ids = [r["job_id"] for r in db.all_rows("SELECT job_id FROM tryon_jobs WHERE user_id = ?", (user_id,))]
    for job_id in job_ids:
        for folder in (UPLOAD_DIR, GENERATED_DIR):
            for file in folder.glob(f"{job_id}_*"):
                file.unlink(missing_ok=True)
        with JOBS_LOCK:
            JOBS.pop(job_id, None)


auth.set_file_cleaner(_delete_user_files)
auth.set_legacy_claimer(claim_legacy_files)
app.include_router(auth.router)
app.include_router(admin.router)
admin.configure(
    {"base": BASE_DIR, "uploads": UPLOAD_DIR, "generated": GENERATED_DIR, "catalog": CATALOG_DIR, "db": DB_FILE},
    queue_counts,
)
_migrate_if_owner_known()
POOL.configure(DATA_DIR, get_remote_url())
admin.start_background()
if os.getenv("FITME_SAMPLER", "1") != "0":
    POOL.start()


@app.get("/")
def root(request: Request):
    if (WEB_APP_DIR / "index.html").is_file() and "text/html" in request.headers.get("accept", ""):
        query = f"?{request.url.query}" if request.url.query else ""  # keeps ?key=... of the start link
        return RedirectResponse(f"{WEB_APP_PATH}/{query}", status_code=307)
    return {
        "app": "FitMe AI",
        "version": APP_VERSION,
        "docs": "/docs",
        "admin": "/admin",
    }


@app.get("/admin", include_in_schema=False)
@app.get("/admin/", include_in_schema=False)
def admin_page():
    """Web admin panel (the full user table, CSV export) for a browser on the laptop."""
    return FileResponse(WEB_DIR / "admin.html", media_type="text/html; charset=utf-8",
                        headers={"Cache-Control": "no-store"})


@app.post("/api/v1/avatar/cutout")
async def avatar_cutout(photo: UploadFile = File(...)):
    raw = await read_image_upload(photo, "Фото для аватара")

    try:
        from rembg import remove

        session = _get_human_cutout_session()
        result = await run_in_threadpool(
            remove,
            raw,
            session=session,
            alpha_matting=True,
            alpha_matting_foreground_threshold=235,
            alpha_matting_background_threshold=15,
            alpha_matting_erode_size=8,
        )
        result = _trim_transparent_person(result)
        return Response(
            content=result,
            media_type="image/png",
            headers={
                "Cache-Control": "no-store",
                "X-FitMe-Cutout": "u2net_human_seg",
            },
        )
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(
            status_code=500,
            detail=f"AI cutout failed: {type(exc).__name__}: {str(exc)[:300]}",
        ) from exc


@app.get("/health")
def health():
    return {
        "app": "FitMe AI",
        "status": "online",
        "version": APP_VERSION,
        "accounts": True,
        "auth": "firebase",
        "firebase": store.available(),
        "api_key_required": bool(API_KEY),
        "max_outfit_items": MAX_OUTFIT_ITEMS,
        "engine": ENGINE,
        "steps": FASHN_STEPS,
        "remote_configured": bool(get_remote_url()),
        "gpus_online": len(POOL.online()),
    }


@app.get("/api/v1/ai/status")
def ai_status():
    provider, online, details, error = resolve_provider()
    active, queued = queue_counts()
    return {
        "provider": provider,
        "engine": ENGINE,
        "steps": FASHN_STEPS,
        "real_ai": True,
        "online": online,
        "remote_ai_online": online,
        "remote_url_configured": bool(get_remote_url()),
        "ai": details,
        "error": error,
        "queue": {"active": active, "waiting": queued},
        "workers": POOL.snapshot(),
        "engines": {
            "upper_body": ENGINE,
            "lower_body": ENGINE,
            "dresses": ENGINE,
        },
    }


_MODELS_CACHE: dict[str, Any] = {"at": 0.0, "items": None}
_MODELS_LOCK = threading.Lock()


@app.get("/api/v1/models")
def list_models(refresh: bool = False):
    """The model chooser of the app: FASHN on our GPUs (laptop + Kaggle)."""
    with _MODELS_LOCK:
        if not refresh and _MODELS_CACHE["items"] is not None and time.time() - _MODELS_CACHE["at"] < 60:
            return {"items": _MODELS_CACHE["items"], "hf_token": False, "cached": True}
    _, online, details, error = resolve_provider(timeout=6.0)
    item = dict(MODEL_CATALOG[0])
    gpus = details.get("gpus_online", 0)
    kaggle = sum(1 for w in POOL.online() if w.kind == "kaggle")
    item["where"] = "Ноутбук + Kaggle" if kaggle else "Ноутбук"
    item["available"] = online
    item["reason"] = None if online else "Запустите START_LOCAL_GPU.bat на ноутбуке"
    item["upscaler"] = bool(details.get("upscaler"))
    item["gpus"] = gpus
    with _MODELS_LOCK:
        _MODELS_CACHE.update(at=time.time(), items=[item])
    return {"items": [item], "hf_token": False, "cached": False}


# ---------------------------------------------------------------- catalog (per account)
def _catalog_json(row: dict[str, Any]) -> dict[str, Any]:
    return {k: row.get(k, "") for k in ("item_id", "name", "category", "description", "image_url", "file_name",
                                        "source_name", "source_url", "created_at")}


def _insert_catalog(item: dict[str, Any], owner_id: str, size: int) -> None:
    st = store.get()
    st.add_catalog(owner_id, item | {"bytes": size})
    st.increment_user(owner_id, {"catalog_count": 1, "catalog_bytes": size})
    auth.forget(owner_id)


@app.get("/api/v1/catalog")
def get_catalog(request: Request):
    user = auth.require_user(request)
    return {"items": [_catalog_json(r) for r in store.get().list_catalog(user["id"])]}


@app.post("/api/v1/catalog/import-url")
def import_catalog_url(payload: ImportUrlPayload, request: Request):
    user = auth.require_user(request)
    if payload.category not in VALID_CATEGORIES:
        raise HTTPException(status_code=422, detail="Invalid garment category")

    source_url = payload.source_url.strip()
    if not source_url:
        raise HTTPException(status_code=422, detail="source_url is required")

    try:
        image_url, title, source_name = discover_product_image(source_url)
        item_id = new_id()
        file_name = f"{user['id']}_{item_id}.jpg"
        destination = CATALOG_DIR / file_name
        download_product_image(image_url, destination)
    except Exception as exc:
        raise HTTPException(
            status_code=422,
            detail=f"Не удалось найти фото товара: {type(exc).__name__}: {str(exc)[:300]}",
        )

    normalized_source = source_url
    if not normalized_source.startswith(("http://", "https://")):
        normalized_source = "https://" + normalized_source

    item = {
        "item_id": item_id,
        "name": title or "Товар по ссылке",
        "category": payload.category,
        "description": title or "garment",
        "image_url": f"/catalog/{file_name}",
        "file_name": file_name,
        "source_name": source_name,
        "source_url": normalized_source,
        "created_at": utc_now_iso(),
    }
    _insert_catalog(item, user["id"], destination.stat().st_size)
    return {
        "status": "saved",
        "item": item,
        "detected_image_url": image_url,
    }


@app.post("/api/v1/catalog/upload")
async def upload_catalog_item(
    request: Request,
    name: str = Form(...),
    category: str = Form(...),
    description: str = Form(""),
    source_name: str = Form(""),
    source_url: str = Form(""),
    garment_photo: UploadFile = File(...),
):
    user = auth.require_user(request)
    if category not in VALID_CATEGORIES:
        raise HTTPException(status_code=422, detail="Invalid garment category")

    data = await read_image_upload(garment_photo, "Фото вещи")
    item_id = new_id()
    file_name = f"{user['id']}_{item_id}{suffix_for(garment_photo)}"
    (CATALOG_DIR / file_name).write_bytes(data)

    item = {
        "item_id": item_id,
        "name": name.strip()[:160] or "Garment",
        "category": category,
        "description": description.strip()[:500] or name.strip()[:160] or "garment",
        "image_url": f"/catalog/{file_name}",
        "file_name": file_name,
        "source_name": source_name.strip()[:80],
        "source_url": source_url.strip()[:500],
        "created_at": utc_now_iso(),
    }
    _insert_catalog(item, user["id"], len(data))
    return {"status": "saved", "item": item}


@app.delete("/api/v1/catalog/{item_id}")
def delete_catalog_item(item_id: str, request: Request):
    user = auth.require_user(request)
    st = store.get()
    found = st.get_catalog(user["id"], item_id)
    if not found:
        raise HTTPException(status_code=404, detail="Catalog item not found")
    (CATALOG_DIR / str(found["file_name"])).unlink(missing_ok=True)
    st.delete_catalog(user["id"], item_id)
    st.increment_user(user["id"], {"catalog_count": -1, "catalog_bytes": -int(found.get("bytes") or 0)})
    auth.forget(user["id"])
    return {"status": "deleted", "item_id": item_id}


# ---------------------------------------------------------------- try-on
def _clamp_steps(value: int | None, provider: str) -> int:
    if value is None or value <= 0:
        return FASHN_STEPS
    return max(10, min(int(value), 50))


def _catalog_item(item_id: str, user: dict[str, Any]) -> dict[str, Any]:
    item = store.get().get_catalog(user["id"], item_id)
    if not item:
        raise HTTPException(status_code=404, detail="Catalog item not found")
    return item


def _prepare_garment(job_id: str, index: int, garment_path: Path, color: str, size: str, fit: str) -> tuple[Path, dict[str, Any]]:
    if color == "Как на фото" and size.upper() == "M" and fit.title() == "Regular":
        return garment_path, {"preprocessed": False}
    try:
        return prepare_garment_for_tryon(
            garment_path,
            UPLOAD_DIR / f"{job_id}_prepared_{index}.png",
            selected_color=color,
            selected_size=size,
            selected_fit=fit,
        )
    except Exception as exc:
        return garment_path, {"preprocessed": False, "fallback": True, "error": f"{type(exc).__name__}: {str(exc)[:240]}"}


def _check_daily_limit(user: dict[str, Any]) -> None:
    if user["role"] != "user":
        return
    limit = int(store.get().get_config().get("daily_tryon_limit") or 0)
    if limit <= 0:
        return
    used = db.scalar("SELECT COUNT(*) FROM tryon_jobs WHERE user_id = ? AND created_at >= ?",
                     (user["id"], time.time() - 86400))
    if used >= limit:
        raise HTTPException(status_code=429, detail=f"Лимит {limit} примерок за сутки исчерпан. Попробуйте позже.")


async def _start_job(
    *,
    user: dict[str, Any],
    person_photo: UploadFile,
    items: list[dict[str, Any]],
    uploads: list[UploadFile],
    color: str,
    size: str,
    fit: str,
    gender: str,
    steps: int | None,
    seed: int | None,
    title: str,
    model: str = "fashn",
) -> dict[str, Any]:
    """items: [{"category", "photo_type", "label", "catalog_item_id"? | "upload_index"?}]"""
    if not items:
        raise HTTPException(status_code=422, detail="Добавь хотя бы одну вещь")
    if len(items) > MAX_OUTFIT_ITEMS:
        raise HTTPException(status_code=422, detail=f"Максимум {MAX_OUTFIT_ITEMS} вещи за одну примерку")
    _check_daily_limit(user)

    model = (model or "fashn").strip()
    if model in REMOVED_MODELS:  # older app versions still offer the Hugging Face models
        model = "fashn"
    if model not in MODEL_IDS:
        raise HTTPException(status_code=422, detail=f"Неизвестная модель: {model}")
    info = model_info(model)
    unsupported = [str(raw.get("category")) for raw in items if str(raw.get("category")) not in info["categories"]]
    if unsupported:
        raise HTTPException(
            status_code=422,
            detail=f"{info['title']} умеет только: {', '.join(categoryRu_py(c) for c in info['categories'])}. "
                   "Уберите лишние вещи или выберите другую модель.",
        )

    provider, online, _, status_error = await run_in_threadpool(resolve_provider, 10.0)
    if not online:
        raise HTTPException(
            status_code=503,
            detail=f"AI сервер недоступен. {status_error or ''} Запусти GPU-сервер на компьютере.",
        )

    job_id = new_id()
    person_bytes = await read_image_upload(person_photo, "Фото человека")
    person_path = UPLOAD_DIR / f"{job_id}_person{suffix_for(person_photo)}"
    person_path.write_bytes(person_bytes)
    bytes_in = len(person_bytes)

    prepared_items: list[dict[str, Any]] = []
    first_source = {"source_name": "", "source_url": ""}
    for index, raw in enumerate(items):
        category = str(raw.get("category") or "upper_body")
        photo_type = str(raw.get("photo_type") or "auto")
        if category not in VALID_CATEGORIES:
            raise HTTPException(status_code=422, detail="Invalid garment category")
        if photo_type not in GARMENT_PHOTO_TYPES:
            photo_type = "auto"

        if raw.get("catalog_item_id"):
            cat = _catalog_item(str(raw["catalog_item_id"]), user)
            category = str(cat.get("category") or category)
            garment_path = CATALOG_DIR / str(cat["file_name"])
            garment_url = str(cat["image_url"])
            label = str(raw.get("label") or cat.get("name") or categoryRu_py(category))
            if index == 0:
                first_source = {"source_name": str(cat.get("source_name") or ""), "source_url": str(cat.get("source_url") or "")}
        else:
            upload_index = int(raw.get("upload_index", -1))
            if not 0 <= upload_index < len(uploads):
                raise HTTPException(status_code=422, detail="garment photo is missing")
            upload = uploads[upload_index]
            garment_bytes = await read_image_upload(upload, "Фото вещи")
            garment_path = UPLOAD_DIR / f"{job_id}_garment{index}{suffix_for(upload)}"
            garment_path.write_bytes(garment_bytes)
            bytes_in += len(garment_bytes)
            garment_url = f"/uploads/{garment_path.name}"
            label = str(raw.get("label") or categoryRu_py(category))

        # Colour is chosen after the try-on now (/recolor); old app builds may still send one.
        item_color = color if len(items) == 1 else "Как на фото"
        prepared_path, prep = _prepare_garment(job_id, index, garment_path, item_color, size, fit)
        prepared_items.append({
            "category": category,
            "photo_type": photo_type,
            "label": label,
            "garment_url": garment_url,
            "prepared_path": prepared_path,
            "preprocessing": prep,
        })

    ordered = order_outfit(prepared_items)
    num_steps = _clamp_steps(steps, provider)
    used_seed = int(seed) if seed is not None and seed >= 0 else 42

    job = {
        "job_id": job_id,
        "user_id": user["id"],
        "status": "queued",
        "provider": provider,
        "model": model,
        "engine": info["title"],
        "category": ordered[-1]["category"] if len(ordered) == 1 else "outfit",
        "categories": sorted({it["category"] for it in ordered}),
        "garment_description": title or " + ".join(it["label"] for it in ordered),
        "created_at": utc_now_iso(),
        "created_ts": time.time(),
        "person_url": f"/uploads/{person_path.name}",
        "garment_url": ordered[0]["garment_url"],
        "items": [
            {"label": it["label"], "category": it["category"], "photo_type": it["photo_type"],
             "garment_url": it["garment_url"], "preprocessing": it["preprocessing"]}
            for it in ordered
        ],
        "total_steps": len(ordered),
        "step": 0,
        "step_label": None,
        "step_results": [],
        "num_timesteps": num_steps,
        "guidance": FASHN_GUIDANCE,
        "seed": used_seed,
        "gender": gender,
        "size": size,
        "fit": fit,
        "color": color,
        "source_name": first_source["source_name"],
        "source_url": first_source["source_url"],
        "result_url": None,
        "error": None,
        "gpu_seconds": 0.0,
        "recolors": 0,
        "_bytes_in": bytes_in,
    }
    with JOBS_LOCK:
        JOBS[job_id] = job
    persist_job(job)
    mirror_job(job)

    threading.Thread(
        target=run_outfit_job,
        args=(job_id, provider, person_path, ordered, num_steps, used_seed),
        daemon=True,
        name=f"fitme-{job_id}",
    ).start()
    return public_job(job)


def public_job(job: dict[str, Any]) -> dict[str, Any]:
    data = {k: v for k, v in job.items() if not k.startswith("_") and k != "user_id"}
    data["queue_position"] = queue_position(job) if job.get("status") == "queued" else 0
    return data


@app.post("/api/v1/try-on/upload")
async def create_try_on(
    request: Request,
    garment_description: str = Form("garment"),
    category: str = Form(...),
    selected_color: str = Form("Как на фото"),
    selected_size: str = Form("M"),
    selected_fit: str = Form("Regular"),
    selected_gender: str = Form("Унисекс"),
    garment_photo_type: str = Form("flat-lay"),
    num_steps: int | None = Form(None),
    seed: int | None = Form(None),
    person_photo: UploadFile = File(...),
    garment_photo: UploadFile | None = File(None),
    catalog_item_id: str | None = Form(None),
    model: str = Form("fashn"),
):
    """Single garment (kept for older app builds; body measurements are no longer used)."""
    item: dict[str, Any] = {"category": category, "photo_type": garment_photo_type, "label": garment_description}
    uploads: list[UploadFile] = []
    if catalog_item_id:
        item["catalog_item_id"] = catalog_item_id
    elif garment_photo is not None:
        uploads.append(garment_photo)
        item["upload_index"] = 0
    else:
        raise HTTPException(status_code=422, detail="garment_photo or catalog_item_id is required")
    return await _start_job(
        user=auth.require_user(request),
        person_photo=person_photo,
        items=[item],
        uploads=uploads,
        color=selected_color,
        size=selected_size,
        fit=selected_fit,
        gender=selected_gender,
        steps=num_steps,
        seed=seed,
        title=garment_description,
        model=model,
    )


@app.post("/api/v1/try-on/outfit")
async def create_outfit_try_on(
    request: Request,
    items: str = Form(...),
    selected_color: str = Form("Как на фото"),
    selected_size: str = Form("M"),
    selected_fit: str = Form("Regular"),
    selected_gender: str = Form(""),
    num_steps: int | None = Form(None),
    seed: int | None = Form(None),
    title: str = Form(""),
    model: str = Form("fashn"),
    person_photo: UploadFile = File(...),
    garment_photos: list[UploadFile] = File(default=[]),
):
    """Up to 3 garments put on one after another (bottoms → dresses → tops)."""
    try:
        parsed = json.loads(items)
        if not isinstance(parsed, list):
            raise ValueError("items must be a list")
    except Exception as exc:
        raise HTTPException(status_code=422, detail=f"Bad items JSON: {exc}") from exc
    return await _start_job(
        user=auth.require_user(request),
        person_photo=person_photo,
        items=parsed,
        uploads=garment_photos,
        color=selected_color,
        size=selected_size,
        fit=selected_fit,
        gender=selected_gender,
        steps=num_steps,
        seed=seed,
        title=title,
        model=model,
    )


def _own_job(job_id: str, user: dict[str, Any]) -> dict[str, Any] | None:
    job = load_job(job_id)
    if job is None:
        return None
    if job.get("user_id") != user["id"] and user["role"] not in ("admin", "owner"):
        return None
    return job


@app.get("/api/v1/try-on/{job_id}")
def get_try_on(job_id: str, request: Request):
    job = _own_job(job_id, auth.require_user(request))
    if job is None:
        return {"job_id": job_id, "status": "not_found"}
    return public_job(job)


# ---------------------------------------------------------------- re-colour after the try-on
@app.get("/api/v1/recolor/palette")
def recolor_palette():
    return {"items": [{"name": name, "hex": hex_} for name, hex_ in recolor_mod.PALETTE]}


def _segmentation_for(job: dict[str, Any], image_path: Path) -> np.ndarray:
    seg_path = GENERATED_DIR / f"{job['job_id']}_seg.png"
    if not seg_path.exists():
        workers = sorted(POOL.online(), key=lambda w: w.kind != "laptop")
        if not workers:
            raise HTTPException(status_code=503, detail="Для смены цвета нужен запущенный GPU-сервер")
        try:
            with image_path.open("rb") as fh:
                resp = httpx.post(f"{workers[0].url}/segment", headers=workers[0].headers,
                                  files={"image": (image_path.name, fh, image_mime(image_path))},
                                  timeout=httpx.Timeout(connect=10.0, read=180.0, write=60.0, pool=10.0))
        except Exception as exc:
            raise HTTPException(status_code=503, detail="GPU-сервер недоступен — запустите START_LOCAL_GPU.bat") from exc
        if resp.status_code != 200:
            raise HTTPException(status_code=503, detail=f"GPU-сервер не смог выделить одежду (HTTP {resp.status_code})")
        seg_path.write_bytes(resp.content)
    return np.asarray(Image.open(seg_path))


@app.post("/api/v1/try-on/{job_id}/recolor")
def recolor_result(job_id: str, payload: RecolorPayload, request: Request):
    """Paints the garment on the finished picture another colour (folds and shadows stay)."""
    user = auth.require_user(request)
    job = _own_job(job_id, user)
    if job is None or job.get("status") != "completed" or not job.get("result_url"):
        raise HTTPException(status_code=404, detail="Примерка не найдена или ещё не готова")
    original_url = str(job["result_url"])
    if payload.color.strip().lower() in ("original", "", "как на фото"):
        return {"url": original_url, "color": "original", "part": None}
    try:
        recolor_mod.parse_hex(payload.color)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail="Цвет нужен в виде #RRGGBB") from exc
    hex_ = payload.color.strip().lstrip("#").lower()

    image_path = GENERATED_DIR / original_url.rsplit("/", 1)[-1]
    if not image_path.exists():
        raise HTTPException(status_code=404, detail="Файл результата не найден")
    seg = _segmentation_for(job, image_path)
    present = recolor_mod.parts_present(seg)
    part = payload.part
    if part == "auto":
        cats = job.get("categories") or [job.get("category")]
        if "dresses" in cats:
            part = "dress"
        elif "upper_body" in cats and "upper" in present:
            part = "upper"
        elif present:
            part = present[0]
        else:
            part = "upper"
    if part not in recolor_mod.PART_LABELS:
        raise HTTPException(status_code=422, detail="part: upper, lower, dress или auto")

    out_name = f"{job_id}_c{hex_}_{part}.jpg"
    out_path = GENERATED_DIR / out_name
    if not out_path.exists():
        try:
            result = recolor_mod.recolor(Image.open(image_path), seg, part, hex_)
        except LookupError as exc:
            raise HTTPException(status_code=422, detail="Не нашёл эту вещь на фото — выберите другую часть") from exc
        result.save(out_path, format="JPEG", quality=93, subsampling=0)
    job["recolors"] = int(job.get("recolors") or 0) + 1
    db.execute("UPDATE tryon_jobs SET recolors = recolors + 1, bytes_out = bytes_out + ? WHERE job_id = ?",
               (out_path.stat().st_size, job_id))
    _mirror(lambda st: (st.increment_user(user["id"], {"recolors": 1}),
                        st.save_tryon(job_id, {"recolors": int(job["recolors"])})))
    return {"url": f"/generated/{out_name}", "color": f"#{hex_}", "part": part, "parts": present}


# ---------------------------------------------------------------- looks (per account)
@app.post("/api/v1/looks/save")
def save_look(payload: SaveLookPayload, request: Request):
    user = auth.require_user(request)
    job = _own_job(payload.job_id, user)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    if job.get("status") != "completed" or not job.get("result_url"):
        raise HTTPException(status_code=409, detail="Job is not completed")
    result_url = str(job["result_url"])
    if payload.result_url and payload.result_url != result_url:
        name = payload.result_url.rsplit("/", 1)[-1]
        if not (payload.result_url.startswith("/generated/") and name.startswith(f"{payload.job_id}_c")
                and (GENERATED_DIR / name).exists()):
            raise HTTPException(status_code=422, detail="Неизвестный вариант результата")
        result_url = payload.result_url

    st = store.get()
    existing = next((lk for lk in st.list_looks(user["id"])
                     if lk.get("job_id") == payload.job_id and lk.get("result_url") == result_url), None)
    if existing:
        return {"status": "already_saved", "look": existing}

    look = {
        "look_id": new_id(),
        "job_id": payload.job_id,
        "title": payload.title or job.get("garment_description") or "AI Look",
        "provider": job.get("provider"),
        "engine": job.get("engine"),
        "model": job.get("model") or "fashn",
        "num_timesteps": job.get("num_timesteps"),
        "category": job.get("category"),
        "created_at": utc_now_iso(),
        "person_url": job.get("person_url"),
        "garment_url": job.get("garment_url"),
        "source_name": job.get("source_name"),
        "source_url": job.get("source_url"),
        "gender": payload.gender or job.get("gender"),
        "size": payload.size or job.get("size"),
        "fit": payload.fit or job.get("fit"),
        "color": payload.color or ("Как на фото" if result_url == job.get("result_url") else None),
        "result_url": result_url,
        "items": job.get("items") or [],
        "total_steps": job.get("total_steps") or 1,
    }
    st.add_look(user["id"], look)
    st.increment_user(user["id"], {"looks_count": 1})
    auth.forget(user["id"])
    return {"status": "saved", "look": look}


@app.get("/api/v1/looks")
def get_looks(request: Request):
    user = auth.require_user(request)
    return {"items": store.get().list_looks(user["id"])}


@app.delete("/api/v1/looks/{look_id}")
def delete_look(look_id: str, request: Request):
    user = auth.require_user(request)
    st = store.get()
    if not st.delete_look(user["id"], look_id):
        raise HTTPException(status_code=404, detail="Look not found")
    st.increment_user(user["id"], {"looks_count": -1})
    auth.forget(user["id"])
    return {"status": "deleted", "look_id": look_id}
