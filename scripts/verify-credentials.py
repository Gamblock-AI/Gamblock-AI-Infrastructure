#!/usr/bin/env python3
"""Validate production credentials without printing their values."""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import os
import re
import stat
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

import yaml
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.serialization import (
    Encoding,
    PublicFormat,
    load_der_private_key,
    load_der_public_key,
)


PROJECT_DIR = Path(__file__).resolve().parent.parent
VAULT_FILE = PROJECT_DIR / "group_vars/all/vault.yml"
VARS_FILE = PROJECT_DIR / "group_vars/all/vars.yml"
VAULT_EXAMPLE_FILE = PROJECT_DIR / "group_vars/all/vault.yml.example"
INVENTORY_FILE = PROJECT_DIR / "inventory/hosts.ini"
KNOWN_HOSTS_FILE = PROJECT_DIR / "inventory/known_hosts"
PLACEHOLDER = re.compile(r"replace|change-this|generate-with|example|todo", re.I)


class SafeCheckError(RuntimeError):
    """An expected validation failure whose message contains no secret value."""


def load_yaml(path: Path) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as handle:
            value = yaml.safe_load(handle)
    except (OSError, yaml.YAMLError) as exc:
        raise SafeCheckError(f"cannot read valid YAML from {path.relative_to(PROJECT_DIR)}") from exc
    if not isinstance(value, dict):
        raise SafeCheckError(f"{path.relative_to(PROJECT_DIR)} must contain a YAML mapping")
    return value


def load_vault() -> dict[str, Any]:
    try:
        first_line = VAULT_FILE.open(encoding="utf-8").readline().strip()
    except OSError as exc:
        raise SafeCheckError("group_vars/all/vault.yml is missing") from exc
    if not first_line.startswith("$ANSIBLE_VAULT;"):
        raise SafeCheckError("group_vars/all/vault.yml is not Ansible-Vault encrypted")
    try:
        result = subprocess.run(
            ["ansible-vault", "view", str(VAULT_FILE)],
            cwd=PROJECT_DIR,
            check=True,
            capture_output=True,
            text=True,
        )
        value = yaml.safe_load(result.stdout)
    except (OSError, subprocess.CalledProcessError, yaml.YAMLError) as exc:
        raise SafeCheckError("the encrypted vault cannot be opened with .vault_pass") from exc
    if not isinstance(value, dict):
        raise SafeCheckError("the decrypted vault must contain a YAML mapping")
    return value


def nested(values: dict[str, Any], path: str) -> Any:
    current: Any = values
    for part in path.split("."):
        if not isinstance(current, dict) or part not in current:
            return None
        current = current[part]
    return current


def clean_string(value: Any) -> str:
    return value if isinstance(value, str) else ""


def leaf_paths(values: dict[str, Any], prefix: str = "") -> set[str]:
    paths: set[str] = set()
    for key, value in values.items():
        path = f"{prefix}.{key}" if prefix else str(key)
        if isinstance(value, dict):
            paths.update(leaf_paths(value, path))
        else:
            paths.add(path)
    return paths


def decode_base64url(value: str) -> bytes:
    padding = "=" * ((4 - len(value) % 4) % 4)
    return base64.urlsafe_b64decode(value + padding)


def inventory_host() -> str:
    try:
        lines = INVENTORY_FILE.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise SafeCheckError("inventory/hosts.ini is unreadable") from exc
    hosts = [
        line.split()[0]
        for line in lines
        if line.strip() and not line.lstrip().startswith(("#", "["))
    ]
    if len(hosts) != 1:
        raise SafeCheckError("inventory must contain exactly one production host")
    return hosts[0]


def known_host_name(token: str) -> str:
    if token.startswith("[") and "]:" in token:
        return token[1:].split("]:", 1)[0]
    return token


def trusted_fingerprints(host: str) -> tuple[set[str], int]:
    try:
        rows = [
            line
            for line in KNOWN_HOSTS_FILE.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]
    except OSError as exc:
        raise SafeCheckError("inventory/known_hosts is unreadable") from exc
    current = [row for row in rows if known_host_name(row.split()[0]) == host]
    if not current:
        raise SafeCheckError("known_hosts must contain a key for the inventory host")
    fingerprints: set[str] = set()
    try:
        for row in current:
            result = subprocess.run(
                ["ssh-keygen", "-lf", "-", "-E", "sha256"],
                input=row + "\n",
                check=True,
                capture_output=True,
                text=True,
            )
            fingerprints.add(result.stdout.split()[1])
    except (OSError, subprocess.CalledProcessError, IndexError) as exc:
        raise SafeCheckError("cannot derive the trusted inventory host fingerprint") from exc
    return fingerprints, len(rows) - len(current)


def validate_mode(path: Path, errors: list[str], *, required: bool) -> None:
    if not path.exists():
        if required:
            errors.append(f"{path.name} is missing")
        return
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode & 0o077:
        errors.append(f"{path.name} must not be readable or writable by group/other")


def validate_offline(vault: dict[str, Any], variables: dict[str, Any]) -> list[str]:
    errors: list[str] = []

    validate_mode(PROJECT_DIR / ".vault_pass", errors, required=True)
    validate_mode(PROJECT_DIR / ".env", errors, required=False)
    validate_mode(VAULT_FILE, errors, required=True)

    try:
        example = load_yaml(VAULT_EXAMPLE_FILE)
        if leaf_paths(vault) != leaf_paths(example):
            errors.append("the encrypted vault schema does not match vault.yml.example")
    except SafeCheckError as exc:
        errors.append(str(exc))

    required_strings = (
        "vault_vps_password",
        "vault_github_registry_pat",
        "vault_postgres_password",
        "vault_gamblock_backend.jwt_access_secret",
        "vault_gamblock_backend.journal_encryption_key",
        "vault_gamblock_backend.protection_grant_signing_private_key",
        "vault_gamblock_backend.fonnte_token",
        "vault_gamblock_backend.fonnte_base_url",
        "vault_gamblock_backend.fonnte_country_code",
        "vault_vapid_private_key",
        "vault_cloudflare_api_token",
    )
    for path in required_strings:
        value = clean_string(nested(vault, path)).strip()
        if not value:
            errors.append(f"{path} is missing or empty")
        elif PLACEHOLDER.search(value):
            errors.append(f"{path} still contains a placeholder")

    vps_password = clean_string(nested(vault, "vault_vps_password"))
    if len(vps_password) < 12:
        errors.append("vault_vps_password must contain at least 12 characters")

    ghcr_pat = clean_string(nested(vault, "vault_github_registry_pat"))
    if ghcr_pat and not ghcr_pat.startswith(("ghp_", "github_pat_")):
        errors.append("vault_github_registry_pat has an unrecognized PAT format")

    postgres_password = clean_string(nested(vault, "vault_postgres_password"))
    if len(postgres_password) < 16:
        errors.append("vault_postgres_password must contain at least 16 characters")
    if postgres_password and not re.fullmatch(r"[A-Za-z0-9._~-]+", postgres_password):
        errors.append("vault_postgres_password is unsafe for the rendered DATABASE_URL")

    jwt_secret = clean_string(nested(vault, "vault_gamblock_backend.jwt_access_secret"))
    if len(jwt_secret) < 64:
        errors.append("vault_gamblock_backend.jwt_access_secret must contain at least 64 characters")

    journal_key = clean_string(nested(vault, "vault_gamblock_backend.journal_encryption_key"))
    if journal_key and not re.fullmatch(r"[A-Fa-f0-9]{64}", journal_key):
        errors.append("vault_gamblock_backend.journal_encryption_key must be 64 hexadecimal characters")

    grant_key_id = clean_string(variables.get("protection_grant_signing_key_id")).strip()
    grant_private = clean_string(
        nested(vault, "vault_gamblock_backend.protection_grant_signing_private_key")
    ).strip()
    trust_store_encoded = clean_string(
        variables.get("protection_grant_trust_store_base64")
    ).strip()
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", grant_key_id):
        errors.append("protection_grant_signing_key_id is invalid")
    try:
        private_der = base64.b64decode(grant_private, validate=True)
        private_key = load_der_private_key(private_der, password=None)
        if not isinstance(private_key, ec.EllipticCurvePrivateKey) or not isinstance(
            private_key.curve, ec.SECP256R1
        ):
            raise ValueError
        trust_store_raw = base64.b64decode(trust_store_encoded, validate=True)
        trust_store = json.loads(trust_store_raw.decode("utf-8"))
        if not isinstance(trust_store, dict) or not trust_store:
            raise ValueError
        for kid, public_der_encoded in trust_store.items():
            if not isinstance(kid, str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", kid):
                raise ValueError
            if not isinstance(public_der_encoded, str):
                raise ValueError
            public_key = load_der_public_key(
                base64.b64decode(public_der_encoded, validate=True)
            )
            if not isinstance(public_key, ec.EllipticCurvePublicKey) or not isinstance(
                public_key.curve, ec.SECP256R1
            ):
                raise ValueError
        expected_public = base64.b64encode(
            private_key.public_key().public_bytes(
                Encoding.DER, PublicFormat.SubjectPublicKeyInfo
            )
        ).decode("ascii")
        if trust_store.get(grant_key_id) != expected_public:
            errors.append(
                "the active protection-grant private key does not match its client trust-store entry"
            )
    except (binascii.Error, UnicodeDecodeError, json.JSONDecodeError, TypeError, ValueError):
        errors.append("the protection-grant key or public trust store is invalid")

    fonnte_url = clean_string(nested(vault, "vault_gamblock_backend.fonnte_base_url"))
    if fonnte_url.rstrip("/") != "https://api.fonnte.com":
        errors.append("vault_gamblock_backend.fonnte_base_url must use the official HTTPS API host")
    country_code = clean_string(nested(vault, "vault_gamblock_backend.fonnte_country_code"))
    if country_code and not re.fullmatch(r"[0-9]{1,3}", country_code):
        errors.append("vault_gamblock_backend.fonnte_country_code must contain 1-3 digits")

    spk_llm_enabled = variables.get("spk_llm_enrichment") is True
    deepseek_key = clean_string(nested(vault, "vault_gamblock_backend.deepseek_api_key")).strip()
    if spk_llm_enabled and not deepseek_key:
        errors.append("vault_gamblock_backend.deepseek_api_key is required while SPK LLM enrichment is enabled")
    if deepseek_key and PLACEHOLDER.search(deepseek_key):
        errors.append("vault_gamblock_backend.deepseek_api_key still contains a placeholder")
    if clean_string(variables.get("deepseek_base_url")).rstrip("/") != "https://api.deepseek.com":
        errors.append("deepseek_base_url must use the official HTTPS API host")
    if not clean_string(variables.get("deepseek_model")).strip():
        errors.append("deepseek_model is missing")

    public_value = clean_string(variables.get("vapid_public_key"))
    private_value = clean_string(nested(vault, "vault_vapid_private_key"))
    try:
        public_bytes = decode_base64url(public_value)
        private_bytes = decode_base64url(private_value)
        if len(public_bytes) != 65 or public_bytes[0] != 4:
            raise ValueError
        if len(private_bytes) != 32:
            raise ValueError
        derived = ec.derive_private_key(
            int.from_bytes(private_bytes, "big"), ec.SECP256R1()
        ).public_key().public_bytes(Encoding.X962, PublicFormat.UncompressedPoint)
        if derived != public_bytes:
            errors.append("the VAPID public and private keys do not form one P-256 pair")
    except (binascii.Error, ValueError, TypeError):
        errors.append("the VAPID keys are not valid base64url-encoded P-256 keys")

    subject = clean_string(variables.get("vapid_subject"))
    if not subject.startswith(("mailto:", "https://")):
        errors.append("vapid_subject must use mailto: or HTTPS")

    media_hosts = variables.get("media_embed_allowed_hosts")
    if not isinstance(media_hosts, list) or not media_hosts:
        errors.append("media_embed_allowed_hosts must be a non-empty list")
    elif any(
        not isinstance(host, str)
        or not re.fullmatch(r"[a-z0-9.-]+", host)
        or host.startswith((".", "-"))
        for host in media_hosts
    ):
        errors.append("media_embed_allowed_hosts contains an invalid hostname")

    try:
        host = inventory_host()
        fingerprints, stale_count = trusted_fingerprints(host)
        if stale_count:
            errors.append("inventory/known_hosts contains keys unrelated to the production host")
        if variables.get("vps_host_fingerprint") not in fingerprints:
            errors.append("vps_host_fingerprint does not match the committed production host key")
    except SafeCheckError as exc:
        errors.append(str(exc))

    return errors


def request_json(
    url: str,
    *,
    headers: dict[str, str] | None = None,
    data: bytes | None = None,
    method: str | None = None,
) -> tuple[int, dict[str, Any]]:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "gamblock-infrastructure-preflight", **(headers or {})},
        data=data,
        method=method,
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            raw = response.read()
            value = json.loads(raw.decode("utf-8")) if raw else {}
            return response.status, value if isinstance(value, dict) else {}
    except urllib.error.HTTPError as exc:
        exc.read()
        return exc.code, {}
    except (
        urllib.error.URLError,
        TimeoutError,
        UnicodeDecodeError,
        json.JSONDecodeError,
    ) as exc:
        raise SafeCheckError(f"provider request failed ({type(exc).__name__})") from exc


def verify_ghcr(vault: dict[str, Any], variables: dict[str, Any]) -> None:
    username = clean_string(variables.get("github_registry_username"))
    pat = clean_string(nested(vault, "vault_github_registry_pat"))
    basic = base64.b64encode(f"{username}:{pat}".encode()).decode()
    for image in ("gamblock-ai-backend", "gamblock-ai-website"):
        scope = urllib.parse.quote(f"repository:gamblock-ai/{image}:pull", safe=":")
        status, auth = request_json(
            f"https://ghcr.io/token?scope={scope}",
            headers={"Authorization": f"Basic {basic}"},
        )
        bearer = clean_string(auth.get("token"))
        if status != 200 or not bearer:
            raise SafeCheckError(f"GHCR did not grant pull access for {image}")
        manifest_request = urllib.request.Request(
            f"https://ghcr.io/v2/gamblock-ai/{image}/manifests/latest",
            headers={
                "Authorization": f"Bearer {bearer}",
                "Accept": (
                    "application/vnd.oci.image.index.v1+json,"
                    "application/vnd.oci.image.manifest.v1+json,"
                    "application/vnd.docker.distribution.manifest.v2+json"
                ),
                "User-Agent": "gamblock-infrastructure-preflight",
            },
        )
        try:
            with urllib.request.urlopen(manifest_request, timeout=20) as response:
                response.read(1)
                if response.status != 200:
                    raise SafeCheckError(f"GHCR latest manifest is unavailable for {image}")
        except urllib.error.HTTPError as exc:
            exc.read()
            raise SafeCheckError(f"GHCR latest manifest is unavailable for {image}") from exc
        except (urllib.error.URLError, TimeoutError) as exc:
            raise SafeCheckError(f"GHCR request failed for {image} ({type(exc).__name__})") from exc


def verify_cloudflare(vault: dict[str, Any], variables: dict[str, Any]) -> None:
    token = clean_string(nested(vault, "vault_cloudflare_api_token"))
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    status, result = request_json(
        "https://api.cloudflare.com/client/v4/user/tokens/verify", headers=headers
    )
    if (
        status != 200
        or result.get("success") is not True
        or nested(result, "result.status") != "active"
    ):
        raise SafeCheckError("the Cloudflare token is not active")
    zone = urllib.parse.urlencode({"name": clean_string(variables.get("cloudflare_zone_name"))})
    status, result = request_json(
        f"https://api.cloudflare.com/client/v4/zones?{zone}", headers=headers
    )
    zones = result.get("result") if isinstance(result.get("result"), list) else []
    if status != 200 or len(zones) != 1:
        raise SafeCheckError("the Cloudflare token cannot read the configured zone")


def verify_fonnte(vault: dict[str, Any]) -> None:
    token = clean_string(nested(vault, "vault_gamblock_backend.fonnte_token"))
    status, result = request_json(
        "https://api.fonnte.com/device",
        headers={"Authorization": token},
        data=b"",
        method="POST",
    )
    if status != 200 or result.get("status") is not True:
        raise SafeCheckError("the Fonnte token is invalid")
    if clean_string(result.get("device_status")).lower() != "connect":
        raise SafeCheckError("the Fonnte device is not connected")


def verify_deepseek(vault: dict[str, Any], variables: dict[str, Any]) -> None:
    if variables.get("spk_llm_enrichment") is not True:
        return
    key = clean_string(nested(vault, "vault_gamblock_backend.deepseek_api_key"))
    base_url = clean_string(variables.get("deepseek_base_url")).rstrip("/")
    status, result = request_json(
        f"{base_url}/models", headers={"Authorization": f"Bearer {key}"}
    )
    models = {
        clean_string(item.get("id"))
        for item in result.get("data", [])
        if isinstance(item, dict)
    }
    if status != 200 or clean_string(variables.get("deepseek_model")) not in models:
        raise SafeCheckError("the DeepSeek key cannot access the configured model")


def validate_online(vault: dict[str, Any], variables: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    checks = (
        ("GHCR", lambda: verify_ghcr(vault, variables)),
        ("Cloudflare", lambda: verify_cloudflare(vault, variables)),
        ("Fonnte", lambda: verify_fonnte(vault)),
        ("DeepSeek", lambda: verify_deepseek(vault, variables)),
    )
    for name, check in checks:
        try:
            check()
        except SafeCheckError as exc:
            errors.append(f"{name}: {exc}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--online",
        action="store_true",
        help="also validate read-only provider access",
    )
    args = parser.parse_args()

    try:
        variables = load_yaml(VARS_FILE)
        vault = load_vault()
    except SafeCheckError as exc:
        print(f"Credential check failed: {exc}", file=sys.stderr)
        return 1

    errors = validate_offline(vault, variables)
    if not errors and args.online:
        errors.extend(validate_online(vault, variables))

    if errors:
        for error in errors:
            print(f"Credential check failed: {error}", file=sys.stderr)
        return 1

    mode = "offline + providers" if args.online else "offline"
    print(f"Credential check passed ({mode}; secret values redacted).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
