"""Generate the dependency-free Xcode project; source folders auto-synchronize."""
from pathlib import Path
import hashlib

def ident(s): return hashlib.sha1(s.encode()).hexdigest()[:24].upper()
objects = []
def add(name, text):
    objects.append(f'{ident(name)} = {{ {text} }};')
    return ident(name)
project = ident('project')
configs = {}
for scope in ['project', 'app', 'tests', 'uitests']:
    refs = []
    for config in ['Debug', 'Release']:
        settings = {'SWIFT_VERSION':'5.0','IPHONEOS_DEPLOYMENT_TARGET':'26.0','SDKROOT':'iphoneos','TARGETED_DEVICE_FAMILY':'1','CLANG_ENABLE_MODULES':'YES','SWIFT_STRICT_CONCURRENCY':'targeted'}
        if scope == 'project':
            settings.update({'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if config=='Debug' else '-O','DEBUG_INFORMATION_FORMAT':'dwarf','ENABLE_TESTABILITY':'YES' if config=='Debug' else 'NO','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG' if config=='Debug' else ''})
        else:
            settings.update({'PRODUCT_NAME':'$(TARGET_NAME)','PRODUCT_BUNDLE_IDENTIFIER':{'app':'com.hydrotone.app','tests':'com.hydrotone.tests','uitests':'com.hydrotone.uitests'}[scope], 'GENERATE_INFOPLIST_FILE':'YES','CODE_SIGN_STYLE':'Automatic','DEVELOPMENT_TEAM':'M3HJ7YK7N7'})
        if scope == 'app':
            settings.update({'INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription':'Save your finished photos and videos to your library.','INFOPLIST_KEY_UILaunchScreen_Generation':'YES','INFOPLIST_KEY_UIApplicationSceneManifest_Generation':'YES','INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone':'UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight','CODE_SIGN_ENTITLEMENTS':'HydroTone/Resources/HydroTone.entitlements','ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','MARKETING_VERSION':'1.0','CURRENT_PROJECT_VERSION':'1','INFOPLIST_KEY_CFBundleDisplayName':'HydroTone'})
        if scope == 'tests': settings.update({'TEST_HOST':'$(BUILT_PRODUCTS_DIR)/HydroTone.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/HydroTone','BUNDLE_LOADER':'$(TEST_HOST)'})
        if scope == 'uitests': settings['TEST_TARGET_NAME']='HydroTone'
        body=' '.join(f'{k} = "{v}";' for k,v in settings.items())
        refs.append(add(scope+config,f'isa = XCBuildConfiguration; buildSettings = {{ {body} }}; name = {config};'))
    configs[scope] = add(scope+'configlist',f'isa = XCConfigurationList; buildConfigurations = ({",".join(refs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
products=[]; groups=[]; targets=[]
for scope,name,kind in [('app','HydroTone','application'),('tests','HydroToneTests','bundle.unit-test'),('uitests','HydroToneUITests','bundle.ui-testing')]:
    group=add(scope+'group',f'isa = PBXFileSystemSynchronizedRootGroup; path = {name}; sourceTree = "<group>";')
    groups.append(group)
    ext='app' if scope=='app' else 'xctest'
    product=add(scope+'product',f'isa = PBXFileReference; explicitFileType = {"wrapper.application" if scope=="app" else "wrapper.cfbundle"}; path = {name}.{ext}; sourceTree = BUILT_PRODUCTS_DIR;')
    products.append(product)
    phases=[add(scope+p,f'isa = PBX{p}BuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;') for p in ['Sources','Frameworks','Resources']]
    deps=[]
    if scope!='app':
        proxy=add(scope+'proxy',f'isa = PBXContainerItemProxy; containerPortal = {project}; proxyType = 1; remoteGlobalIDString = {ident("apptarget")}; remoteInfo = HydroTone;')
        deps.append(add(scope+'dep',f'isa = PBXTargetDependency; target = {ident("apptarget")}; targetProxy = {proxy};'))
    targets.append(add(scope+'target',f'isa = PBXNativeTarget; buildConfigurationList = {configs[scope]}; buildPhases = ({",".join(phases)},); buildRules = (); dependencies = ({",".join(deps)}); fileSystemSynchronizedGroups = ({group},); name = {name}; productName = {name}; productReference = {product}; productType = "com.apple.product-type.{kind}";'))
pg=add('products',f'isa = PBXGroup; children = ({",".join(products)},); name = Products; sourceTree = "<group>";')
main=add('main',f'isa = PBXGroup; children = ({",".join(groups+[pg])},); sourceTree = "<group>";')
add('project',f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2700; }}; buildConfigurationList = {configs["project"]}; compatibilityVersion = "Xcode 16.0"; developmentRegion = en; knownRegions = (en,Base,ko,ja,"zh-Hans","zh-Hant"); mainGroup = {main}; productRefGroup = {pg}; projectDirPath = ""; projectRoot = ""; targets = ({",".join(targets)},); preferredProjectObjectVersion = 77;')
Path('HydroTone.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 77; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {project}; }}\n')
def ref(scope,name): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident(scope+"target")}" BuildableName="{name}.{ "app" if scope=="app" else "xctest"}" BlueprintName="{name}" ReferencedContainer="container:HydroTone.xcodeproj"/>'
Path('HydroTone.xcodeproj/xcshareddata/xcschemes/HydroTone.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref('app','HydroTone')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref('tests','HydroToneTests')}</TestableReference><TestableReference skipped="NO">{ref('uitests','HydroToneUITests')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref('app','HydroTone')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref('app','HydroTone')}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
