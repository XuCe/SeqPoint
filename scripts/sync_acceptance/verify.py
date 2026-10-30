"""Verify a completed native run; emit only non-secret acceptance evidence."""
import json
import hashlib
import pathlib
import sys
import urllib.request


def main():
    with open(sys.argv[1]) as source:
        base = json.load(source)["control"]

    def get(key):
        with urllib.request.urlopen(base + "/" + key, timeout=10) as response:
            return json.load(response)

    status = get("status")
    for key in ["background-no-network", "phone-resumed-and-synced",
                "desktop-complete", "phone-complete"]:
        assert get(key) is True, key
    expected = {}
    for role, name, minimum in [("desktop", "large.m4a", 40 * 1024 * 1024),
                                ("phone", "large.png", 18 * 1024 * 1024)]:
        data = pathlib.Path(sys.argv[1]).resolve().with_name(name).read_bytes()
        assert len(data) >= minimum, name + " must exercise large transfers"
        expected[role] = len(data), hashlib.sha256(data).hexdigest()
    summary = {"scope": "native macOS + iOS simulator, local HTTPS gateways",
               "backgroundSeconds": 70, "resumedAndSynced": True, "devices": {}}
    for role, (size, digest) in expected.items():
        assert get(role + "-text-ready") is True, role + " text"
        result, metrics = get(role + "-files-ready"), status["metrics"][role]
        assert (result["receivedBytes"], result["sha256"]) == (size, digest), role
        downloads = {k: v for k, v in metrics["complete"].items() if k.startswith("GET blobs/")}
        assert downloads and all(v == 1 for v in downloads.values()), role + " duplicate GET"
        assert metrics["faults"] == (1 if role == "phone" else 0), role + " fault count"
        if role == "phone":
            assert "GET " + metrics["interruptedPath"] in downloads, "interrupted block recovered"
        summary["devices"][role] = {**result, "successfulBlobDownloads": len(downloads),
                                   "duplicateSuccessfulDownloads": 0, "faults": metrics["faults"],
                                   "completedResponseBytes": metrics["bytes"]}
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
