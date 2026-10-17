#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the OBS-Luke scene collection, profile and Lua script into the local OBS Studio.

.DESCRIPTION
    What this script does, in order:

      1. Detect the installed OBS Studio and confirm it with the user.
      2. Reuse the scene/profile files shipped next to this script, or download
         the repository from GitHub into a temporary directory and extract it.
      3. Ask before replacing a scene collection or profile of the same name;
         anything that is replaced is backed up first.
      4. Install the scene collection and the profile, then activate them.
      5. Install the Lua script (and the background image asset).
      6. Rewrite every machine-dependent value it can determine (file paths and
         recording folders) and report the values that need to be configured
         by hand (camera device, capture monitor, stream key, ...).

    OBS must be closed while the script runs, otherwise OBS overwrites the
    changes when it exits.

.PARAMETER OBSRoot
    OBS installation directory. Auto-detection is skipped when this is given.

.PARAMETER LocalDir
    Take the scene/profile files from this directory instead of downloading.

.PARAMETER Name
    Scene collection and profile name, default "讲课". Must match the file
    names inside the package.

.PARAMETER Force
    Replace existing files without asking. A backup is still created.

.PARAMETER DryRun
    Touch nothing in the real OBS configuration. The transformed files are
    written to a temporary directory and printed, so the result can be
    inspected first.

.PARAMETER KeepTemp
    Keep the downloaded/extracted package directory.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string] $OBSRoot,
    [string] $LocalDir,
    [string] $Name = '讲课',
    [string] $RepoZipUrl = 'https://codeload.github.com/USTB-SkyCode/OBS-Luke/zip/refs/heads/main',
    [switch] $Force,
    [switch] $DryRun,
    [switch] $KeepTemp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Placeholders used by the desensitized files that live in the repository.
# tools/desensitize.ps1 writes them, this script replaces them with real paths.
$AssetsToken = '__OBS_LUKE_ASSETS__'
$ScriptToken = '__OBS_LUKE_SCRIPT__'
$VideosToken = '__OBS_LUKE_VIDEOS__'

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Utf8Bom = New-Object System.Text.UTF8Encoding($true)

# The manual steps are collected here and printed at the end.
$manual = [System.Collections.Generic.List[string]]::new()
$tempDirs = [System.Collections.Generic.List[string]]::new()

# Every exit path removes the temporary download directory.
function Exit-Script([int] $code = 0) {
    foreach ($temp in $tempDirs) {
        if ($KeepTemp) { Write-Note "临时目录保留：$temp" }
        else { Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    exit $code
}

# ---------------------------------------------------------------------------
# Output helpers

function Write-Section([string] $text) { Write-Host ''; Write-Host "== $text" -ForegroundColor Cyan }
function Write-Ok([string] $text) { Write-Host "   [ok] $text" -ForegroundColor Green }
function Write-Note([string] $text) { Write-Host "   $text" }
function Write-Warn2([string] $text) { Write-Host "   [warn] $text" -ForegroundColor Yellow }
function Write-Fail([string] $text) { Write-Host "   [error] $text" -ForegroundColor Red }

function Read-YesNo([string] $prompt, [bool] $defaultYes = $true) {
    if ($Force) { return $true }
    while ($true) {
        $suffix = if ($defaultYes) { '[Y/n]' } else { '[y/N]' }
        $answer = Read-Host "$prompt $suffix"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $defaultYes }
        switch ($answer.Trim().ToLowerInvariant()) {
            'y' { return $true }
            'yes' { return $true }
            'n' { return $false }
            'no' { return $false }
            default { Write-Warn2 '请输入 y 或 n。' }
        }
    }
}

# ---------------------------------------------------------------------------
# Text helpers
#
# OBS writes the profile files as UTF-8 with BOM and LF line endings, and the
# scene collection as UTF-8 without BOM. The scripts keep that unchanged so
# that OBS keeps parsing the files the same way.

function Read-Utf8Text([string] $path) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $offset = if ($hasBom) { 3 } else { 0 }
    return [pscustomobject]@{
        Text   = [System.Text.Encoding]::UTF8.GetString($bytes, $offset, $bytes.Length - $offset)
        HasBom = $hasBom
    }
}

function Write-Utf8Text([string] $path, [string] $text, [bool] $withBom) {
    $dir = Split-Path $path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $encoding = if ($withBom) { $Utf8Bom } else { $Utf8NoBom }
    [System.IO.File]::WriteAllText($path, $text, $encoding)
}

# Literal replacement inside a regex replacement string ("$" would be special).
function Set-RegexValue([string] $text, [string] $pattern, [string] $value) {
    return [regex]::Replace($text, $pattern, $value.Replace('$', '$$'))
}

# Replaces the string value of every key matching $keyPattern, keeping the
# original "key<spaces>:<spaces>" separator of the file.
function Set-JsonString {
    param([string] $Text, [string] $KeyPattern, [string] $JsonValue)
    [regex] $re = '(' + $KeyPattern + '\s*:\s*)"((?:[^"\\]|\\.)*)"'
    $changed = 0
    $at = 0
    while ($true) {
        $match = $re.Match($Text, $at)
        if (-not $match.Success) { break }
        $replacement = $match.Groups[1].Value + '"' + $JsonValue + '"'
        if ($match.Value -ne $replacement) { $changed++ }
        $Text = $Text.Remove($match.Index, $match.Length).Insert($match.Index, $replacement)
        $at = $match.Index + $replacement.Length
    }
    return [pscustomobject]@{ Text = $Text; Changed = $changed }
}

function ConvertTo-JsonPath([string] $path) { return $path.Replace('\', '/') }
function ConvertTo-IniValue([string] $path) { return $path.Replace('\', '\\') }

function Edit-IniSection {
    param(
        [string] $Text,
        [string] $Section,
        [System.Collections.Specialized.OrderedDictionary] $Set,
        [string[]] $Remove = @()
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]] ($Text -split "`n"))
    $sectionHeader = "[$Section]"

    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].TrimEnd("`r").Trim() -eq $sectionHeader) { $start = $i; break }
    }

    if ($start -lt 0) {
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -ne '') { $lines.Add('') }
        $lines.Add($sectionHeader)
        foreach ($key in $Set.Keys) { $lines.Add("$key=$($Set[$key])") }
        return ($lines -join "`n")
    }

    $end = $lines.Count
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].TrimStart().StartsWith('[')) { $end = $i; break }
    }

    $body = [System.Collections.Generic.List[string]]::new()
    $written = @{}
    for ($i = $start + 1; $i -lt $end; $i++) {
        $line = $lines[$i]
        $eq = $line.IndexOf('=')
        $key = if ($eq -ge 0) { $line.Substring(0, $eq).Trim() } else { $null }
        if ($key -and ($Remove -contains $key)) { continue }
        if ($key -and $Set.Contains($key)) {
            $body.Add("$key=$($Set[$key])")
            $written[$key] = $true
            continue
        }
        $body.Add($line)
    }
    foreach ($key in $Set.Keys) {
        if (-not $written.ContainsKey($key)) { $body.Add("$key=$($Set[$key])") }
    }

    $result = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -le $start; $i++) { $result.Add($lines[$i]) }
    $result.AddRange($body)
    for ($i = $end; $i -lt $lines.Count; $i++) { $result.Add($lines[$i]) }
    return ($result -join "`n")
}

# ---------------------------------------------------------------------------
# Step 1: detect OBS

function Get-OBSCandidates {
    $found = [System.Collections.Generic.List[string]]::new()
    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($root in $uninstallRoots) {
        Get-ItemProperty -Path $root -ErrorAction SilentlyContinue | ForEach-Object {
            $props = $_.PSObject.Properties.Name
            if (-not ($props -contains 'DisplayName') -or $_.DisplayName -notlike 'OBS Studio*') { return }
            if ($props -contains 'InstallLocation' -and $_.InstallLocation) { $found.Add($_.InstallLocation) }
            if ($props -contains 'DisplayIcon' -and $_.DisplayIcon) {
                $icon = ($_.DisplayIcon -replace '"', '') -replace ',\d+$', ''
                if ($icon -match '(?i)\\bin\\64bit\\obs64\.exe$') {
                    $found.Add(($icon -replace '(?i)\\bin\\64bit\\obs64\.exe$', ''))
                } elseif (Test-Path $icon) {
                    $found.Add((Split-Path (Split-Path $icon -Parent) -Parent))
                }
            }
        }
    }
    foreach ($guess in @(
            (Join-Path $env:ProgramFiles 'obs-studio'),
            $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'obs-studio' }),
            (Join-Path $env:LOCALAPPDATA 'Programs\obs-studio')
        )) {
        if ($guess) { $found.Add($guess) }
    }
    $valid = $found |
        Where-Object { $_ -and (Test-Path (Join-Path $_ 'bin\64bit\obs64.exe')) } |
        ForEach-Object { (Resolve-Path $_).Path } |
        Select-Object -Unique
    return @($valid)
}

function Get-OBSVersion([string] $root) {
    $exe = Join-Path $root 'bin\64bit\obs64.exe'
    try { return (Get-Item $exe).VersionInfo.FileVersion } catch { return 'unknown' }
}

function Get-OBSConfigRoot([string] $root) {
    # OBS in portable mode keeps its configuration in <install>\config\obs-studio.
    $portable = Join-Path $root 'config\obs-studio'
    if (Test-Path (Join-Path $portable 'user.ini')) { return $portable }
    return (Join-Path $env:APPDATA 'obs-studio')
}

# Tests whether a (possibly not yet existing) path can be created/written.
function Test-CanWrite([string] $path) {
    $probe = $path
    while ($probe -and -not (Test-Path $probe)) {
        $parent = Split-Path $probe -Parent
        if (-not $parent -or $parent -eq $probe) { return $false }
        $probe = $parent
    }
    if (-not $probe) { return $false }
    $file = Join-Path $probe ("obs-luke-write-test-" + [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($file, 'x', $Utf8NoBom)
        Remove-Item $file -Force
        return $true
    } catch { return $false }
}

Write-Section "1. 检测 OBS Studio"

if (-not $OBSRoot) {
    $candidates = @(Get-OBSCandidates)
    if ($candidates.Count -eq 0) {
        Write-Fail '没有找到 OBS Studio。请先安装 OBS，或用 -OBSRoot <安装目录> 指定。'
        Exit-Script 1
    }
    if ($candidates.Count -eq 1) {
        $candidate = $candidates[0]
        Write-Note "检测到 OBS Studio：$candidate（版本 $(Get-OBSVersion $candidate)）"
        if (-not (Read-YesNo '使用这个 OBS 吗？')) {
            Write-Note '已取消。'
            Exit-Script 1
        }
        $OBSRoot = $candidate
    } else {
        Write-Note '检测到多个 OBS 安装：'
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            Write-Note "  [$($i + 1)] $($candidates[$i])（版本 $(Get-OBSVersion $candidates[$i])）"
        }
        if ($Force) {
            $OBSRoot = $candidates[0]
            Write-Warn2 "-Force 已指定，使用第一个：$OBSRoot"
        } else {
            $pick = Read-Host "请选择序号 [1-$($candidates.Count)]"
            $index = 0
            if (-not [int]::TryParse($pick, [ref] $index) -or $index -lt 1 -or $index -gt $candidates.Count) {
                Write-Fail '选择无效。'
                Exit-Script 1
            }
            $OBSRoot = $candidates[$index - 1]
        }
    }
}

$OBSRoot = (Resolve-Path $OBSRoot -ErrorAction SilentlyContinue).Path
if (-not $OBSRoot -or -not (Test-Path (Join-Path $OBSRoot 'bin\64bit\obs64.exe'))) {
    Write-Fail "这不是一个 OBS 安装目录（找不到 bin\64bit\obs64.exe）：$OBSRoot"
    Exit-Script 1
}
$obsVersion = Get-OBSVersion $OBSRoot
Write-Ok "OBS 安装目录：$OBSRoot（版本 $obsVersion）"

if ((Get-Process -Name 'obs64' -ErrorAction SilentlyContinue)) {
    if ($DryRun) {
        Write-Warn2 'OBS 正在运行。演练模式不会写入配置，继续执行。'
    } else {
        Write-Fail 'OBS 正在运行。场景与配置会在 OBS 退出时被覆盖，请先关闭 OBS 再运行本脚本。'
        Exit-Script 1
    }
} else {
    Write-Ok 'OBS 当前没有运行。'
}

$configRoot = Get-OBSConfigRoot $OBSRoot
$userIni = Join-Path $configRoot 'user.ini'
$scenesDir = Join-Path $configRoot 'basic\scenes'
$profilesDir = Join-Path $configRoot 'basic\profiles'
$script:TargetScene = Join-Path $scenesDir "$Name.json"
$script:TargetProfile = Join-Path $profilesDir $Name

Write-Ok "OBS 配置目录：$configRoot"

if (-not (Test-Path $userIni)) {
    Write-Fail "找不到 $userIni。请先启动一次 OBS（让它生成默认配置）再运行本脚本。"
    Exit-Script 1
}

$requiredMajor = 32
$requiredMinor = 2
if ($obsVersion -match '^(\d+)\.(\d+)') {
    if ([int] $Matches[1] -ne $requiredMajor -or [int] $Matches[2] -ne $requiredMinor) {
        Write-Warn2 "本包是在 OBS $requiredMajor.$requiredMinor 上制作的，本机是 $obsVersion。"
        Write-Warn2 '跨小版本一般可用，但 OBS 可能会在首次加载时改写文件；如有异常请以 OBS 的日志为准。'
    }
}

# ---------------------------------------------------------------------------
# Step 2: locate or download the package

Write-Section '2. 准备场景与配置'

function Find-Package([string] $dir) {
    if (-not $dir -or -not (Test-Path $dir)) { return $null }
    $root = (Resolve-Path $dir).Path
    $reposLayout = Join-Path $root 'examples'
    foreach ($layout in @(@{ Scene = Join-Path $reposLayout "$Name.json"; Profile = Join-Path $reposLayout $Name; Lua = Join-Path $root 'activity-scene-switch.lua' },
            @{ Scene = Join-Path $root "$Name.json"; Profile = Join-Path $root $Name; Lua = Join-Path $root 'activity-scene-switch.lua' })) {
        if ((Test-Path $layout.Scene) -and (Test-Path $layout.Profile)) {
            $asset = @(
                (Join-Path (Split-Path $layout.Scene -Parent) 'background.png')
            ) | Where-Object { Test-Path $_ } | Select-Object -First 1
            return [pscustomobject]@{
                Root    = $root
                Scene   = $layout.Scene
                Profile = $layout.Profile
                Lua     = $layout.Lua
                Asset   = $asset
            }
        }
    }
    return $null
}

$package = $null
$searchDirs = [System.Collections.Generic.List[string]]::new()
if ($LocalDir) { $searchDirs.Add($LocalDir) }
# $PSScriptRoot is empty when the script is executed inline (irm ... | iex).
if ($PSScriptRoot) {
    $searchDirs.Add($PSScriptRoot)
    $parent = Split-Path $PSScriptRoot -Parent
    if ($parent) { $searchDirs.Add($parent) }
}
foreach ($candidateDir in $searchDirs) {
    $package = Find-Package $candidateDir
    if ($package) { break }
}

if ($package) {
    Write-Ok "使用脚本旁边的场景与配置：$($package.Root)"
} else {
    Write-Note '脚本旁边没有场景与配置，从 GitHub 下载本仓库……'
    Write-Note "  $RepoZipUrl"
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("obs-luke-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    $tempDirs.Add($temp)
    $zip = Join-Path $temp 'obs-luke.zip'
    try {
        Invoke-WebRequest -Uri $RepoZipUrl -OutFile $zip -UseBasicParsing
        Expand-Archive -Path $zip -DestinationPath $temp -Force
    } catch {
        Write-Fail "下载或解压失败：$($_.Exception.Message)"
        Write-Note '可以手动下载仓库压缩包，解压后在仓库目录里运行 install.ps1，或用 -LocalDir <仓库目录>。'
        Exit-Script 1
    }
    $extracted = Get-ChildItem $temp -Directory | Where-Object { $_.Name -ne 'obs-luke.zip' } | Select-Object -First 1
    if ($extracted) { $package = Find-Package $extracted.FullName }
    if (-not $package) {
        Write-Fail '下载到的仓库里没有找到场景与配置（examples\ 目录）。'
        Write-Note '如果你还没有把脱敏后的 examples\ 提交到仓库，请先提交，或改用 -LocalDir 指定本地目录。'
        Exit-Script 1
    }
    Write-Ok "已下载并解压到：$($extracted.FullName)"
}

if (-not (Test-Path $package.Lua)) { Write-Warn2 '包里没有 activity-scene-switch.lua，脚本不会被安装。' }
else { Write-Ok "包内容：$($package.Scene) / $($package.Profile) / $($package.Lua)" }
if (-not $package.Asset) { Write-Warn2 '包里没有 background.png，直播背景图源会缺文件。' }

# ---------------------------------------------------------------------------
# Step 3/4: install scene collection and profile

Write-Section '3. 检查同名场景与配置'

$sceneExists = Test-Path $script:TargetScene
$profileExists = Test-Path $script:TargetProfile

if ($sceneExists -or $profileExists) {
    if ($sceneExists) { Write-Warn2 "已存在同名场景集合：$script:TargetScene" }
    if ($profileExists) { Write-Warn2 "已存在同名配置档案：$script:TargetProfile" }
    if (-not (Read-YesNo '要用本包的内容替换它们吗？（替换前会自动备份）' $false)) {
        Write-Note '已取消，未做任何修改。'
        Exit-Script 1
    }
} else {
    Write-Ok '没有同名场景集合与配置档案，将新建。'
}

Write-Section '4. 写入场景与配置'

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path $configRoot "obs-luke-backup-$stamp"
$workDir = if ($DryRun) { Join-Path $env:TEMP "obs-luke-dryrun-$stamp" } else { $null }
$writtenScenePath = if ($DryRun) { Join-Path $workDir "scenes\$Name.json" } else { $script:TargetScene }
$writtenProfileDir = if ($DryRun) { Join-Path $workDir "profiles\$Name" } else { $script:TargetProfile }

# ---- install location for the Lua script and the image asset ----
$scriptDirPreferred = Join-Path $OBSRoot 'data\obs-plugins\frontend-tools\scripts\OBS-Luke'
$scriptDirFallback = Join-Path $configRoot 'OBS-Luke'
$scriptDir = $scriptDirPreferred
if (-not (Test-CanWrite $scriptDirPreferred)) {
    $scriptDir = $scriptDirFallback
    Write-Warn2 "没有权限写入 OBS 安装目录，脚本与素材改放到：$scriptDir"
    if ($DryRun) { Write-Note '（如果想装进安装目录，请用管理员身份运行。）' }
} else {
    Write-Ok "脚本与素材目录：$scriptDir"
}

$assetsDir = $scriptDir
$videosDir = [Environment]::GetFolderPath('MyVideos')
if (-not $videosDir) { $videosDir = Join-Path $env:USERPROFILE 'Videos' }

# ---- back up what is about to be replaced ----
if (-not $DryRun -and ($sceneExists -or $profileExists)) {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    if ($sceneExists) {
        New-Item -ItemType Directory -Path (Join-Path $backupDir 'scenes') -Force | Out-Null
        Copy-Item $script:TargetScene (Join-Path $backupDir "scenes\$Name.json") -Force
    }
    if ($profileExists -and (Get-ChildItem $script:TargetProfile -File -ErrorAction SilentlyContinue)) {
        New-Item -ItemType Directory -Path (Join-Path $backupDir "profiles\$Name") -Force | Out-Null
        Copy-Item (Join-Path $script:TargetProfile '*') (Join-Path $backupDir "profiles\$Name") -Force
    }
    $basic = Get-Content $userIni -Raw -Encoding utf8
    $currentBasic = [regex]::Match($basic, '(?m)^\[Basic\][\s\S]*?(?=\r?\n\[|\z)').Value
    Write-Utf8Text (Join-Path $backupDir 'user.ini.Basic.before.txt') $currentBasic $false
    Copy-Item $userIni (Join-Path $backupDir 'user.ini.before') -Force
    Write-Ok "已备份到：$backupDir"
}

# ---- scene collection: replace the placeholders with real values ----
$sceneFile = Read-Utf8Text $package.Scene
$sceneText = $sceneFile.Text
$changeLog = [System.Collections.Generic.List[string]]::new()

$scriptLuaPath = ConvertTo-JsonPath (Join-Path $scriptDir 'activity-scene-switch.lua')
$result = Set-JsonString -Text $sceneText -KeyPattern '"path"' -JsonValue $scriptLuaPath
$sceneText = $result.Text
if ($result.Changed -gt 0) { $changeLog.Add("脚本路径 -> $scriptLuaPath") }

if ($package.Asset) {
    $assetPath = ConvertTo-JsonPath (Join-Path $assetsDir (Split-Path $package.Asset -Leaf))
    $result = Set-JsonString -Text $sceneText -KeyPattern '"file"' -JsonValue $assetPath
    $sceneText = $result.Text
    if ($result.Changed -gt 0) { $changeLog.Add("背景图片路径 -> $assetPath") }
}

$result = Set-JsonString -Text $sceneText -KeyPattern '"monitor_id"' -JsonValue 'DUMMY'
$sceneText = $result.Text
if ($result.Changed -gt 0) {
    $changeLog.Add('显示器采集的 monitor_id -> "DUMMY"（需要手动选择显示器）')
}
foreach ($key in @('video_device_id', 'last_video_device_id')) {
    $result = Set-JsonString -Text $sceneText -KeyPattern ('"' + $key + '"') -JsonValue ''
    $sceneText = $result.Text
    if ($result.Changed -gt 0) { $changeLog.Add("摄像头的 $key -> 空（需要手动选择设备）") }
}

if ($sceneText -match [regex]::Escape($ScriptToken) -or $sceneText -match [regex]::Escape($AssetsToken)) {
    Write-Warn2 '场景集合里仍有未替换的占位符。'
}

try {
    $null = $sceneText | ConvertFrom-Json
    Write-Ok '场景集合 JSON 校验通过。'
} catch {
    Write-Fail "场景集合 JSON 校验失败：$($_.Exception.Message)"
    Exit-Script 1
}
Write-Utf8Text $writtenScenePath $sceneText $false

# ---- profile: recording folders and machine-local panel cookie ----
New-Item -ItemType Directory -Path $writtenProfileDir -Force | Out-Null
$videosIni = ConvertTo-IniValue $videosDir
foreach ($file in (Get-ChildItem $package.Profile -File)) {
    $target = Join-Path $writtenProfileDir $file.Name
    if ($file.Name -eq 'basic.ini') {
        $ini = Read-Utf8Text $file.FullName
        $text = $ini.Text
        foreach ($key in @('FilePath', 'RecFilePath', 'FFFilePath')) {
            $before = $text
            $text = Set-RegexValue $text ("(?m)^$key=.*$") "$key=$videosIni"
            if ($text -ne $before) { $changeLog.Add("$key -> $videosDir") }
        }
        $before = $text
        $text = Set-RegexValue $text '(?m)^CookieId=.*(\r?\n)?' ''
        if ($text -ne $before) { $changeLog.Add('[Panels] CookieId 已移除（机器本地值）') }
        $text = Set-RegexValue $text '(?m)^Name=.*$' "Name=$Name"
        if ($text -match [regex]::Escape($VideosToken)) {
            $text = Set-RegexValue $text ([regex]::Escape($VideosToken)) $videosIni
            $changeLog.Add("录制路径占位符 -> $videosDir")
        }
        if ($text -match [regex]::Escape($VideosToken)) {
            Write-Warn2 'basic.ini 里仍有未替换的录制路径占位符。'
        }
        Write-Utf8Text $target $text $ini.HasBom
    } else {
        Copy-Item $file.FullName $target -Force
    }
}
foreach ($entry in $changeLog) { Write-Note "- $entry" }
Write-Ok "场景集合：$writtenScenePath"
Write-Ok "配置档案：$writtenProfileDir（$((Get-ChildItem $package.Profile -File).Count) 个文件）"

# ---- Lua script and image asset ----
if (Test-Path $package.Lua) {
    $targetLua = Join-Path $scriptDir 'activity-scene-switch.lua'
    if ($DryRun) {
        Write-Note "（演练）会安装脚本到：$targetLua"
    } else {
        New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null
        Copy-Item $package.Lua $targetLua -Force
        Write-Ok "脚本已安装：$targetLua"
    }
}
if ($package.Asset) {
    $targetAsset = Join-Path $assetsDir (Split-Path $package.Asset -Leaf)
    if ($DryRun) {
        Write-Note "（演练）会安装背景素材到：$targetAsset"
    } else {
        New-Item -ItemType Directory -Path $assetsDir -Force | Out-Null
        Copy-Item $package.Asset $targetAsset -Force
        Write-Ok "背景素材已安装：$targetAsset"
    }
}

# ---------------------------------------------------------------------------
# Step 5: activate the profile and the scene collection

Write-Section '5. 激活配置档案与场景集合'

$userIniFile = Read-Utf8Text $userIni
$basic = [ordered]@{
    'Profile'             = $Name
    'ProfileDir'          = $Name
    'SceneCollection'     = $Name
    'SceneCollectionFile' = "$Name.json"
}
$userIniText = Edit-IniSection -Text $userIniFile.Text -Section 'Basic' -Set $basic
if ($DryRun) {
    Write-Utf8Text (Join-Path $workDir 'user.ini') $userIniText $userIniFile.HasBom
    Write-Note "（演练）会写入 user.ini 的 [Basic]：Profile=$Name / SceneCollection=$Name"
} else {
    Write-Utf8Text $userIni $userIniText $userIniFile.HasBom
    Write-Ok "已激活：Profile=$Name，SceneCollection=$Name"
}

# ---------------------------------------------------------------------------
# Step 6: checks on values that cannot be detected

Write-Section '6. 可以自动确定的变量与需要手动配置的项'

if ($changeLog.Count -gt 0) {
    Write-Ok '已自动改写的变量：'
    foreach ($entry in $changeLog) { Write-Note "   - $entry" }
} else {
    Write-Warn2 '没有改写任何变量，请检查包内的文件是否已脱敏。'
}

$nvidia = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(?i)nvidia' })
if ($nvidia.Count -eq 0) {
    Write-Warn2 '本机没有检测到 NVIDIA 显卡，而配置里的推流/录制编码器写死了 nvenc。'
    $manual.Add('设置 → 输出：把「串流/录制编码器」从 NVENC 改成 x264 或其他可用编码器')
} else {
    Write-Ok "检测到 NVIDIA 显卡（$($nvidia[0].Name)），nvenc 可用。"
}

$manual.Add('场景「电脑桌面」→ 显示器采集 → 属性：选择要抓取的显示器（monitor_id 已置为未指定）')
$manual.Add('场景「电脑桌面」/「教室实景」→ 视频采集 → 属性：选择摄像头设备')
$manual.Add('设置 → 直播：填写推流服务器与推流密钥（service.json 里是空的）')
$manual.Add('设置 → 音频：确认默认麦克风，并试听压缩器/扩展器的阈值是否合适')
$manual.Add('启动 OBS 后确认场景集合与配置档案都显示为「讲课」，画面正常再开播')

Write-Host ''
Write-Host '需要手动配置的部分：' -ForegroundColor Yellow
$index = 0
foreach ($item in $manual) { $index++; Write-Note "   $index. $item" }

if ($DryRun) {
    Write-Section '演练结果'
    Write-Note "没有改动任何真实文件。生成的样例在：$workDir"
    Write-Note '可以在里面检查 scenes\讲课.json、profiles\讲课\basic.ini 和 user.ini 的内容。'
} else {
    Write-Section '完成'
    Write-Note "备份目录：$(if (Test-Path $backupDir) { $backupDir } else { '（本次没有覆盖文件，未创建备份）' })"
    Write-Note ('脚本与素材：' + $scriptDir)
    Write-Note '现在可以启动 OBS 了。'
}

Exit-Script 0
