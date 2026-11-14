import contextlib
import csv
import hashlib
import json
import pathlib
import shlex
import socket
import subprocess
import time
import urllib.error
import urllib.request

import pins

HARNESS = pathlib.Path(__file__).resolve().parent
ROOT = HARNESS.parent if (HARNESS.parent / "charts").is_dir() else pathlib.Path.home() / "stayup" / "tree"
TREE_PARTS = ("charts", "configuration/etcd_launch_files", "proto-files")
STEWARDS = ("server", "clientone", "clienttwo", "clientthree")
REQUEST_PATH = (
    ("api-gateway", "api-gateway"),
    ("orchestrator", "policy-enforcer"),
    ("orchestrator", "orchestrator"),
    ("server", "server"),
    ("clientone", "clientone"),
    ("clienttwo", "clienttwo"),
    ("clientthree", "clientthree"),
)
PLACEMENT = {
    ("api-gateway", "api-gateway"): "dynamos",
    ("orchestrator", "policy-enforcer"): "dynamos",
    ("orchestrator", "orchestrator"): "clienttwo",
    ("server", "server"): "server",
    ("clientone", "clientone"): "clientone",
    ("clienttwo", "clienttwo"): "clienttwo",
    ("clientthree", "clientthree"): "clientthree",
}
ACCOUNTS = ("dynamos1", "tamjiyan", "2bias123")
USER = "jake.jongejans@student.uva.nl"
REQUEST_TYPE = "vflTrainModelRequest"
KIND_CONTEXT = "kind-stayup"
KIND_ACCOUNT = "tamjiyan"
KIND_TAG = "stay-up-enforcement"
KIND_LINE = "kind mode: digest and placement gates not run; nothing here is counted"
NOT_ON_KIND = "not checkable on kind"
FORWARD_PORTS = {"api-gateway": 18080, "orchestrator": 18082}


class Failed(Exception):
    pass


class Void(Failed):
    pass


def run(argv, stdin=None, timeout=60, binary=False):
    shown = shlex.join(argv)[:200]
    try:
        done = subprocess.run(argv, input=stdin, capture_output=True, text=not binary, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise Failed(f"{shown}: no answer within {timeout} s") from None
    except OSError as error:
        raise Failed(f"{shown}: {error}") from None
    if done.returncode != 0:
        error = " ".join((done.stderr if not binary else done.stderr.decode(errors="replace")).split())
        if argv[0] == "ssh" and done.returncode == 255:
            raise Void(f"void ssh: {shown}: {error[-300:]}")
        raise Failed(f"{shown}: exit {done.returncode}: {error[-500:]}")
    return done.stdout


def kubectl(*args, **options):
    return run(["kubectl", *args], **options)


def kjson(*args, **options):
    return json.loads(kubectl(*args, "-o", "json", **options))


def until(what, seconds, probe, every=2):
    deadline = time.monotonic() + seconds
    while True:
        value = probe()
        if value:
            return value
        if time.monotonic() >= deadline:
            raise Failed(f"{what}: not within {seconds} s")
        time.sleep(every)


def tree_problem():
    listed = {row["path"]: row["sha256"] for row in csv.DictReader((HARNESS / "tree.csv").read_text().splitlines())}
    held = {}
    for part in TREE_PARTS:
        for path in (ROOT / part).rglob("*"):
            name = path.relative_to(ROOT).as_posix()
            if path.is_symlink() or not (path.is_dir() or path.is_file()):
                held[name] = "not a regular file"
            elif path.is_file():
                held[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    missing = sorted(set(listed) - set(held))
    extra = sorted(set(held) - set(listed))
    differ = sorted(name for name in set(listed) & set(held) if listed[name] != held[name])
    if not (missing or extra or differ):
        return None
    found = [f"{len(items)} {what}, first {items[0]}" for items, what in
             ((missing, "missing"), (extra, "not in tree.csv"), (differ, "differing")) if items]
    return f"the tree at {ROOT} is not the set's files of tree.csv: {'; '.join(found)}"


def nodes():
    found = {}
    for item in kjson("get", "nodes")["items"]:
        status = item["status"]
        found[item["metadata"]["name"]] = {
            "ip": next(a["address"] for a in status["addresses"] if a["type"] == "InternalIP"),
            "ready": any(c["type"] == "Ready" and c["status"] == "True" for c in status["conditions"]),
        }
    return found


def guard(mode):
    contexts = kubectl("config", "get-contexts", "-o", "name").split()
    current = kubectl("config", "current-context").strip()
    if mode == "kind":
        if contexts != [KIND_CONTEXT] or current != KIND_CONTEXT:
            raise Failed(f"kind mode needs a kubeconfig whose only context is {KIND_CONTEXT}; it holds {contexts}")
        return
    if any(name.startswith("kind-") for name in contexts):
        raise Failed(f"fabric mode on a kubeconfig with a kind context: {contexts}")
    missing = {"dynamos", *STEWARDS} - set(nodes())
    if missing:
        raise Failed(f"fabric mode needs the nodes dynamos and the four stewards; missing {sorted(missing)}")


def host(mode, vm):
    if mode == "kind" or vm == "control":
        return None
    return nodes()[vm]["ip"]


def on(target, argv):
    if target is None:
        return list(argv)
    return ["ssh", "-i", str(pathlib.Path.home() / ".ssh" / "slice_key"), "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR", "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10", target, shlex.join(argv)]


def pinned(path=pins.DEFAULT):
    return {row["name"]: row for row in pins.load(path)}


def image(mode, name):
    if mode == "kind":
        return f"{KIND_ACCOUNT}/{name}:{KIND_TAG}"
    row = pinned()[name]
    return f"{row['repository']}@{row['digest']}"


def parse_image(reference):
    reference = reference.removeprefix("docker.io/")
    if "@" in reference:
        repository, tag = reference.split("@", 1)[0], ""
    else:
        repository, _, tag = reference.partition(":")
    account, _, name = repository.partition("/")
    return account, name, tag


def listening(port):
    with socket.socket() as probe:
        probe.settimeout(1)
        return probe.connect_ex(("127.0.0.1", port)) == 0


@contextlib.contextmanager
def service(mode, name):
    if mode == "fabric":
        found = kjson("-n", name, "get", "svc", name)
        if found["spec"]["type"] != "NodePort":
            kubectl("-n", name, "patch", "svc", name, "-p", '{"spec":{"type":"NodePort"}}')
            found = kjson("-n", name, "get", "svc", name)
        address = next(iter(nodes().values()))["ip"]
        yield f"http://{address}:{found['spec']['ports'][0]['nodePort']}"
        return
    port = FORWARD_PORTS[name]
    if listening(port):
        raise Failed(f"local port {port} is already in use")
    forward = subprocess.Popen(
        ["kubectl", "-n", name, "port-forward", f"svc/{name}", f"{port}:8080"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        until(f"port-forward to {name} on {port}", 20, lambda: listening(port) or forward.poll() is not None, every=0.2)
        if forward.poll() is not None:
            raise Failed(f"port-forward to {name} on {port} ended with exit {forward.returncode}")
        yield f"http://127.0.0.1:{port}"
    finally:
        forward.terminate()
        try:
            forward.wait(timeout=10)
        except subprocess.TimeoutExpired:
            forward.kill()


def http(method, url, body=None, timeout=30):
    request = urllib.request.Request(url, data=body, method=method, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode(errors="replace")
    except OSError as error:
        return 0, str(error)
