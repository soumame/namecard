#!/usr/bin/env python3
"""Generate the Xcode project with Python's standard library and macOS plutil."""
import hashlib
import copy
import json
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
objects = {}

def ident(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()

def add(identifier_name, isa, **fields):
    key = ident(identifier_name)
    objects[key] = {"isa": isa, **fields}
    return key

def ref(name):
    return ident(name)

def render(value, depth=0):
    if isinstance(value, dict):
        return "{\n" + "".join("\t" * (depth + 1) + f"{json.dumps(str(key))} = {render(val, depth + 1)};\n" for key, val in value.items()) + "\t" * depth + "}"
    if isinstance(value, list):
        return "(" + ", ".join(render(v, depth) for v in value) + ")"
    return json.dumps(str(value), ensure_ascii=False)

configs = ["Debug", "Release", "HardwareTest", "Beta"]
package = add("package", "XCLocalSwiftPackageReference", relativePath="NamecardCore")
product_refs = []
group_refs = []
targets = []

for name, product_type, extension in [
    ("Namecard", "com.apple.product-type.application", "app"),
    ("NamecardTests", "com.apple.product-type.bundle.unit-test", "xctest"),
    ("NamecardUITests", "com.apple.product-type.bundle.ui-testing", "xctest"),
]:
    product = add(name + "Product", "PBXFileReference", explicitFileType="wrapper.application" if extension == "app" else "wrapper.cfbundle", includeInIndex=0, path=f"{name}.{extension}", sourceTree="BUILT_PRODUCTS_DIR")
    product_refs.append(product)
    group = add(name + "Group", "PBXFileSystemSynchronizedRootGroup", path=name, sourceTree="<group>", explicitFileTypes={}, explicitFolders=[])
    group_refs.append(group)
    phases = []
    dependencies = []
    package_dependencies = []
    frameworks = []
    if name != "NamecardUITests":
        dependency = add(name + "Core", "XCSwiftPackageProductDependency", package=package, productName="NamecardCore")
        package_dependencies.append(dependency)
        frameworks.append(add(name + "CoreBuild", "PBXBuildFile", productRef=dependency))
    for kind in ["Sources", "Frameworks", "Resources"]:
        phases.append(add(name + kind, "PBX" + kind + "BuildPhase", buildActionMask=2147483647, files=frameworks if kind == "Frameworks" else [], runOnlyForDeploymentPostprocessing=0))
    if name != "Namecard":
        proxy = add(name + "Proxy", "PBXContainerItemProxy", containerPortal=ref("Project"), proxyType=1, remoteGlobalIDString=ref("NamecardTarget"), remoteInfo="Namecard")
        dependencies.append(add(name + "Dependency", "PBXTargetDependency", target=ref("NamecardTarget"), targetProxy=proxy))
    build_configs = []
    for config in configs:
        optimized = config in {"Release", "Beta"}
        settings = {
            "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": "work.tokumaru.namecard" + ("" if name == "Namecard" else "." + name),
            "SWIFT_VERSION": "5.0", "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "TARGETED_DEVICE_FAMILY": "1",
            "CODE_SIGN_STYLE": "Automatic", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "SUPPORTS_MACCATALYST": "NO", "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
            "SWIFT_EMIT_LOC_STRINGS": "YES", "SWIFT_OPTIMIZATION_LEVEL": "-O" if optimized else "-Onone",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited)" + (" DEBUG" if not optimized else "") + (" HARDWARE_TESTING" if config == "HardwareTest" else "") + (" NAMECARD_BETA" if config == "Beta" else ""),
            "GENERATE_INFOPLIST_FILE": "YES" if name != "Namecard" else "NO",
        }
        if name == "Namecard":
            settings.update({"INFOPLIST_FILE": "Config/Info.plist", "CODE_SIGN_ENTITLEMENTS": "Config/Namecard.entitlements", "MARKETING_VERSION": "0.1.0", "CURRENT_PROJECT_VERSION": "1", "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon"})
            settings.update({"SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD": "NO",
                             "NAMECARD_DISPLAY_NAME": "Namecard Beta" if config == "Beta" else "Namecard",
                             "NAMECARD_DISTRIBUTION_CHANNEL": "beta" if config == "Beta" else "hardware" if config == "HardwareTest" else "app-store"})
        elif name == "NamecardTests":
            settings.update({"TEST_HOST": "$(BUILT_PRODUCTS_DIR)/Namecard.app/Namecard", "BUNDLE_LOADER": "$(TEST_HOST)", "TEST_TARGET_NAME": "Namecard"})
        else:
            settings["TEST_TARGET_NAME"] = "Namecard"
        build_configs.append(add(name + config, "XCBuildConfiguration", buildSettings=settings, name=config))
    config_list = add(name + "Configurations", "XCConfigurationList", buildConfigurations=build_configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
    target = add(name + "Target", "PBXNativeTarget", buildConfigurationList=config_list, buildPhases=phases, buildRules=[], dependencies=dependencies,
                 fileSystemSynchronizedGroups=[group], name=name, packageProductDependencies=package_dependencies, productName=name, productReference=product, productType=product_type)
    targets.append(target)

product_group = add("Products", "PBXGroup", children=product_refs, name="Products", sourceTree="<group>")
main_group = add("MainGroup", "PBXGroup", children=group_refs + [product_group], sourceTree="<group>")
project_configs = []
for config in configs:
    optimized = config in {"Release", "Beta"}
    settings = {"SDKROOT": "iphoneos", "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES", "ENABLE_TESTABILITY": "NO" if optimized else "YES", "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym" if optimized else "dwarf", "SWIFT_COMPILATION_MODE": "wholemodule" if optimized else "singlefile"}
    settings["ONLY_ACTIVE_ARCH"] = "NO" if optimized else "YES"
    project_configs.append(add("Project" + config, "XCBuildConfiguration", buildSettings=settings, name=config))
config_list = add("ProjectConfigurations", "XCConfigurationList", buildConfigurations=project_configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
project = add("Project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "2600", "TargetAttributes": {ref("NamecardTarget"): {"CreatedOnToolsVersion": "26.0", "SystemCapabilities": {"com.apple.NearFieldCommunicationTagReading": {"enabled": 1}}}}}, buildConfigurationList=config_list, compatibilityVersion="Xcode 16.0", developmentRegion="ja", hasScannedForEncodings=0, knownRegions=["ja", "en", "Base"], mainGroup=main_group, minimizedProjectReferenceProxies=1, productRefGroup=product_group, projectDirPath="", projectRoot="", packageReferences=[package], targets=targets)

# These are user-managed signing/version values, not generated feature flags.
# Preserve them on regeneration, including when Xcode reformats the project.
LOCAL_SETTINGS = {"DEVELOPMENT_TEAM", "CODE_SIGN_STYLE", "CODE_SIGN_IDENTITY", "PROVISIONING_PROFILE_SPECIFIER",
                  "PROVISIONING_PROFILE", "MARKETING_VERSION", "CURRENT_PROJECT_VERSION"}

def read_project(path):
    return json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(path)], text=True))

def project_data(existing=None):
    data = {"archiveVersion": 1, "classes": {}, "objectVersion": 71,
            "objects": copy.deepcopy(objects), "rootObject": project}
    prior = (existing or {}).get("objects", {})
    for name in ["Namecard", "NamecardTests", "NamecardUITests"]:
        for config in configs:
            key = ref(name + config)
            # The first Beta configuration inherits the user's Release signing.
            source = prior.get(key, prior.get(ref(name + "Release"), {}))
            for setting, value in source.get("buildSettings", {}).items():
                if setting.split("[", 1)[0] in LOCAL_SETTINGS:
                    data["objects"][key]["buildSettings"][setting] = value
    return data

def canonical(value):
    if isinstance(value, dict):
        value = dict(value)
        if value.get("isa") == "PBXFileSystemSynchronizedRootGroup":
            value.setdefault("explicitFileTypes", {})
            value.setdefault("explicitFolders", [])
        return {key: canonical(item) for key, item in value.items()}
    if isinstance(value, list):
        return [canonical(item) for item in value]
    return str(value)

def xml_structure(text):
    def node(element):
        return (element.tag, sorted(element.attrib.items()), (element.text or "").strip(),
                [node(child) for child in element])
    return node(ET.fromstring(text))

def build_reference(name):
    ext = "app" if name == "Namecard" else "xctest"
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ref(name + "Target")}" BuildableName="{name}.{ext}" BlueprintName="{name}" ReferencedContainer="container:Namecard.xcodeproj"/>'

def scheme(config):
    archive_config = "Beta" if config == "Beta" else "Release"
    main = build_reference("Namecard")
    tests = "".join(f'<TestableReference skipped="NO">{build_reference(name)}</TestableReference>' for name in ["NamecardTests", "NamecardUITests"])
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{main}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="{config}" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables>{tests}</Testables></TestAction>
<LaunchAction buildConfiguration="{config}" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{main}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="{archive_config}" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{main}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="{config}"/>
<ArchiveAction buildConfiguration="{archive_config}" revealArchiveInOrganizer="YES"/>
</Scheme>
'''

def main():
    project_path = ROOT / "Namecard.xcodeproj/project.pbxproj"
    existing = read_project(project_path) if project_path.exists() else None
    expected = project_data(existing)
    schemes = {"Namecard": "Debug", "Namecard Hardware": "HardwareTest", "Namecard Beta": "Beta"}
    outputs = {ROOT / f"Namecard.xcodeproj/xcshareddata/xcschemes/{name}.xcscheme": scheme(config)
               for name, config in schemes.items()}
    if "--check" in sys.argv:
        if canonical(existing) != canonical(expected):
            raise SystemExit("Regenerate project: Namecard.xcodeproj/project.pbxproj")
        for path, content in outputs.items():
            if not path.exists() or xml_structure(path.read_text()) != xml_structure(content):
                raise SystemExit(f"Regenerate project: {path.relative_to(ROOT)}")
        print("Xcode project and schemes match (local signing/version values preserved)")
        return
    outputs[project_path] = "// !$*UTF8*$!\n" + render(expected) + "\n"
    for path, content in outputs.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

if __name__ == "__main__":
    main()
