@echo off
setlocal enabledelayedexpansion

echo Detecting connected devices... >&2
set count=0

rem Parse adb devices output to find authorized devices
for /f "tokens=1,2" %%A in ('adb devices') do (
    if "%%B"=="device" (
        set /a count+=1
        set "device[!count!]=%%A"
    )
)

if !count!==0 (
    echo Error: No authorized devices connected via ADB. >&2
    goto :EOF
)

if !count!==1 (
    set "TARGET_SERIAL=!device[1]!"
    echo Found 1 device: !TARGET_SERIAL! >&2
    goto :Extract
)

rem Menu for multiple devices
echo Multiple devices detected: >&2
for /L %%I in (1,1,!count!) do (
    for /f "delims=" %%M in ('adb -s !device[%%I]! shell "getprop ro.product.model | tr -d '\r'"') do set "model_name=%%M"
    echo [%%I] !device[%%I]! - !model_name! >&2
)

:PromptUser
rem Ensure the prompt itself prints to standard error so it remains visible
set /p choice="Select a device (1-!count!): " >&2
if "!device[%choice%]!"=="" (
    echo Invalid selection. Please try again. >&2
    goto :PromptUser
)

set "TARGET_SERIAL=!device[%choice%]!"
echo Selected device: !TARGET_SERIAL! >&2

:Extract
call :FetchProp brand ro.product.brand
call :FetchProp manufacturer ro.product.manufacturer
call :FetchProp model ro.product.model
call :FetchProp productName ro.product.name
call :FetchProp deviceCode ro.product.device
call :FetchProp board ro.product.board
call :FetchProp hardware ro.hardware
call :FetchProp boardPlatform ro.board.platform
call :FetchProp buildFingerprint ro.build.fingerprint
call :FetchProp buildId ro.build.id
call :FetchProp buildDisplayId ro.build.display.id
call :FetchProp buildIncremental ro.build.version.incremental
call :FetchProp buildRelease ro.build.version.release
call :FetchProp buildSdk ro.build.version.sdk
call :FetchProp securityPatch ro.build.version.security_patch
call :FetchProp buildDescription ro.build.description
call :FetchProp buildFlavor ro.build.flavor
call :FetchProp buildProduct ro.build.product
call :FetchProp buildCharacteristics ro.build.characteristics

rem Extract integer metrics for screen
for /f "tokens=3 delims= " %%i in ('adb -s "!TARGET_SERIAL!" shell "wm size | tr -d '\r'"') do set wm_size=%%i
for /f "tokens=1,2 delims=x" %%a in ("!wm_size!") do (
    set screenWidth=%%a
    set screenHeight=%%b
)
for /f "tokens=3 delims= " %%i in ('adb -s "!TARGET_SERIAL!" shell "wm density | tr -d '\r'"') do set screenDensity=%%i

rem Extract telephony and misc (cutting at comma for primary SIM)
call :FetchPropCut operatorAlpha gsm.operator.alpha
call :FetchPropCut operatorNumeric gsm.operator.numeric
call :FetchPropCut simOperatorAlpha gsm.sim.operator.alpha
call :FetchPropCut simOperatorNumeric gsm.sim.operator.numeric
call :FetchPropCut simCountryIso gsm.sim.operator.iso-country
call :FetchProp timezone persist.sys.timezone
call :FetchProp socModel ro.soc.model
call :FetchProp socManufacturer ro.soc.manufacturer

rem Fallbacks for null/missing properties
if "!socModel!"=="" set socModel=!boardPlatform!
if "!buildSdk!"=="" set buildSdk=0
if "!screenWidth!"=="" set screenWidth=0
if "!screenHeight!"=="" set screenHeight=0
if "!screenDensity!"=="" set screenDensity=0

rem Generate JSON to stdout
echo {
echo     "id": "!deviceCode!",
echo     "brandLabel": "!manufacturer!",
echo     "modelLabel": "!model!",
echo     "summary": "!socModel! - Android !buildRelease!",
echo     "profile": {
echo         "brand": "!brand!",
echo         "manufacturer": "!manufacturer!",
echo         "model": "!model!",
echo         "productName": "!productName!",
echo         "deviceCode": "!deviceCode!",
echo         "board": "!board!",
echo         "hardware": "!hardware!",
echo         "boardPlatform": "!boardPlatform!",
echo         "buildFingerprint": "!buildFingerprint!",
echo         "buildId": "!buildId!",
echo         "buildDisplayId": "!buildDisplayId!",
echo         "buildIncremental": "!buildIncremental!",
echo         "buildRelease": "!buildRelease!",
echo         "buildSdk": !buildSdk!,
echo         "securityPatch": "!securityPatch!",
echo         "buildDescription": "!buildDescription!",
echo         "buildFlavor": "!buildFlavor!",
echo         "buildProduct": "!buildProduct!",
echo         "buildCharacteristics": "!buildCharacteristics!",
echo         "screenWidth": !screenWidth!,
echo         "screenHeight": !screenHeight!,
echo         "screenDensity": !screenDensity!,
echo         "operatorAlpha": "!operatorAlpha!",
echo         "operatorNumeric": "!operatorNumeric!",
echo         "simOperatorAlpha": "!simOperatorAlpha!",
echo         "simOperatorNumeric": "!simOperatorNumeric!",
echo         "simCountryIso": "!simCountryIso!",
echo         "timezone": "!timezone!",
echo         "socModel": "!socModel!",
echo         "socManufacturer": "!socManufacturer!"
echo     }
echo }

goto :EOF

:FetchProp
set "%~1="
for /f "delims=" %%i in ('adb -s "!TARGET_SERIAL!" shell "getprop %~2 | tr -d '\r'"') do set "%~1=%%i"
goto :EOF

:FetchPropCut
set "%~1="
for /f "delims=" %%i in ('adb -s "!TARGET_SERIAL!" shell "getprop %~2 | tr -d '\r' | cut -d',' -f1"') do set "%~1=%%i"
goto :EOF