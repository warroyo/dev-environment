#!/usr/bin/env python3
"""Print a Cloud Foundry access token for the deployer account, for use in $(...).

Signs a private_key_jwt client assertion with the key in the Hub OAuth app's
client assertion secret, and trades it at the foundation UAA for a
client-credentials token. Reads ~/.lab.env. Writes only the token to stdout,
so never run it bare: capture it.

    CF_ACCESS_TOKEN=$(~/.claude/skills/lab-creds/cf-token.py)
    cf-token.py --check     # prints the token's scopes and the org names, no token

The assertion file is base64url text. It decodes to JSON with oauthAppId,
header (ES256 and kid), privateKey (PEM with literal \\n) and aud. Its aud is
Hub's issuer. The foundation refuses that aud and wants its own token URL.
"""
import base64
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils


def lab_env():
    path = os.environ.get("LAB_ENV", os.path.expanduser("~/.lab.env"))
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k] = v.strip().strip('"')
    return env


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def main():
    env = lab_env()
    token_url = env["CF_UAA_TOKEN_URL"]
    raw = open(os.path.expanduser(env["CF_CLIENT_ASSERTION_FILE"])).read().strip()
    raw += "=" * (-len(raw) % 4)
    decoded = base64.urlsafe_b64decode(raw).decode("latin-1")
    blob = json.loads(decoded[decoded.index("{"):])
    client_id = blob["oauthAppId"]
    key = serialization.load_pem_private_key(blob["privateKey"].replace("\\n", "\n").encode(), password=None)

    now = int(time.time())
    claims = {"iss": client_id, "sub": client_id, "aud": token_url,
              "jti": str(uuid.uuid4()), "iat": now, "exp": now + 300}
    signing_input = (b64(json.dumps(blob["header"]).encode()) + "." + b64(json.dumps(claims).encode())).encode()
    r, s = utils.decode_dss_signature(key.sign(signing_input, ec.ECDSA(hashes.SHA256())))
    assertion = signing_input.decode() + "." + b64(r.to_bytes(32, "big") + s.to_bytes(32, "big"))

    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE  # lab certificates are self-signed
    form = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "client_id": client_id,
        "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
        "client_assertion": assertion,
    }).encode()
    req = urllib.request.Request(token_url, form, {"Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=20) as resp:
            token = json.load(resp)["access_token"]
    except urllib.error.HTTPError as e:
        body = json.load(e) if e.headers.get_content_type() == "application/json" else {}
        sys.exit(f"token request refused: {e.code} {body.get('error', '')} {body.get('error_description', '')}")

    if "--check" in sys.argv:
        payload = json.loads(base64.urlsafe_b64decode(token.split(".")[1] + "=="))
        print("client:", payload.get("client_id"), "| expires in:", payload["exp"] - int(time.time()), "s")
        print("scopes:", " ".join(sorted(payload.get("scope", []))))
        req = urllib.request.Request(env["CF_API_URL"] + "/v3/organizations", headers={"Authorization": "bearer " + token})
        with urllib.request.urlopen(req, context=ctx, timeout=20) as resp:
            print("orgs:", [o["name"] for o in json.load(resp)["resources"]])
    else:
        print(token)


if __name__ == "__main__":
    main()
