#!/usr/bin/env python3
"""Generate the checked-in Xcode project using only Python's standard library."""
import hashlib
import json
from pathlib import Path
import sys

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
        return "{\n" + "".join("\t" * (depth + 1) + f"{key} = {render(val, depth + 1)};\n" for key, val in value.items()) + "\t" * depth + "}"
    if isinstance(value, list):
        return "(" + ", ".join(render(v, depth) for v in value) + ")"
    return json.dumps(str(value), ensure_ascii=False)

configs = ["Debug", "Release", "HardwareTest"]
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
    group = add(name + "Group", "PBXFileSystemSynchronizedRootGroup", path=name, sourceTree="<group>")
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
        settings = {
            "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": "work.tokumaru.namecard" + ("" if name == "Namecard" else "." + name),
            "SWIFT_VERSION": "5.0", "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "TARGETED_DEVICE_FAMILY": "1",
            "CODE_SIGN_STYLE": "Automatic", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "SUPPORTS_MACCATALYST": "NO", "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
            "SWIFT_EMIT_LOC_STRINGS": "YES", "SWIFT_OPTIMIZATION_LEVEL": "-O" if config == "Release" else "-Onone",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited)" + (" DEBUG" if config != "Release" else "") + (" HARDWARE_TESTING" if config == "HardwareTest" else ""),
            "GENERATE_INFOPLIST_FILE": "YES" if name != "Namecard" else "NO",
        }
        if name == "Namecard":
            settings.update({"INFOPLIST_FILE": "Config/Info.plist", "CODE_SIGN_ENTITLEMENTS": "Config/Namecard.entitlements", "MARKETING_VERSION": "0.1.0", "CURRENT_PROJECT_VERSION": "1", "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon"})
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
    settings = {"SDKROOT": "iphoneos", "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES", "ENABLE_TESTABILITY": "NO" if config == "Release" else "YES", "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym" if config == "Release" else "dwarf", "SWIFT_COMPILATION_MODE": "wholemodule" if config == "Release" else "singlefile"}
    project_configs.append(add("Project" + config, "XCBuildConfiguration", buildSettings=settings, name=config))
config_list = add("ProjectConfigurations", "XCConfigurationList", buildConfigurations=project_configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
project = add("Project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "2600", "TargetAttributes": {ref("NamecardTarget"): {"CreatedOnToolsVersion": "26.0", "SystemCapabilities": {"com.apple.NearFieldCommunicationTagReading": {"enabled": 1}}}}}, buildConfigurationList=config_list, compatibilityVersion="Xcode 16.0", developmentRegion="ja", hasScannedForEncodings=0, knownRegions=["ja", "en", "Base"], mainGroup=main_group, minimizedProjectReferenceProxies=1, preferredProjectObjectVersion=77, productRefGroup=product_group, projectDirPath="", projectRoot="", packageReferences=[package], targets=targets)
project_text = "// !$*UTF8*$!\n" + render({"archiveVersion": 1, "classes": {}, "objectVersion": 77, "objects": objects, "rootObject": project}) + "\n"

def build_reference(name):
    ext = "app" if name == "Namecard" else "xctest"
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ref(name + "Target")}" BuildableName="{name}.{ext}" BlueprintName="{name}" ReferencedContainer="container:Namecard.xcodeproj"/>'

def scheme(config):
    main = build_reference("Namecard")
    tests = "".join(f'<TestableReference skipped="NO">{build_reference(name)}</TestableReference>' for name in ["NamecardTests", "NamecardUITests"])
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{main}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="{config}" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables>{tests}</Testables></TestAction>
<LaunchAction buildConfiguration="{config}" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{main}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{main}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="{config}"/>
<ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''

outputs = {
    ROOT / "Namecard.xcodeproj/project.pbxproj": project_text,
    ROOT / "Namecard.xcodeproj/xcshareddata/xcschemes/Namecard.xcscheme": scheme("Debug"),
    ROOT / "Namecard.xcodeproj/xcshareddata/xcschemes/Namecard Hardware.xcscheme": scheme("HardwareTest"),
}
for path, content in outputs.items():
    if "--check" in sys.argv:
        if not path.exists() or path.read_text() != content:
            raise SystemExit(f"Regenerate project: {path.relative_to(ROOT)}")
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
