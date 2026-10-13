#!/usr/bin/env python3
"""Create this pilot's Xcode project without installing a project generator."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parent
NAME = "SproutCallPilot"
SDK_REVISION = "b466eb161e348a50c45da0842acd84972e52f2f2"  # official 4.2.1 tag

def identity(value):
    return hashlib.sha256(value.encode()).hexdigest()[:24].upper()

def quoted(value):
    return json.dumps(str(value))

def reference(value):
    return identity(value)

objects = []
def add(name, isa, fields):
    objects.append(f"\t\t{identity(name)} = {{isa = {isa}; {fields}}};")

sources = sorted((ROOT / "Sources").glob("*.swift"))
for source in sources:
    add(source.name, "PBXFileReference", f"lastKnownFileType = sourcecode.swift; path = {quoted(source.name)}; sourceTree = \"<group>\";")
    add("build:" + source.name, "PBXBuildFile", f"fileRef = {reference(source.name)};")
add("info", "PBXFileReference", 'lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>";')
add("product", "PBXFileReference", f"explicitFileType = wrapper.application; path = {NAME}.app; sourceTree = BUILT_PRODUCTS_DIR;")
add("sources", "PBXGroup", f"children = ({','.join(reference(s.name) for s in sources)}); path = Sources; sourceTree = \"<group>\";")
add("products", "PBXGroup", f"children = ({reference('product')}); name = Products; sourceTree = \"<group>\";")
add("root", "PBXGroup", f"children = ({reference('sources')},{reference('info')},{reference('products')}); sourceTree = \"<group>\";")
add("sources-phase", "PBXSourcesBuildPhase", f"buildActionMask = 2147483647; files = ({','.join(reference('build:' + s.name) for s in sources)}); runOnlyForDeploymentPostprocessing = 0;")
add("sdk-build", "PBXBuildFile", f"productRef = {reference('sdk-product')};")
add("frameworks-phase", "PBXFrameworksBuildPhase", f"buildActionMask = 2147483647; files = ({reference('sdk-build')}); runOnlyForDeploymentPostprocessing = 0;")
add("resources-phase", "PBXResourcesBuildPhase", "buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
add("sdk", "XCRemoteSwiftPackageReference", f'repositoryURL = "https://github.com/team-telnyx/telnyx-webrtc-ios.git"; requirement = {{kind = revision; revision = {SDK_REVISION};}};')
add("sdk-product", "XCSwiftPackageProductDependency", f'package = {reference("sdk")}; productName = "telnyx-webrtc-ios";')

for config in ["Debug", "Release"]:
    settings = {"SDKROOT": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": "16.0", "SWIFT_VERSION": "5.0",
                "CLANG_ENABLE_MODULES": "YES", "ENABLE_BITCODE": "NO"}
    if config == "Debug": settings.update({"SWIFT_OPTIMIZATION_LEVEL": "-Onone", "DEBUG_INFORMATION_FORMAT": "dwarf", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG"})
    else: settings.update({"SWIFT_OPTIMIZATION_LEVEL": "-O", "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym"})
    add("project-" + config, "XCBuildConfiguration", f"name = {config}; buildSettings = {{{' '.join(k + ' = ' + quoted(v) + ';' for k,v in settings.items())}}};")
    target = {"PRODUCT_NAME": NAME, "PRODUCT_BUNDLE_IDENTIFIER": "local.sprout.recruit.callpilot",
              "INFOPLIST_FILE": "Info.plist", "GENERATE_INFOPLIST_FILE": "NO", "CODE_SIGN_STYLE": "Automatic",
              "TARGETED_DEVICE_FAMILY": "1", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
              "SUPPORTS_MACCATALYST": "NO", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks"}
    add("target-" + config, "XCBuildConfiguration", f"name = {config}; buildSettings = {{{' '.join(k + ' = ' + quoted(v) + ';' for k,v in target.items())}}};")

for owner in ["project", "target"]:
    add(owner + "-configs", "XCConfigurationList", f"buildConfigurations = ({reference(owner + '-Debug')},{reference(owner + '-Release')}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
add("target", "PBXNativeTarget", f"buildConfigurationList = {reference('target-configs')}; buildPhases = ({reference('sources-phase')},{reference('frameworks-phase')},{reference('resources-phase')}); buildRules = (); dependencies = (); name = {NAME}; productName = {NAME}; productReference = {reference('product')}; productType = \"com.apple.product-type.application\"; packageProductDependencies = ({reference('sdk-product')});")
add("project", "PBXProject", f"attributes = {{LastUpgradeCheck = 1600;}}; buildConfigurationList = {reference('project-configs')}; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base); mainGroup = {reference('root')}; productRefGroup = {reference('products')}; projectDirPath = \"\"; projectRoot = \"\"; targets = ({reference('target')}); packageReferences = ({reference('sdk')});")

project = ROOT / f"{NAME}.xcodeproj"
project.mkdir(exist_ok=True)
(project / "project.pbxproj").write_text("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n" + "\n".join(objects) + "\n\t};\n\trootObject = " + reference("project") + ";\n}\n")
schemes = project / "xcshareddata" / "xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
buildable = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{reference("target")}" BuildableName="{NAME}.app" BlueprintName="{NAME}" ReferencedContainer="container:{NAME}.xcodeproj"/>'
(schemes / f"{NAME}.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildable}</BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(f"Created {project.name}; open in Xcode and select your signing team. No packages fetched or calls placed.")
