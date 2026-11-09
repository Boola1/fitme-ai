"""Where accounts and user data live: Firebase (Authentication + Cloud Firestore).

Firestore layout (visible in the Firebase console):
  users/{uid}                 email, name, role, blocked, created_at, last_seen_at, counters
  users/{uid}/catalog/{id}    the user's garments (pictures stay on the laptop)
  users/{uid}/looks/{id}      saved looks
  tryons/{job_id}             one document per try-on (who, model, GPU seconds, status)
  config/app                  registration_open, daily_tryon_limit, owner_uid

The backend talks to Firebase with the Admin SDK and a service-account key
(backend/data/firebase-service-account.json, written by SETUP_FIREBASE.bat).
Tests use MemoryStore, which behaves the same without the internet.
"""
from __future__ import annotations

import copy
import json
import os
import threading
import time
from pathlib import Path
from typing import Any

DEFAULT_CONFIG: dict[str, Any] = {
    "registration_open": True,
    "daily_tryon_limit": 0,  # per client per day, 0 = no limit
    "owner_uid": "",
}


class NotConfigured(RuntimeError):
    """Firebase keys are not on this laptop yet."""


class TokenError(ValueError):
    """The sign-in token is invalid, expired or revoked."""


class Store:
    """Interface shared by FirestoreStore and MemoryStore."""

    project_id: str = ""

    # auth
    def verify_token(self, token: str) -> dict[str, Any]: ...
    def set_auth_disabled(self, uid: str, disabled: bool) -> None: ...
    def delete_auth_user(self, uid: str) -> None: ...
    # users
    def get_user(self, uid: str) -> dict[str, Any] | None: ...
    def create_user(self, uid: str, data: dict[str, Any]) -> None: ...
    def update_user(self, uid: str, fields: dict[str, Any]) -> None: ...
    def increment_user(self, uid: str, counters: dict[str, float]) -> None: ...
    def list_users(self) -> list[dict[str, Any]]: ...
    def delete_user_data(self, uid: str) -> None: ...
    # config
    def get_config(self) -> dict[str, Any]: ...
    def update_config(self, fields: dict[str, Any]) -> None: ...
    # catalog / looks / try-ons
    def list_catalog(self, uid: str) -> list[dict[str, Any]]: ...
    def get_catalog(self, uid: str, item_id: str) -> dict[str, Any] | None: ...
    def add_catalog(self, uid: str, item: dict[str, Any]) -> None: ...
    def delete_catalog(self, uid: str, item_id: str) -> None: ...
    def list_looks(self, uid: str) -> list[dict[str, Any]]: ...
    def add_look(self, uid: str, look: dict[str, Any]) -> None: ...
    def delete_look(self, uid: str, look_id: str) -> bool: ...
    def save_tryon(self, job_id: str, data: dict[str, Any]) -> None: ...


# ---------------------------------------------------------------- Firebase
def credentials_path(data_dir: Path) -> Path:
    inline = os.getenv("FITME_FIREBASE_CREDENTIALS_JSON", "").strip()
    if inline:  # cloud hosting: secrets come as environment variables, not files
        path = data_dir / "firebase-service-account.json"
        path.write_text(inline, encoding="utf-8")
        return path
    env = os.getenv("FITME_FIREBASE_CREDENTIALS", "").strip()
    return Path(env) if env else data_dir / "firebase-service-account.json"


class FirestoreStore(Store):
    def __init__(self, data_dir: Path):
        path = credentials_path(data_dir)
        if not path.exists():
            raise NotConfigured(f"нет файла {path.name}")
        import firebase_admin
        from firebase_admin import auth, credentials, firestore

        info = json.loads(path.read_text(encoding="utf-8"))
        self.project_id = str(info.get("project_id") or "")
        try:
            self.app = firebase_admin.get_app("fitme")
        except ValueError:
            self.app = firebase_admin.initialize_app(credentials.Certificate(str(path)), name="fitme")
        self.auth = auth
        self.firestore = firestore
        self.db = firestore.client(self.app)

    # auth ------------------------------------------------------------
    def verify_token(self, token: str) -> dict[str, Any]:
        try:
            return self.auth.verify_id_token(token, app=self.app, check_revoked=True, clock_skew_seconds=10)
        except self.auth.UserDisabledError as exc:
            raise TokenError("disabled") from exc
        except Exception as exc:  # expired, revoked, malformed, wrong project
            raise TokenError(type(exc).__name__) from exc

    def set_auth_disabled(self, uid: str, disabled: bool) -> None:
        self.auth.update_user(uid, disabled=disabled, app=self.app)
        if disabled:
            self.auth.revoke_refresh_tokens(uid, app=self.app)

    def delete_auth_user(self, uid: str) -> None:
        try:
            self.auth.delete_user(uid, app=self.app)
        except self.auth.UserNotFoundError:
            pass

    # users -----------------------------------------------------------
    def _user(self, uid: str):
        return self.db.collection("users").document(uid)

    def get_user(self, uid: str) -> dict[str, Any] | None:
        snap = self._user(uid).get()
        return ({"uid": uid} | snap.to_dict()) if snap.exists else None

    def create_user(self, uid: str, data: dict[str, Any]) -> None:
        self._user(uid).set(data)

    def update_user(self, uid: str, fields: dict[str, Any]) -> None:
        self._user(uid).set(fields, merge=True)

    def increment_user(self, uid: str, counters: dict[str, float]) -> None:
        inc = self.firestore.Increment
        self._user(uid).set({k: inc(v) for k, v in counters.items()}, merge=True)

    def list_users(self) -> list[dict[str, Any]]:
        return [{"uid": s.id} | s.to_dict() for s in self.db.collection("users").stream()]

    def delete_user_data(self, uid: str) -> None:
        ref = self._user(uid)
        for sub in ("catalog", "looks"):
            for snap in ref.collection(sub).stream():
                snap.reference.delete()
        ref.delete()

    # config ----------------------------------------------------------
    def get_config(self) -> dict[str, Any]:
        snap = self.db.collection("config").document("app").get()
        return DEFAULT_CONFIG | (snap.to_dict() or {})

    def update_config(self, fields: dict[str, Any]) -> None:
        self.db.collection("config").document("app").set(fields, merge=True)

    # catalog / looks / try-ons --------------------------------------
    def list_catalog(self, uid: str) -> list[dict[str, Any]]:
        items = [s.to_dict() for s in self._user(uid).collection("catalog").stream()]
        return sorted(items, key=lambda x: x.get("created_at", ""), reverse=True)

    def get_catalog(self, uid: str, item_id: str) -> dict[str, Any] | None:
        snap = self._user(uid).collection("catalog").document(item_id).get()
        return snap.to_dict() if snap.exists else None

    def add_catalog(self, uid: str, item: dict[str, Any]) -> None:
        self._user(uid).collection("catalog").document(item["item_id"]).set(item)

    def delete_catalog(self, uid: str, item_id: str) -> None:
        self._user(uid).collection("catalog").document(item_id).delete()

    def list_looks(self, uid: str) -> list[dict[str, Any]]:
        items = [s.to_dict() for s in self._user(uid).collection("looks").stream()]
        return sorted(items, key=lambda x: x.get("created_at", ""), reverse=True)

    def add_look(self, uid: str, look: dict[str, Any]) -> None:
        self._user(uid).collection("looks").document(look["look_id"]).set(look)

    def delete_look(self, uid: str, look_id: str) -> bool:
        ref = self._user(uid).collection("looks").document(look_id)
        if not ref.get().exists:
            return False
        ref.delete()
        return True

    def save_tryon(self, job_id: str, data: dict[str, Any]) -> None:
        self.db.collection("tryons").document(job_id).set(data, merge=True)


# ---------------------------------------------------------------- in memory (tests)
class MemoryStore(Store):
    """Same behaviour without Firebase. Tokens look like 'test:<uid>:<email>[:unverified]'."""

    project_id = "fitme-test"

    def __init__(self):
        self.lock = threading.Lock()
        self.users: dict[str, dict[str, Any]] = {}
        self.catalog: dict[str, dict[str, dict[str, Any]]] = {}
        self.looks: dict[str, dict[str, dict[str, Any]]] = {}
        self.tryons: dict[str, dict[str, Any]] = {}
        self.config: dict[str, Any] = {}
        self.disabled: set[str] = set()
        self.revoked: set[str] = set()
        self.deleted_auth: set[str] = set()

    def verify_token(self, token: str) -> dict[str, Any]:
        parts = token.split(":")
        if len(parts) < 3 or parts[0] != "test":
            raise TokenError("bad token")
        uid, email = parts[1], parts[2]
        if uid in self.disabled:
            raise TokenError("disabled")
        if uid in self.revoked or uid in self.deleted_auth:
            raise TokenError("revoked")
        return {"uid": uid, "email": email, "email_verified": "unverified" not in parts}

    def set_auth_disabled(self, uid: str, disabled: bool) -> None:
        (self.disabled.add if disabled else self.disabled.discard)(uid)

    def delete_auth_user(self, uid: str) -> None:
        self.deleted_auth.add(uid)

    def get_user(self, uid: str) -> dict[str, Any] | None:
        with self.lock:
            u = self.users.get(uid)
            return ({"uid": uid} | copy.deepcopy(u)) if u is not None else None

    def create_user(self, uid: str, data: dict[str, Any]) -> None:
        with self.lock:
            self.users[uid] = copy.deepcopy(data)

    def update_user(self, uid: str, fields: dict[str, Any]) -> None:
        with self.lock:
            self.users.setdefault(uid, {}).update(copy.deepcopy(fields))

    def increment_user(self, uid: str, counters: dict[str, float]) -> None:
        with self.lock:
            u = self.users.setdefault(uid, {})
            for k, v in counters.items():
                u[k] = u.get(k, 0) + v

    def list_users(self) -> list[dict[str, Any]]:
        with self.lock:
            return [{"uid": uid} | copy.deepcopy(u) for uid, u in self.users.items()]

    def delete_user_data(self, uid: str) -> None:
        with self.lock:
            self.users.pop(uid, None)
            self.catalog.pop(uid, None)
            self.looks.pop(uid, None)

    def get_config(self) -> dict[str, Any]:
        return DEFAULT_CONFIG | self.config

    def update_config(self, fields: dict[str, Any]) -> None:
        self.config.update(fields)

    def list_catalog(self, uid: str) -> list[dict[str, Any]]:
        items = list(copy.deepcopy(self.catalog.get(uid, {})).values())
        return sorted(items, key=lambda x: x.get("created_at", ""), reverse=True)

    def get_catalog(self, uid: str, item_id: str) -> dict[str, Any] | None:
        return copy.deepcopy(self.catalog.get(uid, {}).get(item_id))

    def add_catalog(self, uid: str, item: dict[str, Any]) -> None:
        self.catalog.setdefault(uid, {})[item["item_id"]] = copy.deepcopy(item)

    def delete_catalog(self, uid: str, item_id: str) -> None:
        self.catalog.get(uid, {}).pop(item_id, None)

    def list_looks(self, uid: str) -> list[dict[str, Any]]:
        items = list(copy.deepcopy(self.looks.get(uid, {})).values())
        return sorted(items, key=lambda x: x.get("created_at", ""), reverse=True)

    def add_look(self, uid: str, look: dict[str, Any]) -> None:
        self.looks.setdefault(uid, {})[look["look_id"]] = copy.deepcopy(look)

    def delete_look(self, uid: str, look_id: str) -> bool:
        return self.looks.get(uid, {}).pop(look_id, None) is not None

    def save_tryon(self, job_id: str, data: dict[str, Any]) -> None:
        self.tryons.setdefault(job_id, {}).update(copy.deepcopy(data))


# ---------------------------------------------------------------- the active store
_store: Store | None = None
_error: str | None = None


def init(data_dir: Path) -> None:
    global _store, _error
    if os.getenv("FITME_STORE") == "memory":
        _store, _error = MemoryStore(), None
        return
    try:
        _store, _error = FirestoreStore(data_dir), None
    except NotConfigured as exc:
        _store, _error = None, str(exc)
    except Exception as exc:  # broken key file, no internet at start, ...
        _store, _error = None, f"{type(exc).__name__}: {str(exc)[:200]}"
        print(f"[FitMe] Firebase is not available: {_error}")


def set_store(store: Store | None) -> None:
    global _store, _error
    _store, _error = store, None if store else "не настроен"


def get() -> Store:
    from fastapi import HTTPException

    if _store is None:
        raise HTTPException(status_code=503, detail=f"Firebase не подключён ({_error}). Запустите SETUP_FIREBASE.bat на ноутбуке.")
    return _store


def available() -> bool:
    return _store is not None


def status() -> dict[str, Any]:
    return {"configured": _store is not None, "project_id": _store.project_id if _store else "", "error": _error}


def now() -> float:
    return time.time()
