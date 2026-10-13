# AMP writes AMP_server_settings.json; this converts typed values to the mod's TOML.
# No user settings are interpolated into executable commands.
[CmdletBinding()]
param([string]$BaseDirectory = $PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$culture = [Globalization.CultureInfo]::InvariantCulture
$utf8 = New-Object Text.UTF8Encoding($false)

function ConvertTo-TomlString([string]$Value) {
    # JSON string escaping is compatible with TOML basic strings, except \/.
    # Windows PowerShell can also emit \u0027 and other valid TOML escapes.
    return (ConvertTo-Json -InputObject $Value -Compress).Replace('\/', '/')
}

function ConvertTo-TomlValue($Value, $Default, [string]$Setting) {
    if ($null -eq $Value) { throw "Missing setting: $Setting" }
    if ($Default -is [bool]) {
        if ([string]$Value -notmatch '^(?i:true|false)$') {
            throw "Setting $Setting must be true or false."
        }
        return ([string]$Value).ToLowerInvariant()
    }
    if ($Default -is [array]) {
        # The AMP text input accepts a comma-separated list, not executable TOML.
        $items = @()
        if ($Value -is [array]) { $items = @($Value) }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$Value)) {
            $items = @(([string]$Value).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
        $known = @('debugMode', 'verboseLogging', 'logPlayerActions', 'logAdminCommands',
            'logNetworkingDebug', 'logMessageRoutingDebug', 'logMessagingBackendDebug',
            'logStartupDebug', 'logServerNetworkDebug', 'logPlayerLifecycleDebug', 'logAuthenticationDebug')
        foreach ($item in $items) {
            if ($item -cnotin $known) { throw "Unknown logging option in ${Setting}: $item" }
        }
        $quoted = @($items | ForEach-Object { ConvertTo-TomlString ([string]$_) })
        return '[' + ($quoted -join ', ') + ']'
    }
    if ($Default -is [string]) { return ConvertTo-TomlString ([string]$Value) }
    if ($Default -is [double] -or $Default -is [decimal] -or $Default -is [single]) {
        $number = 0.0
        if (-not [double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float, $culture, [ref]$number) -or
            [double]::IsNaN($number) -or [double]::IsInfinity($number)) {
            throw "Setting $Setting must be a finite number using a decimal point."
        }
        return $number.ToString('R', $culture)
    }
    $integer = [long]0
    if (-not [long]::TryParse([string]$Value, [Globalization.NumberStyles]::Integer, $culture, [ref]$integer)) {
        throw "Setting $Setting must be a whole number."
    }
    return $integer.ToString($culture)
}

$settingsPath = Join-Path $BaseDirectory 'AMP_server_settings.json'
$defaultsPath = Join-Path $BaseDirectory 'AMP_server_settings.default.json'
$templatePath = Join-Path $BaseDirectory 'AMP_server_config.default.toml'
foreach ($requiredPath in @($settingsPath, $defaultsPath, $templatePath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Configuration support file missing: $requiredPath. Run Update in AMP before starting the server."
    }
}
$settings = Get-Content -Raw -Encoding UTF8 -LiteralPath $settingsPath | ConvertFrom-Json
$defaults = Get-Content -Raw -Encoding UTF8 -LiteralPath $defaultsPath | ConvertFrom-Json
$managed = @{}
foreach ($section in $defaults.PSObject.Properties) {
    $settingsSection = $settings.PSObject.Properties[$section.Name]
    if ($null -eq $settingsSection) { throw "Missing settings section: $($section.Name)" }
    foreach ($entry in $section.Value.PSObject.Properties) {
        $setting = $section.Name + '.' + $entry.Name
        $property = $settingsSection.Value.PSObject.Properties[$entry.Name]
        if ($null -eq $property) { throw "Missing setting: $setting" }
        $managed[$setting] = ConvertTo-TomlValue $property.Value $entry.Value $setting
    }
}
# Ports must match AMP's reservations; reject invalid numbers before changing files.
foreach ($setting in @('server.serverPort', 'authentication.steamGameServerQueryPort', 'tcpConsole.tcpConsolePort', 'webPanel.webPanelPort')) {
    if ([long]$managed[$setting] -lt 1 -or [long]$managed[$setting] -gt 65535) {
        throw "Setting $setting must be between 1 and 65535."
    }
}
if ([long]$managed['server.maxPlayers'] -lt 1) { throw 'Max Players must be at least 1.' }
if ([double]$managed['gameplay.timeProgressionMultiplier'] -le 0 -or
    [double]$managed['autosave.autoSaveIntervalMinutes'] -le 0) {
    throw 'Time multiplier and autosave interval must be greater than zero.'
}

$userData = Join-Path $BaseDirectory 'UserData'
$targetPath = Join-Path $userData 'server_config.toml'
$backupPath = $targetPath + '.before-amp.bak'
$markerPath = Join-Path $BaseDirectory 'AMP_server_config.initialized'
$firstWrite = -not (Test-Path -LiteralPath $markerPath)
$existing = Test-Path -LiteralPath $targetPath -PathType Leaf

# Keep server-added keys and comments. Add any missing managed sections and keys.
$sourcePath = if ($existing) { $targetPath } else { $templatePath }
$lines = [IO.File]::ReadAllLines($sourcePath)
$output = New-Object 'Collections.Generic.List[string]'
$seen = @{}
$currentSection = ''
$seenSections = @{}
$continuingManagedArray = $false
function Add-MissingSettings([string]$SectionName) {
    if (-not $SectionName) { return }
    $section = $defaults.PSObject.Properties[$SectionName]
    if ($null -eq $section) { return }
    foreach ($entry in $section.Value.PSObject.Properties) {
        $path = $SectionName + '.' + $entry.Name
        if (-not $seen.ContainsKey($path)) {
            $output.Add($entry.Name + ' = ' + $managed[$path])
            $seen[$path] = $true
        }
    }
}
foreach ($line in $lines) {
    if ($continuingManagedArray) {
        if ($line -match '\]\s*(?:#.*)?$') { $continuingManagedArray = $false }
        continue
    }
    if ($line -match '^\s*\[([^\[\]]+)\]\s*(?:#.*)?$') {
        Add-MissingSettings $currentSection
        $currentSection = $Matches[1].Trim()
        if ($seenSections.ContainsKey($currentSection)) { throw "Duplicate TOML section: $currentSection" }
        $seenSections[$currentSection] = $true
        $output.Add($line)
    }
    elseif ($line -match '^\s*([A-Za-z0-9_]+)\s*=') {
        $key = $Matches[1]
        $path = $currentSection + '.' + $key
        if ($managed.ContainsKey($path)) {
            if ($seen.ContainsKey($path)) { throw "Duplicate TOML setting: $path" }
            $output.Add($key + ' = ' + $managed[$path])
            $seen[$path] = $true
            $schemaEntry = $defaults.PSObject.Properties[$currentSection].Value.PSObject.Properties[$key]
            if ($schemaEntry.Value -is [array] -and $line -notmatch '\]\s*(?:#.*)?$') {
                $continuingManagedArray = $true
            }
        }
        else { $output.Add($line) }
    }
    else { $output.Add($line) }
}
if ($continuingManagedArray) { throw 'Incomplete logging array in existing server_config.toml.' }
Add-MissingSettings $currentSection
foreach ($section in $defaults.PSObject.Properties) {
    if (-not $seenSections.ContainsKey($section.Name)) {
        $output.Add('')
        $output.Add('[' + $section.Name + ']')
        Add-MissingSettings $section.Name
    }
}

[IO.Directory]::CreateDirectory($userData) | Out-Null
if ($firstWrite -and $existing -and -not (Test-Path -LiteralPath $backupPath)) {
    [IO.File]::Copy($targetPath, $backupPath, $false)
}
# Replace the file only after conversion and validation finish successfully.
$temporaryPath = $targetPath + '.amp.tmp'
try {
    [IO.File]::WriteAllLines($temporaryPath, $output.ToArray(), $utf8)
    if ($existing) { [IO.File]::Replace($temporaryPath, $targetPath, [NullString]::Value) }
    else { [IO.File]::Move($temporaryPath, $targetPath) }
}
finally {
    if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath }
}
[IO.File]::WriteAllText($markerPath, 'AMP manages server_config.toml. Permissions are managed by the server.', $utf8)
Write-Output 'Schedule I server_config.toml updated from AMP settings.'
