"""Exercise a disposable seqpoint-gateway:1 Docker image with two real app services."""
import argparse
import base64
import os
import re
import secrets
import socket
import ssl
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


def docker(*args, env=None):
    return subprocess.check_output(["docker", *args], text=True, env=env).strip()


def issue_invite(admin, password):
    auth = base64.b64encode(("admin:" + password).encode()).decode()
    request = urllib.request.Request(admin, data=b"action=invite",
                                     headers={"Authorization": "Basic " + auth})
    with urllib.request.urlopen(request, timeout=5) as response:
        page = response.read().decode()
    return re.search(r'https?://[^"]+/invite#gw\.[0-9a-f]{64}', page).group()


def wait_ready(origin, cert):
    context = ssl.create_default_context(cafile=str(cert))
    for _ in range(50):
        try:
            with urllib.request.urlopen(origin + "/invite", context=context, timeout=1):
                return
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("Gateway did not start")


def verify(use_http=False):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    scheme = "http" if use_http else "https"
    origin = f"{scheme}://127.0.0.1:{port}"
    password = secrets.token_hex(24)
    env = dict(os.environ, GATEWAY_ORIGIN=origin, GATEWAY_ADMIN_PASSWORD=password)
    with tempfile.TemporaryDirectory() as tmp:
        tls = Path(tmp) / "tls"
        tls.mkdir(mode=0o755)
        cert, key = tls / "cert.pem", tls / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-subj", "/CN=localhost", "-addext", "subjectAltName=IP:127.0.0.1",
                        "-days", "1", "-keyout", str(key), "-out", str(cert)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        key.chmod(0o644)  # The parent temporary directory is private; the container runs as 65532.
        tls_args = [] if use_http else ["-tls-cert", "/tls/cert.pem", "-tls-key", "/tls/key.pem"]
        container = docker("run", "-d", "--read-only", "--cap-drop", "ALL",
                           "-e", "GATEWAY_ORIGIN", "-e", "GATEWAY_ADMIN_PASSWORD",
                           "-e", "GATEWAY_ADMIN_LISTEN=:8081", "-v", "/data",
                           "-v", f"{tls}:/tls:ro", "-p", f"127.0.0.1:{port}:8080",
                           "-p", "127.0.0.1::8081", "seqpoint-gateway:1", "-gateway",
                           *tls_args, env=env)
        try:
            wait_ready(origin, cert)
            admin = "http://" + docker("port", container, "8081/tcp") + "/"
            env.update(SEQPOINT_TEST_GATEWAY_LINK=issue_invite(admin, password),
                       SEQPOINT_TEST_GATEWAY_PEM=str(cert), SEQPOINT_TEST_GATEWAY_ADMIN=admin,
                       SEQPOINT_TEST_GATEWAY_PASSWORD=password)
            subprocess.run(["flutter", "test", "--no-pub", "--reporter", "expanded",
                            "test/app_sync_service_test.dart", "--plain-name",
                            "gateway invitation enrolls"], check=True, env=env,
                           cwd=REPO / "apps/seqpoint_app")
        finally:
            docker("rm", "-fv", container)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--http", action="store_true", help="Exercise a plaintext HTTP gateway")
    verify(parser.parse_args().http)
