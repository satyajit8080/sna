#!/usr/bin/env python3
"""
Validates SnapCal.xcodeproj without Xcode.

Parses project.pbxproj as OpenStep plist and checks the things that actually
break a CI build: dangling object references, files listed in build phases that
do not exist on disk, missing shared scheme, and Swift sources that exist in the
repo but were never added to a target.

    python3 ios/tools/validate_xcodeproj.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PBX = ROOT / "SnapCal.xcodeproj" / "project.pbxproj"


# ── minimal OpenStep plist parser ────────────────────────────────────────────
class Parser:
    def __init__(self, text):
        self.s = text
        self.i = 0

    def ws(self):
        while self.i < len(self.s):
            c = self.s[self.i]
            if c in " \t\r\n":
                self.i += 1
            elif self.s.startswith("//", self.i):
                self.i = self.s.find("\n", self.i) + 1 or len(self.s)
            elif self.s.startswith("/*", self.i):
                self.i = self.s.find("*/", self.i) + 2
            else:
                return

    def parse(self):
        self.ws()
        return self.value()

    def value(self):
        self.ws()
        c = self.s[self.i]
        if c == "{":
            return self.dict()
        if c == "(":
            return self.array()
        if c == '"':
            return self.quoted()
        return self.bare()

    def dict(self):
        self.i += 1
        out = {}
        while True:
            self.ws()
            if self.s[self.i] == "}":
                self.i += 1
                return out
            key = self.value()
            self.ws()
            assert self.s[self.i] == "=", f"expected = at {self.i}"
            self.i += 1
            out[key] = self.value()
            self.ws()
            if self.s[self.i] == ";":
                self.i += 1

    def array(self):
        self.i += 1
        out = []
        while True:
            self.ws()
            if self.s[self.i] == ")":
                self.i += 1
                return out
            out.append(self.value())
            self.ws()
            if self.s[self.i] == ",":
                self.i += 1

    def quoted(self):
        self.i += 1
        buf = []
        while self.s[self.i] != '"':
            if self.s[self.i] == "\\":
                self.i += 1
            buf.append(self.s[self.i])
            self.i += 1
        self.i += 1
        return "".join(buf)

    def bare(self):
        start = self.i
        while self.s[self.i] not in " \t\r\n;,=(){}":
            self.i += 1
        return self.s[start:self.i]


errors, warnings = [], []


def fail(msg):
    errors.append(msg)


def warn(msg):
    warnings.append(msg)


if not PBX.exists():
    print(f"FAIL: {PBX} does not exist")
    sys.exit(1)

raw = PBX.read_text()
root = Parser(raw).parse()
objects = root["objects"]

print(f"parsed {len(objects)} objects, objectVersion={root.get('objectVersion')}")

# ── 1. every referenced ID exists ────────────────────────────────────────────
ID_RE = re.compile(r"^[0-9A-F]{24}$")


def scan_refs(node, path="root"):
    if isinstance(node, dict):
        for k, v in node.items():
            scan_refs(v, f"{path}.{k}")
    elif isinstance(node, list):
        for idx, v in enumerate(node):
            scan_refs(v, f"{path}[{idx}]")
    elif isinstance(node, str) and ID_RE.match(node):
        if node not in objects:
            fail(f"dangling object reference {node} at {path}")


for oid, obj in objects.items():
    scan_refs(obj, f"objects.{oid}({obj.get('isa')})")

if root["rootObject"] not in objects:
    fail("rootObject does not resolve")

# ── 2. structural sanity ─────────────────────────────────────────────────────
by_isa = {}
for oid, obj in objects.items():
    by_isa.setdefault(obj.get("isa"), []).append((oid, obj))

expected_counts = {
    "PBXProject": 1,
    "PBXNativeTarget": 3,
    "PBXSourcesBuildPhase": 3,
    "PBXResourcesBuildPhase": 3,
    "PBXFrameworksBuildPhase": 3,
    "PBXTargetDependency": 2,
    "PBXContainerItemProxy": 2,
    "XCConfigurationList": 4,
    "XCBuildConfiguration": 8,
}
for isa, want in expected_counts.items():
    got = len(by_isa.get(isa, []))
    if got != want:
        fail(f"expected {want} {isa}, found {got}")

project = by_isa["PBXProject"][0][1]
targets = {objects[t]["name"]: objects[t] for t in project["targets"]}
for name in ("SnapCal", "SnapCalTests", "SnapCalUITests"):
    if name not in targets:
        fail(f"missing target {name}")

# ── 3. resolve group paths, confirm every build file exists on disk ──────────
group_parent = {}
for oid, obj in objects.items():
    if obj.get("isa") == "PBXGroup":
        for child in obj.get("children", []):
            group_parent[child] = oid


def resolve(ref_id):
    """Walks the group tree upward to build a real filesystem path."""
    parts = []
    node = ref_id
    seen = set()
    while node and node not in seen:
        seen.add(node)
        obj = objects.get(node, {})
        p = obj.get("path")
        if p:
            parts.append(p)
        node = group_parent.get(node)
    return ROOT / Path(*reversed(parts)) if parts else None


file_refs = {oid for oid, o in objects.items() if o.get("isa") == "PBXFileReference"}
referenced_paths = set()

for oid, obj in objects.items():
    if obj.get("isa") != "PBXBuildFile":
        continue
    ref = obj.get("fileRef")
    if ref not in file_refs:
        fail(f"PBXBuildFile {oid} points at non-file {ref}")
        continue
    path = resolve(ref)
    if path is None:
        fail(f"could not resolve path for fileRef {ref}")
    elif not path.exists():
        fail(f"build file missing on disk: {path.relative_to(ROOT)}")
    else:
        referenced_paths.add(path.resolve())

# ── 4. no Swift source left out of a target ──────────────────────────────────
for swift in sorted(ROOT.rglob("*.swift")):
    if ".xcodeproj" in str(swift) or "/tools/" in str(swift):
        continue
    if swift.resolve() not in referenced_paths:
        fail(f"Swift file not in any target: {swift.relative_to(ROOT)}")

# ── 5. build settings that decide whether CI works ───────────────────────────
def settings_for(target_name):
    t = targets[target_name]
    cl = objects[t["buildConfigurationList"]]
    return {objects[c]["name"]: objects[c]["buildSettings"] for c in cl["buildConfigurations"]}


app = settings_for("SnapCal")
for conf in ("Debug", "Release"):
    s = app[conf]
    if s.get("PRODUCT_BUNDLE_IDENTIFIER") != "app.snapcal.ios":
        fail(f"{conf}: wrong bundle id {s.get('PRODUCT_BUNDLE_IDENTIFIER')}")
    if "SnapCal.entitlements" not in s.get("CODE_SIGN_ENTITLEMENTS", ""):
        fail(f"{conf}: entitlements not wired")
    if s.get("GENERATE_INFOPLIST_FILE") != "NO":
        fail(f"{conf}: GENERATE_INFOPLIST_FILE must be NO when INFOPLIST_FILE is set")

proj_cl = objects[project["buildConfigurationList"]]
for c in proj_cl["buildConfigurations"]:
    conf = objects[c]
    if "baseConfigurationReference" not in conf:
        fail(f"project {conf['name']} config has no xcconfig attached")
    else:
        xc = resolve(conf["baseConfigurationReference"])
        if not xc or not xc.exists():
            fail(f"xcconfig missing: {xc}")

tests = settings_for("SnapCalTests")["Release"]
if "TEST_HOST" not in tests:
    fail("unit test target has no TEST_HOST")
uitests = settings_for("SnapCalUITests")["Release"]
if uitests.get("TEST_TARGET_NAME") != "SnapCal":
    fail("UI test target TEST_TARGET_NAME not set")

# ── 6. shared scheme (CI cannot see user schemes) ────────────────────────────
scheme = ROOT / "SnapCal.xcodeproj" / "xcshareddata" / "xcschemes" / "SnapCal.xcscheme"
if not scheme.exists():
    fail("no shared scheme — `xcodebuild -scheme SnapCal` will fail on CI")
else:
    text = scheme.read_text()
    app_target_id = [oid for oid, o in objects.items()
                     if o.get("isa") == "PBXNativeTarget" and o.get("name") == "SnapCal"][0]
    if app_target_id not in text:
        fail("scheme references a stale target ID")
    if 'buildConfiguration = "Release"' not in text:
        fail("scheme ArchiveAction is not Release")
    # An empty <TestPlans/> makes xcodebuild report
    # "Scheme is not currently configured for the test action".
    if "<TestPlans>" in text:
        fail("scheme has an empty TestPlans block — test action will not run")
    for t in ("SnapCalTests", "SnapCalUITests"):
        if f'BlueprintName = "{t}"' not in text:
            fail(f"scheme TestAction does not reference {t}")
    test_ids = {oid for oid, o in objects.items()
                if o.get("isa") == "PBXNativeTarget" and o.get("name", "").endswith("Tests")}
    for tid in test_ids:
        if tid not in text:
            fail(f"scheme references a stale test target ID for {objects[tid]['name']}")

# ── 7. secrets must not be in the app bundle ─────────────────────────────────
# Matches key-shaped *literals*, not mentions of the names — the test target
# deliberately references OPENAI_API_KEY to assert it is absent.
SECRET_LITERALS = [
    re.compile(r'"sk-[A-Za-z0-9_\-]{16,}"'),          # OpenAI
    re.compile(r'"AIza[A-Za-z0-9_\-]{30,}"'),         # Google
    re.compile(r'"postgres(ql)?://[^"]+:[^"@]+@'),    # DB URL with password
    re.compile(r'-----BEGIN [A-Z ]*PRIVATE KEY-----'),
]
for f in ROOT.rglob("*"):
    if f.is_file() and f.suffix in {".swift", ".plist", ".xcconfig", ".entitlements"}:
        body = f.read_text(errors="ignore")
        for pattern in SECRET_LITERALS:
            if pattern.search(body):
                fail(f"secret literal matching {pattern.pattern} in {f.relative_to(ROOT)}")

# The release config must not ship a localhost or plaintext API URL.
# @testable import requires ENABLE_TESTABILITY in the configuration the tests
# run under, and it must NOT be on in Release.
debug_xc = (ROOT / "Config" / "Debug.xcconfig").read_text()
if "ENABLE_TESTABILITY = YES" not in debug_xc:
    fail("Debug.xcconfig lacks ENABLE_TESTABILITY=YES — @testable import will fail")

release_xc = (ROOT / "Config" / "Release.xcconfig").read_text()
if "ENABLE_TESTABILITY = YES" in release_xc:
    fail("Release.xcconfig enables testability — remove it before shipping")
if "localhost" in release_xc:
    fail("Release.xcconfig points at localhost")
if "API_SCHEME = https" not in release_xc:
    fail("Release.xcconfig is not HTTPS")

# ── report ───────────────────────────────────────────────────────────────────
for w in warnings:
    print(f"warn  {w}")
for e in errors:
    print(f"FAIL  {e}")

print(f"\n{len(referenced_paths)} files wired into targets")
print("RESULT:", "PASS" if not errors else f"FAIL ({len(errors)} problems)")
sys.exit(1 if errors else 0)
