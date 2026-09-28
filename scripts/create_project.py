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
for scope in ['project', 'app', 'tests', 'uitests', 'share']:
    refs = []
    for config in ['Debug', 'Release']:
        settings = {'SWIFT_VERSION':'6.0','IPHONEOS_DEPLOYMENT_TARGET':'26.0','SDKROOT':'iphoneos','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','TARGETED_DEVICE_FAMILY':'1','SUPPORTS_MACCATALYST':'NO','SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD':'NO','SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD':'NO','CLANG_ENABLE_MODULES':'YES','SWIFT_APPROACHABLE_CONCURRENCY':'YES'}
        if scope == 'project':
            settings.update({'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if config=='Debug' else '-O','DEBUG_INFORMATION_FORMAT':'dwarf' if config=='Debug' else 'dwarf-with-dsym','ENABLE_TESTABILITY':'YES' if config=='Debug' else 'NO','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG' if config=='Debug' else ''})
            if config == 'Debug': settings['COPY_PHASE_STRIP'] = 'NO'  # the embedded extension is signed; stripping it only warns
            if config == 'Release': settings.update({'SWIFT_COMPILATION_MODE':'wholemodule','VALIDATE_PRODUCT':'YES','DEAD_CODE_STRIPPING':'YES','COPY_PHASE_STRIP':'YES','ENABLE_NS_ASSERTIONS':'NO'})
        else:
            settings.update({'PRODUCT_NAME':'$(TARGET_NAME)','PRODUCT_BUNDLE_IDENTIFIER':{'app':'com.underblue.app','tests':'com.underblue.tests','uitests':'com.underblue.uitests','share':'com.underblue.app.share'}[scope], 'GENERATE_INFOPLIST_FILE':'YES','CODE_SIGN_STYLE':'Automatic','DEVELOPMENT_TEAM':'M3HJ7YK7N7'})
        if scope == 'app':
            settings.update({'INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription':'Save your finished photos and videos to your library.','INFOPLIST_KEY_ITSAppUsesNonExemptEncryption':'NO','INFOPLIST_KEY_LSApplicationCategoryType':'public.app-category.photography','INFOPLIST_KEY_UILaunchScreen_Generation':'YES','INFOPLIST_KEY_UIApplicationSceneManifest_Generation':'YES','INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone':'UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight','CODE_SIGN_ENTITLEMENTS':'UnderBlue/Resources/UnderBlue.entitlements','ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','MARKETING_VERSION':'1.0','CURRENT_PROJECT_VERSION':'1','INFOPLIST_KEY_CFBundleDisplayName':'UnderBlue','INFOPLIST_FILE':'UnderBlue/Resources/Info.plist'})
        if scope == 'tests': settings.update({'TEST_HOST':'$(BUILT_PRODUCTS_DIR)/UnderBlue.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/UnderBlue','BUNDLE_LOADER':'$(TEST_HOST)'})
        if scope == 'uitests': settings['TEST_TARGET_NAME']='UnderBlue'
        # The share extension's versions must match the app's, or App Store validation rejects the build.
        if scope == 'share': settings.update({'CODE_SIGN_ENTITLEMENTS':'UnderBlueShare/UnderBlueShare.entitlements','INFOPLIST_FILE':'UnderBlueShare/Info.plist','INFOPLIST_KEY_CFBundleDisplayName':'UnderBlue','MARKETING_VERSION':'1.0','CURRENT_PROJECT_VERSION':'1','SKIP_INSTALL':'YES','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'})
        body=' '.join(f'{k} = "{v}";' for k,v in settings.items())
        refs.append(add(scope+config,f'isa = XCBuildConfiguration; buildSettings = {{ {body} }}; name = {config};'))
    configs[scope] = add(scope+'configlist',f'isa = XCConfigurationList; buildConfigurations = ({",".join(refs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
products=[]; groups=[]; targets=[]
share_target=ident('sharetarget')
for scope,name,kind in [('app','UnderBlue','application'),('tests','UnderBlueTests','bundle.unit-test'),('uitests','UnderBlueUITests','bundle.ui-testing'),('share','UnderBlueShare','app-extension')]:
    # Developer media (UIEB, dive clips, market pairs) lives in DeveloperMedia/ at the repo root, outside every
    # synchronized group. Anything under UnderBlueTests/ ships in the test bundle, git-ignored or not.
    exceptions=''
    # The share extension also compiles SharedInbox.swift from the app folder. An Info.plist is not a resource.
    exception_sets={'app':[('exceptions','Import/SharedInbox.swift',share_target),('plistexceptions','Resources/Info.plist',ident('apptarget'))],
                    'share':[('exceptions','Info.plist',share_target)]}.get(scope,[])
    if exception_sets:
        sets=[add(scope+key,f'isa = PBXFileSystemSynchronizedBuildFileExceptionSet; membershipExceptions = ({files},); target = {target};') for key,files,target in exception_sets]
        exceptions=f'exceptions = ({",".join(sets)},); '
    group=add(scope+'group',f'isa = PBXFileSystemSynchronizedRootGroup; {exceptions}path = {name}; sourceTree = "<group>";')
    groups.append(group)
    ext={'app':'app','share':'appex'}.get(scope,'xctest')
    filetype={'app':'wrapper.application','share':'"wrapper.app-extension"'}.get(scope,'wrapper.cfbundle')
    product=add(scope+'product',f'isa = PBXFileReference; explicitFileType = {filetype}; path = {name}.{ext}; sourceTree = BUILT_PRODUCTS_DIR;')
    products.append(product)
    phases=[add(scope+p,f'isa = PBX{p}BuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;') for p in ['Sources','Frameworks','Resources']]
    deps=[]
    if scope=='app':
        # The app embeds the share extension and builds it first.
        embedded=add('appembedfile',f'isa = PBXBuildFile; fileRef = {ident("shareproduct")}; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }};')
        phases.append(add('appembed',f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 13; files = ({embedded},); name = "Embed Foundation Extensions"; runOnlyForDeploymentPostprocessing = 0;'))
        proxy=add('appshareproxy',f'isa = PBXContainerItemProxy; containerPortal = {project}; proxyType = 1; remoteGlobalIDString = {share_target}; remoteInfo = UnderBlueShare;')
        deps.append(add('appsharedep',f'isa = PBXTargetDependency; target = {share_target}; targetProxy = {proxy};'))
    elif scope!='share':
        proxy=add(scope+'proxy',f'isa = PBXContainerItemProxy; containerPortal = {project}; proxyType = 1; remoteGlobalIDString = {ident("apptarget")}; remoteInfo = UnderBlue;')
        deps.append(add(scope+'dep',f'isa = PBXTargetDependency; target = {ident("apptarget")}; targetProxy = {proxy};'))
    targets.append(add(scope+'target',f'isa = PBXNativeTarget; buildConfigurationList = {configs[scope]}; buildPhases = ({",".join(phases)},); buildRules = (); dependencies = ({",".join(deps)}); fileSystemSynchronizedGroups = ({group},); name = {name}; productName = {name}; productReference = {product}; productType = "com.apple.product-type.{kind}";'))
pg=add('products',f'isa = PBXGroup; children = ({",".join(products)},); name = Products; sourceTree = "<group>";')
main=add('main',f'isa = PBXGroup; children = ({",".join(groups+[pg])},); sourceTree = "<group>";')
add('project',f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2700; }}; buildConfigurationList = {configs["project"]}; compatibilityVersion = "Xcode 16.0"; developmentRegion = en; knownRegions = (en,Base,ko,ja,"zh-Hans","zh-Hant"); mainGroup = {main}; productRefGroup = {pg}; projectDirPath = ""; projectRoot = ""; targets = ({",".join(targets)},); preferredProjectObjectVersion = 77;')
Path('UnderBlue.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 77; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {project}; }}\n')
def ref(scope,name): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident(scope+"target")}" BuildableName="{name}.{ "app" if scope=="app" else "xctest"}" BlueprintName="{name}" ReferencedContainer="container:UnderBlue.xcodeproj"/>'
Path('UnderBlue.xcodeproj/xcshareddata/xcschemes/UnderBlue.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref('app','UnderBlue')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref('tests','UnderBlueTests')}</TestableReference><TestableReference skipped="NO">{ref('uitests','UnderBlueUITests')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref('app','UnderBlue')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref('app','UnderBlue')}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
