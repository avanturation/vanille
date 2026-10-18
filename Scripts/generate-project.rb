#!/usr/bin/env ruby
# Uses only Ruby's standard library; generated project is checked in.
require 'digest'
root = File.expand_path('..', __dir__)
def uid(s)
  Digest::SHA256.hexdigest(s)[0,24].upcase
end
files = Dir.chdir(root) { Dir['Vanille/**/*.swift'].sort }
objects = []
files.each do |path|
  objects << "#{uid(path)} = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = \"#{path}\"; sourceTree = \"<group>\"; };"
  objects << "#{uid('build'+path)} = {isa = PBXBuildFile; fileRef = #{uid(path)}; };"
end
objects << "#{uid('info')} = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Vanille/Resources/Info.plist; sourceTree = \"<group>\"; };"
objects << "#{uid('version')} = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Config/Version.xcconfig; sourceTree = \"<group>\"; };"
objects << "#{uid('license')} = {isa = PBXFileReference; lastKnownFileType = text; path = LICENSE; sourceTree = \"<group>\"; };"
objects << "#{uid('licensebuild')} = {isa = PBXBuildFile; fileRef = #{uid('license')}; };"
objects << "#{uid('app')} = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Vanille.app; sourceTree = BUILT_PRODUCTS_DIR; };"
objects << "#{uid('main')} = {isa = PBXGroup; children = (#{uid('sources')},#{uid('products')}); sourceTree = \"<group>\"; };"
objects << "#{uid('sources')} = {isa = PBXGroup; name = Sources; children = (#{(files.map { |f| uid(f) } + [uid('info'),uid('version'),uid('license')]).join(',')}); sourceTree = \"<group>\"; };"
objects << "#{uid('products')} = {isa = PBXGroup; name = Products; children = (#{uid('app')}); sourceTree = \"<group>\"; };"
objects << "#{uid('sourcephase')} = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (#{files.map { |f| uid('build'+f) }.join(',')}); runOnlyForDeploymentPostprocessing = 0; };"
objects << "#{uid('frameworkphase')} = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };"
objects << "#{uid('resourcephase')} = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (#{uid('licensebuild')}); runOnlyForDeploymentPostprocessing = 0; };"
objects << "#{uid('target')} = {isa = PBXNativeTarget; buildConfigurationList = #{uid('targetconfigs')}; buildPhases = (#{uid('sourcephase')},#{uid('frameworkphase')},#{uid('resourcephase')}); buildRules = (); dependencies = (); name = Vanille; productName = Vanille; productReference = #{uid('app')}; productType = \"com.apple.product-type.application\"; };"
objects << "#{uid('project')} = {isa = PBXProject; attributes = {BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1600; }; buildConfigurationList = #{uid('projectconfigs')}; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base); mainGroup = #{uid('main')}; productRefGroup = #{uid('products')}; projectDirPath = \"\"; projectRoot = \"\"; targets = (#{uid('target')}); };"
['Debug','Release'].each do |config|
  objects << "#{uid('project'+config)} = {isa = XCBuildConfiguration; baseConfigurationReference = #{uid('version')}; buildSettings = {SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; ARCHS = arm64; CLANG_ENABLE_MODULES = YES; }; name = #{config}; };"
  optimization = config == 'Release' ? '-O' : '-Onone'
  objects << "#{uid('target'+config)} = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = com.avanturation.Vanille; PRODUCT_NAME = Vanille; INFOPLIST_FILE = Vanille/Resources/Info.plist; GENERATE_INFOPLIST_FILE = NO; CODE_SIGN_STYLE = Manual; CODE_SIGN_IDENTITY = \"-\"; ENABLE_APP_SANDBOX = NO; ENABLE_HARDENED_RUNTIME = NO; SWIFT_VERSION = 5.0; SWIFT_STRICT_CONCURRENCY = minimal; SWIFT_OPTIMIZATION_LEVEL = \"#{optimization}\"; LD_RUNPATH_SEARCH_PATHS = \"$(inherited) @executable_path/../Frameworks\"; COMBINE_HIDPI_IMAGES = YES; }; name = #{config}; };"
end
['project','target'].each do |kind|
  objects << "#{uid(kind+'configs')} = {isa = XCConfigurationList; buildConfigurations = (#{uid(kind+'Debug')},#{uid(kind+'Release')}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };"
end
File.write(File.join(root,'Vanille.xcodeproj/project.pbxproj'), "// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n#{objects.join("\n")}\n}; rootObject = #{uid('project')}; }\n")
File.write(File.join(root,'Vanille.xcodeproj/xcshareddata/xcschemes/Vanille.xcscheme'), <<~XML)
<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="#{uid('target')}" BuildableName="Vanille.app" BlueprintName="Vanille" ReferencedContainer="container:Vanille.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="#{uid('target')}" BuildableName="Vanille.app" BlueprintName="Vanille" ReferencedContainer="container:Vanille.xcodeproj"/></BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="#{uid('target')}" BuildableName="Vanille.app" BlueprintName="Vanille" ReferencedContainer="container:Vanille.xcodeproj"/></BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
XML
puts 'Generated Vanille.xcodeproj'
