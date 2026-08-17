#!/usr/bin/env python3
"""
Static checks for the Swift sources.

Covers the failure classes that have actually reached a build in this project:
unbalanced delimiters, `dismiss()` without a declaration, `$0` inside an
explicit-argument closure, Decimal-times-integer, and fabricated food data on a
production surface.

    python3 ios/tools/lint_swift.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = sorted((ROOT / "SnapCal").rglob("*.swift"))
TESTS = sorted((ROOT / "SnapCalTests").rglob("*.swift")) + \
        sorted((ROOT / "SnapCalUITests").rglob("*.swift"))

# The onboarding animation is an explicit, labelled product demo shown before
# sign-in. It never mixes with user data, so it is the one sanctioned place a
# food name may be hardcoded.
DEMO_EXEMPT = {"WelcomeView.swift"}

FOODS = ["rajma", "fish curry", "grilled chicken", "dal tadka",
         "roti", "paneer", "biryani", "poha", "idli"]

failures: list[str] = []


def fail(msg: str) -> None:
    failures.append(msg)


def check_delimiters(path: Path, src: str) -> None:
    for open_ch, close_ch, name in (("{", "}", "braces"),
                                    ("(", ")", "parens"),
                                    ("[", "]", "brackets")):
        if src.count(open_ch) != src.count(close_ch):
            fail(f"{path.name}: unbalanced {name}")


def check_dismiss(path: Path, src: str) -> None:
    """`dismiss()` needs an @Environment declaration in the *same* struct."""
    for match in re.finditer(r"struct (\w+): View \{", src):
        start = match.end()
        nxt = src.find("\nstruct ", start)
        block = src[start: nxt if nxt > 0 else len(src)]
        if "dismiss()" in block and "private var dismiss" not in block:
            fail(f"{path.name}: {match.group(1)} calls dismiss() without declaring it")


def check_closures(path: Path, src: str) -> None:
    for i, line in enumerate(src.split("\n"), 1):
        if re.search(r"\{\s*\w+\s+in\b", line) and "$0" in line.split("in", 1)[-1]:
            fail(f"{path.name}:{i}: $0 inside an explicit-argument closure")
        if re.search(r"\.price\s*[*/]\s*\d+\b", line):
            fail(f"{path.name}:{i}: Decimal price mixed with an integer literal")


def check_import_placement(path: Path, src: str) -> None:
    """
    `import` may only appear before the first declaration.

    A stray `import` appended to the end of a file — the usual result of a
    paste landing after the closing brace — is a syntax error the compiler
    reports as "consecutive statements on a line", which reads as unrelated to
    the real problem.
    """
    lines = src.split("\n")
    first_decl = None
    for i, line in enumerate(lines):
        if re.match(r"^\s*(struct|class|enum|extension|func|@main|actor|protocol)\b", line):
            first_decl = i
            break
    if first_decl is None:
        return

    for i, line in enumerate(lines[first_decl:], start=first_decl + 1):
        if re.match(r"^\s*@?\w*\s*import\s+\w", line) and "//" not in line.split("import")[0]:
            fail(f"{path.name}:{i}: import after the first declaration — "
                 f"almost always a paste landing past the end of the file")

    # Anything glued to the final closing brace.
    if re.search(r"\}\s*import\s", src):
        fail(f"{path.name}: `import` glued to a closing brace")


def check_swiftui_import(path: Path, src: str) -> None:
    if "View {" in src and "import SwiftUI" not in src:
        fail(f"{path.name}: uses View without importing SwiftUI")


def check_no_fabricated_food(path: Path, src: str) -> None:
    """
    No production surface may hardcode a food with a calorie figure.

    Fabricated meals are indistinguishable from real ones on screen — this is
    exactly how foods nobody logged ended up on the Home screen.
    """
    if path.name in DEMO_EXEMPT:
        return
    for i, line in enumerate(src.split("\n"), 1):
        low = line.lower()
        hit = next((food for food in FOODS if food in low), None)
        if not hit:
            continue
        if not re.search(r"\b\d{2,4}\b", line):
            continue
        if "//" in line[: low.find(hit)]:       # a comment, not code
            continue
        fail(f"{path.name}:{i}: hardcoded food with a number on a production surface")


BACKEND_INPUT_METHODS = {"photo", "text", "voice", "barcode", "search", "manual"}


def check_input_method_contract() -> None:
    """
    Every value LogMode.inputMethod can produce must exist in the backend's
    `input_method` enum. A mismatch here rejected every camera scan with a 400
    that surfaced as "Something went wrong".
    """
    flow = (ROOT / "SnapCal/Features/Scan/LogFlowView.swift").read_text()
    block = flow[flow.find("var inputMethod: String {"):]
    block = block[: block.find("\n    }")]
    produced = set(re.findall(r'"(\w+)"', block))

    unknown = produced - BACKEND_INPUT_METHODS
    if unknown:
        fail(f"LogFlowView: input_method values the backend rejects: {sorted(unknown)}")

    # The raw case name must never be sent; `camera` is not a backend value.
    if re.search(r'method:\s*route\.mode\.rawValue', flow):
        fail("LogFlowView: sends the raw LogMode case as input_method")

    schema = (ROOT.parent / "backend/src/routes/log.ts").read_text()
    match = re.search(r'input_method: z\.enum\(\[(.*?)\]\)', schema, re.S)
    if match:
        backend = set(re.findall(r'"(\w+)"', match.group(1)))
        if backend != BACKEND_INPUT_METHODS:
            fail(f"backend input_method enum changed to {sorted(backend)} — update the client")


def check_exhaustive_switches() -> None:
    """
    A `switch` over an app enum must handle every case or have a default.

    Adding an enum case and missing one switch is a compile error that only
    appears on a macOS runner — cheap to catch here.
    """
    for path in APP:
        src = path.read_text()

        for enum_match in re.finditer(r"enum (\w+): String[^{]*\{(.*?)\n\}", src, re.S):
            name, body = enum_match.group(1), enum_match.group(2)
            cases: set[str] = set()
            for line in body.split("\n"):
                m = re.match(r"\s*case\s+([\w, ]+)$", line)
                if m:
                    cases |= {c.strip() for c in m.group(1).split(",") if c.strip()}
            if not cases:
                continue

            # Every switch in the app that dispatches on this enum's cases.
            for sw in re.finditer(r"switch\s+[\w.$]+\s*\{", src):
                start = sw.end()
                depth, i = 1, start
                while i < len(src) and depth:
                    if src[i] == "{": depth += 1
                    elif src[i] == "}": depth -= 1
                    i += 1
                block = src[start:i]

                # `case .a, .b:` lists several cases on one line — capture all
                # of them, or the check reports a false missing case.
                handled: set[str] = set()
                for case_line in re.findall(r"case\s+([^\n:]+):", block):
                    handled |= set(re.findall(r"\.(\w+)", case_line))
                if not handled or not handled & cases:
                    continue                      # switching on something else
                if re.search(r"\bdefault\s*:", block):
                    continue

                missing = cases - handled
                if missing:
                    line_no = src[:sw.start()].count("\n") + 1
                    fail(f"{path.name}:{line_no}: switch over {name} missing "
                         f"{sorted(missing)} — add the case or a default")


def check_no_duplicate_declarations(path: Path, src: str) -> None:
    """
    A type declared twice in one file, or a method declared twice inside the
    same type.

    Scripted edits that append rather than replace produce this, and Swift only
    reports it as "invalid redeclaration" on a macOS runner. Methods are scoped
    to their enclosing type, since `makeBody` legitimately appears once per
    ViewModifier.
    """
    types: dict[str, int] = {}
    current_type = "<file>"
    methods: dict[tuple[str, str], int] = {}

    for line_no, line in enumerate(src.split("\n"), 1):
        type_match = re.match(r"^(?:struct|class|enum|actor|protocol)\s+(\w+)", line)
        if type_match:
            name = type_match.group(1)
            if name in types:
                fail(f"{path.name}:{line_no}: duplicate type '{name}' "
                     f"(also at line {types[name]})")
            else:
                types[name] = line_no
            current_type = name
            continue

        func_match = re.match(
            r"^\s+(?:@\w+\s+)*(?:private |fileprivate |internal |public |static |nonisolated )*"
            r"func\s+(\w+)\s*\(", line)
        if func_match:
            # Read to the closing paren: Swift signatures often wrap, and
            # truncating at the newline makes two different overloads look
            # identical.
            rest = "\n".join(src.split("\n")[line_no - 1:])
            open_at = rest.index("(")
            depth, i = 1, open_at + 1
            while i < len(rest) and depth:
                if rest[i] == "(": depth += 1
                elif rest[i] == ")": depth -= 1
                i += 1
            params = re.sub(r"\s+", " ", rest[open_at + 1:i - 1]).strip()
            signature = (current_type, f"{func_match.group(1)}({params})")
            if signature in methods:
                fail(f"{path.name}:{line_no}: duplicate method "
                     f"'{func_match.group(1)}' in {current_type} "
                     f"(also at line {methods[signature]})")
            else:
                methods[signature] = line_no


# SwiftUI types that need `import SwiftUI`. UIKit's UIImage and UIColor are
# deliberately absent — they resolve under `import UIKit`.
SWIFTUI_ONLY = [
    "Color", "Font", "Angle", "Alignment", "Edge", "AnyView",
    "EnvironmentObject", "ObservedObject", "StateObject", "ViewBuilder",
]


def check_swiftui_types_have_import(path: Path, src: str) -> None:
    """
    A SwiftUI type used in a file that only imports Foundation.

    Xcode reports this as "cannot find type 'Color' in scope", which is only
    visible on a macOS runner. It usually means presentation has leaked into a
    layer that should not depend on SwiftUI at all.
    """
    imports = set(re.findall(r"^import (\w+)", src, re.M))
    if "SwiftUI" in imports:
        return

    body = re.sub(r"//[^\n]*", "", src)          # ignore comments
    body = re.sub(r'"[^"]*"', '""', body)         # and string literals

    for name in SWIFTUI_ONLY:
        for m in re.finditer(rf"(?<![.\w]){name}\b", body):
            line_no = body[:m.start()].count("\n") + 1
            fail(f"{path.name}:{line_no}: uses SwiftUI type '{name}' "
                 f"but the file imports only {', '.join(sorted(imports)) or 'nothing'}")
            break


def check_symbols_defined(path: Path, src: str) -> None:
    """
    A property or method referenced in a file that never declares it.

    Brace-balance checks pass happily on this, and Xcode only reports it as
    "cannot find X in scope" on a macOS runner — a full build away.

    Deliberately narrow: it only considers `@State` properties and functions,
    and only flags a reference when nothing in the file declares that name at
    all. Cross-file symbols are out of scope, since checking those properly
    means compiling.
    """
    # Every form of declaration, not just `private` ones — an internal method
    # is just as valid a definition.
    declared = set()
    declared |= set(re.findall(r"\bfunc\s+(\w+)", src))
    declared |= set(re.findall(r"\b(?:var|let)\s+(\w+)", src))
    declared |= set(re.findall(r"\bcase\s+(\w+)", src))

    # Function parameters, including the `_ label: Type` form where the name
    # that matters is the second word, and closure captures.
    for params in re.findall(r"func\s+\w+\s*\(([^)]*)\)", src, re.S):
        for part in params.split(","):
            tokens = re.findall(r"\w+", part)
            if tokens:
                declared.add(tokens[-2] if len(tokens) > 2 else tokens[0])
                declared.update(tokens[:2])
    declared |= set(re.findall(r"\{\s*\[?([\w,\s]+?)\]?\s*in\b", src))
    declared |= set(re.findall(r"(?:if|guard)\s+let\s+(\w+)", src))

    referenced = set()
    for m in re.finditer(r"await\s+(\w+)\s*\(", src):
        referenced.add(m.group(1))
    for m in re.finditer(r"(?<![.\w])(\w+)\s*==\s*\"", src):
        referenced.add(m.group(1))

    missing = sorted(n for n in referenced - declared
                     if n[0].islower() and len(n) > 3)

    for name in missing:
        line_no = next((i for i, line in enumerate(src.split("\n"), 1)
                        if re.search(rf"(?<![.\w]){name}\b", line)), 0)
        fail(f"{path.name}:{line_no}: '{name}' is used but never declared in this file")


def check_no_contradicting_expectations() -> None:
    """
    Two tests asserting opposite bounds on the same property.

    A stale assertion left behind after a redesign (`benefits.count >= 4`)
    survived alongside its replacement (`<= 3`), so the suite could never pass
    — and it only showed up on a macOS runner, several minutes into a build.
    """
    tests = ROOT / "SnapCalTests"
    if not tests.exists():
        return

    # property -> {"lower": [(bound, line)], "upper": [(bound, line)]}
    bounds: dict[str, dict[str, list]] = {}

    for path in sorted(tests.glob("*.swift")):
        for line_no, line in enumerate(path.read_text().split("\n"), 1):
            m = re.search(r"#expect\(\s*([\w.]+(?:\.count)?)\s*(>=|<=|>|<)\s*(\d+)", line)
            if not m:
                continue
            prop, op, value = m.group(1), m.group(2), int(m.group(3))
            # Strip the receiver so `context.benefits.count` and
            # `ctx.benefits.count` compare as the same property.
            key = ".".join(prop.split(".")[-2:])
            entry = bounds.setdefault(key, {"lower": [], "upper": []})
            entry["lower" if op in (">=", ">") else "upper"].append((value, line_no, path.name))

    for prop, entry in bounds.items():
        for low, low_line, low_file in entry["lower"]:
            for high, high_line, high_file in entry["upper"]:
                if low > high:
                    fail(f"{low_file}:{low_line}: '{prop} >= {low}' contradicts "
                         f"'{prop} <= {high}' at {high_file}:{high_line} — "
                         f"one is a leftover from a redesign")


def check_guest_is_empty() -> None:
    models = (ROOT / "SnapCal/Net/Models.swift").read_text()
    start = models.find("static let guest =")
    if start == -1:
        fail("Models.swift: Dashboard.guest missing")
        return
    guest = models[start: models.find("static let placeholder")]
    if "Meal(" in guest:
        fail("Models.swift: guest dashboard fabricates meals")


for path in APP:
    src = path.read_text()
    check_delimiters(path, src)
    check_dismiss(path, src)
    check_closures(path, src)
    check_swiftui_import(path, src)
    check_import_placement(path, src)
    check_no_duplicate_declarations(path, src)
    check_swiftui_types_have_import(path, src)
    check_symbols_defined(path, src)
    check_no_fabricated_food(path, src)

# Test fixtures may name any food — they are never rendered to a user.
for path in TESTS:
    src = path.read_text()
    check_delimiters(path, src)
    check_closures(path, src)

check_guest_is_empty()
check_input_method_contract()
check_exhaustive_switches()
check_no_contradicting_expectations()

for message in failures:
    print(f"FAIL  {message}")

print(f"\nswift lint: {'PASS' if not failures else f'FAIL ({len(failures)})'} "
      f"({len(APP)} app files, {len(TESTS)} test files)")
sys.exit(1 if failures else 0)
