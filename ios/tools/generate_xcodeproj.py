#!/usr/bin/env python3
"""
Generates ios/SnapCal.xcodeproj from the files on disk.

The generated project is committed, so a developer clones and opens it — this
script only exists so the project can be regenerated deterministically after
adding files, rather than hand-editing project.pbxproj and hitting merge hell.

    python3 ios/tools/generate_xcodeproj.py

Object IDs are md5-derived from stable keys, so regenerating produces a
byte-identical file when the file list has not changed.
"""
import hashlib
import os
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]          # ios/
PROJ = ROOT / "SnapCal.xcodeproj"

APP = "SnapCal"
TESTS = "SnapCalTests"
UITESTS = "SnapCalUITests"
BUNDLE_ID = "app.snapcal.ios"

SOURCE_EXT = {".swift", ".m", ".mm", ".c"}
RESOURCE_EXT = {".xcassets", ".storekit", ".xib", ".storyboard", ".json", ".png"}


def uid(key: str) -> str:
    return hashlib.md5(key.encode()).hexdigest()[:24].upper()


def collect(target_dir: Path):
    """Returns (sources, resources) as paths relative to ios/."""
    sources, resources = [], []
    for path in sorted(target_dir.rglob("*")):
        # Asset catalogs are a single resource, not a directory of files.
        if any(p.suffix == ".xcassets" for p in path.parents):
            continue
        if path.suffix == ".xcassets":
            resources.append(path.relative_to(ROOT))
            continue
        if not path.is_file():
            continue
        if path.name == "Info.plist" or path.suffix == ".entitlements":
            continue                                 # referenced via build settings
        if path.suffix in SOURCE_EXT:
            sources.append(path.relative_to(ROOT))
    return sources, resources


app_sources, app_resources = collect(ROOT / APP)
test_sources, _ = collect(ROOT / TESTS)
uitest_sources, _ = collect(ROOT / UITESTS)

config_files = {
    "Base": Path("Config/Base.xcconfig"),
    "Debug": Path("Config/Debug.xcconfig"),
    "Release": Path("Config/Release.xcconfig"),
}
storekit = Path("Config/SnapCal.storekit")
extra_refs = [
    Path(f"{APP}/Resources/Info.plist"),
    Path(f"{APP}/SnapCal.entitlements"),
    storekit,
    *config_files.values(),
]

all_refs = sorted({*app_sources, *app_resources, *test_sources, *uitest_sources, *extra_refs},
                  key=str)

FILE_REF = {p: uid(f"fileref:{p}") for p in all_refs}
BUILD_FILE = {}


def build_file_id(path: Path, target: str) -> str:
    key = (path, target)
    if key not in BUILD_FILE:
        BUILD_FILE[key] = uid(f"buildfile:{target}:{path}")
    return BUILD_FILE[key]


def file_type(path: Path) -> str:
    return {
        ".swift": "sourcecode.swift",
        ".plist": "text.plist.xml",
        ".entitlements": "text.plist.entitlements",
        ".xcassets": "folder.assetcatalog",
        ".xcconfig": "text.xcconfig",
        ".storekit": "text.json",
        ".png": "image.png",
        ".json": "text.json",
    }.get(path.suffix, "text")


# ── product references ───────────────────────────────────────────────────────
PRODUCTS = {
    APP: (uid("product:app"), f"{APP}.app", "wrapper.application"),
    TESTS: (uid("product:tests"), f"{TESTS}.xctest", "wrapper.cfbundle"),
    UITESTS: (uid("product:uitests"), f"{UITESTS}.xctest", "wrapper.cfbundle"),
}

TARGET_ID = {name: uid(f"target:{name}") for name in (APP, TESTS, UITESTS)}
PROJECT_ID = uid("project")
MAIN_GROUP = uid("group:main")
PRODUCTS_GROUP = uid("group:products")


# ── group tree ───────────────────────────────────────────────────────────────
class Group:
    def __init__(self, name, path=None):
        self.name = name
        self.path = path
        self.children = {}
        self.files = []
        self.id = uid(f"group:{name}:{path}")


def build_tree():
    root = Group("__root__")
    for p in all_refs:
        parts = p.parts
        node = root
        for part in parts[:-1]:
            if part not in node.children:
                child = Group(part, part)
                child.id = uid("group:" + "/".join(parts[:parts.index(part) + 1]))
                node.children[part] = child
            node = node.children[part]
        node.files.append(p)
    return root


tree = build_tree()


def emit_groups(node, out, is_root=False):
    children = []
    for name in sorted(node.children):
        child = node.children[name]
        emit_groups(child, out)
        children.append((child.id, name))
    for f in sorted(node.files, key=str):
        children.append((FILE_REF[f], f.name))

    if is_root:
        return children

    lines = [f"\t\t{node.id} /* {node.name} */ = {{",
             "\t\t\tisa = PBXGroup;",
             "\t\t\tchildren = ("]
    for cid, cname in children:
        lines.append(f"\t\t\t\t{cid} /* {cname} */,")
    lines += ["\t\t\t);",
              f'\t\t\tpath = "{node.path}";',
              "\t\t\tsourceTree = \"<group>\";",
              "\t\t};"]
    out.append("\n".join(lines))
    return children


group_objects = []
root_children = emit_groups(tree, group_objects, is_root=True)


# ── phases ───────────────────────────────────────────────────────────────────
PHASES = {}
for name in (APP, TESTS, UITESTS):
    PHASES[name] = {
        "sources": uid(f"phase:sources:{name}"),
        "frameworks": uid(f"phase:frameworks:{name}"),
        "resources": uid(f"phase:resources:{name}"),
    }

TARGET_SOURCES = {APP: app_sources, TESTS: test_sources, UITESTS: uitest_sources}
TARGET_RESOURCES = {APP: app_resources, TESTS: [], UITESTS: []}


def phase_block(pid, isa, name, files, target):
    lines = [f"\t\t{pid} /* {name} */ = {{",
             f"\t\t\tisa = {isa};",
             "\t\t\tbuildActionMask = 2147483647;",
             "\t\t\tfiles = ("]
    for f in files:
        lines.append(f"\t\t\t\t{build_file_id(f, target)} /* {f.name} in {name} */,")
    lines += ["\t\t\t);",
              "\t\t\trunOnlyForDeploymentPostprocessing = 0;",
              "\t\t};"]
    return "\n".join(lines)


# ── build settings ───────────────────────────────────────────────────────────
PROJECT_SETTINGS = """\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCLANG_WARN_DOCUMENTATION_COMMENTS = YES;
\t\t\t\tCLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSWIFT_STRICT_CONCURRENCY = complete;
\t\t\t\tENABLE_MODULE_VERIFIER = NO;"""

APP_SETTINGS = """\t\t\t\tCODE_SIGN_ENTITLEMENTS = SnapCal/SnapCal.entitlements;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = SnapCal/Resources/Info.plist;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t);
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = app.snapcal.ios;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;"""

TESTS_SETTINGS = """\t\t\t\tBUNDLE_LOADER = "$(TEST_HOST)";
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 18.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = app.snapcal.ios.tests;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = 1;
\t\t\t\tTEST_HOST = "$(BUILT_PRODUCTS_DIR)/SnapCal.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/SnapCal";"""

UITESTS_SETTINGS = """\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 18.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = app.snapcal.ios.uitests;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = 1;
\t\t\t\tTEST_TARGET_NAME = SnapCal;"""

TARGET_SETTINGS = {APP: APP_SETTINGS, TESTS: TESTS_SETTINGS, UITESTS: UITESTS_SETTINGS}

CONFIG_ID = {}
for scope in ("project", APP, TESTS, UITESTS):
    for conf in ("Debug", "Release"):
        CONFIG_ID[(scope, conf)] = uid(f"config:{scope}:{conf}")
CONFLIST_ID = {scope: uid(f"conflist:{scope}") for scope in ("project", APP, TESTS, UITESTS)}

DEP_ID = {TESTS: uid("dep:tests"), UITESTS: uid("dep:uitests")}
PROXY_ID = {TESTS: uid("proxy:tests"), UITESTS: uid("proxy:uitests")}


def config_block(scope, conf, settings, base_ref=None):
    lines = [f"\t\t{CONFIG_ID[(scope, conf)]} /* {conf} */ = {{",
             "\t\t\tisa = XCBuildConfiguration;"]
    if base_ref:
        lines.append(f"\t\t\tbaseConfigurationReference = {base_ref} /* {conf}.xcconfig */;")
    lines += ["\t\t\tbuildSettings = {", settings, "\t\t\t};",
              f"\t\t\tname = {conf};", "\t\t};"]
    return "\n".join(lines)


def conflist_block(scope, comment):
    return "\n".join([
        f"\t\t{CONFLIST_ID[scope]} /* Build configuration list for {comment} */ = {{",
        "\t\t\tisa = XCConfigurationList;",
        "\t\t\tbuildConfigurations = (",
        f"\t\t\t\t{CONFIG_ID[(scope, 'Debug')]} /* Debug */,",
        f"\t\t\t\t{CONFIG_ID[(scope, 'Release')]} /* Release */,",
        "\t\t\t);",
        "\t\t\tdefaultConfigurationIsVisible = 0;",
        "\t\t\tdefaultConfigurationName = Release;",
        "\t\t};",
    ])


# Build-file IDs must exist before the PBXBuildFile section is emitted, which
# happens earlier in the file than the phases that would otherwise create them.
for _t in (APP, TESTS, UITESTS):
    for _f in TARGET_SOURCES[_t] + TARGET_RESOURCES[_t]:
        build_file_id(_f, _t)

# ── assemble ─────────────────────────────────────────────────────────────────
out = []
out.append("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 56;\n\tobjects = {\n")

# PBXBuildFile
out.append("/* Begin PBXBuildFile section */")
for (path, target), bid in sorted(BUILD_FILE.items(), key=lambda kv: kv[1]):
    phase = "Resources" if path.suffix in RESOURCE_EXT else "Sources"
    out.append(f"\t\t{bid} /* {path.name} in {phase} */ = {{isa = PBXBuildFile; "
               f"fileRef = {FILE_REF[path]} /* {path.name} */; }};")
out.append("/* End PBXBuildFile section */\n")

# PBXContainerItemProxy
out.append("/* Begin PBXContainerItemProxy section */")
for t in (TESTS, UITESTS):
    out.append("\n".join([
        f"\t\t{PROXY_ID[t]} /* PBXContainerItemProxy */ = {{",
        "\t\t\tisa = PBXContainerItemProxy;",
        f"\t\t\tcontainerPortal = {PROJECT_ID} /* Project object */;",
        "\t\t\tproxyType = 1;",
        f"\t\t\tremoteGlobalIDString = {TARGET_ID[APP]};",
        f"\t\t\tremoteInfo = {APP};",
        "\t\t};",
    ]))
out.append("/* End PBXContainerItemProxy section */\n")

# PBXFileReference
out.append("/* Begin PBXFileReference section */")
for path in all_refs:
    out.append(f'\t\t{FILE_REF[path]} /* {path.name} */ = {{isa = PBXFileReference; '
               f'lastKnownFileType = {file_type(path)}; path = "{path.name}"; sourceTree = "<group>"; }};')
for name, (pid, filename, ftype) in PRODUCTS.items():
    out.append(f'\t\t{pid} /* {filename} */ = {{isa = PBXFileReference; explicitFileType = {ftype}; '
               f'includeInIndex = 0; path = "{filename}"; sourceTree = BUILT_PRODUCTS_DIR; }};')
out.append("/* End PBXFileReference section */\n")

# PBXFrameworksBuildPhase
out.append("/* Begin PBXFrameworksBuildPhase section */")
for name in (APP, TESTS, UITESTS):
    out.append(phase_block(PHASES[name]["frameworks"], "PBXFrameworksBuildPhase", "Frameworks", [], name))
out.append("/* End PBXFrameworksBuildPhase section */\n")

# PBXGroup
out.append("/* Begin PBXGroup section */")
main_children = "\n".join(f"\t\t\t\t{cid} /* {cname} */," for cid, cname in root_children)
out.append("\n".join([
    f"\t\t{MAIN_GROUP} = {{",
    "\t\t\tisa = PBXGroup;",
    "\t\t\tchildren = (",
    main_children,
    f"\t\t\t\t{PRODUCTS_GROUP} /* Products */,",
    "\t\t\t);",
    "\t\t\tsourceTree = \"<group>\";",
    "\t\t};",
]))
out.append("\n".join([
    f"\t\t{PRODUCTS_GROUP} /* Products */ = {{",
    "\t\t\tisa = PBXGroup;",
    "\t\t\tchildren = (",
    *[f"\t\t\t\t{pid} /* {fn} */," for pid, fn, _ in PRODUCTS.values()],
    "\t\t\t);",
    "\t\t\tname = Products;",
    "\t\t\tsourceTree = \"<group>\";",
    "\t\t};",
]))
out.extend(group_objects)
out.append("/* End PBXGroup section */\n")

# PBXNativeTarget
out.append("/* Begin PBXNativeTarget section */")
TARGET_TYPE = {
    APP: "com.apple.product-type.application",
    TESTS: "com.apple.product-type.bundle.unit-test",
    UITESTS: "com.apple.product-type.bundle.ui-testing",
}
for name in (APP, TESTS, UITESTS):
    deps = "" if name == APP else f"\t\t\t\t{DEP_ID[name]} /* PBXTargetDependency */,\n"
    out.append("\n".join([
        f"\t\t{TARGET_ID[name]} /* {name} */ = {{",
        "\t\t\tisa = PBXNativeTarget;",
        f"\t\t\tbuildConfigurationList = {CONFLIST_ID[name]} /* Build configuration list for PBXNativeTarget \"{name}\" */;",
        "\t\t\tbuildPhases = (",
        f"\t\t\t\t{PHASES[name]['sources']} /* Sources */,",
        f"\t\t\t\t{PHASES[name]['frameworks']} /* Frameworks */,",
        f"\t\t\t\t{PHASES[name]['resources']} /* Resources */,",
        "\t\t\t);",
        "\t\t\tbuildRules = (",
        "\t\t\t);",
        "\t\t\tdependencies = (",
        deps + "\t\t\t);",
        f"\t\t\tname = {name};",
        f"\t\t\tproductName = {name};",
        f"\t\t\tproductReference = {PRODUCTS[name][0]} /* {PRODUCTS[name][1]} */;",
        f"\t\t\tproductType = \"{TARGET_TYPE[name]}\";",
        "\t\t};",
    ]))
out.append("/* End PBXNativeTarget section */\n")

# PBXProject
target_attrs = "\n".join(
    f"\t\t\t\t\t{TARGET_ID[n]} = {{\n\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;\n"
    + (f"\t\t\t\t\t\tTestTargetID = {TARGET_ID[APP]};\n" if n != APP else "")
    + "\t\t\t\t\t};"
    for n in (APP, TESTS, UITESTS)
)
out.append("/* Begin PBXProject section */")
out.append("\n".join([
    f"\t\t{PROJECT_ID} /* Project object */ = {{",
    "\t\t\tisa = PBXProject;",
    "\t\t\tattributes = {",
    "\t\t\t\tBuildIndependentTargetsInParallel = 1;",
    "\t\t\t\tLastSwiftUpdateCheck = 1600;",
    "\t\t\t\tLastUpgradeCheck = 1600;",
    "\t\t\t\tTargetAttributes = {",
    target_attrs,
    "\t\t\t\t};",
    "\t\t\t};",
    f"\t\t\tbuildConfigurationList = {CONFLIST_ID['project']} /* Build configuration list for PBXProject \"SnapCal\" */;",
    "\t\t\tcompatibilityVersion = \"Xcode 14.0\";",
    "\t\t\tdevelopmentRegion = en;",
    "\t\t\thasScannedForEncodings = 0;",
    "\t\t\tknownRegions = (",
    "\t\t\t\ten,",
    "\t\t\t\tBase,",
    "\t\t\t);",
    f"\t\t\tmainGroup = {MAIN_GROUP};",
    f"\t\t\tproductRefGroup = {PRODUCTS_GROUP} /* Products */;",
    "\t\t\tprojectDirPath = \"\";",
    "\t\t\tprojectRoot = \"\";",
    "\t\t\ttargets = (",
    *[f"\t\t\t\t{TARGET_ID[n]} /* {n} */," for n in (APP, TESTS, UITESTS)],
    "\t\t\t);",
    "\t\t};",
]))
out.append("/* End PBXProject section */\n")

# PBXResourcesBuildPhase
out.append("/* Begin PBXResourcesBuildPhase section */")
for name in (APP, TESTS, UITESTS):
    out.append(phase_block(PHASES[name]["resources"], "PBXResourcesBuildPhase", "Resources",
                           TARGET_RESOURCES[name], name))
out.append("/* End PBXResourcesBuildPhase section */\n")

# PBXSourcesBuildPhase
out.append("/* Begin PBXSourcesBuildPhase section */")
for name in (APP, TESTS, UITESTS):
    out.append(phase_block(PHASES[name]["sources"], "PBXSourcesBuildPhase", "Sources",
                           TARGET_SOURCES[name], name))
out.append("/* End PBXSourcesBuildPhase section */\n")

# PBXTargetDependency
out.append("/* Begin PBXTargetDependency section */")
for t in (TESTS, UITESTS):
    out.append("\n".join([
        f"\t\t{DEP_ID[t]} /* PBXTargetDependency */ = {{",
        "\t\t\tisa = PBXTargetDependency;",
        f"\t\t\ttarget = {TARGET_ID[APP]} /* {APP} */;",
        f"\t\t\ttargetProxy = {PROXY_ID[t]} /* PBXContainerItemProxy */;",
        "\t\t};",
    ]))
out.append("/* End PBXTargetDependency section */\n")

# XCBuildConfiguration
out.append("/* Begin XCBuildConfiguration section */")
for conf in ("Debug", "Release"):
    base = FILE_REF[config_files[conf]]
    out.append(config_block("project", conf, PROJECT_SETTINGS, base))
for name in (APP, TESTS, UITESTS):
    for conf in ("Debug", "Release"):
        out.append(config_block(name, conf, TARGET_SETTINGS[name]))
out.append("/* End XCBuildConfiguration section */\n")

# XCConfigurationList
out.append("/* Begin XCConfigurationList section */")
out.append(conflist_block("project", 'PBXProject "SnapCal"'))
for name in (APP, TESTS, UITESTS):
    out.append(conflist_block(name, f'PBXNativeTarget "{name}"'))
out.append("/* End XCConfigurationList section */\n")

out.append(f"\t}};\n\trootObject = {PROJECT_ID} /* Project object */;\n}}\n")

# ── write ────────────────────────────────────────────────────────────────────
if PROJ.exists():
    shutil.rmtree(PROJ)
(PROJ / "xcshareddata" / "xcschemes").mkdir(parents=True)
(PROJ / "project.pbxproj").write_text("\n".join(out))

# A *shared* scheme is mandatory: `xcodebuild -scheme SnapCal` on CI cannot see
# user-specific schemes, which is the classic "scheme not found" CI failure.
scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{TARGET_ID[APP]}"
               BuildableName = "{APP}.app"
               BlueprintName = "{APP}"
               ReferencedContainer = "container:{APP}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES"
      shouldAutocreateTestPlan = "YES">
      <Testables>
         <TestableReference skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{TARGET_ID[TESTS]}"
               BuildableName = "{TESTS}.xctest"
               BlueprintName = "{TESTS}"
               ReferencedContainer = "container:{APP}.xcodeproj">
            </BuildableReference>
         </TestableReference>
         <TestableReference skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{TARGET_ID[UITESTS]}"
               BuildableName = "{UITESTS}.xctest"
               BlueprintName = "{UITESTS}"
               ReferencedContainer = "container:{APP}.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{TARGET_ID[APP]}"
            BuildableName = "{APP}.app"
            BlueprintName = "{APP}"
            ReferencedContainer = "container:{APP}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{TARGET_ID[APP]}"
            BuildableName = "{APP}.app"
            BlueprintName = "{APP}"
            ReferencedContainer = "container:{APP}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
(PROJ / "xcshareddata" / "xcschemes" / f"{APP}.xcscheme").write_text(scheme)

(PROJ / "project.xcworkspace").mkdir(parents=True, exist_ok=True)
(PROJ / "project.xcworkspace" / "contents.xcworkspacedata").write_text(
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<Workspace version = "1.0">\n'
    '   <FileRef location = "self:">\n'
    '   </FileRef>\n'
    '</Workspace>\n'
)

print(f"wrote {PROJ.relative_to(ROOT.parent)}")
print(f"  app sources     : {len(app_sources)}")
print(f"  app resources   : {len(app_resources)}")
print(f"  unit tests      : {len(test_sources)}")
print(f"  ui tests        : {len(uitest_sources)}")
print(f"  total file refs : {len(all_refs)}")
