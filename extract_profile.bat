@echo off
setlocal
rem Embedded PowerShell keeps JSON and device values out of cmd.exe expansion.
set "EXTRACT_PROFILE_SCRIPT=%~f0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "try { $source = [IO.File]::ReadAllText($env:EXTRACT_PROFILE_SCRIPT); $code = ($source -split '(?m)^# POWERSHELL_PAYLOAD\r?$', 2)[1]; if (-not $code) { throw 'Embedded script is missing.' }; & ([ScriptBlock]::Create($code)) } catch { [Console]::Error.WriteLine($_.Exception.Message); [Console]::Error.WriteLine('Press any key to exit...'); try { [void][Console]::ReadKey($true) } catch { [void](Read-Host) }; exit 1 }"
exit /b %errorlevel%
# POWERSHELL_PAYLOAD
$ErrorActionPreference = 'Stop'
$action = 'com.spoofmydevice.ACTION_SEND_CONFIG'
$receiverPackage = 'com.spoofmydevice'
$skipPause = $false
$exitCode = 1
function Log([string]$Message) {
    [Console]::Error.WriteLine(('[{0:HH:mm:ss}] {1}' -f (Get-Date), $Message))
}
function Prompt([string]$Message) {
    [Console]::Error.Write($Message)
    return [Console]::ReadLine()
}
function Quote-Native([string]$Value) {
    # Windows CreateProcess quoting, including quotes and trailing backslashes.
    return '"' + (($Value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}
function Invoke-Adb([string[]]$Arguments, [int]$TimeoutMilliseconds = 30000) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $script:adbPath
    $info.Arguments = (($Arguments | ForEach-Object { Quote-Native $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $process.Kill()
            throw 'ADB timed out. Check the device connection.'
        }
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        if ($stderr.Trim()) { Log ('ADB: ' + $stderr.Trim()) }
        if ($process.ExitCode -ne 0) { throw ('ADB exited with code {0}: {1} {2}' -f $process.ExitCode, $stdout.Trim(), $stderr.Trim()) }
        return $stdout.TrimEnd([char[]]@(13, 10))
    } finally { $process.Dispose() }
}
function Device-Shell([string]$Command) {
    return Invoke-Adb @('-s', $script:serial, 'shell', $Command)
}
function Get-Devices([int]$TimeoutMilliseconds = 30000) {
    $output = Invoke-Adb -Arguments @('devices') -TimeoutMilliseconds $TimeoutMilliseconds
    foreach ($line in ($output -split '\r?\n')) {
        if ($line -match '^(\S+)\s+device\s*$') { $matches[1] }
    }
}
function Has-RegisteredReceiver([string]$Output) {
    # Inspect live registrations only, excluding manifest receivers and history.
    if ($Output -notmatch '(?s)Registered Receivers:(.*?)(?:Receiver Resolver Table:|Historical broadcasts|Active broadcasts|Pending broadcasts|Sticky broadcasts|$)') { return $false }
    $registered = $matches[1]
    $packagePattern = '(?<![\w.])' + [regex]::Escape($receiverPackage) + '(?![\w.])'
    foreach ($block in ($registered -split '(?m)^\s*\*?\s*ReceiverList\{')) {
        if ($block -match $packagePattern -and $block.Contains($action)) { return $true }
    }
    return $false
}
function Find-ReceiverDevice {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    Log "Waiting up to 90 seconds for an active registered receiver for $action..."
    while ($timer.Elapsed.TotalSeconds -lt 90) {
        $found = @()
        try {
            $remaining = [Math]::Max(1, 90000 - [int]$timer.Elapsed.TotalMilliseconds)
            $connected = @(Get-Devices -TimeoutMilliseconds ([Math]::Min(5000, $remaining)))
            foreach ($candidate in $connected) {
                $remaining = 90000 - [int]$timer.Elapsed.TotalMilliseconds
                if ($remaining -le 0) { break }
                try {
                    $output = Invoke-Adb -Arguments @('-s', $candidate, 'shell', 'dumpsys activity broadcasts') -TimeoutMilliseconds ([Math]::Min(5000, $remaining))
                    if (Has-RegisteredReceiver $output) { $found += $candidate }
                } catch { Log ("WARNING: Receiver check on $candidate failed: " + $_.Exception.Message) }
            }
        } catch { Log ('WARNING: Device scan failed: ' + $_.Exception.Message) }
        if ($timer.Elapsed.TotalSeconds -ge 90) { break }
        if ($found.Count -gt 1) { throw ('Multiple devices have active registered receivers: ' + ($found -join ', ') + '. Keep the receiving app active on only one device.') }
        if ($found.Count -eq 1) { return $found[0] }
        Start-Sleep -Milliseconds ([Math]::Min(1000, [Math]::Max(1, 90000 - [int]$timer.Elapsed.TotalMilliseconds)))
    }
    $script:skipPause = $true
    throw 'No active registered receiver detected within 90 seconds.'
}
function Json-Integer([string]$Value, [string]$Name) {
    [long]$number = 0
    if ($Value -notmatch '^\d+$' -or -not [long]::TryParse($Value, [ref]$number)) {
        Log "WARNING: Invalid or missing $Name; defaulting to zero."
        return 0
    }
    return $number
}
try {
    $script:adbPath = (Get-Command adb -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    Log "Using ADB: $script:adbPath"
    Log ('Launch directory: ' + (Get-Location).Path)
    $receiverSerial = Find-ReceiverDevice
    Log "Receiver device: $receiverSerial"
    $devices = @(Get-Devices | Where-Object { $_ -ne $receiverSerial })
    if ($devices.Count -eq 0) { throw 'No authorized source device connected besides the receiver device.' }
    if ($devices.Count -eq 1) {
        $script:serial = $devices[0]
    } else {
        for ($i = 0; $i -lt $devices.Count; $i++) {
            $modelName = Invoke-Adb @('-s', $devices[$i], 'shell', 'getprop ro.product.model')
            Log ('[{0}] {1} - {2}' -f ($i + 1), $devices[$i], $modelName)
        }
        while ($true) {
            $answer = Prompt ('Select a source device (1-{0}): ' -f $devices.Count)
            if ($null -eq $answer) { throw 'Input closed before device selection.' }
            $selection = 0
            if ([int]::TryParse($answer, [ref]$selection) -and $selection -ge 1 -and $selection -le $devices.Count) { break }
            Log 'Invalid selection. Please try again.'
        }
        $script:serial = $devices[$selection - 1]
    }
    Log "Profile source device: $script:serial"
    $profile = [ordered]@{}
    $properties = [ordered]@{
        brand = 'ro.product.brand'
        manufacturer = 'ro.product.manufacturer'
        model = 'ro.product.model'
        productName = 'ro.product.name'
        deviceCode = 'ro.product.device'
        board = 'ro.product.board'
        hardware = 'ro.hardware'
        boardPlatform = 'ro.board.platform'
        buildFingerprint = 'ro.build.fingerprint'
        buildId = 'ro.build.id'
        buildDisplayId = 'ro.build.display.id'
        buildIncremental = 'ro.build.version.incremental'
        buildRelease = 'ro.build.version.release'
        buildSdk = 'ro.build.version.sdk'
        securityPatch = 'ro.build.version.security_patch'
        buildDescription = 'ro.build.description'
        buildFlavor = 'ro.build.flavor'
        buildProduct = 'ro.build.product'
        buildCharacteristics = 'ro.build.characteristics'
        operatorAlpha = 'gsm.operator.alpha'
        operatorNumeric = 'gsm.operator.numeric'
        simOperatorAlpha = 'gsm.sim.operator.alpha'
        simOperatorNumeric = 'gsm.sim.operator.numeric'
        simCountryIso = 'gsm.sim.operator.iso-country'
        timezone = 'persist.sys.timezone'
        socModel = 'ro.soc.model'
        socManufacturer = 'ro.soc.manufacturer'
    }
    foreach ($name in $properties.Keys) {
        Log ('Reading property ' + $properties[$name])
        $value = Device-Shell ('getprop ' + $properties[$name])
        if (-not $value) { Log ('WARNING: Empty property ' + $properties[$name]) }
        if ($name -in @('operatorAlpha','operatorNumeric','simOperatorAlpha','simOperatorNumeric','simCountryIso')) { $value = ($value -split ',', 2)[0] }
        $profile[$name] = $value
    }
    if (-not $profile.socModel) { $profile.socModel = $profile.boardPlatform }
    $profile.buildSdk = Json-Integer $profile.buildSdk 'buildSdk'
    Log 'Reading screen size and density...'
    $sizeOutput = Device-Shell 'wm size'
    $densityOutput = Device-Shell 'wm density'
    $sizes = [regex]::Matches($sizeOutput, 'size:\s*([0-9]+)x([0-9]+)')
    $densities = [regex]::Matches($densityOutput, 'density:\s*([0-9]+)')
    $profile.screenWidth = 0
    $profile.screenHeight = 0
    $profile.screenDensity = 0
    if ($sizes.Count) {
        $profile.screenWidth = Json-Integer $sizes[$sizes.Count - 1].Groups[1].Value 'screenWidth'
        $profile.screenHeight = Json-Integer $sizes[$sizes.Count - 1].Groups[2].Value 'screenHeight'
    } else { Log 'WARNING: Missing screen size; defaulting to zero.' }
    if ($densities.Count) {
        $profile.screenDensity = Json-Integer $densities[$densities.Count - 1].Groups[1].Value 'screenDensity'
    } else { Log 'WARNING: Missing screen density; defaulting to zero.' }
    Log ('Screen: {0}x{1}, density {2}' -f $profile.screenWidth, $profile.screenHeight, $profile.screenDensity)
    $config = [ordered]@{
        id = $profile.deviceCode
        brandLabel = $profile.manufacturer
        modelLabel = $profile.model
        summary = ($profile.socModel + ' - Android ' + $profile.buildRelease)
        profile = $profile
    }
    $json = ConvertTo-Json -InputObject $config -Depth 4 -Compress
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    [Console]::WriteLine($json)
    Log ('Extraction complete ({0} JSON characters).' -f $json.Length)
    # Recheck the original destination; never redirect delivery to another device.
    $liveOutput = Invoke-Adb @('-s', $receiverSerial, 'shell', 'dumpsys activity broadcasts')
    if (-not (Has-RegisteredReceiver $liveOutput)) { throw "Registered receiver is no longer active on $receiverSerial. Nothing was sent." }
    $receiverAvailable = $true
    $broadcastOk = $false
    try {
        # Protect JSON from the remote shell as well as Windows argument parsing.
        $apostrophe = [string][char]39
        $quotedJson = $apostrophe + $json.Replace($apostrophe, ($apostrophe + '\' + $apostrophe + $apostrophe)) + $apostrophe
        Log "Sending JSON to receiver device $receiverSerial in the broadcast content extra..."
        $result = Invoke-Adb @('-s', $receiverSerial, 'shell', "am broadcast --user current --include-stopped-packages -a $action --es content $quotedJson")
        Log $result
        $broadcastOk = $result.Contains('Broadcast completed:') -and $result -notmatch 'Error|Exception|Permission Denial'
    } catch { Log ('WARNING: Broadcast failed: ' + $_.Exception.Message) }
    if ($receiverAvailable -and $broadcastOk) {
        Log 'Broadcast dispatched to an available receiver. App-side import is not acknowledged by ADB.'
        $exitCode = 0
    } else {
        Log 'WARNING: No available receiver could be verified, or the broadcast failed.'
        $outputPath = Join-Path (Get-Location).Path 'output.json'
        $answer = Prompt "Create $outputPath instead? [y/N]: "
        if ($answer -match '^(?i)y(es)?$') {
            if (Test-Path -LiteralPath $outputPath) {
                $answer = Prompt 'output.json already exists. Overwrite it? [y/N]: '
                if ($answer -notmatch '^(?i)y(es)?$') { throw 'Existing output.json was preserved.' }
            }
            $tempOutput = Join-Path (Get-Location).Path ('.output.json.' + [guid]::NewGuid().ToString('N') + '.tmp')
            try {
                [IO.File]::WriteAllText($tempOutput, $json + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
                if ([IO.File]::Exists($outputPath)) { [IO.File]::Replace($tempOutput, $outputPath, [System.Management.Automation.Language.NullString]::Value) }
                else { [IO.File]::Move($tempOutput, $outputPath) }
            } finally {
                if ([IO.File]::Exists($tempOutput)) { [IO.File]::Delete($tempOutput) }
            }
            Log "Saved $outputPath"
            $exitCode = 0
        } else { throw 'JSON file declined; broadcast delivery was not verified.' }
    }
} catch { Log ('ERROR: ' + $_.Exception.Message) }
finally {
    if (-not $skipPause) {
    Log "Finished (exit status $exitCode). Press any key to exit..."
    try {
        if ([Console]::IsInputRedirected) { [void][Console]::Read() }
        else { [void][Console]::ReadKey($true) }
    } catch { Log ('Input unavailable: ' + $_.Exception.Message) }
    }
}
exit $exitCode
