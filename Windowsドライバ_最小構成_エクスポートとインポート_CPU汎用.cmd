@echo off
setlocal
set "SELF_PATH=%~f0"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "try{$ErrorActionPreference='Stop'; $b=[IO.File]::ReadAllBytes($env:SELF_PATH); $u=New-Object Text.UTF8Encoding($false,$true); try{$t=$u.GetString($b)}catch{$t=[Text.Encoding]::GetEncoding(932).GetString($b)}; $m='# === PS_'+'BODY_START ==='; $i=$t.IndexOf($m); if($i -lt 0){throw 'Script body not found.'}; & ([scriptblock]::Create($t.Substring($i+$m.Length)))}catch{Write-Host $_.Exception.Message -ForegroundColor Red; Read-Host 'Press Enter to close'; exit 1}"
exit /b %errorlevel%
# === PS_BODY_START ===

param([switch]$LibraryOnly)

$ErrorActionPreference = 'Stop'
# スクリプトのUTF-8デコードと、端末のコードページは別に扱う。
# 従来のコンソールで全角文字の幅が崩れる場合があるため強制変更しない。
$script:workDir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($env:SELF_PATH))
if (-not (Test-Path -LiteralPath $script:workDir -PathType Container)) {
    throw 'スクリプトの配置フォルダを取得できませんでした。'
}
$script:pnpUtilPath = Join-Path $env:SystemRoot 'System32\pnputil.exe'

function Format-ByteSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Get-DirectorySize {
    param([Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "フォルダがありません: $Path" }
    $sum = [long]0
    Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction Stop | ForEach-Object {
        $sum += $_.Length
    }
    return $sum
}

function Get-SafeModelName {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $raw = if ($cs -and $cs.Model) { $cs.Model.Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($raw) -or $raw -match '^(System Product Name|To be filled|Default string)') {
        $raw = $env:COMPUTERNAME
    }
    $safe = ($raw -replace '[\\/:*?"<>|\s]+', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'PC' }
    return $safe
}

function Assert-NoReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $rootItem = Get-Item -LiteralPath $Path -Force
    if ($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "再解析ポイント（ジャンクション/シンボリックリンク）は許可されていません: $Path"
    }
    if ($rootItem.PSIsContainer) {
        Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop | ForEach-Object {
            if ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                throw "再解析ポイント（ジャンクション/シンボリックリンク）が含まれています: $($_.FullName)"
            }
        }
    }
}

function Read-InfTextLines {
    param([Parameter(Mandatory = $true)][string]$FilePath)
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { throw "INFファイルが見つかりません: $FilePath" }
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = [System.Text.Encoding]::Unicode
        $text = $encoding.GetString($bytes, 2, $bytes.Length - 2)
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = [System.Text.Encoding]::BigEndianUnicode
        $text = $encoding.GetString($bytes, 2, $bytes.Length - 2)
    } elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = [System.Text.Encoding]::UTF8
        $text = $encoding.GetString($bytes, 3, $bytes.Length - 3)
    } else {
        $nullCount = 0
        $sampleLen = [Math]::Min($bytes.Length, 512)
        for ($k = 1; $k -lt $sampleLen; $k += 2) {
            if ($bytes[$k] -eq 0) { $nullCount++ }
        }
        if ($sampleLen -gt 10 -and ($nullCount / ($sampleLen / 2)) -gt 0.6) {
            $text = [System.Text.Encoding]::Unicode.GetString($bytes)
        } else {
            try {
                $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
                $text = $utf8Strict.GetString($bytes)
            } catch {
                $text = [System.Text.Encoding]::GetEncoding(932).GetString($bytes)
            }
        }
    }
    return ($text -split "`r?`n")
}

function Test-HasExcludedAncestor {
    param(
        [string]$InstanceId,
        [hashtable]$ParentMap,
        [System.Collections.Generic.HashSet[string]]$ExcludedIds
    )
    $cur = $InstanceId
    $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    while (-not [string]::IsNullOrEmpty($cur)) {
        if (-not $visited.Add($cur)) { break }
        if ($ExcludedIds.Contains($cur)) { return $true }
        if ($ParentMap.ContainsKey($cur)) {
            $cur = $ParentMap[$cur]
        } else {
            break
        }
    }
    return $false
}

function Show-Page {
    param([string]$Title)
    # Clear-Host後の全角文字の再描画崩れを避け、前の結果もスクロールで確認可能にする。
    Write-Host ''
    Write-Host '------------------------------------------------------------' -ForegroundColor DarkCyan
    Write-Host '  ドライバ エクスポート / インポート [CPU汎用]' -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor White
    Write-Host '------------------------------------------------------------' -ForegroundColor DarkCyan
    Write-Host ''
}

function Resolve-ExportFolder {
    param([AllowEmptyString()][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = 'driver' }
    if ($Name -in @('.', '..') -or $Name -match '[\\/:*?"<>|\x00-\x1f]' -or
        $Name -match '[. ]$' -or $Name -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') {
        throw 'フォルダ名が無効です。パスではなく名前だけを指定してください。'
    }
    $path = [System.IO.Path]::GetFullPath((Join-Path $script:workDir $Name))
    if ([System.IO.Path]::GetDirectoryName($path) -ine $script:workDir) {
        throw '保存先は、この .cmd の直下フォルダに限定しています。'
    }
    if (Test-Path -LiteralPath $path) {
        Assert-NoReparsePoint -Path $path
        $item = Get-Item -LiteralPath $path -Force
        if (-not $item.PSIsContainer) {
            throw '保存先は通常のフォルダを指定してください。'
        }
        if (@(Get-ChildItem -LiteralPath $path -Force).Count -gt 0) {
            throw '既存ファイルは上書きしません。空のフォルダか別の名前を指定してください。'
        }
    }
    return $path
}

function Test-ExcludedVirtualNetworkDevice {
    param([Parameter(Mandatory = $true)]$Device)
    if (-not $Device) { return $false }
    $id = [string]$Device.InstanceId
    $name = if ($Device.PSObject.Properties['FriendlyName'] -and $Device.FriendlyName) {
        [string]$Device.FriendlyName
    } elseif ($Device.PSObject.Properties['Name'] -and $Device.Name) {
        [string]$Device.Name
    } else { '' }

    # システムルート疑似ノード
    if ($id -match '^HTREE\\ROOT' -or $id -eq 'ROOT\SYSTEM\0000') { return $true }

    # Hyper-V 仮想スイッチ・仮想NIC（wvms_mp, vms_vsmp, vms_mp）
    if ($id -match '(?i)vms_vsmp|vms_mp|^ROOT\\vms_|wvms_mp' -or
        $name -match '(?i)Hyper-V.*Switch|Hyper-V.*Ethernet|Virtual Switch') {
        return $true
    }

    # WAN Miniport, カーネルデバッグNIC, Wi-Fi Direct Virtual
    if ($name -match '(?i)WAN Miniport|Kernel Debug Network Adapter|Wi-Fi Direct Virtual' -or
        $id -match '(?i)^SWD\\MSRRAS\\|^ROOT\\KDNIC\\|vwifimp') {
        return $true
    }

    # MS Bluetooth 仮想プロトコル列挙子
    if ($id -match '(?i)^BTH\\MS_' -or $name -match '(?i)Bluetooth Device \(Personal Area Network\)') {
        return $true
    }

    return $false
}

function Get-DeviceHardwareAndCompatibleIds {
    param(
        [Parameter(Mandatory = $true)]$Device,
        [hashtable]$HwIdsByDev = @{},
        [hashtable]$CompatIdsByDev = @{}
    )
    $id = if ($Device -and $Device.PSObject.Properties['InstanceId'] -and $Device.InstanceId) { [string]$Device.InstanceId } else { '' }

    $hwList = @()
    if ($id -and $HwIdsByDev.ContainsKey($id) -and @($HwIdsByDev[$id]).Count -gt 0) {
        $hwList = @($HwIdsByDev[$id] | ForEach-Object { [string]$_ } | Where-Object { $_ })
    } elseif ($Device.PSObject.Properties['HardwareID'] -and $Device.HardwareID) {
        $hwList = @($Device.HardwareID | ForEach-Object { [string]$_ } | Where-Object { $_ })
    } elseif ($Device.PSObject.Properties['HardwareIds'] -and $Device.HardwareIds) {
        $hwList = @($Device.HardwareIds | ForEach-Object { [string]$_ } | Where-Object { $_ })
    }

    $compatList = @()
    if ($id -and $CompatIdsByDev.ContainsKey($id) -and @($CompatIdsByDev[$id]).Count -gt 0) {
        $compatList = @($CompatIdsByDev[$id] | ForEach-Object { [string]$_ } | Where-Object { $_ })
    } elseif ($Device.PSObject.Properties['CompatibleID'] -and $Device.CompatibleID) {
        $compatList = @($Device.CompatibleID | ForEach-Object { [string]$_ } | Where-Object { $_ })
    } elseif ($Device.PSObject.Properties['CompatibleIds'] -and $Device.CompatibleIds) {
        $compatList = @($Device.CompatibleIds | ForEach-Object { [string]$_ } | Where-Object { $_ })
    }

    return [PSCustomObject]@{
        HardwareIds   = [string[]]@($hwList)
        CompatibleIds = [string[]]@($compatList)
    }
}

function Test-ExpectedDriverlessRawDevice {
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowEmptyString()][string]$PrimaryInf = '',
        [hashtable]$HwIdsByDev = @{},
        [hashtable]$CompatIdsByDev = @{},
        [hashtable]$DevNodeStatusByDev = @{}
    )
    if (-not $Device -or -not $Device.InstanceId) { return $false }

    # PnP 問題コードが発生しているデバイス（Code 28 / Code 10 / Code 43 等）は除外しない
    $prob = 0
    if ($Device.PSObject.Properties['Problem'] -and $null -ne $Device.Problem) {
        $prob = [int]$Device.Problem
    }
    if ($prob -ne 0) { return $false }

    $devClass = if ($Device.PSObject.Properties['Class'] -and $Device.Class) { [string]$Device.Class } else { '' }
    if ((-not [string]::IsNullOrWhiteSpace($devClass) -and $devClass -ine 'Unknown') -or -not [string]::IsNullOrWhiteSpace($PrimaryInf)) {
        return $false
    }

    $id = ([string]$Device.InstanceId).Trim()

    # 0. デバイスマネージャー通常表示での非表示ノード (DN_NO_SHOW_IN_DM = 0x40000000)
    $rawStatus = $null
    if ($DevNodeStatusByDev -and $DevNodeStatusByDev.ContainsKey($id) -and $null -ne $DevNodeStatusByDev[$id]) {
        $rawStatus = $DevNodeStatusByDev[$id]
    } elseif ($Device.PSObject.Properties['DevNodeStatus'] -and $null -ne $Device.DevNodeStatus) {
        $rawStatus = $Device.DevNodeStatus
    }
    if ($null -ne $rawStatus) {
        $statusVal = [uint32]0
        $parsedStatus = $false
        if ($rawStatus -is [uint32]) {
            $statusVal = $rawStatus; $parsedStatus = $true
        } elseif ($rawStatus -is [int]) {
            $statusVal = [BitConverter]::ToUInt32([BitConverter]::GetBytes($rawStatus), 0); $parsedStatus = $true
        } elseif ($rawStatus -is [long]) {
            $statusVal = [BitConverter]::ToUInt32([BitConverter]::GetBytes([long]$rawStatus), 0); $parsedStatus = $true
        } elseif ($rawStatus -is [uint64]) {
            $statusVal = [uint32]([uint64]$rawStatus -band [uint64]0xFFFFFFFF); $parsedStatus = $true
        } else {
            $sRaw = ([string]$rawStatus).Trim()
            if ($sRaw -match '^0[xX]([0-9A-Fa-f]+)$') {
                $parsedStatus = [uint32]::TryParse($Matches[1], [System.Globalization.NumberStyles]::HexNumber, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$statusVal)
            } else {
                $parsedStatus = [uint32]::TryParse($sRaw, [ref]$statusVal)
            }
        }
        if ($parsedStatus) {
            # DN_HAS_PROBLEM (0x0400) または DN_PRIVATE_PROBLEM (0x8000) が設定されている場合は除外しない
            if (($statusVal -band [uint32]0x00008400) -ne 0) { return $false }
            if (($statusVal -band [uint32]0x40000000) -ne 0) { return $true }
        }
    }

    # これ以降の個別・構造ルールは Class が空の場合のみ対象とする
    if (-not [string]::IsNullOrWhiteSpace($devClass)) { return $false }

    $idPair = Get-DeviceHardwareAndCompatibleIds -Device $Device -HwIdsByDev $HwIdsByDev -CompatIdsByDev $CompatIdsByDev
    $hwIds = @($idPair.HardwareIds)
    $compatIds = @($idPair.CompatibleIds)

    # 1. AMD ACP (amdacpbus.sys) が列挙する HDA 論理子ノード (ACP\DEVTYPE_0001*)
    #    独立 HDA コントローラ経由でコーデックが稼働する標準構成では専用 INF が存在せず RAW PDO 稼働が正規仕様
    if ($id -match '^(?i)ACP\\DEVTYPE_0001(?:&|\\|$)') { return $true }
    foreach ($hw in $hwIds) {
        if ($hw -match '^(?i)ACP\\DEVTYPE_0001(?:&|\\|$)') { return $true }
    }

    # 2. Realtek Bluetooth フィルタ (RtkBtFilter2.sys) 等の内部制御用 RAW PDO
    if ($id -match '^(?i)\{742787E2-EA40-4366-8FB4-DE98EE777D7C\}\\RTKFILTER') { return $true }

    # 3. USB4 ホストルーター (Usb4HostRouter.sys) が列挙する電力協調用 RAW PDO (USB4\VIRTUAL_POWER_PDO*)
    if ($id -match '^(?i)USB4\\VIRTUAL_POWER_PDO(?:&|\\|$)') { return $true }
    foreach ($hw in $hwIds) {
        if ($hw -match '^(?i)USB4\\VIRTUAL_POWER_PDO(?:&|\\|$)') { return $true }
    }

    # 4. HardwareIds / CompatibleIds を一切報告しない非物理バス上の内部 RAW PDO
    #    （PnP 仕様上いかなる INF もマッチング対象にならず、親ドライバが直接 I/O を処理するノード）
    if ($hwIds.Count -eq 0 -and $compatIds.Count -eq 0) {
        $hasExplicitIdSource = (
            ($Device -is [Microsoft.Management.Infrastructure.CimInstance]) -or
            $HwIdsByDev.ContainsKey($id) -or
            $CompatIdsByDev.ContainsKey($id) -or
            ($null -ne $Device.PSObject.Properties['HardwareID']) -or
            ($null -ne $Device.PSObject.Properties['HardwareIds']) -or
            ($null -ne $Device.PSObject.Properties['CompatibleID']) -or
            ($null -ne $Device.PSObject.Properties['CompatibleIds'])
        )
        $isStandardHardwareBus = ($id -match '^(?i)(PCI|ACPI|USB|USB4|HDAUDIO|INTELAUDIO|SD|SCSI|NVME|HID|UEFI)\\')
        if ($hasExplicitIdSource -and -not $isStandardHardwareBus) {
            return $true
        }
    }

    return $false
}

function Get-SafePnpDeviceProperties {
    param(
        [array]$Devices = @(),
        [Parameter(Mandatory = $true)][string[]]$KeyNames
    )
    if (@($Devices).Count -eq 0 -or @($KeyNames).Count -eq 0) { return @() }

    $results = New-Object System.Collections.Generic.List[object]
    $pnpCmd = Get-Command -Name 'Get-PnpDeviceProperty' -ErrorAction SilentlyContinue
    $isNativePnpModule = ($null -ne $pnpCmd -and $pnpCmd.ModuleName -eq 'PnpDevice')
    $hasThrottleLimit = ($isNativePnpModule -and $null -ne $pnpCmd.Parameters -and $pnpCmd.Parameters.ContainsKey('ThrottleLimit'))

    $cimDevices = @()
    $fallbackIds = New-Object System.Collections.Generic.List[string]
    $seenFallbackIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    if ($isNativePnpModule) {
        $cimList = New-Object System.Collections.Generic.List[object]
        foreach ($d in $Devices) {
            if ($null -eq $d) { continue }
            if ($d -is [Microsoft.Management.Infrastructure.CimInstance]) {
                $cimList.Add($d)
            } elseif ($d.PSObject.Properties['InstanceId'] -and $d.InstanceId) {
                $sId = [string]$d.InstanceId
                if ($seenFallbackIds.Add($sId)) { $fallbackIds.Add($sId) }
            }
        }
        $cimDevices = $cimList.ToArray()
    } else {
        foreach ($d in $Devices) {
            if ($d -and $d.PSObject.Properties['InstanceId'] -and $d.InstanceId) {
                $sId = [string]$d.InstanceId
                if ($seenFallbackIds.Add($sId)) { $fallbackIds.Add($sId) }
            }
        }
    }

    $prevProgress = $global:ProgressPreference
    try {
        $global:ProgressPreference = 'SilentlyContinue'
        # CimInstance 直接渡しにより WQL 長大化による WBEM_E_QUOTA_VIOLATION（クォータ違反）を回避し、
        # ThrottleLimit 1 により WMI プロバイダ内部の並列競合（DeviceID 混入・欠落）を防止する
        if ($cimDevices.Count -gt 0) {
            $cimArgs = @{ InputObject = $cimDevices; KeyName = $KeyNames; ErrorAction = 'SilentlyContinue' }
            if ($hasThrottleLimit) { $cimArgs['ThrottleLimit'] = 1 }
            $cimProps = @(Get-PnpDeviceProperty @cimArgs)
            if ($cimProps.Count -gt 0) {
                foreach ($p in $cimProps) { if ($null -ne $p) { $results.Add($p) } }
            } elseif ($KeyNames.Count -gt 1) {
                foreach ($k in $KeyNames) {
                    $singleArgs = @{ InputObject = $cimDevices; KeyName = $k; ErrorAction = 'SilentlyContinue' }
                    if ($hasThrottleLimit) { $singleArgs['ThrottleLimit'] = 1 }
                    Get-PnpDeviceProperty @singleArgs | ForEach-Object {
                        if ($null -ne $_) { $results.Add($_) }
                    }
                }
            }
        }

        # モック環境や非CimInstance向けの安全な小バッチ分割（WMI クエリ長・OR条件数上限を十分に下回るサイズ）
        if ($fallbackIds.Count -gt 0) {
            $chunks = New-Object System.Collections.Generic.List[object]
            $curChunk = New-Object System.Collections.Generic.List[string]
            $curChars = 0
            foreach ($sId in $fallbackIds) {
                $len = $sId.Length + 32
                if ($curChunk.Count -gt 0 -and ($curChunk.Count -ge 30 -or ($curChars + $len) -gt 3000)) {
                    $chunks.Add([string[]]$curChunk.ToArray())
                    $curChunk = New-Object System.Collections.Generic.List[string]
                    $curChars = 0
                }
                $curChunk.Add($sId)
                $curChars += $len
            }
            if ($curChunk.Count -gt 0) {
                $chunks.Add([string[]]$curChunk.ToArray())
            }

            foreach ($chunk in $chunks) {
                $chunkArgs = @{ InstanceId = $chunk; KeyName = $KeyNames; ErrorAction = 'SilentlyContinue' }
                if ($hasThrottleLimit) { $chunkArgs['ThrottleLimit'] = 1 }
                $chunkProps = @(Get-PnpDeviceProperty @chunkArgs)
                if ($chunkProps.Count -gt 0) {
                    foreach ($cp in $chunkProps) { if ($null -ne $cp) { $results.Add($cp) } }
                } elseif ($KeyNames.Count -gt 1) {
                    foreach ($k in $KeyNames) {
                        $singleChunkArgs = @{ InstanceId = $chunk; KeyName = $k; ErrorAction = 'SilentlyContinue' }
                        if ($hasThrottleLimit) { $singleChunkArgs['ThrottleLimit'] = 1 }
                        Get-PnpDeviceProperty @singleChunkArgs | ForEach-Object {
                            if ($null -ne $_) { $results.Add($_) }
                        }
                    }
                }
            }
        }
    } finally {
        $global:ProgressPreference = $prevProgress
    }

    return $results.ToArray()
}

function Get-UnhealthyOrUnboundDevices {
    param(
        [Parameter(Mandatory = $true)][array]$Devices,
        [hashtable]$InfByDev = @{},
        [hashtable]$HwIdsByDev = @{},
        [hashtable]$CompatIdsByDev = @{},
        [hashtable]$DevNodeStatusByDev = @{}
    )
    $results = New-Object System.Collections.ArrayList
    foreach ($dev in $Devices) {
        if (-not $dev.InstanceId) { continue }
        if (Test-ExcludedVirtualNetworkDevice -Device $dev) { continue }

        $id = [string]$dev.InstanceId
        $devClass = [string]$dev.Class
        $devName = if ($dev.PSObject.Properties['FriendlyName'] -and $dev.FriendlyName) {
            [string]$dev.FriendlyName
        } elseif ($dev.PSObject.Properties['Name'] -and $dev.Name) {
            [string]$dev.Name
        } else { $id }

        $primaryInf = if ($InfByDev.ContainsKey($id)) { [string]$InfByDev[$id] } else { '' }

        # 1. PnP 問題コード（Problem != 0）
        $prob = 0
        if ($dev.PSObject.Properties['Problem'] -and $null -ne $dev.Problem) {
            $prob = [int]$dev.Problem
        }
        if ($prob -ne 0) {
            [void]$results.Add([PSCustomObject]@{
                InstanceId = $id
                Name       = $devName
                Class      = $devClass
                Severity   = 'Error'
                Category   = 'PnPProblemCode'
                Detail     = "PnP問題コード: $prob"
            })
            continue
        }

        # 2. Null Driver（「ほかのデバイス」状態）: Class が空または 'Unknown' かつ DriverInfPath が空
        if (([string]::IsNullOrWhiteSpace($devClass) -or $devClass -ieq 'Unknown') -and [string]::IsNullOrWhiteSpace($primaryInf)) {
            if (Test-ExpectedDriverlessRawDevice -Device $dev -PrimaryInf $primaryInf -HwIdsByDev $HwIdsByDev -CompatIdsByDev $CompatIdsByDev -DevNodeStatusByDev $DevNodeStatusByDev) {
                continue
            }
            [void]$results.Add([PSCustomObject]@{
                InstanceId = $id
                Name       = $devName
                Class      = '(不明/ほかのデバイス)'
                Severity   = 'Error'
                Category   = 'NullDriver'
                Detail     = 'ドライバ未バインド（Null Driver 状態、INF未適用）'
            })
            continue
        }

        # 3. DSP有効マルチメディアオーディオ（PCI\CC_0401 / CC_040380）へのインボックスINF強制適用
        #    ※ Intel SST 等の DSP が有効なオーディオコントローラはクラスコードが CC_0401 または CC_040380 となり、
        #       OEM製SSTバスドライバ（IntcAudioBus.sys等）が必須となる。
        #       一方、BIOSでDSPが無効（標準HD Audioモード）の場合はクラスコードが CC_0403 / CC_040300 となり、
        #       Windows標準インボックス（hdaudbus.inf）での稼働が正規仕様のため除外する。
        $idPair = Get-DeviceHardwareAndCompatibleIds -Device $dev -HwIdsByDev $HwIdsByDev -CompatIdsByDev $CompatIdsByDev
        $allIds = @(@($idPair.HardwareIds) + @($idPair.CompatibleIds))
        $isSstDsp = ($allIds -match '(?i)PCI\\CC_0401|&CC_0401|&CC_040380')
        if ($isSstDsp) {
            $isOem = ($primaryInf -match '(?i)^oem\d+\.inf$')
            if (-not $isOem) {
                $currentInfText = if ($primaryInf) { $primaryInf } else { 'なし' }
                [void]$results.Add([PSCustomObject]@{
                    InstanceId = $id
                    Name       = $devName
                    Class      = $devClass
                    Severity   = 'Warning'
                    Category   = 'IntelSstInboxDriver'
                    Detail     = "OEM製SSTバスドライバ未適用（現在: $currentInfText）。クリーンインストール後に自動復元されません。"
                })
            }
        }
    }
    return @($results)
}

function Get-CoreCategoryStatus {
    param(
        [Parameter(Mandatory = $true)][array]$Devices,
        [hashtable]$InfByDev = @{},
        [hashtable]$DriverMap = @{},
        [hashtable]$HwIdsByDev = @{},
        [hashtable]$CompatIdsByDev = @{},
        [hashtable]$DevNodeStatusByDev = @{}
    )
    $categories = @(
        @{ Key = 'Audio';     Name = 'オーディオ (SST / ACP / コーデック / Display Audio)' },
        @{ Key = 'Video';     Name = 'ビデオ (Intel / AMD / NVIDIA 等)' },
        @{ Key = 'WiredLan';  Name = '有線LAN (物理 NIC)' },
        @{ Key = 'Wireless';  Name = '無線LAN (Wi-Fi)' },
        @{ Key = 'Bluetooth'; Name = 'Bluetooth' }
    )

    $statusList = New-Object System.Collections.ArrayList
    foreach ($cat in $categories) {
        $matchedDevs = New-Object System.Collections.ArrayList
        foreach ($dev in $Devices) {
            if (-not $dev.InstanceId) { continue }
            if (Test-ExcludedVirtualNetworkDevice -Device $dev) { continue }
            $id = [string]$dev.InstanceId
            $devClass = [string]$dev.Class
            $devName = if ($dev.PSObject.Properties['FriendlyName'] -and $dev.FriendlyName) {
                [string]$dev.FriendlyName
            } elseif ($dev.PSObject.Properties['Name'] -and $dev.Name) {
                [string]$dev.Name
            } else { $id }
            $inf = if ($InfByDev.ContainsKey($id)) { [string]$InfByDev[$id] } else { '' }
            if (Test-ExpectedDriverlessRawDevice -Device $dev -PrimaryInf $inf -HwIdsByDev $HwIdsByDev -CompatIdsByDev $CompatIdsByDev -DevNodeStatusByDev $DevNodeStatusByDev) { continue }

            $match = $false
            switch ($cat.Key) {
                'Audio' {
                    if (($devClass -in @('MEDIA', 'AudioProcessingObject') -or
                        $id -match '(?i)VEN_8086&DEV_54C8|VEN_1022&DEV_15E2|PCI\\CC_0401|INTELAUDIO\\|AMDACP\\|HDAUDIO\\' -or
                        $devName -match '(?i)オーディオ|Audio|High Definition|Smart Sound') -and
                        $devClass -ne 'Net') {
                        $match = $true
                    }
                }
                'Video' {
                    if (($devClass -eq 'Display' -or $id -match '(?i)VEN_8086&DEV_46D4' -or $devName -match '(?i)Graphics|グラフィックス|Radeon|GeForce|Display') -and
                        $devClass -ne 'Processor') {
                        $match = $true
                    }
                }
                'WiredLan' {
                    if ($devClass -eq 'Net' -and ($id -match '(?i)VEN_10EC&DEV_8168|PCI\\' -and $devName -match '(?i)GbE|Gigabit|Ethernet|Family Controller|PCIe')) {
                        $match = $true
                    }
                }
                'Wireless' {
                    if ($devClass -eq 'Net' -and ($id -match '(?i)VEN_8086&DEV_3165' -or $devName -match '(?i)Wireless|Wi-Fi|802\.11|Dual Band')) {
                        $match = $true
                    }
                }
                'Bluetooth' {
                    if ($devClass -eq 'Bluetooth' -or $devName -match '(?i)Bluetooth|ワイヤレス.*Bluetooth') {
                        $match = $true
                    }
                }
            }
            if ($match) {
                [void]$matchedDevs.Add([PSCustomObject]@{
                    Device = $dev
                    Inf    = $inf
                })
            }
        }

        $hasOem = $false
        $hasInbox = $false
        $hasUnboundOrError = $false
        $descList = New-Object System.Collections.ArrayList

        if ($matchedDevs.Count -eq 0) {
            [void]$descList.Add('該当デバイス未検出')
            $summaryState = 'NotDetected'
        } else {
            foreach ($m in $matchedDevs) {
                $d = $m.Device
                $inf = $m.Inf
                $dName = if ($d.PSObject.Properties['FriendlyName'] -and $d.FriendlyName) { $d.FriendlyName } else { $d.InstanceId }
                $prob = if ($d.PSObject.Properties['Problem'] -and $null -ne $d.Problem) { [int]$d.Problem } else { 0 }
                if ($prob -ne 0 -or [string]::IsNullOrWhiteSpace($inf)) {
                    $hasUnboundOrError = $true
                    [void]$descList.Add("$dName : 未適用または異常(Code $prob)")
                } elseif ($inf -match '(?i)^oem\d+\.inf$') {
                    $hasOem = $true
                    $pkgName = if ($DriverMap.ContainsKey($inf.ToLowerInvariant())) { $DriverMap[$inf.ToLowerInvariant()].PackageName } else { $inf }
                    [void]$descList.Add("$dName : OEM製ドライバ適用中 ($pkgName -> 必須保存対象)")
                } else {
                    $hasInbox = $true
                    [void]$descList.Add("$dName : Windows標準インボックス ($inf -> OS内蔵・保存対象外)")
                }
            }
            if ($hasUnboundOrError) {
                $summaryState = 'UnboundOrError'
            } elseif ($hasOem) {
                $summaryState = 'OemDriverBound'
            } else {
                $summaryState = 'InboxDriverOnly'
            }
        }

        [void]$statusList.Add([PSCustomObject]@{
            Key     = $cat.Key
            Name    = $cat.Name
            State   = $summaryState
            Devices = @($matchedDevs)
            Details = @($descList)
        })
    }
    return @($statusList)
}

function Get-InfDeclaredFileNames {
    param([AllowEmptyString()][string]$InfFilePath = '')
    $names = @{}
    if ([string]::IsNullOrWhiteSpace($InfFilePath) -or -not (Test-Path -LiteralPath $InfFilePath -PathType Leaf)) {
        return $names
    }
    $names[[System.IO.Path]::GetFileName($InfFilePath)] = $true
    $inSourceFiles = $false
    foreach ($line in (Read-InfTextLines -FilePath $InfFilePath)) {
        if ($line -match '^\s*\[([^\]]+)\]') {
            $inSourceFiles = ($Matches[1].Trim() -match '^(?i)SourceDisksFiles(?:\.|$)')
            continue
        }
        $clean = ($line -replace ';.*$', '').Trim()
        if (-not $clean) { continue }
        if ($clean -match '^\s*CatalogFile(?:\.[^=]+)?\s*=\s*(.+)$') {
            $catLeaf = [System.IO.Path]::GetFileName($Matches[1].Trim().Trim('"'))
            if ($catLeaf) { $names[$catLeaf] = $true }
        } elseif ($inSourceFiles -and $clean -match '^\s*([^=]+?)\s*=') {
            $srcLeaf = [System.IO.Path]::GetFileName(($Matches[1].Trim().Trim('"') -replace '/', '\'))
            if ($srcLeaf) { $names[$srcLeaf] = $true }
        }
    }
    return $names
}

function Test-KnownDriverStoreRuntimeFile {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [AllowEmptyString()][string]$LeafInf = '',
        [switch]$IgnoreAmdFendrRuntimeLogs,
        [hashtable]$InfDeclaredNames = @{}
    )
    $leafName = [System.IO.Path]::GetFileName($RelativePath)
    if ($InfDeclaredNames -and $leafName -and $InfDeclaredNames.ContainsKey($leafName)) {
        return $false
    }
    # 1. AMD Crash Defender (amdfendr.inf) が DriverStore に残す、パッケージ外の実行時ログ・ダンプ
    if (($IgnoreAmdFendrRuntimeLogs -or $LeafInf -ieq 'amdfendr.inf') -and
        $RelativePath -match '^(?i)AMD\\(?:[A-Za-z0-9_]+Dumps|Persistent|Real)\\[^\\]+\.(?:log|dmp)$') {
        return $true
    }
    # 2. AMD ディスプレイドライバ (u0*.inf / c0*.inf) が DriverStore に保存する HDCP SRM 実行時データ
    if ($LeafInf -match '^(?i)[uc]\d+\.inf$' -and
        $RelativePath -match '^(?i)(?:B\d+\\)?HDCPSrmData\.txt$') {
        return $true
    }
    return $false
}

function Get-PackageFiles {
    param(
        [string]$Root,
        [switch]$IgnoreAmdFendrRuntimeLogs,
        [AllowEmptyString()][string]$LeafInf = ''
    )
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $checkRuntime = ($IgnoreAmdFendrRuntimeLogs -or -not [string]::IsNullOrWhiteSpace($LeafInf))
    $declaredNames = if ($checkRuntime -and -not [string]::IsNullOrWhiteSpace($LeafInf)) {
        Get-InfDeclaredFileNames -InfFilePath (Join-Path $Root $LeafInf)
    } else { @{} }
    foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -File -Force) {
        # PNFはWindowsが生成するプリコンパイル済みINFキャッシュ。
        # pnputilの出力に含まれなくても正常。元・出力とも必須照合/ハッシュ記録から除外する。
        if ($file.Extension -ieq '.pnf') { continue }
        $relativePath = $file.FullName.Substring($prefix.Length)
        # AMD ドライバ等が DriverStore に残す、パッケージ外の実行時生成ファイル。
        if ($checkRuntime -and (Test-KnownDriverStoreRuntimeFile -RelativePath $relativePath -LeafInf $LeafInf -IgnoreAmdFendrRuntimeLogs:$IgnoreAmdFendrRuntimeLogs -InfDeclaredNames $declaredNames)) {
            continue
        }
        [PSCustomObject]@{
            Path = $relativePath
            Length = $file.Length
            SHA256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        }
    }
}

function Assert-ExportedPackage {
    param([string]$SourceRoot, [string]$ExportRoot, [string]$LeafInf)
    $sourceFiles = @(Get-PackageFiles -Root $SourceRoot -IgnoreAmdFendrRuntimeLogs:($LeafInf -ieq 'amdfendr.inf') -LeafInf $LeafInf)
    if ($sourceFiles.Count -eq 0) { throw '元パッケージが空です。' }
    foreach ($sourceFile in $sourceFiles) {
        $exported = Get-BackupFilePath -Root $ExportRoot -RelativePath $sourceFile.Path
        if (-not (Test-Path -LiteralPath $exported -PathType Leaf)) {
            throw "出力ファイル不足: $($sourceFile.Path)"
        }
        if ((Get-Item -LiteralPath $exported).Length -ne $sourceFile.Length -or
            (Get-FileHash -LiteralPath $exported -Algorithm SHA256).Hash -ne $sourceFile.SHA256) {
            throw "元パッケージと内容が異なります: $($sourceFile.Path)"
        }
    }
}

function Get-BackupFilePath {
    param([string]$Root, [string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath)) {
        throw '検証情報に無効なファイルパスがあります。'
    }
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw '検証対象がバックアップフォルダの外を参照しています。'
    }
    return $full
}

function Write-BackupManifest {
    param(
        [string]$Root,
        [string]$Status,
        [string]$Mode,
        [array]$Files = @(),
        [array]$DeviceBindings = @(),
        [array]$OnlineDrivers = @()
    )
    $manifestObj = [ordered]@{
        FormatVersion = 1
        Status = $Status
        Created = (Get-Date).ToString('o')
        Model = Get-SafeModelName
        Mode = $Mode
        Files = @($Files)
    }
    if (@($DeviceBindings).Count -gt 0) {
        $manifestObj['DeviceBindings'] = @($DeviceBindings)
    }
    if (@($OnlineDrivers).Count -gt 0) {
        $manifestObj['OnlineDrivers'] = @($OnlineDrivers)
    }
    [PSCustomObject]$manifestObj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Root 'driver-backup.json') -Encoding UTF8
}

function Get-ManifestOnlineDrivers {
    param([Parameter(Mandatory = $true)][string]$BackupRoot)
    $manifestPath = Join-Path $BackupRoot 'driver-backup.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return @() }
    try {
        $mf = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($mf -and $mf.Status -eq 'Complete' -and $mf.PSObject.Properties['OnlineDrivers'] -and $null -ne $mf.OnlineDrivers) {
            return @($mf.OnlineDrivers)
        }
    } catch {}
    return @()
}

function Initialize-SetupApiDriverBinder {
    if ('PnPForcedDriverBinder' -as [type]) { return }
    $packSize = if ([IntPtr]::Size -eq 8) { 8 } else { 1 }
    $csharp = @"
using System;
using System.Runtime.InteropServices;

public class PnPForcedDriverBinder {
    [StructLayout(LayoutKind.Sequential, Pack = $packSize)]
    public struct SP_DEVINFO_DATA {
        public uint cbSize; public Guid ClassGuid; public uint DevInst; public IntPtr Reserved;
    }
    [StructLayout(LayoutKind.Sequential, Pack = $packSize, CharSet = CharSet.Unicode)]
    public struct SP_DEVINSTALL_PARAMS_W {
        public uint cbSize; public uint Flags; public uint FlagsEx; public IntPtr hwndParent;
        public IntPtr InstallMsgHandler; public IntPtr InstallMsgHandlerContext; public IntPtr FileQueue;
        public IntPtr ClassInstallReserved; public uint Reserved;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string DriverPath;
    }
    [StructLayout(LayoutKind.Sequential, Pack = $packSize, CharSet = CharSet.Unicode)]
    public struct SP_DRVINFO_DATA_W {
        public uint cbSize; public uint DriverType; public IntPtr Reserved;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Description;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string MfgName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string ProviderName;
        public System.Runtime.InteropServices.ComTypes.FILETIME DriverDate;
        public ulong DriverVersion;
    }
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr SetupDiCreateDeviceInfoList(IntPtr g, IntPtr h);
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool SetupDiOpenDeviceInfoW(IntPtr s, string id, IntPtr h, uint f, ref SP_DEVINFO_DATA d);
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool SetupDiGetDeviceInstallParamsW(IntPtr s, ref SP_DEVINFO_DATA d, ref SP_DEVINSTALL_PARAMS_W p);
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool SetupDiSetDeviceInstallParamsW(IntPtr s, ref SP_DEVINFO_DATA d, ref SP_DEVINSTALL_PARAMS_W p);
    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiBuildDriverInfoList(IntPtr s, ref SP_DEVINFO_DATA d, uint t);
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool SetupDiEnumDriverInfoW(IntPtr s, ref SP_DEVINFO_DATA d, uint t, uint idx, ref SP_DRVINFO_DATA_W drv);
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool SetupDiSetSelectedDriverW(IntPtr s, ref SP_DEVINFO_DATA d, ref SP_DRVINFO_DATA_W drv);
    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiDestroyDeviceInfoList(IntPtr s);
    [DllImport("newdev.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool DiInstallDevice(IntPtr h, IntPtr s, ref SP_DEVINFO_DATA d, ref SP_DRVINFO_DATA_W drv, uint f, out bool reboot);

    public static bool BindDriver(string instanceId, string infPath, string preferredDesc, out bool needReboot, out int lastErr, out string appliedDesc) {
        needReboot = false; lastErr = 0; appliedDesc = string.Empty;
        IntPtr hSet = SetupDiCreateDeviceInfoList(IntPtr.Zero, IntPtr.Zero);
        if (hSet == new IntPtr(-1)) { lastErr = Marshal.GetLastWin32Error(); return false; }
        try {
            SP_DEVINFO_DATA d = new SP_DEVINFO_DATA(); d.cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVINFO_DATA));
            if (!SetupDiOpenDeviceInfoW(hSet, instanceId, IntPtr.Zero, 0, ref d)) { lastErr = Marshal.GetLastWin32Error(); return false; }
            SP_DEVINSTALL_PARAMS_W p = new SP_DEVINSTALL_PARAMS_W(); p.cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVINSTALL_PARAMS_W));
            if (!SetupDiGetDeviceInstallParamsW(hSet, ref d, ref p)) { lastErr = Marshal.GetLastWin32Error(); return false; }
            p.Flags |= 0x00010000 | 0x00800000; p.FlagsEx |= 0x00000800; p.DriverPath = infPath;
            if (!SetupDiSetDeviceInstallParamsW(hSet, ref d, ref p)) { lastErr = Marshal.GetLastWin32Error(); return false; }
            if (!SetupDiBuildDriverInfoList(hSet, ref d, 1)) { lastErr = Marshal.GetLastWin32Error(); return false; }
            SP_DRVINFO_DATA_W chosen = new SP_DRVINFO_DATA_W(); bool hasFirst = false;
            for (uint idx = 0; idx < 256; idx++) {
                SP_DRVINFO_DATA_W cur = new SP_DRVINFO_DATA_W(); cur.cbSize = (uint)Marshal.SizeOf(typeof(SP_DRVINFO_DATA_W));
                if (!SetupDiEnumDriverInfoW(hSet, ref d, 1, idx, ref cur)) { if (idx == 0) { lastErr = Marshal.GetLastWin32Error(); } break; }
                if (!hasFirst) { chosen = cur; hasFirst = true; if (string.IsNullOrWhiteSpace(preferredDesc)) { break; } }
                if (!string.IsNullOrWhiteSpace(preferredDesc) && string.Equals(cur.Description, preferredDesc, StringComparison.OrdinalIgnoreCase)) { chosen = cur; break; }
            }
            if (!hasFirst) { return false; }
            if (!SetupDiSetSelectedDriverW(hSet, ref d, ref chosen)) { lastErr = Marshal.GetLastWin32Error(); return false; }
            if (!DiInstallDevice(IntPtr.Zero, hSet, ref d, ref chosen, 0, out needReboot)) { lastErr = Marshal.GetLastWin32Error(); return false; }
            appliedDesc = chosen.Description ?? string.Empty;
            return true;
        } finally { SetupDiDestroyDeviceInfoList(hSet); }
    }
}
"@
    Add-Type -TypeDefinition $csharp -ErrorAction Stop
}

function Test-BackupIntegrity {
    param([string]$Root)
    Assert-NoReparsePoint -Path $Root
    $manifestPath = Join-Path $Root 'driver-backup.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw '検証情報（driver-backup.json）が見つかりません。'
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifestFiles = @(if ($manifest -and $manifest.PSObject.Properties['Files'] -and $null -ne $manifest.Files) { $manifest.Files })
    $onlineDrivers = @(if ($manifest -and $manifest.PSObject.Properties['OnlineDrivers'] -and $null -ne $manifest.OnlineDrivers) { $manifest.OnlineDrivers })
    $hasFiles = ($manifestFiles.Count -gt 0)
    $hasOnline = ($onlineDrivers.Count -gt 0)

    if (-not $manifest -or $manifest.FormatVersion -ne 1 -or $manifest.Status -ne 'Complete' -or (-not $hasFiles -and -not $hasOnline)) {
        throw 'このバックアップは未完了、または検証情報が無効です。元のWindowsで別名のフォルダに再エクスポートしてください。'
    }

    foreach ($od in $onlineDrivers) {
        $odHw = @(if ($od -and $od.PSObject.Properties['HardwareIds'] -and $od.HardwareIds) { $od.HardwareIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } })
        $odCompat = @(if ($od -and $od.PSObject.Properties['CompatibleIds'] -and $od.CompatibleIds) { $od.CompatibleIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } })
        if ($odHw.Count -eq 0 -and $odCompat.Count -eq 0) {
            throw 'オンライン取得ドライバ情報（OnlineDrivers）に有効なハードウェアIDがありません。'
        }
    }

    $manifestInfCount = 0
    foreach ($entry in $manifestFiles) {
        if ($null -eq $entry -or -not $entry.PSObject.Properties['Path']) {
            throw '検証情報に無効なファイル項目があります。'
        }
        $path = Get-BackupFilePath -Root $Root -RelativePath ([string]$entry.Path)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "保存ファイルがありません: $($entry.Path)" }
        $file = Get-Item -LiteralPath $path -Force
        if ($null -eq $entry.Length -or [string]::IsNullOrWhiteSpace([string]$entry.SHA256) -or
            $file.Length -ne [long]$entry.Length -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine ([string]$entry.SHA256).Trim()) {
            throw "保存ファイルが変更・破損しています: $($entry.Path)"
        }
        if ($file.Extension -ieq '.inf') { $manifestInfCount++ }
    }

    if ($manifestInfCount -eq 0 -and -not $hasOnline) {
        $infs = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.inf' -Force -ErrorAction Stop)
        if ($infs.Count -eq 0) { throw '保存先にINFファイルがありません。' }
    }
}

function Assert-DriverCatalogSignatures {
    param([Parameter(Mandatory = $true)][string]$Root, [switch]$AllowPayloadInf)
    Assert-NoReparsePoint -Path $Root
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw "フォルダがありません: $Root" }
    $infFiles = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.inf' -Force -ErrorAction Stop)
    if ($infFiles.Count -eq 0) { throw "保存先に INF ファイルが見つかりません: $Root" }

    $procArch = if ($env:PROCESSOR_ARCHITEW6432) { [string]$env:PROCESSOR_ARCHITEW6432 } else { [string]$env:PROCESSOR_ARCHITECTURE }
    $procArch = $procArch.Trim().ToUpperInvariant()
    $archSuffix = switch ($procArch) {
        'AMD64' { 'NTAMD64' }
        'ARM64' { 'NTARM64' }
        'X86'   { 'NTX86' }
        default { '' }
    }

    $verified = New-Object 'System.Collections.Generic.List[object]'
    $missing = New-Object 'System.Collections.Generic.List[object]'
    foreach ($infFile in $infFiles) {
        $infDir = $infFile.DirectoryName
        $lines = Read-InfTextLines -FilePath $infFile.FullName
        $inVersion = $false
        $hasVersionSection = $false
        $catalogsBySuffix = @{}
        $allDeclaredCatalogs = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($line in $lines) {
            $cleanLine = ($line -replace ';.*$', '').Trim()
            if (-not $cleanLine) { continue }
            if ($cleanLine -match '^\[([^\]]+)\]') {
                $secName = $Matches[1].Trim()
                $inVersion = ($secName -ieq 'Version')
                if ($inVersion) { $hasVersionSection = $true }
                continue
            }
            if ($hasVersionSection -and -not $inVersion) { continue }
            if ($cleanLine -match '^\s*CatalogFile(?:\.([^=\s]+))?\s*=\s*(.+)$') {
                $suffixKey = if ($Matches[1]) { $Matches[1].Trim().ToUpperInvariant() } else { '' }
                $catLeaf = [System.IO.Path]::GetFileName($Matches[2].Trim().Trim('"'))
                if ($catLeaf) {
                    [void]$allDeclaredCatalogs.Add($catLeaf)
                    if (-not $catalogsBySuffix.ContainsKey($suffixKey)) {
                        $catalogsBySuffix[$suffixKey] = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                    }
                    [void]$catalogsBySuffix[$suffixKey].Add($catLeaf)
                }
            }
        }

        # Windows INF 仕様に従い、現在の OS アーキテクチャに適合する最も具体的な CatalogFile エントリを優先する
        # (例: AMD64 環境では CatalogFile.NTamd64 > CatalogFile.NT > CatalogFile)
        $catalogNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        if ($archSuffix -and $catalogsBySuffix.ContainsKey($archSuffix)) {
            foreach ($c in $catalogsBySuffix[$archSuffix]) { [void]$catalogNames.Add($c) }
        } elseif ($catalogsBySuffix.ContainsKey('NT')) {
            foreach ($c in $catalogsBySuffix['NT']) { [void]$catalogNames.Add($c) }
        } elseif ($catalogsBySuffix.ContainsKey('')) {
            foreach ($c in $catalogsBySuffix['']) { [void]$catalogNames.Add($c) }
        } else {
            foreach ($c in $allDeclaredCatalogs) { [void]$catalogNames.Add($c) }
        }

        if ($catalogNames.Count -eq 0) {
            $defaultCat = [System.IO.Path]::ChangeExtension($infFile.Name, '.cat')
            if (Test-Path -LiteralPath (Join-Path $infDir $defaultCat) -PathType Leaf) {
                [void]$catalogNames.Add($defaultCat)
            } else {
                throw "INF '$($infFile.Name)' にカタログファイル（CatalogFile）の指定がなく、同名 CAT も見つかりません。未署名パッケージの可能性があります。"
            }
        }

        $missingCatalogs = @(foreach ($catLeaf in $catalogNames) {
            if (-not (Test-Path -LiteralPath (Join-Path $infDir $catLeaf) -PathType Leaf)) { $catLeaf }
        })
        if ($missingCatalogs.Count -gt 0) {
            # CAT が一部だけ不足する INF は、同梱物の候補にしない。
            if (-not $AllowPayloadInf -or $missingCatalogs.Count -ne $catalogNames.Count) {
                throw "INF '$($infFile.FullName)' のカタログファイルが見つかりません: $($missingCatalogs -join ', ')"
            }
            $missing.Add([PSCustomObject]@{ Inf = $infFile; Catalogs = $missingCatalogs })
            continue
        }

        foreach ($catLeaf in $catalogNames) {
            $catPath = Join-Path $infDir $catLeaf
            $sig = Get-AuthenticodeSignature -LiteralPath $catPath
            if ($sig.Status -ne 'Valid') {
                throw "カタログファイル '$catLeaf' のデジタル署名が無効または破損しています (Status: $($sig.Status), Message: $($sig.StatusMessage))"
            }
        }
        $verified.Add([PSCustomObject]@{ Inf = $infFile; Lines = $lines })
    }

    foreach ($entry in $missing) {
        # ハッシュ照合済みのバックアップに限り、CAT 検証済みの同階層の親 INF が
        # SourceDisksFiles に明記した INF を同梱ファイルとみなす。ファイルは削除しない。
        $isPayload = $false
        $sourcePattern = '^\s*"?' + [regex]::Escape($entry.Inf.Name) + '"?\s*=\s*\d+\s*(?:[,;]|$)'
        foreach ($parent in $verified) {
            if ($parent.Inf.DirectoryName -ine $entry.Inf.DirectoryName) { continue }
            $inSourceFiles = $false
            foreach ($line in $parent.Lines) {
                if ($line -match '^\s*\[([^\]]+)\]') {
                    $inSourceFiles = ($Matches[1].Trim() -match '^SourceDisksFiles(?:\.[^\s]+)?$')
                } elseif ($inSourceFiles -and $line -match $sourcePattern) {
                    $isPayload = $true
                    break
                }
            }
            if ($isPayload) { break }
        }
        if (-not $isPayload) {
            throw "INF '$($entry.Inf.FullName)' のカタログファイルが見つかりません: $($entry.Catalogs -join ', ')"
        }
        Write-Host "  同梱 INF（単独インストール対象外）: $($entry.Inf.FullName)" -ForegroundColor Gray
    }

    if ($verified.Count -eq 0) { throw '署名を確認できるドライバ INF が見つかりません。' }
    if ($AllowPayloadInf) {
        # CopyINF 参照先が先に DriverStore へ登録されるよう依存順に並べる（自己参照は除外）
        $presentLeafNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($v in $verified) { [void]$presentLeafNames.Add($v.Inf.Name) }

        $itemsWithDeps = New-Object 'System.Collections.Generic.List[object]'
        foreach ($v in $verified) {
            $deps = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($line in $v.Lines) {
                if ($line -match '^\s*CopyINF\s*=\s*([^;]+)') {
                    foreach ($ref in ($Matches[1] -split ',')) {
                        $refLeaf = [System.IO.Path]::GetFileName($ref.Trim().Trim('"'))
                        if ($refLeaf -and ($refLeaf -ine $v.Inf.Name) -and $presentLeafNames.Contains($refLeaf)) {
                            [void]$deps.Add($refLeaf)
                        }
                    }
                }
            }
            $itemsWithDeps.Add([PSCustomObject]@{ Inf = $v.Inf; Deps = $deps; Emitted = $false })
        }

        $emittedNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $orderedInfs = New-Object 'System.Collections.Generic.List[object]'
        while ($orderedInfs.Count -lt $itemsWithDeps.Count) {
            $progressed = $false
            foreach ($item in $itemsWithDeps) {
                if ($item.Emitted) { continue }
                $allReady = $true
                foreach ($dName in $item.Deps) {
                    if (-not $emittedNames.Contains($dName)) { $allReady = $false; break }
                }
                if ($allReady) {
                    $item.Emitted = $true
                    [void]$emittedNames.Add($item.Inf.Name)
                    $orderedInfs.Add($item.Inf)
                    $progressed = $true
                }
            }
            if (-not $progressed) {
                foreach ($item in $itemsWithDeps) {
                    if (-not $item.Emitted) {
                        $item.Emitted = $true
                        [void]$emittedNames.Add($item.Inf.Name)
                        $orderedInfs.Add($item.Inf)
                    }
                }
                break
            }
        }
        $orderedInfs | ForEach-Object { $_ }
    }
}

function Invoke-PnpUtil {
    param([string[]]$Arguments, [string]$LogPath)
    if (-not (Test-Path -LiteralPath $script:pnpUtilPath -PathType Leaf)) { throw 'pnputil.exe が見つかりません。' }
    # Windows PowerShell 5.1 では native stderr を ErrorRecord に変換する場合がある。
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = $null
        $output = & $script:pnpUtilPath @Arguments 2>&1
        $code = $global:LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    $output | Out-File -LiteralPath $LogPath -Append -Encoding UTF8
    if ($null -eq $code) { throw "pnputilを実行できませんでした。ログ: $LogPath" }
    return [int]$code
}


function Invoke-DriverExport {
    param([bool]$MinimalMode)

    $modeLabel = if ($MinimalMode) { '最小構成バックアップ（必須ドライバ一式）' } else { '全ドライババックアップ' }
    Show-Page $modeLabel
    Write-Host '保存先は、この .cmd と同じ場所です。' -ForegroundColor Gray
    Write-Host 'Enter = driver ／ 別名も入力可 ／ 0 = 戻る'
    Write-Host '保存後にフォルダ名を変えても、復元時に選択できます。'
    while ($true) {
        $inputName = (Read-Host '保存フォルダ名 [driver]').Trim()
        if ($inputName -eq '0') { return }
        try {
            $targetDir = Resolve-ExportFolder -Name $inputName
            break
        } catch {
            Write-Host $_.Exception.Message -ForegroundColor Yellow
        }
    }
    $safeModel = Get-SafeModelName
    $folderName = [System.IO.Path]::GetFileName($targetDir)
    Write-Host "`n保存先: $targetDir" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "[1/4] DriverStore 内のサードパーティ製ドライバ一覧を取得しています..." -ForegroundColor Gray
    $storeDrivers = @(Get-WindowsDriver -Online -ErrorAction Stop)
    if ($storeDrivers.Count -eq 0) {
        throw '保存対象のサードパーティ製ドライバが見つかりませんでした。'
    }

    $driverMap = @{}
    $leafInfMap = @{}
    $totalStoreBytes = [long]0

    foreach ($d in $storeDrivers) {
        if ([string]::IsNullOrWhiteSpace($d.Driver)) { continue }
        $oemKey = $d.Driver.Trim().ToLowerInvariant()
        $origInf = $d.OriginalFileName
        if (-not $origInf -or -not (Test-Path -LiteralPath $origInf -PathType Leaf)) {
            throw "元のドライバパッケージを参照できません: $oemKey"
        }
        $pkgDir = [System.IO.Path]::GetDirectoryName($origInf)
        $leafInf = [System.IO.Path]::GetFileName($origInf).ToLowerInvariant()
        $pkgBytes = Get-DirectorySize -Path $pkgDir
        $totalStoreBytes += $pkgBytes

        $info = [PSCustomObject]@{
            OemInf       = $oemKey
            OriginalInf  = $origInf
            LeafInf      = $leafInf
            PackageDir   = $pkgDir
            PackageName  = [System.IO.Path]::GetFileName($pkgDir)
            ClassName    = [string]$d.ClassName
            ClassGuid    = if ($d.PSObject.Properties['ClassGuid'] -and $d.ClassGuid) { [string]$d.ClassGuid } else { '' }
            ProviderName = [string]$d.ProviderName
            Version      = [string]$d.Version
            Date         = $d.Date
            BootCritical = [bool]$d.BootCritical
            SizeBytes    = $pkgBytes
        }
        $driverMap[$oemKey] = $info
        if ($leafInf) {
            if (-not $leafInfMap.ContainsKey($leafInf)) {
                $leafInfMap[$leafInf] = New-Object System.Collections.ArrayList
            }
            [void]$leafInfMap[$leafInf].Add($info)
        }
    }

    Write-Host "[2/4] 現在PCに搭載されているデバイスと使用中ドライバを解析しています..." -ForegroundColor Gray
    $allDevices = @(Get-PnpDevice -PresentOnly -ErrorAction Stop)
    $presentDevices = $allDevices
    if ($allDevices.Count -eq 0) { throw '接続デバイスを取得できませんでした。' }

    $allIds = @($allDevices | Where-Object { $_.InstanceId } | ForEach-Object { $_.InstanceId })
    $infByDev = @{}
    $extendedInfsByDev = @{}
    $parentMap = @{}
    $hwIdsByDev = @{}
    $compatIdsByDev = @{}
    $drvDescByDev = @{}
    $devNodeStatusByDev = @{}

    if ($allIds.Count -gt 0) {
        $corePropKeys = @(
            'DEVPKEY_Device_DriverInfPath',
            'DEVPKEY_Device_Parent',
            'DEVPKEY_Device_HardwareIds',
            'DEVPKEY_Device_CompatibleIds',
            'DEVPKEY_Device_DriverDesc',
            'DEVPKEY_Device_DevNodeStatus'
        )
        foreach ($prop in (Get-SafePnpDeviceProperties -Devices $allDevices -KeyNames $corePropKeys)) {
            if (-not $prop.InstanceId -or $null -eq $prop.Data) { continue }
            switch ($prop.KeyName) {
                'DEVPKEY_Device_DriverInfPath' {
                    if ($prop.Data) { $infByDev[[string]$prop.InstanceId] = [string]$prop.Data }
                }
                'DEVPKEY_Device_Parent' {
                    if ($prop.Data) { $parentMap[[string]$prop.InstanceId] = [string]$prop.Data }
                }
                'DEVPKEY_Device_HardwareIds' {
                    $hwVals = @($prop.Data | ForEach-Object { [string]$_ } | Where-Object { $_ })
                    if ($hwVals.Count -gt 0) { $hwIdsByDev[[string]$prop.InstanceId] = $hwVals }
                }
                'DEVPKEY_Device_CompatibleIds' {
                    $compatVals = @($prop.Data | ForEach-Object { [string]$_ } | Where-Object { $_ })
                    if ($compatVals.Count -gt 0) { $compatIdsByDev[[string]$prop.InstanceId] = $compatVals }
                }
                'DEVPKEY_Device_DriverDesc' {
                    if ($prop.Data) { $drvDescByDev[[string]$prop.InstanceId] = [string]$prop.Data }
                }
                'DEVPKEY_Device_DevNodeStatus' {
                    if ($null -ne $prop.Data) { $devNodeStatusByDev[[string]$prop.InstanceId] = $prop.Data }
                }
            }
        }
        # DEVPKEY_Device_DriverExtendedInfs ({A8B865DD-2E3D-4094-AD97-E593A70C75D6} 20) を分離取得
        $extProps = @(Get-SafePnpDeviceProperties -Devices $allDevices -KeyNames @('{A8B865DD-2E3D-4094-AD97-E593A70C75D6} 20'))
        if ($extProps.Count -eq 0) {
            $extProps = @(Get-SafePnpDeviceProperties -Devices $allDevices -KeyNames @('DEVPKEY_Device_ExtendedInfNames'))
        }
        foreach ($ep in $extProps) {
            if ($ep.InstanceId -and $ep.Data) { $extendedInfsByDev[[string]$ep.InstanceId] = @($ep.Data) }
        }
    }

    Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop | ForEach-Object {
        if ($_.DeviceID -and $_.InfName -and -not $infByDev.ContainsKey($_.DeviceID)) {
            $infByDev[$_.DeviceID] = [string]$_.InfName
        }
    }
    if ($MinimalMode -and $infByDev.Count -eq 0) { throw '使用中のINF情報を取得できませんでした。' }

    # 必須5カテゴリの適用状態診断
    $catStatuses = @(Get-CoreCategoryStatus -Devices $presentDevices -InfByDev $infByDev -DriverMap $driverMap -HwIdsByDev $hwIdsByDev -CompatIdsByDev $compatIdsByDev -DevNodeStatusByDev $devNodeStatusByDev)
    Write-Host "`n--- 必須カテゴリのドライバ適用状況 ---" -ForegroundColor Cyan
    foreach ($cs in $catStatuses) {
        $stateColor = switch ($cs.State) {
            'OemDriverBound'   { 'Green' }
            'InboxDriverOnly'  { 'Gray' }
            'UnboundOrError'   { 'Yellow' }
            default            { 'DarkGray' }
        }
        $stateText = switch ($cs.State) {
            'OemDriverBound'   { '[OEM適用中・保存対象]' }
            'InboxDriverOnly'  { '[OS標準インボックス・保存不要]' }
            'UnboundOrError'   { '[未適用/要注意]' }
            default            { '[未検出]' }
        }
        Write-Host ("  {0,-40} : {1}" -f $cs.Name, $stateText) -ForegroundColor $stateColor
        foreach ($d in $cs.Details) {
            Write-Host "      $d" -ForegroundColor DarkGray
        }
    }

    # 未適用・要注意デバイスの診断
    $unhealthyDevices = @(Get-UnhealthyOrUnboundDevices -Devices $presentDevices -InfByDev $infByDev -HwIdsByDev $hwIdsByDev -CompatIdsByDev $compatIdsByDev -DevNodeStatusByDev $devNodeStatusByDev)
    if ($unhealthyDevices.Count -gt 0) {
        Write-Host ""
        Write-Host "【警告】ドライバが未適用または異常なデバイスが $($unhealthyDevices.Count) 件あります:" -ForegroundColor Yellow
        foreach ($uh in $unhealthyDevices) {
            Write-Host "  - [$($uh.Severity)] $($uh.Name) [$($uh.InstanceId)]" -ForegroundColor Yellow
            Write-Host "      内容: $($uh.Detail)" -ForegroundColor DarkYellow
        }
        Write-Host '  ※未適用のデバイスはバックアップに含まれません。OS消去前にドライバを適用することを強く推奨します。' -ForegroundColor Yellow
        if ((Read-Host 'このまま保存を続行しますか？ [Y/N]') -notmatch '^(?i:y|yes)$') { return }
    }

    $alwaysExcludedClasses = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    @('Printer', 'PrintQueue', 'Fax') | ForEach-Object { [void]$alwaysExcludedClasses.Add($_) }

    $selectedOemInfs = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $excludedReasonMap = @{}
    $deviceUsageMap = @{}

    foreach ($dev in $allDevices) {
        $id = $dev.InstanceId
        if (-not $id) { continue }
        if (Test-ExcludedVirtualNetworkDevice -Device $dev) { continue }

        $devClass = [string]$dev.Class
        $devName = if ($dev.FriendlyName) { $dev.FriendlyName } elseif ($dev.Name) { $dev.Name } else { $id }

        $candidateInfs = New-Object System.Collections.ArrayList
        if ($infByDev.ContainsKey($id)) { [void]$candidateInfs.Add([string]$infByDev[$id]) }
        if ($extendedInfsByDev.ContainsKey($id)) {
            foreach ($extInf in $extendedInfsByDev[$id]) {
                if ($extInf) { [void]$candidateInfs.Add([string]$extInf) }
            }
        }

        $oemCandidates = @($candidateInfs | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ -match '^oem\d+\.inf$' -and $driverMap.ContainsKey($_) })
        if ($oemCandidates.Count -eq 0) { continue }

        if ($alwaysExcludedClasses.Contains($devClass)) {
            foreach ($oem in $oemCandidates) {
                if (-not $excludedReasonMap.ContainsKey($oem)) { $excludedReasonMap[$oem] = "プリンタ/仮想キュー ($devName)" }
            }
            continue
        }

        foreach ($oem in $oemCandidates) {
            $dInfo = $driverMap[$oem]
            if ($alwaysExcludedClasses.Contains($dInfo.ClassName)) {
                if (-not $excludedReasonMap.ContainsKey($oem)) { $excludedReasonMap[$oem] = "プリンタクラス ($($dInfo.PackageName))" }
                continue
            }

            [void]$selectedOemInfs.Add($oem)
            if (-not $deviceUsageMap.ContainsKey($oem)) {
                $deviceUsageMap[$oem] = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
            }
            [void]$deviceUsageMap[$oem].Add($devName)
        }
    }

    # Extension / SoftwareComponent / AudioProcessingObject / BootCritical を安全側で残す
    # （プリンタ等は除外）
    foreach ($info in $driverMap.Values) {
        if ($alwaysExcludedClasses.Contains($info.ClassName)) { continue }
        if (-not $MinimalMode -or $info.BootCritical -or
            ($info.ClassName -in @('Extension', 'SoftwareComponent', 'AudioProcessingObject'))) {
            [void]$selectedOemInfs.Add($info.OemInf)
            if (-not $deviceUsageMap.ContainsKey($info.OemInf)) {
                $deviceUsageMap[$info.OemInf] = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
            }
            [void]$deviceUsageMap[$info.OemInf].Add('全保存、または関連パッケージを安全側で保持')
        }
    }

    $onlineExcludedOemInfs = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $onlineDriversToRecord = New-Object System.Collections.Generic.List[object]

    if ($MinimalMode) {
        $eligibleOnlineDisplays = @(Get-OnlineEligibleDisplayDrivers -Devices $allDevices -DriverMap $driverMap -InfByDev $infByDev -HwIdsByDev $hwIdsByDev -CompatIdsByDev $compatIdsByDev -DrvDescByDev $drvDescByDev -SelectedOemInfs $selectedOemInfs)
        if ($eligibleOnlineDisplays.Count -gt 0) {
            $uniqueOnlineOems = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
            $onlineTotalBytes = [long]0
            foreach ($ed in $eligibleOnlineDisplays) {
                if ($uniqueOnlineOems.Add($ed.OemInf)) {
                    $onlineTotalBytes += [long]$ed.EstimatedSizeBytes
                }
            }
            Write-Host "`n--- 物理ディスプレイドライバの保存方法 ---" -ForegroundColor Cyan
            foreach ($ed in $eligibleOnlineDisplays) {
                Write-Host ("  対象: {0} ({1}, v{2}, {3})" -f $ed.DeviceName, $ed.LeafInf, $ed.Version, (Format-ByteSize $ed.EstimatedSizeBytes)) -ForegroundColor White
            }
            Write-Host ("  削減見込み容量: 約 {0}（復元時はLAN/Wi-Fi適用後にMSカタログ等から自動取得）" -f (Format-ByteSize $onlineTotalBytes)) -ForegroundColor Gray
            $useOnlineDisplay = $true
            while ($true) {
                $ansOnline = ([string](Read-Host 'ディスプレイドライバをローカル保存せず、復元時にインターネット（MSカタログ等）から自動取得しますか？ [Y/N]')).Trim()
                if ([string]::IsNullOrEmpty($ansOnline) -or $ansOnline -match '^(?i:y|yes)$') {
                    $useOnlineDisplay = $true
                    break
                }
                if ($ansOnline -match '^(?i:n|no)$') {
                    $useOnlineDisplay = $false
                    break
                }
                Write-Host 'Y（オンライン取得・既定）または N（ローカル保存に含める）を入力してください。' -ForegroundColor Yellow
            }
            if ($useOnlineDisplay) {
                foreach ($ed in $eligibleOnlineDisplays) {
                    [void]$onlineExcludedOemInfs.Add($ed.OemInf)
                    [void]$selectedOemInfs.Remove($ed.OemInf)
                    $excludedReasonMap[$ed.OemInf] = "復元時にオンライン取得（MSカタログ等: $($ed.DeviceName) v$($ed.Version)）"
                    $onlineDriversToRecord.Add([PSCustomObject]@{
                        DeviceName         = $ed.DeviceName
                        ClassName          = $ed.ClassName
                        ProviderName       = $ed.ProviderName
                        LeafInf            = $ed.LeafInf
                        PackageName        = $ed.PackageName
                        Version            = $ed.Version
                        DriverDate         = $ed.DriverDate
                        DriverDesc         = $ed.DriverDesc
                        EstimatedSizeBytes = [long]$ed.EstimatedSizeBytes
                        HardwareIds        = [string[]]@($ed.HardwareIds)
                        CompatibleIds      = [string[]]@($ed.CompatibleIds)
                    })
                }
                Write-Host ("  -> ディスプレイドライバ（{0} パッケージ / 約 {1}）をオンライン取得に設定しました。" -f $uniqueOnlineOems.Count, (Format-ByteSize $onlineTotalBytes)) -ForegroundColor Green
            } else {
                Write-Host '  -> ディスプレイドライバもローカル保存に含めます。' -ForegroundColor Gray
            }
        }
    }

    # CopyINF の連鎖依存解析
    $bfsQueue = New-Object System.Collections.Queue
    foreach ($oem in $selectedOemInfs) { $bfsQueue.Enqueue($oem) }

    while ($bfsQueue.Count -gt 0) {
        $curOem = [string]$bfsQueue.Dequeue()
        $curInfo = $driverMap[$curOem]
        if (-not $curInfo -or -not $curInfo.OriginalInf -or -not (Test-Path -LiteralPath $curInfo.OriginalInf)) { continue }

        $lines = Read-InfTextLines -FilePath $curInfo.OriginalInf
        foreach ($line in $lines) {
            if ($line -match '^\s*CopyINF\s*=\s*([^;]+)') {
                $refs = $Matches[1] -split ','
                foreach ($ref in $refs) {
                    $refLeaf = [System.IO.Path]::GetFileName($ref.Trim().Trim('"')).ToLowerInvariant()
                    if ($refLeaf -and $leafInfMap.ContainsKey($refLeaf)) {
                        foreach ($bestMatch in $leafInfMap[$refLeaf]) {
                            $depOem = $bestMatch.OemInf
                            if ($onlineExcludedOemInfs.Contains($depOem)) { continue }
                            if ($selectedOemInfs.Add($depOem)) {
                                $bfsQueue.Enqueue($depOem)
                                if (-not $deviceUsageMap.ContainsKey($depOem)) {
                                    $deviceUsageMap[$depOem] = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                                }
                                [void]$deviceUsageMap[$depOem].Add("CopyINF連動 ($($curInfo.LeafInf))")
                            }
                        }
                    }
                }
            }
        }
    }

    if ($selectedOemInfs.Count -eq 0 -and $onlineDriversToRecord.Count -eq 0) {
        throw 'エクスポート対象がありません。全ドライババックアップを試してください。'
    }

    $sortedSelected = @($selectedOemInfs | ForEach-Object { $driverMap[$_] } | Sort-Object ClassName, PackageName)
    $estimate = [long]0
    if ($sortedSelected.Count -gt 0) {
        $estimate = [long](($sortedSelected | Measure-Object SizeBytes -Sum).Sum)
    }
    Write-Host "`n保存予定: $($sortedSelected.Count) パッケージ / 約 $(Format-ByteSize $estimate)" -ForegroundColor Cyan
    if ($onlineDriversToRecord.Count -gt 0) {
        Write-Host "オンライン取得登録: $($onlineDriversToRecord.Count) 件（復元時にMSカタログ等から自動取得）" -ForegroundColor Cyan
    }
    if ($MinimalMode) {
        Write-Host '使用中の必須ドライバ一式（オーディオ・ビデオ・有線/無線NIC・Bluetooth・システム等）を保存します。' -ForegroundColor Gray
        Write-Host '未使用・旧版パッケージやプリンタ等は除外されます。' -ForegroundColor Gray
    }
    if ((Read-Host 'この内容で保存しますか？ [Y/N]') -notmatch '^(?i:y|yes)$') { return }
    # 入力後に保存先が変化していないか再確認する。既存データは削除しない。
    $null = Resolve-ExportFolder -Name $folderName
    [System.IO.Directory]::CreateDirectory($targetDir) | Out-Null
    Assert-NoReparsePoint -Path $targetDir
    Write-BackupManifest -Root $targetDir -Status 'InProgress' -Mode $modeLabel
    $logPath = Join-Path $targetDir '_pnputil_export.log'
    Write-Host "`n[3/4] パッケージの保存と内容検証" -ForegroundColor Cyan
    if ($sortedSelected.Count -eq 0) {
        Write-Host '  ローカル保存対象パッケージはありません（オンライン取得情報のみ記録します）。' -ForegroundColor Gray
        '[Info] Local INF packages: 0 (OnlineDrivers metadata only)' | Out-File -LiteralPath $logPath -Append -Encoding UTF8
    }

    $exportedCount = 0
    $failedList = New-Object System.Collections.ArrayList
    $verifiedFiles = New-Object System.Collections.Generic.List[object]
    $exportedInfRelByOem = @{}

    foreach ($item in $sortedSelected) {
        $exportedCount++
        $sizeText = Format-ByteSize $item.SizeBytes
        Write-Host ("  [{0}/{1}] {2} ({3} / {4})" -f $exportedCount, $sortedSelected.Count, $item.PackageName, $item.ClassName, $sizeText)

        try {
            $subFolderName = $item.OemInf.Replace('.inf', '')
            $destSub = Join-Path $targetDir $subFolderName
            [IO.Directory]::CreateDirectory($destSub) | Out-Null
            $code = Invoke-PnpUtil -Arguments @('/export-driver', $item.OemInf, $destSub) -LogPath $logPath
            if ($code -ne 0) { throw "pnputil 終了コード: $code" }
            $verifyInfs = @(Get-ChildItem -LiteralPath $destSub -Recurse -File | Where-Object { $_.Name -ieq $item.LeafInf })
            if ($verifyInfs.Count -ne 1) { throw '出力されたINFを特定できません。' }
            $packageRoot = [IO.Path]::GetDirectoryName($verifyInfs[0].FullName)
            Assert-ExportedPackage -SourceRoot $item.PackageDir -ExportRoot $packageRoot -LeafInf $item.LeafInf
            $destSubPrefix = [IO.Path]::GetFullPath($destSub).TrimEnd('\') + '\'
            $exportedInfRelByOem[$item.OemInf] = $subFolderName + '\' + $verifyInfs[0].FullName.Substring($destSubPrefix.Length)
            foreach ($file in Get-PackageFiles -Root $destSub) {
                $file.Path = $subFolderName + '\' + $file.Path
                $verifiedFiles.Add($file)
            }
            Write-Host '    OK' -ForegroundColor Green
        } catch {
            [void]$failedList.Add($item.PackageName)
            Write-Host "    失敗: $($_.Exception.Message)" -ForegroundColor Red
            "[$($item.OemInf)] $($_.Exception.Message)" | Out-File -LiteralPath $logPath -Append -Encoding UTF8
        }
    }

    Write-Host "[4/4] エクスポート内訳レポートを生成しています..." -ForegroundColor Gray

    $finalBytes = Get-DirectorySize -Path $targetDir
    $savedBytes = [Math]::Max([long]0, ($totalStoreBytes - $finalBytes))
    $savedPct = if ($totalStoreBytes -gt 0) { ($savedBytes * 100.0 / $totalStoreBytes) } else { 0 }

    $reportLines = New-Object System.Collections.Generic.List[string]
    $reportLines.Add("================================================================")
    $reportLines.Add(" Windows ドライバ エクスポート内訳レポート")
    $reportLines.Add("================================================================")
    $reportLines.Add("作成日時       : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $reportLines.Add("PCモデル       : $safeModel")
    $reportLines.Add("モード         : $modeLabel")
    $reportLines.Add("サードパーティINF合計: $(Format-ByteSize $totalStoreBytes) ($($storeDrivers.Count) パッケージ、論理サイズ)")
    $reportLines.Add("エクスポート量 : $(Format-ByteSize $finalBytes) ($($sortedSelected.Count) パッケージ)")
    $reportLines.Add("オンライン取得登録: $($onlineDriversToRecord.Count) 件（復元時にMSカタログ等から自動取得）")
    $reportLines.Add(("削減サイズ     : {0} ({1:N1}% 削減)" -f (Format-ByteSize $savedBytes), $savedPct))
    $reportLines.Add("")
    if ($onlineDriversToRecord.Count -gt 0) {
        $reportLines.Add("--- オンライン取得対象ドライバ一覧 ($($onlineDriversToRecord.Count) 件) ---")
        foreach ($od in $onlineDriversToRecord) {
            $reportLines.Add(("[{0}] {1} ({2}, v{3}, 削減見込み: {4})" -f $od.ClassName, $od.DeviceName, $od.PackageName, $od.Version, (Format-ByteSize $od.EstimatedSizeBytes)))
            $reportLines.Add(("    HardwareIds: {0}" -f (@($od.HardwareIds) -join ', ')))
        }
        $reportLines.Add("")
    }
    $reportLines.Add("--- 保存対象パッケージ一覧 ($($sortedSelected.Count) 件) ---")
    $reportLines.Add("検証失敗: $($failedList.Count) 件 / $($failedList -join ', ')")
    $reportLines.Add('検証対象: INF・CAT・ドライバ本体など。元フォルダとの照合では、PNFキャッシュと AMD ドライバの既知の実行時生成ファイル（Crash Defender ログ・HDCP SRM データ）を除外。')
    $reportLines.Add("")
    $reportLines.Add("--- 必須カテゴリのドライバ適用状況 ---")
    foreach ($cs in $catStatuses) {
        $reportLines.Add(("[{0}] {1}" -f $cs.State, $cs.Name))
        foreach ($d in $cs.Details) {
            $reportLines.Add("    $d")
        }
    }
    $reportLines.Add("")
    $reportLines.Add("--- 未適用・要注意デバイス診断結果 ($($unhealthyDevices.Count) 件) ---")
    if ($unhealthyDevices.Count -eq 0) {
        $reportLines.Add("なし（全接続デバイスが正常にバインドされています）")
    } else {
        foreach ($uh in $unhealthyDevices) {
            $reportLines.Add(("[{0}] {1} [{2}] : {3}" -f $uh.Severity, $uh.Name, $uh.InstanceId, $uh.Detail))
        }
    }
    $reportLines.Add("")
    foreach ($item in $sortedSelected) {
        $devs = if ($deviceUsageMap.ContainsKey($item.OemInf)) { ($deviceUsageMap[$item.OemInf] -join ', ') } else { '-' }
        $reportLines.Add(("[{0}] {1} ({2}, v{3}, {4})" -f $item.ClassName, $item.PackageName, $item.ProviderName, $item.Version, (Format-ByteSize $item.SizeBytes)))
        $reportLines.Add("    対象: $devs")
    }
    $reportLines.Add("")
    $reportLines.Add("--- 除外されたドライバパッケージ一覧 ---")
    $excludedItems = @($driverMap.Values | Where-Object { -not $selectedOemInfs.Contains($_.OemInf) } | Sort-Object SizeBytes -Descending)
    foreach ($ex in $excludedItems) {
        $reason = if ($excludedReasonMap.ContainsKey($ex.OemInf)) { $excludedReasonMap[$ex.OemInf] } else { '接続デバイスの使用中INF・安全側保持の対象外' }
        $reportLines.Add(("[除外] {0} ({1}, {2}) -> 理由: {3}" -f $ex.PackageName, $ex.ClassName, (Format-ByteSize $ex.SizeBytes), $reason))
    }

    $reportPath = Join-Path $targetDir '_エクスポート内訳レポート.txt'
    [System.IO.File]::WriteAllLines($reportPath, $reportLines, (New-Object System.Text.UTF8Encoding($true)))

    if ($failedList.Count -gt 0) {
        Write-BackupManifest -Root $targetDir -Status 'Failed' -Mode $modeLabel
        throw "保存・検証に $($failedList.Count) 件失敗しました。バックアップは未完了です。ログ: $logPath"
    }

    $deviceBindings = New-Object System.Collections.Generic.List[object]
    foreach ($dev in $allDevices) {
        $id = [string]$dev.InstanceId
        if (-not $id -or (Test-ExcludedVirtualNetworkDevice -Device $dev)) { continue }
        $prob = if ($dev.PSObject.Properties['Problem'] -and $null -ne $dev.Problem) { [int]$dev.Problem } else { 0 }
        if ($prob -ne 0 -or -not $infByDev.ContainsKey($id)) { continue }
        $primaryOem = $infByDev[$id].Trim().ToLowerInvariant()
        if ($primaryOem -notmatch '^oem\d+\.inf$' -or -not $selectedOemInfs.Contains($primaryOem) -or -not $driverMap.ContainsKey($primaryOem)) { continue }
        $hwIds = @((Get-DeviceHardwareAndCompatibleIds -Device $dev -HwIdsByDev $hwIdsByDev).HardwareIds)
        if ($hwIds.Count -eq 0) { continue }
        $dInfo = $driverMap[$primaryOem]
        $drvDesc = if ($drvDescByDev.ContainsKey($id)) { $drvDescByDev[$id] } else { '' }
        $infRel = if ($exportedInfRelByOem.ContainsKey($primaryOem)) { $exportedInfRelByOem[$primaryOem] } else { '' }
        $deviceBindings.Add([PSCustomObject]@{
            HardwareIds     = $hwIds
            LeafInf         = $dInfo.LeafInf
            PackageName     = $dInfo.PackageName
            ClassName       = $dInfo.ClassName
            DriverDesc      = $drvDesc
            InfRelativePath = $infRel
        })
    }

    Write-BackupManifest -Root $targetDir -Status 'Complete' -Mode $modeLabel -Files $verifiedFiles.ToArray() -DeviceBindings $deviceBindings.ToArray() -OnlineDrivers $onlineDriversToRecord.ToArray()
    if ($onlineDriversToRecord.Count -gt 0) {
        Write-Host "`n[完了] ローカル $($sortedSelected.Count) パッケージ保存 ＋ オンライン取得対象 $($onlineDriversToRecord.Count) 件を記録しました。" -ForegroundColor Green
    } else {
        Write-Host "`n[完了] $($sortedSelected.Count) パッケージを保存・検証しました。" -ForegroundColor Green
    }
    Write-Host "保存先: $targetDir"
    Write-Host "容量  : $(Format-ByteSize (Get-DirectorySize $targetDir))"
    Write-Host "レポート: $reportPath"
    Write-Host "`nこの .cmd と保存フォルダを、消去しないUSB等へ一緒に退避してください。" -ForegroundColor Yellow
    Write-Host 'フォルダ名は後から変更可能です。中の階層・ファイルは変更しないでください。'
}

function Test-DriverFolderValidity {
    param([string]$FolderPath)
    Assert-NoReparsePoint -Path $FolderPath
    if (-not (Test-Path -LiteralPath $FolderPath -PathType Container)) { throw "フォルダがありません: $FolderPath" }
    $allFiles = @(Get-ChildItem -LiteralPath $FolderPath -Recurse -File -Force -ErrorAction Stop)
    $infCount = 0
    $catCount = 0
    $totalBytes = [long]0
    foreach ($f in $allFiles) {
        $totalBytes += $f.Length
        $ext = $f.Extension.ToLowerInvariant()
        if ($ext -eq '.inf') { $infCount++ }
        elseif ($ext -eq '.cat') { $catCount++ }
    }
    $manifestPath = Join-Path $FolderPath 'driver-backup.json'
    $hasManifest = Test-Path -LiteralPath $manifestPath -PathType Leaf
    $manifestStatus = ''
    $onlineCount = 0
    if ($hasManifest) {
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($manifest.FormatVersion -eq 1) {
                $manifestStatus = [string]$manifest.Status
                if ($manifestStatus -eq 'Complete' -and $manifest.OnlineDrivers) { $onlineCount = @($manifest.OnlineDrivers).Count }
            }
        } catch { $manifestStatus = '' }
    }
    return [PSCustomObject]@{
        HasInf            = ($infCount -gt 0)
        HasCatalog        = ($catCount -gt 0)
        InfCount          = $infCount
        HasManifest       = $hasManifest
        ManifestStatus    = $manifestStatus
        HasOnlineDrivers  = ($onlineCount -gt 0)
        OnlineDriverCount = $onlineCount
        SizeBytes         = $totalBytes
    }
}

function Get-DriverFolderCandidates {
    $subDirs = @(Get-ChildItem -LiteralPath $script:workDir -Directory | Sort-Object @{ Expression = { $_.Name -ine 'driver' } }, Name)
    foreach ($sd in $subDirs) {
        if ($sd.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        try {
            $v = Test-DriverFolderValidity -FolderPath $sd.FullName
        } catch {
            Write-Host "検索をスキップ（読み取り不可または検証失敗）: $($sd.Name)" -ForegroundColor DarkGray
            continue
        }
        if ($v.HasInf -or $v.HasOnlineDrivers) {
            [PSCustomObject]@{ Name = $sd.Name; FullName = $sd.FullName; Info = $v }
        }
    }
}

function Select-ImportFolder {
    $defaultFolder = [System.IO.Path]::GetFullPath((Join-Path $script:workDir 'driver'))
    $hasDefault = $false
    if (Test-Path -LiteralPath $defaultFolder -PathType Container) {
        try {
            $defItem = Get-Item -LiteralPath $defaultFolder -Force
            if (-not ($defItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $vDef = Test-DriverFolderValidity -FolderPath $defaultFolder
                $hasDefault = ($vDef.HasInf -or $vDef.HasOnlineDrivers)
            }
        } catch { $hasDefault = $false }
    }

    $defStateText = if ($hasDefault) { '検出済み・Enterで選択' } else { '未作成' }
    Write-Host ("既定の保存先: {0} ({1})" -f $defaultFolder, $defStateText) -ForegroundColor $(if ($hasDefault) { 'Cyan' } else { 'DarkGray' })
    Write-Host ''

    $candidates = @(Get-DriverFolderCandidates)
    Write-Host '同じ場所にあるバックアップ（名前を変更したフォルダも表示）:'
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $c = $candidates[$i]
        $label = if ($c.Info.HasManifest) {
            if ($c.Info.ManifestStatus -eq 'Complete') { '完全性検証可能' } else { '未完了または検証情報が無効・再エクスポートが必要' }
        } elseif ($c.Info.HasCatalog) { 'カタログ署名のみ検証可能' } else { 'CATなし・要確認' }
        $defMark = if ($c.FullName -ieq $defaultFolder) { ' [既定]' } else { '' }
        $onlineNote = if ($c.Info.OnlineDriverCount -gt 0) { " + オンライン取得 $($c.Info.OnlineDriverCount) 件" } else { '' }
        Write-Host ("  [{0}] {1}{2}" -f ($i + 1), $c.Name, $defMark) -ForegroundColor White
        Write-Host ("       INF {0} 件{1} / {2} / {3}" -f $c.Info.InfCount, $onlineNote, (Format-ByteSize $c.Info.SizeBytes), $label) -ForegroundColor Gray
    }
    if ($candidates.Count -eq 0) { Write-Host '  見つかりませんでした。Mまたはパス入力で保存先を指定できます。' -ForegroundColor Yellow }
    Write-Host "`n  Enter = 既定の保存先 (driver)    [M] パスを直接入力    [0] 戻る"
    while ($true) {
        $pick = ([string](Read-Host 'フォルダの番号 / Enter=driver / M / 0')).Trim()
        if ([string]::IsNullOrEmpty($pick)) {
            if (Test-Path -LiteralPath $defaultFolder -PathType Container) {
                Assert-NoReparsePoint -Path $defaultFolder
                return $defaultFolder
            }
            Write-Host "既定の保存先が見つかりません: $defaultFolder" -ForegroundColor Yellow
            if ($candidates.Count -gt 0) {
                Write-Host "一覧の番号（1～$($candidates.Count)）、または M でパスを指定してください。" -ForegroundColor Yellow
            }
            continue
        }
        if ($pick -eq '0') { return $null }
        if ($pick -ieq 'M') {
            $path = (Read-Host '保存フォルダのパス（空欄で戻る）').Trim().Trim('"')
            if ([string]::IsNullOrWhiteSpace($path)) { return $null }
            if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path $script:workDir $path }
            $fullPath = [System.IO.Path]::GetFullPath($path)
            if (Test-Path -LiteralPath $fullPath -PathType Container) {
                Assert-NoReparsePoint -Path $fullPath
                return $fullPath
            }
            Write-Host '指定フォルダが見つかりません。' -ForegroundColor Yellow
            continue
        }
        $number = 0
        if ([int]::TryParse($pick, [ref]$number) -and $number -ge 1 -and $number -le $candidates.Count) {
            $chosen = $candidates[$number - 1].FullName
            Assert-NoReparsePoint -Path $chosen
            return $chosen
        }
        $directCandidate = $pick.Trim('"')
        if (-not [string]::IsNullOrWhiteSpace($directCandidate)) {
            $resolvedDirect = if ([IO.Path]::IsPathRooted($directCandidate)) { $directCandidate } else { Join-Path $script:workDir $directCandidate }
            try { $resolvedDirect = [System.IO.Path]::GetFullPath($resolvedDirect) } catch { $resolvedDirect = $null }
            if ($resolvedDirect -and (Test-Path -LiteralPath $resolvedDirect -PathType Container)) {
                Assert-NoReparsePoint -Path $resolvedDirect
                return $resolvedDirect
            }
        }
        Write-Host 'Enter（driver）、表示されている番号、または有効なフォルダパスを入力してください。' -ForegroundColor Yellow
    }
}

function Resolve-StagedOrBackupInfPath {
    param([Parameter(Mandatory = $true)][string]$BackupInfFullPath)
    $leafInf = [System.IO.Path]::GetFileName($BackupInfFullPath)
    $repoRoot = Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository'
    if (Test-Path -LiteralPath $repoRoot -PathType Container) {
        $targetHash = (Get-FileHash -LiteralPath $BackupInfFullPath -Algorithm SHA256).Hash
        $candDirs = @(Get-ChildItem -LiteralPath $repoRoot -Directory -Filter "$leafInf*" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        foreach ($cd in $candDirs) {
            $candInf = Join-Path $cd.FullName $leafInf
            if ((Test-Path -LiteralPath $candInf -PathType Leaf) -and (Get-FileHash -LiteralPath $candInf -Algorithm SHA256).Hash -eq $targetHash) {
                return $candInf
            }
        }
        foreach ($cd in $candDirs) {
            $candInf = Join-Path $cd.FullName $leafInf
            if (Test-Path -LiteralPath $candInf -PathType Leaf) { return $candInf }
        }
    }
    return $BackupInfFullPath
}

function Get-BackupMediaInfMetadata {
    param([array]$InfFiles)
    $mediaInfs = New-Object System.Collections.ArrayList
    foreach ($infFile in $infFiles) {
        $lines = Read-InfTextLines -FilePath $infFile.FullName
        $isMedia = $false; $inStrings = $false; $stringsMap = @{}
        foreach ($line in $lines) {
            if ($line -match '^\s*\[([^\]]+)\]') {
                $inStrings = ($Matches[1].Trim() -match '(?i)^Strings(\.|$)')
                continue
            }
            if ($inStrings) {
                if ($line -match '^\s*([^=;\s]+)\s*=\s*"?([^";\r\n]*)"?') {
                    $k = $Matches[1].Trim().ToLowerInvariant()
                    if (-not $stringsMap.ContainsKey($k)) { $stringsMap[$k] = $Matches[2].Trim() }
                }
            } elseif (-not $isMedia -and $line -match '(?i)^\s*Class\s*=\s*MEDIA\b') {
                $isMedia = $true
            }
        }
        if ($isMedia) {
            $prio = if ($infFile.Name -match '(?i)^hdxsstwhite\.inf$') { 30 } elseif ($infFile.Name -match '(?i)white') { 20 } elseif ($infFile.Name -match '(?i)sst') { 10 } else { 0 }
            [void]$mediaInfs.Add([PSCustomObject]@{ FullName = $infFile.FullName; LeafInf = $infFile.Name.ToLowerInvariant(); Priority = $prio; Lines = $lines; StringsMap = $stringsMap })
        }
    }
    return @($mediaInfs | Sort-Object -Property @{ Expression = { -$_.Priority } }, LeafInf)
}

function Find-FallbackInfForUnboundDevice {
    param(
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][array]$HardwareIds,
        [array]$ManifestBindings = @(),
        [array]$BackupInfFiles = @(),
        [array]$MediaInfs = @()
    )
    if (@($ManifestBindings).Count -gt 0 -and @($HardwareIds).Count -gt 0) {
        foreach ($hw in $HardwareIds) {
            if ([string]::IsNullOrWhiteSpace($hw)) { continue }
            foreach ($b in $ManifestBindings) {
                $bHwIds = @($b.HardwareIds)
                if ($bHwIds | Where-Object { $_ -ieq $hw }) {
                    $resolvedInf = $null
                    if ($b.PSObject.Properties['InfRelativePath'] -and -not [string]::IsNullOrWhiteSpace([string]$b.InfRelativePath)) {
                        try {
                            $cand = Get-BackupFilePath -Root $BackupRoot -RelativePath ([string]$b.InfRelativePath)
                            if ($cand -in $BackupInfFiles.FullName) { $resolvedInf = $cand }
                        } catch { $resolvedInf = $null }
                    }
                    if (-not $resolvedInf -and $b.PSObject.Properties['LeafInf'] -and $b.LeafInf) {
                        $found = $BackupInfFiles | Where-Object { $_.Name -ieq [string]$b.LeafInf } | Select-Object -First 1
                        if ($found) { $resolvedInf = $found.FullName }
                    }
                    if ($resolvedInf) {
                        return [PSCustomObject]@{ BackupInfPath = $resolvedInf; PreferredDesc = [string]$b.DriverDesc; MatchReason = 'マニフェスト記録バインド一致' }
                    }
                }
            }
        }
    }

    foreach ($hw in $HardwareIds) {
        if ($hw -match '^(?i)((?:INTELAUDIO|HDAUDIO)\\FUNC_[0-9A-F]{2}&VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4})(?:&|$)') {
            $baseId = $Matches[1]
            $escapedBase = [regex]::Escape($baseId) + '&SUBSYS_'
            foreach ($mInf in $MediaInfs) {
                foreach ($line in $mInf.Lines) {
                    if ($line -match '(?i)^\s*("[^"]+"|%[^%]+%)\s*=\s*[^,;]+\s*,\s*' + $escapedBase) {
                        $rawDesc = $Matches[1].Trim()
                        $desc = if ($rawDesc.StartsWith('"') -and $rawDesc.EndsWith('"')) {
                            $rawDesc.Trim('"')
                        } elseif ($rawDesc.StartsWith('%') -and $rawDesc.EndsWith('%')) {
                            $tok = $rawDesc.Trim('%').ToLowerInvariant()
                            if ($mInf.StringsMap.ContainsKey($tok)) { $mInf.StringsMap[$tok] } else { '' }
                        } else { '' }
                        return [PSCustomObject]@{ BackupInfPath = $mInf.FullName; PreferredDesc = $desc; MatchReason = "同一コーデックSUBSYS非一致救済 ($baseId)" }
                    }
                }
            }
        }
    }
    return $null
}

function Invoke-DriverImport {
    Show-Page '復元（インポート）'
    $selectedFolder = Select-ImportFolder
    if (-not $selectedFolder) { return }

    Assert-NoReparsePoint -Path $selectedFolder
    $info = Test-DriverFolderValidity $selectedFolder
    if ($info.HasManifest) {
        Write-Host "`nマニフェスト対象ファイルの完全性（存在・サイズ・SHA-256ハッシュ）を検証しています..." -ForegroundColor Cyan
        Test-BackupIntegrity -Root $selectedFolder
        Write-Host '[OK] マニフェスト対象ファイルの正常性を確認しました。' -ForegroundColor Green
    }
    if (-not $info.HasInf -and -not $info.HasOnlineDrivers) {
        throw 'INFファイルおよびオンライン取得ドライバ情報がありません。保存フォルダを確認してください。'
    }

    $installInfs = @()
    if ($info.HasInf) {
        Write-Host "`nドライバパッケージのカタログデジタル署名を検証しています..." -ForegroundColor Cyan
        if ($info.HasManifest) {
            $installInfs = @(Assert-DriverCatalogSignatures -Root $selectedFolder -AllowPayloadInf)
        } else {
            Assert-DriverCatalogSignatures -Root $selectedFolder
        }
        Write-Host '[OK] 単独インストール対象のカタログ署名が有効です。' -ForegroundColor Green
    }

    if (-not $info.HasManifest) {
        Write-Host 'マニフェスト（driver-backup.json）がないため、全ファイル完全性は確認できません。' -ForegroundColor Yellow
        Write-Host '※全INFのカタログ署名は有効であることを確認済みです。' -ForegroundColor Yellow
        if ((Read-Host '出所と内容を確認済みなら IMPORT と入力（それ以外で中止）') -cne 'IMPORT') { return }
    }

    $onlineDrivers = @(Get-ManifestOnlineDrivers -BackupRoot $selectedFolder)

    Write-Host "`n復元元: $selectedFolder" -ForegroundColor Cyan
    if ($onlineDrivers.Count -gt 0) {
        Write-Host ("ローカル復元後にインターネット取得（MSカタログ等）を行う対象: {0} 件" -f $onlineDrivers.Count) -ForegroundColor Cyan
        foreach ($od in $onlineDrivers) {
            Write-Host ("  - {0} (記録版: v{1})" -f $od.DeviceName, $od.Version) -ForegroundColor Gray
        }
    }
    Write-Host 'ドライバは対応するデバイスにのみ適用されます。強制上書き・自動再起動はしません。'
    $confirmImport = ([string](Read-Host 'このフォルダから復元しますか？ [Y/N]')).Trim()
    if (-not ([string]::IsNullOrEmpty($confirmImport) -or $confirmImport -match '^(?i:y|yes)$')) { return }

    $logPath = Join-Path $script:workDir ('driver-import-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    Write-Host "`n復元処理中です。しばらくお待ちください..." -ForegroundColor Cyan
    Write-Host "ログ: $logPath"

    if ($info.HasInf) {
        $pnpExit = 0
        if ($info.HasManifest) {
            $okCount = 0
            $upToDateCount = 0
            $retryInfs = New-Object 'System.Collections.Generic.List[object]'
            $failedInfs = New-Object 'System.Collections.Generic.List[string]'
            $totalInfs = $installInfs.Count
            $curIdx = 0

            foreach ($inf in $installInfs) {
                $curIdx++
                $pkgLabel = "$($inf.Directory.Name)\$($inf.Name)"
                "[LocalRestore] $($inf.FullName)" | Out-File -LiteralPath $logPath -Append -Encoding UTF8
                $code = Invoke-PnpUtil -Arguments @('/add-driver', $inf.FullName, '/install') -LogPath $logPath
                # pnputil 終了コード: 0=成功, 259(ERROR_NO_MORE_ITEMS)=登録済み・最新適用済み, 3010/1641=成功(要再起動)
                if ($code -eq 0) {
                    $okCount++
                    Write-Host ("  [{0}/{1}] {2} -> 追加・適用完了" -f $curIdx, $totalInfs, $pkgLabel) -ForegroundColor Green
                } elseif ($code -eq 259) {
                    $okCount++
                    $upToDateCount++
                    Write-Host ("  [{0}/{1}] {2} -> 登録済み・最新状態" -f $curIdx, $totalInfs, $pkgLabel) -ForegroundColor DarkGray
                } elseif ($code -in @(3010, 1641)) {
                    $okCount++
                    $pnpExit = 3010
                    Write-Host ("  [{0}/{1}] {2} -> 追加・適用完了（要再起動）" -f $curIdx, $totalInfs, $pkgLabel) -ForegroundColor Yellow
                } else {
                    $retryInfs.Add($inf)
                    Write-Host ("  [{0}/{1}] {2} -> 保留（他パッケージ追加後に再試行します: Code {3}）" -f $curIdx, $totalInfs, $pkgLabel, $code) -ForegroundColor DarkYellow
                }
            }

            if ($retryInfs.Count -gt 0) {
                Write-Host "`n保留されたパッケージ ($($retryInfs.Count) 件) を再試行しています..." -ForegroundColor Cyan
                foreach ($rInf in $retryInfs) {
                    $pkgLabel = "$($rInf.Directory.Name)\$($rInf.Name)"
                    "[LocalRestore:Retry] $($rInf.FullName)" | Out-File -LiteralPath $logPath -Append -Encoding UTF8
                    $code2 = Invoke-PnpUtil -Arguments @('/add-driver', $rInf.FullName, '/install') -LogPath $logPath
                    if ($code2 -eq 0) {
                        $okCount++
                        Write-Host ("  [再試行OK] {0} -> 追加・適用完了" -f $pkgLabel) -ForegroundColor Green
                    } elseif ($code2 -eq 259) {
                        $okCount++
                        $upToDateCount++
                        Write-Host ("  [再試行OK] {0} -> 登録済み・最新状態" -f $pkgLabel) -ForegroundColor DarkGray
                    } elseif ($code2 -in @(3010, 1641)) {
                        $okCount++
                        $pnpExit = 3010
                        Write-Host ("  [再試行OK] {0} -> 追加・適用完了（要再起動）" -f $pkgLabel) -ForegroundColor Yellow
                    } else {
                        $failEntry = "$pkgLabel (終了コード $code2)"
                        $failedInfs.Add($failEntry)
                        "[LocalRestore:FAIL] $($rInf.FullName) (ExitCode=$code2)" | Out-File -LiteralPath $logPath -Append -Encoding UTF8
                        Write-Host ("  [スキップ] {0}" -f $failEntry) -ForegroundColor Yellow
                    }
                }
            }

            if ($okCount -eq 0 -and $failedInfs.Count -gt 0) {
                throw "ローカルドライバの追加にすべて失敗しました（$($failedInfs.Count) 件）。ログを確認してください: $logPath"
            }
            if ($failedInfs.Count -gt 0) {
                Write-Host "`n[警告] 一部のパッケージ（$($failedInfs.Count) 件）は適用されませんでした（旧版・非対応等の可能性があります）:" -ForegroundColor Yellow
                foreach ($fe in $failedInfs) {
                    Write-Host "  - $fe" -ForegroundColor Yellow
                }
            }
            Write-Host ("`nローカル処理集計: 正常 {0}/{1} 件（うち既存・最新 {2} 件）" -f $okCount, $totalInfs, $upToDateCount) -ForegroundColor Cyan
        } else {
            $pnpExit = Invoke-PnpUtil -Arguments @('/add-driver', (Join-Path $selectedFolder '*.inf'), '/subdirs', '/install') -LogPath $logPath
        }
        switch ($pnpExit) {
            0 { Write-Host '[完了] pnputilのローカルドライバ追加処理が正常終了しました。' -ForegroundColor Green }
            259 { Write-Host '[完了] ローカルドライバはすべて登録済みまたは最新の状態です。' -ForegroundColor Green }
            1641 { Write-Host '[完了・再起動必要] pnputilのローカル処理が完了しました（後ほど手動で再起動してください）。' -ForegroundColor Yellow }
            3010 { Write-Host '[完了・再起動必要] pnputilのローカル処理が完了しました（後ほど手動で再起動してください）。' -ForegroundColor Yellow }
            default { throw "pnputilが正常終了しませんでした（終了コード $pnpExit）。ログを確認してください。" }
        }

        # デバイス再スキャン（親バス起動後に非同期列挙される子・孫デバイスの検出を含む）
        Write-Host "`nデバイスの再スキャンを実行して子デバイスの検出を促しています..." -ForegroundColor Cyan
        $null = Invoke-PnpUtil -Arguments @('/scan-devices') -LogPath $logPath
        Start-Sleep -Seconds 3
        $null = Invoke-PnpUtil -Arguments @('/scan-devices') -LogPath $logPath

        # サブシステムID非一致等で自動マッチングから漏れたデバイスへのフォールバックバインド
        if (-not $info.HasManifest) {
            $installInfs = @(Get-ChildItem -LiteralPath $selectedFolder -Recurse -File -Filter '*.inf' -Force)
        }
        $fallbackReboot = Invoke-UnboundDeviceFallbackBinding -BackupRoot $selectedFolder -LogPath $logPath -BackupInfFiles $installInfs
        if ($fallbackReboot) {
            Write-Host '[通知] フォールバック適用されたドライバの一部で再起動が推奨されています。' -ForegroundColor Yellow
        }
    } else {
        '[Info] ローカルINFは0件のため、オンライン取得フェーズへ進みます。' | Out-File -LiteralPath $logPath -Append -Encoding UTF8
    }

    if ($onlineDrivers.Count -gt 0) {
        $onlineReboot = Invoke-OnlineDriverRestore -OnlineDrivers $onlineDrivers -LogPath $logPath
        if ($onlineReboot) {
            Write-Host '[通知] オンライン適用されたドライバで再起動が推奨されています。' -ForegroundColor Yellow
        }
    }

    # 復元後の実デバイスバインド照合
    Write-Host "復元後のデバイス適用状態を照合しています..." -ForegroundColor Cyan
    $postDevs = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue)
    $postInfByDev = @{}
    $postHwByDev = @{}
    $postCompatByDev = @{}
    $postStatusByDev = @{}
    if ($postDevs.Count -gt 0) {
        $postPropKeys = @(
            'DEVPKEY_Device_DriverInfPath',
            'DEVPKEY_Device_HardwareIds',
            'DEVPKEY_Device_CompatibleIds',
            'DEVPKEY_Device_DevNodeStatus'
        )
        foreach ($prop in (Get-SafePnpDeviceProperties -Devices $postDevs -KeyNames $postPropKeys)) {
            if (-not $prop.InstanceId -or $null -eq $prop.Data) { continue }
            switch ($prop.KeyName) {
                'DEVPKEY_Device_DriverInfPath' {
                    if ($prop.Data) { $postInfByDev[[string]$prop.InstanceId] = [string]$prop.Data }
                }
                'DEVPKEY_Device_HardwareIds' {
                    $hwVals = @($prop.Data | ForEach-Object { [string]$_ } | Where-Object { $_ })
                    if ($hwVals.Count -gt 0) { $postHwByDev[[string]$prop.InstanceId] = $hwVals }
                }
                'DEVPKEY_Device_CompatibleIds' {
                    $compatVals = @($prop.Data | ForEach-Object { [string]$_ } | Where-Object { $_ })
                    if ($compatVals.Count -gt 0) { $postCompatByDev[[string]$prop.InstanceId] = $compatVals }
                }
                'DEVPKEY_Device_DevNodeStatus' {
                    if ($null -ne $prop.Data) { $postStatusByDev[[string]$prop.InstanceId] = $prop.Data }
                }
            }
        }
        Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.DeviceID -and $_.InfName -and -not $postInfByDev.ContainsKey($_.DeviceID)) {
                $postInfByDev[$_.DeviceID] = [string]$_.InfName
            }
        }
    }
    $postUnhealthy = @(Get-UnhealthyOrUnboundDevices -Devices $postDevs -InfByDev $postInfByDev -HwIdsByDev $postHwByDev -CompatIdsByDev $postCompatByDev -DevNodeStatusByDev $postStatusByDev)
    if ($postUnhealthy.Count -gt 0) {
        Write-Host "`n【確認】現在もドライバ未適用または要注意のデバイスが $($postUnhealthy.Count) 件あります:" -ForegroundColor Yellow
        foreach ($uh in $postUnhealthy) {
            Write-Host "  - [$($uh.Severity)] $($uh.Name): $($uh.Detail)" -ForegroundColor Yellow
        }
        "復元後未適用/要注意デバイス一覧 ($($postUnhealthy.Count) 件):" | Out-File -LiteralPath $logPath -Append -Encoding UTF8
        foreach ($uh in $postUnhealthy) {
            "  - [$($uh.Severity)] $($uh.Name) [$($uh.InstanceId)]: $($uh.Detail)" | Out-File -LiteralPath $logPath -Append -Encoding UTF8
        }
    } else {
        Write-Host '[OK] 主要ハードウェアに正常にドライバがバインドされています。' -ForegroundColor Green
    }

    Write-Host "`nより優先順位の高いドライバがある場合は置き換えられません。"
    Write-Host '再起動後にデバイスマネージャーで状態を確認してください。'
}

function Invoke-UnboundDeviceFallbackBinding {
    param(
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$LogPath,
        [Parameter(Mandatory = $true)][array]$BackupInfFiles
    )
    $anyRebootNeeded = $false
    $curDevs = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue)
    if ($curDevs.Count -eq 0) { return $false }

    $curInfByDev = @{}
    $curStatusByDev = @{}
    $curHwByDev = @{}
    $curCompatByDev = @{}
    $fbPropKeys = @(
        'DEVPKEY_Device_DriverInfPath',
        'DEVPKEY_Device_DevNodeStatus',
        'DEVPKEY_Device_HardwareIds',
        'DEVPKEY_Device_CompatibleIds'
    )
    foreach ($prop in (Get-SafePnpDeviceProperties -Devices $curDevs -KeyNames $fbPropKeys)) {
        if (-not $prop.InstanceId -or $null -eq $prop.Data) { continue }
        switch ($prop.KeyName) {
            'DEVPKEY_Device_DriverInfPath' {
                if ($prop.Data) { $curInfByDev[[string]$prop.InstanceId] = [string]$prop.Data }
            }
            'DEVPKEY_Device_DevNodeStatus' {
                if ($null -ne $prop.Data) { $curStatusByDev[[string]$prop.InstanceId] = $prop.Data }
            }
            'DEVPKEY_Device_HardwareIds' {
                $hwVals = @($prop.Data | ForEach-Object { [string]$_ } | Where-Object { $_ })
                if ($hwVals.Count -gt 0) { $curHwByDev[[string]$prop.InstanceId] = $hwVals }
            }
            'DEVPKEY_Device_CompatibleIds' {
                $compatVals = @($prop.Data | ForEach-Object { [string]$_ } | Where-Object { $_ })
                if ($compatVals.Count -gt 0) { $curCompatByDev[[string]$prop.InstanceId] = $compatVals }
            }
        }
    }
    Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.DeviceID -and $_.InfName -and -not $curInfByDev.ContainsKey($_.DeviceID)) {
            $curInfByDev[$_.DeviceID] = [string]$_.InfName
        }
    }

    $unboundCandidates = @(foreach ($dev in $curDevs) {
        if (-not $dev.InstanceId -or (Test-ExcludedVirtualNetworkDevice -Device $dev)) { continue }
        $id = [string]$dev.InstanceId
        $prob = if ($dev.PSObject.Properties['Problem'] -and $null -ne $dev.Problem) { [int]$dev.Problem } else { 0 }
        $devClass = [string]$dev.Class
        $inf = if ($curInfByDev.ContainsKey($id)) { $curInfByDev[$id] } else { '' }
        if (Test-ExpectedDriverlessRawDevice -Device $dev -PrimaryInf $inf -HwIdsByDev $curHwByDev -CompatIdsByDev $curCompatByDev -DevNodeStatusByDev $curStatusByDev) { continue }
        if ($prob -eq 28 -or (([string]::IsNullOrWhiteSpace($devClass) -or $devClass -ieq 'Unknown') -and [string]::IsNullOrWhiteSpace($inf))) {
            $dev
        }
    })
    if ($unboundCandidates.Count -eq 0) { return $false }

    $manifestBindings = @()
    $manifestPath = Join-Path $BackupRoot 'driver-backup.json'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        try {
            $mf = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($mf.PSObject.Properties['DeviceBindings'] -and $mf.DeviceBindings) { $manifestBindings = @($mf.DeviceBindings) }
        } catch { $manifestBindings = @() }
    }

    $mediaInfs = @(Get-BackupMediaInfMetadata -InfFiles $BackupInfFiles)
    $boundCount = 0

    foreach ($uDev in $unboundCandidates) {
        $uId = [string]$uDev.InstanceId
        $uName = if ($uDev.FriendlyName) { [string]$uDev.FriendlyName } elseif ($uDev.Name) { [string]$uDev.Name } else { $uId }
        $hwIds = @((Get-DeviceHardwareAndCompatibleIds -Device $uDev -HwIdsByDev $curHwByDev -CompatIdsByDev $curCompatByDev).HardwareIds)
        if ($hwIds.Count -eq 0) {
            $hwProp = @(Get-SafePnpDeviceProperties -Devices @($uDev) -KeyNames @('DEVPKEY_Device_HardwareIds')) | Select-Object -First 1
            if ($hwProp -and $hwProp.Data) {
                $hwIds = @($hwProp.Data | ForEach-Object { [string]$_ } | Where-Object { $_ })
            }
        }
        if ($hwIds.Count -eq 0) { continue }

        $match = Find-FallbackInfForUnboundDevice -BackupRoot $BackupRoot -HardwareIds $hwIds -ManifestBindings $manifestBindings -BackupInfFiles $backupInfFiles -MediaInfs $mediaInfs
        if (-not $match) { continue }

        Initialize-SetupApiDriverBinder
        $infToInstall = Resolve-StagedOrBackupInfPath -BackupInfFullPath $match.BackupInfPath
        $leafName = [System.IO.Path]::GetFileName($infToInstall)
        Write-Host ("  自動マッチング対象外のデバイスへドライバをバインドしています: {0} -> {1} ({2})" -f $uName, $leafName, $match.MatchReason) -ForegroundColor Cyan

        $needReboot = $false; $win32Err = 0; $appliedDesc = ''
        $ok = [PnPForcedDriverBinder]::BindDriver($uId, $infToInstall, [string]$match.PreferredDesc, [ref]$needReboot, [ref]$win32Err, [ref]$appliedDesc)
        if ($ok) {
            $boundCount++
            if ($needReboot) { $anyRebootNeeded = $true }
            Write-Host ("    [OK] バインド完了: {0} (NeedReboot={1})" -f $appliedDesc, $needReboot) -ForegroundColor Green
            "[FallbackBind:OK] $uId -> $infToInstall ($appliedDesc, Reason=$($match.MatchReason), NeedReboot=$needReboot)" | Out-File -LiteralPath $LogPath -Append -Encoding UTF8
        } else {
            Write-Host ("    [警告] バインド失敗: {0} (Win32Error={1})" -f $uName, $win32Err) -ForegroundColor Yellow
            "[FallbackBind:FAIL] $uId -> $infToInstall (Win32Error=$win32Err, Reason=$($match.MatchReason))" | Out-File -LiteralPath $LogPath -Append -Encoding UTF8
        }
    }

    if ($boundCount -gt 0) {
        $null = Invoke-PnpUtil -Arguments @('/scan-devices') -LogPath $LogPath
        Start-Sleep -Seconds 2
    }
    return $anyRebootNeeded
}

function Enable-ModernTls {
    try {
        if (([Net.ServicePointManager]::SecurityProtocol -band [Net.SecurityProtocolType]::Tls12) -eq 0) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        }
    } catch {}
}

function Get-NormalizedHardwareSearchKeys {
    param(
        [array]$HardwareIds = @(),
        [array]$CompatibleIds = @()
    )
    $fourList = New-Object System.Collections.Generic.List[string]
    $twoList = New-Object System.Collections.Generic.List[string]
    $seenFour = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $seenTwo = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    $combined = @(@($HardwareIds) + @($CompatibleIds))
    foreach ($raw in $combined) {
        if ([string]::IsNullOrWhiteSpace([string]$raw)) { continue }
        $s = ([string]$raw).Trim()

        if ($s -match '^(?i)(PCI\\VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4}&SUBSYS_[0-9A-F]{8})(?:&|$)') {
            $k4 = $Matches[1].ToUpperInvariant()
            if ($seenFour.Add($k4)) { $fourList.Add($k4) }
        } elseif ($s -match '^(?i)(ACPI\\VEN_[A-Z0-9]{3,8}&DEV_[A-Z0-9]{3,8}&SUBSYS_[A-Z0-9]{4,12})(?:&|$)') {
            $k4a = $Matches[1].ToUpperInvariant()
            if ($seenFour.Add($k4a)) { $fourList.Add($k4a) }
        }

        if ($s -match '^(?i)(PCI\\VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4})(?:&|$)') {
            $k2 = $Matches[1].ToUpperInvariant()
            if ($seenTwo.Add($k2)) { $twoList.Add($k2) }
        } elseif ($s -match '^(?i)(ACPI\\(?:VEN_[A-Z0-9]{3,8}&DEV_[A-Z0-9]{3,8}|[A-Z0-9]{7,8}))(?:&|$)') {
            $k2a = $Matches[1].ToUpperInvariant()
            if ($seenTwo.Add($k2a)) { $twoList.Add($k2a) }
        }
    }

    return [PSCustomObject]@{
        FourPartIds = [string[]]$fourList.ToArray()
        TwoPartIds  = [string[]]$twoList.ToArray()
    }
}

function Get-OnlineEligibleDisplayDrivers {
    param(
        [Parameter(Mandatory = $true)][array]$Devices,
        [Parameter(Mandatory = $true)][hashtable]$DriverMap,
        [hashtable]$InfByDev = @{},
        [hashtable]$HwIdsByDev = @{},
        [hashtable]$CompatIdsByDev = @{},
        [hashtable]$DrvDescByDev = @{},
        $SelectedOemInfs = $null
    )
    $results = New-Object System.Collections.Generic.List[object]
    $seenKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($dev in $Devices) {
        if (-not $dev -or -not $dev.InstanceId) { continue }
        if (Test-ExcludedVirtualNetworkDevice -Device $dev) { continue }

        $id = [string]$dev.InstanceId
        if ($id -notmatch '^(?i)(PCI|ACPI)\\') { continue }

        $prob = if ($dev.PSObject.Properties['Problem'] -and $null -ne $dev.Problem) { [int]$dev.Problem } else { 0 }
        if ($prob -ne 0) { continue }
        if (-not $InfByDev.ContainsKey($id)) { continue }

        $oem = ([string]$InfByDev[$id]).Trim().ToLowerInvariant()
        if ($oem -notmatch '^oem\d+\.inf$' -or -not $DriverMap.ContainsKey($oem)) { continue }
        if ($null -ne $SelectedOemInfs -and -not $SelectedOemInfs.Contains($oem)) { continue }

        $dInfo = $DriverMap[$oem]
        $isDisplayPkg = ($dInfo.ClassName -ieq 'Display' -or ($dInfo.PSObject.Properties['ClassGuid'] -and $dInfo.ClassGuid -ieq '{4d36e968-e325-11ce-bfc1-08002be10318}'))
        if (-not $isDisplayPkg) { continue }

        $idPair = Get-DeviceHardwareAndCompatibleIds -Device $dev -HwIdsByDev $HwIdsByDev -CompatIdsByDev $CompatIdsByDev
        $hwIds = @($idPair.HardwareIds)
        $compatIds = @($idPair.CompatibleIds)

        $normKeys = Get-NormalizedHardwareSearchKeys -HardwareIds $hwIds -CompatibleIds $compatIds
        if ($normKeys.FourPartIds.Count -eq 0 -and $normKeys.TwoPartIds.Count -eq 0) { continue }

        $primarySearchKey = if ($normKeys.FourPartIds.Count -gt 0) { $normKeys.FourPartIds[0] } else { $normKeys.TwoPartIds[0] }
        $dedupKey = "$oem|$primarySearchKey"
        if (-not $seenKeys.Add($dedupKey)) { continue }

        $devName = if ($dev.PSObject.Properties['FriendlyName'] -and $dev.FriendlyName) {
            [string]$dev.FriendlyName
        } elseif ($dev.PSObject.Properties['Name'] -and $dev.Name) {
            [string]$dev.Name
        } else { $id }

        $drvDesc = if ($DrvDescByDev.ContainsKey($id)) { [string]$DrvDescByDev[$id] } else { $devName }
        $dateStr = ''
        if ($dInfo.Date) {
            try { $dateStr = ([datetime]$dInfo.Date).ToString('yyyy-MM-dd') } catch { $dateStr = [string]$dInfo.Date }
        }

        $results.Add([PSCustomObject]@{
            OemInf             = $oem
            DeviceInstanceId   = $id
            DeviceName         = $devName
            ClassName          = [string]$dInfo.ClassName
            ProviderName       = [string]$dInfo.ProviderName
            LeafInf            = [string]$dInfo.LeafInf
            PackageName        = [string]$dInfo.PackageName
            Version            = [string]$dInfo.Version
            DriverDate         = $dateStr
            DriverDesc         = $drvDesc
            EstimatedSizeBytes = [long]$dInfo.SizeBytes
            HardwareIds        = @($hwIds)
            CompatibleIds      = @($compatIds)
        })
    }

    return $results.ToArray()
}

function ConvertTo-ComparableDriverVersion {
    param([AllowEmptyString()][string]$VersionString)
    if ([string]::IsNullOrWhiteSpace($VersionString)) { return $null }
    if ($VersionString.Trim() -match '(\d+\.\d+\.\d+(?:\.\d+)?)') {
        $verObj = $null
        if ([version]::TryParse($Matches[1], [ref]$verObj)) { return $verObj }
    }
    return $null
}

function Test-DriverVersionExactMatch {
    param(
        [AllowEmptyString()][string]$CandidateVersion,
        [AllowEmptyString()][string]$CandidateTitle,
        [AllowEmptyString()][string]$TargetVersion
    )
    if ([string]::IsNullOrWhiteSpace($TargetVersion)) { return $false }
    $targetTrim = $TargetVersion.Trim()
    if (-not [string]::IsNullOrWhiteSpace($CandidateVersion)) {
        if ($CandidateVersion.Trim() -ieq $targetTrim) { return $true }
        $vCand = ConvertTo-ComparableDriverVersion -VersionString $CandidateVersion
        $vTarg = ConvertTo-ComparableDriverVersion -VersionString $targetTrim
        if ($null -ne $vCand -and $null -ne $vTarg -and $vCand -eq $vTarg) { return $true }
    }
    if (-not [string]::IsNullOrWhiteSpace($CandidateTitle)) {
        $escaped = [regex]::Escape($targetTrim)
        if ($CandidateTitle -match "(?<![0-9.])$escaped(?![0-9.])") { return $true }
    }
    return $false
}

function Test-InternetForDriverDownload {
    param([switch]$Interactive)
    Enable-ModernTls
    while ($true) {
        $reachable = $false
        $prevProg = $ProgressPreference
        try {
            $ProgressPreference = 'SilentlyContinue'
            $resp = Invoke-WebRequest -Uri 'https://www.catalog.update.microsoft.com/Home.aspx' -Method Head -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400) { $reachable = $true }
        } catch {
            try {
                $respGet = Invoke-WebRequest -Uri 'https://www.catalog.update.microsoft.com/Home.aspx' -Method Get -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
                if ($respGet.StatusCode -ge 200 -and $respGet.StatusCode -lt 400) { $reachable = $true }
            } catch {
                $reachable = $false
            }
        } finally {
            $ProgressPreference = $prevProg
        }

        if ($reachable) { return $true }
        if (-not $Interactive) { return $false }

        Write-Host "`n[待機] インターネット未接続、または Microsoft Update カタログへ到達できません。" -ForegroundColor Yellow
        $ans = ([string](Read-Host 'Wi-Fi または有線LANに接続してから Enter を押してください（S = スキップして後で適用）')).Trim()
        if ($ans -match '^(?i:s|skip)$') {
            return $false
        }
    }
}

function Get-CurrentOsCatalogProfile {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    $build = if ($os -and $os.BuildNumber) { [int]$os.BuildNumber } else { [Environment]::OSVersion.Version.Build }
    $prodType = if ($os -and $os.ProductType) { [int]$os.ProductType } else { 1 }
    $arch = if ($env:PROCESSOR_ARCHITEW6432) { [string]$env:PROCESSOR_ARCHITEW6432 } else { [string]$env:PROCESSOR_ARCHITECTURE }
    return [PSCustomObject]@{
        BuildNumber  = $build
        IsServer     = ($prodType -ne 1)
        Architecture = $arch.ToUpperInvariant()
    }
}

function Get-MsCatalogOsMatchScore {
    param(
        [Parameter(Mandatory = $true)]$Candidate,
        $OsProfile = $null
    )
    if ($null -eq $OsProfile) { $OsProfile = Get-CurrentOsCatalogProfile }
    $build = [int]$OsProfile.BuildNumber
    $isServer = [bool]$OsProfile.IsServer
    $arch = [string]$OsProfile.Architecture
    $title = [string]$Candidate.Title
    $products = [string]$Candidate.Products

    if ($arch -eq 'AMD64') {
        if ($title -match '(?i)\bARM64\b' -and $title -notmatch '(?i)\b(x64|AMD64)\b') { return -1 }
        if ($title -match '(?i)\bx86\b' -and $title -notmatch '(?i)\b(x64|AMD64)\b') { return -1 }
    } elseif ($arch -eq 'ARM64') {
        if ($title -match '(?i)\b(x64|AMD64|x86)\b' -and $title -notmatch '(?i)\bARM64\b') { return -1 }
    }

    $hasServer = ($products -match '(?i)\bServer\b')
    $hasClient = ($products -match '(?i)\b(Client|Windows\s*11|Windows\s*10)\b')
    if (-not $isServer -and $hasServer -and -not $hasClient) { return -1 }
    if ($isServer -and -not $hasServer) { return -1 }
    if ($isServer) { return 80 }

    # ビルド番号ではハード除外(-1)せず、適合度に応じた正のスコアを付与してどのビルド番号でも動作可能にする
    $bestScore = -1
    $w11Matches = [regex]::Matches($products, '(?i)Windows\s*11[^,;]*(?:,\s*version\s*(\d{2}H[12])[^,;]*)?')
    foreach ($m in $w11Matches) {
        $verTag = if ($m.Groups[1].Success) { $m.Groups[1].Value.ToUpperInvariant() } else { '' }
        $reqBuild = switch ($verTag) {
            '21H2'  { 22000 }
            '22H2'  { 22621 }
            '23H2'  { 22631 }
            '24H2'  { 26100 }
            '25H2'  { 26200 }
            '26H1'  { 28000 }
            '26H2'  { 26300 }
            default { if ($verTag -match '^\d{2}H[12]$') { 27000 } else { 22000 } }
        }
        $sc = if ($build -lt 22000) {
            40
        } elseif ($build -lt $reqBuild) {
            65
        } elseif ($reqBuild -ge 26100) {
            100
        } elseif ($reqBuild -ge 22621) {
            if ($build -ge 26100) { 90 } else { 100 }
        } else {
            85
        }
        if ($sc -gt $bestScore) { $bestScore = $sc }
    }

    $wGenericClient = [regex]::Matches($products, '(?i)Windows\s*-\s*Client(?:\s*S)?(?:\s*,\s*version\s*(\d{2}H[12]))?')
    foreach ($m in $wGenericClient) {
        $verTag = if ($m.Groups[1].Success) { $m.Groups[1].Value.ToUpperInvariant() } else { '' }
        $reqBuild = switch ($verTag) {
            '21H2'  { 19044 }
            '22H2'  { 19045 }
            '24H2'  { 26100 }
            '25H2'  { 26200 }
            '26H2'  { 26300 }
            default { if ($verTag -match '^\d{2}H[12]$') { 27000 } else { 19041 } }
        }
        $sc = if ($build -lt $reqBuild) {
            60
        } elseif ($build -ge 22000 -and $build -lt 22621) {
            100
        } elseif ($build -lt 22000) {
            90
        } else {
            75
        }
        if ($sc -gt $bestScore) { $bestScore = $sc }
    }

    if ($products -match '(?i)Windows\s*10\b') {
        $req10 = if ($products -match '(?i)Vibranium') { 19041 } else { 10240 }
        $sc10 = if ($build -lt $req10) {
            40
        } elseif ($build -lt 22000) {
            100
        } else {
            45
        }
        if ($sc10 -gt $bestScore) { $bestScore = $sc10 }
    }

    if ($bestScore -lt 0) {
        $bestScore = 50
    }
    return $bestScore
}

function Select-BestMsCatalogCandidate {
    param(
        [array]$Candidates = @(),
        [AllowEmptyString()][string]$TargetVersion = '',
        [switch]$RequireExactVersion,
        $OsProfile = $null
    )
    if (@($Candidates).Count -eq 0) { return $null }
    if ($null -eq $OsProfile) { $OsProfile = Get-CurrentOsCatalogProfile }

    $scored = New-Object System.Collections.Generic.List[object]
    foreach ($c in $Candidates) {
        if (-not $c) { continue }
        $osScore = Get-MsCatalogOsMatchScore -Candidate $c -OsProfile $OsProfile
        if ($osScore -lt 0) { continue }
        $isExact = Test-DriverVersionExactMatch -CandidateVersion $c.Version -CandidateTitle $c.Title -TargetVersion $TargetVersion
        if ($RequireExactVersion -and -not $isExact) { continue }

        $verObj = if ($c.PSObject.Properties['ParsedVersion'] -and $c.ParsedVersion) {
            $c.ParsedVersion
        } else {
            ConvertTo-ComparableDriverVersion -VersionString ([string]$c.Version)
        }
        if ($null -eq $verObj) { $verObj = [version]'0.0.0.0' }

        $scored.Add([PSCustomObject]@{
            Candidate     = $c
            OsScore       = $osScore
            IsNativeBand  = ($osScore -ge 70)
            IsExact       = $isExact
            SortVersion   = $verObj
            LastUpdated   = if ($c.LastUpdated) { [datetime]$c.LastUpdated } else { [datetime]::MinValue }
        })
    }

    if ($scored.Count -eq 0) { return $null }
    $best = $scored | Sort-Object `
        @{ Expression = { $_.IsExact }; Descending = $true }, `
        @{ Expression = { $_.IsNativeBand }; Descending = $true }, `
        @{ Expression = { if ($_.IsExact) { $_.OsScore } else { 0 } }; Descending = $true }, `
        @{ Expression = { $_.SortVersion }; Descending = $true }, `
        @{ Expression = { $_.OsScore }; Descending = $true }, `
        @{ Expression = { $_.LastUpdated }; Descending = $true } |
        Select-Object -First 1

    return $best.Candidate
}

function Search-MsCatalogDriver {
    param([Parameter(Mandatory = $true)][string]$Query)
    if ([string]::IsNullOrWhiteSpace($Query)) { return @() }
    Enable-ModernTls
    $q = [uri]::EscapeDataString($Query.Trim())
    $uri = "https://www.catalog.update.microsoft.com/Search.aspx?q=$q"

    $prevProg = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'
        $resp = Invoke-WebRequest -Uri $uri -Headers @{ 'Accept-Language' = 'en-US,en;q=0.9' } -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' -UseBasicParsing -TimeoutSec 25 -ErrorAction Stop
    } finally {
        $ProgressPreference = $prevProg
    }
    if (-not $resp -or [string]::IsNullOrWhiteSpace($resp.Content)) { return @() }

    $results = New-Object System.Collections.Generic.List[object]
    $rowMatches = [regex]::Matches($resp.Content, '<tr\s+id="([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})_R\d+"[\s\S]*?</tr>')
    foreach ($rm in $rowMatches) {
        $uid = $rm.Groups[1].Value.ToLowerInvariant()
        $cellMatches = [regex]::Matches($rm.Value, '<td[^>]*>([\s\S]*?)</td>')
        if ($cellMatches.Count -lt 7) { continue }

        $cells = @(foreach ($cm in $cellMatches) {
            $plain = $cm.Groups[1].Value -replace '<[^>]+>', ' '
            $decoded = [System.Net.WebUtility]::HtmlDecode($plain)
            ($decoded -replace '\s+', ' ').Trim()
        })

        $title = $cells[1]
        $products = $cells[2]
        $classification = $cells[3]
        $dateRaw = $cells[4]
        $verCell = $cells[5]
        $sizeRaw = $cells[6]

        if ($classification -notmatch '(?i)Driver') { continue }

        $extractedVer = ''
        if ($verCell -and $verCell -ine 'N/A' -and $verCell -match '(\d+\.\d+\.\d+(?:\.\d+)?)') {
            $extractedVer = $Matches[1]
        } else {
            $verMatches = [regex]::Matches($title, '(\d+\.\d+\.\d+\.\d+|\d+\.\d+\.\d+)')
            if ($verMatches.Count -gt 0) {
                $extractedVer = $verMatches[$verMatches.Count - 1].Groups[1].Value
            }
        }

        $dt = [datetime]::MinValue
        $null = [datetime]::TryParse($dateRaw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$dt)
        if ($dt -eq [datetime]::MinValue) {
            $null = [datetime]::TryParse($dateRaw, [ref]$dt)
        }

        $sizeText = $sizeRaw
        $sizeBytes = [long]0
        if ($sizeRaw -match '^(.+?)\s+(\d{4,})$') {
            $sizeText = $Matches[1].Trim()
            [void][long]::TryParse($Matches[2], [ref]$sizeBytes)
        }

        $results.Add([PSCustomObject]@{
            UpdateId       = $uid
            Title          = $title
            Products       = $products
            Classification = $classification
            LastUpdated    = $dt
            Version        = $extractedVer
            ParsedVersion  = (ConvertTo-ComparableDriverVersion -VersionString $extractedVer)
            SizeText       = $sizeText
            SizeBytes      = $sizeBytes
        })
    }
    return $results.ToArray()
}

function Find-BestMsCatalogDriverForDevice {
    param(
        [Parameter(Mandatory = $true)]$SearchKeys,
        [AllowEmptyString()][string]$TargetVersion = '',
        $OsProfile = $null,
        [scriptblock]$SearchProvider = $null
    )
    if ($null -eq $OsProfile) { $OsProfile = Get-CurrentOsCatalogProfile }
    $invokeSearch = {
        param([string]$q)
        if ($null -ne $SearchProvider) { return @(& $SearchProvider $q) }
        return @(Search-MsCatalogDriver -Query $q)
    }

    $fourCache = New-Object System.Collections.Generic.List[object]
    $twoCache = New-Object System.Collections.Generic.List[object]

    foreach ($id4 in @($SearchKeys.FourPartIds)) {
        if ([string]::IsNullOrWhiteSpace($id4)) { continue }
        $rows4 = @(& $invokeSearch $id4)
        foreach ($r in $rows4) { $fourCache.Add($r) }
        if (-not [string]::IsNullOrWhiteSpace($TargetVersion) -and $rows4.Count -gt 0) {
            $hit1 = Select-BestMsCatalogCandidate -Candidates $rows4 -TargetVersion $TargetVersion -RequireExactVersion -OsProfile $OsProfile
            if ($hit1) {
                return [PSCustomObject]@{ Candidate = $hit1; MatchTier = '優先1 (OEM SUBSYS一致・同一バージョン)'; Query = $id4 }
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($TargetVersion)) {
        foreach ($id2 in @($SearchKeys.TwoPartIds)) {
            if ([string]::IsNullOrWhiteSpace($id2)) { continue }
            $qExact = "$id2 $($TargetVersion.Trim())"
            $rows2Ver = @(& $invokeSearch $qExact)
            if ($rows2Ver.Count -gt 0) {
                $hit2a = Select-BestMsCatalogCandidate -Candidates $rows2Ver -TargetVersion $TargetVersion -RequireExactVersion -OsProfile $OsProfile
                if ($hit2a) {
                    return [PSCustomObject]@{ Candidate = $hit2a; MatchTier = '優先2 (汎用デバイスID一致・同一バージョン)'; Query = $qExact }
                }
            }
            $rows2 = @(& $invokeSearch $id2)
            foreach ($r in $rows2) { $twoCache.Add($r) }
            if ($rows2.Count -gt 0) {
                $hit2b = Select-BestMsCatalogCandidate -Candidates $rows2 -TargetVersion $TargetVersion -RequireExactVersion -OsProfile $OsProfile
                if ($hit2b) {
                    return [PSCustomObject]@{ Candidate = $hit2b; MatchTier = '優先2 (汎用デバイスID一致・同一バージョン)'; Query = $id2 }
                }
            }
        }
    }

    if ($fourCache.Count -gt 0) {
        $hit3 = Select-BestMsCatalogCandidate -Candidates $fourCache.ToArray() -TargetVersion $TargetVersion -OsProfile $OsProfile
        if ($hit3) {
            return [PSCustomObject]@{ Candidate = $hit3; MatchTier = '優先3 (OEM SUBSYS一致・カタログ最新WHQL版)'; Query = $SearchKeys.FourPartIds[0] }
        }
    }

    if ($twoCache.Count -eq 0) {
        foreach ($id2 in @($SearchKeys.TwoPartIds)) {
            if ([string]::IsNullOrWhiteSpace($id2)) { continue }
            $rows2 = @(& $invokeSearch $id2)
            foreach ($r in $rows2) { $twoCache.Add($r) }
        }
    }
    if ($twoCache.Count -gt 0) {
        $hit4 = Select-BestMsCatalogCandidate -Candidates $twoCache.ToArray() -TargetVersion $TargetVersion -OsProfile $OsProfile
        if ($hit4) {
            return [PSCustomObject]@{ Candidate = $hit4; MatchTier = '優先4 (汎用デバイスID一致・カタログ最新WHQL版)'; Query = $SearchKeys.TwoPartIds[0] }
        }
    }

    return $null
}

function Get-MsCatalogDownloadFiles {
    param(
        [Parameter(Mandatory = $true)][string]$UpdateId,
        $OsProfile = $null
    )
    $uid = $UpdateId.Trim().ToLowerInvariant()
    if ($uid -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        throw "無効な UpdateID 形式です: $UpdateId"
    }
    if ($null -eq $OsProfile) { $OsProfile = Get-CurrentOsCatalogProfile }
    Enable-ModernTls

    $postBody = @{
        updateIDs = ('[{{"size":0,"languages":"","uidInfo":"{0}","updateID":"{0}"}}]' -f $uid)
    }
    $prevProg = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'
        $dl = Invoke-WebRequest -Uri 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' -Headers @{ 'Accept-Language' = 'en-US' } -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' -Method Post -Body $postBody -UseBasicParsing -TimeoutSec 25 -ErrorAction Stop
    } finally {
        $ProgressPreference = $prevProg
    }
    if (-not $dl -or [string]::IsNullOrWhiteSpace($dl.Content)) { return @() }

    $fileMap = @{}
    $propMatches = [regex]::Matches($dl.Content, 'downloadInformation\[\d+\]\.files\[(\d+)\]\.([a-zA-Z0-9_]+)\s*=\s*''([^'']*)''')
    foreach ($pm in $propMatches) {
        $idx = [int]$pm.Groups[1].Value
        $propName = $pm.Groups[2].Value
        $propVal = $pm.Groups[3].Value
        if (-not $fileMap.ContainsKey($idx)) { $fileMap[$idx] = @{} }
        $fileMap[$idx][$propName] = $propVal
    }

    if ($fileMap.Count -eq 0) {
        $fbIdx = 0
        foreach ($um in [regex]::Matches($dl.Content, 'https?://[^\s"''<>]+_[0-9a-fA-F]{40}\.cab')) {
            $fileMap[$fbIdx] = @{ url = $um.Value }
            $fbIdx++
        }
    }

    $outList = New-Object System.Collections.Generic.List[object]
    $seenUrls = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($idx in ($fileMap.Keys | Sort-Object)) {
        $entry = $fileMap[$idx]
        $rawUrl = [string]$entry['url']
        if ([string]::IsNullOrWhiteSpace($rawUrl)) { continue }
        $uriObj = $null
        if (-not [uri]::TryCreate($rawUrl, [System.UriKind]::Absolute, [ref]$uriObj)) { continue }
        if ($uriObj.Scheme -notin @('https', 'http')) { continue }
        if ($uriObj.Host -notmatch '(?i)\.(windowsupdate|microsoft)\.com$') { continue }
        if ($uriObj.AbsolutePath -notmatch '(?i)\.cab$') { continue }

        $archSpec = ([string]$entry['architectures']).Trim()
        if (-not [string]::IsNullOrWhiteSpace($archSpec)) {
            $curArch = [string]$OsProfile.Architecture
            if ($curArch -eq 'AMD64' -and $archSpec -notmatch '(?i)(amd64|x64)') { continue }
            if ($curArch -eq 'ARM64' -and $archSpec -notmatch '(?i)arm64') { continue }
        }

        $sha256Hex = ''
        $s256B64 = ([string]$entry['sha256']).Trim()
        if (-not [string]::IsNullOrWhiteSpace($s256B64)) {
            try {
                $b = [Convert]::FromBase64String($s256B64)
                if ($b.Length -eq 32) { $sha256Hex = ([BitConverter]::ToString($b)).Replace('-', '').ToUpperInvariant() }
            } catch {}
        }

        $sha1Hex = ''
        $digB64 = ([string]$entry['digest']).Trim()
        if (-not [string]::IsNullOrWhiteSpace($digB64)) {
            try {
                $b1 = [Convert]::FromBase64String($digB64)
                if ($b1.Length -eq 20) { $sha1Hex = ([BitConverter]::ToString($b1)).Replace('-', '').ToUpperInvariant() }
            } catch {}
        }
        if ([string]::IsNullOrWhiteSpace($sha1Hex) -and $uriObj.AbsolutePath -match '_([0-9a-fA-F]{40})\.cab$') {
            $sha1Hex = $Matches[1].ToUpperInvariant()
        }
        if ([string]::IsNullOrWhiteSpace($sha256Hex) -and [string]::IsNullOrWhiteSpace($sha1Hex)) { continue }

        $finalUrl = if ($uriObj.Scheme -eq 'http' -and $uriObj.Host -match '(?i)\.download\.windowsupdate\.com$') {
            'https://' + $uriObj.Host + $uriObj.PathAndQuery
        } else { $rawUrl }

        if ($seenUrls.Add($finalUrl)) {
            $leafName = [System.IO.Path]::GetFileName($uriObj.LocalPath)
            $outList.Add([PSCustomObject]@{
                Url       = $finalUrl
                FileName  = $leafName
                Sha256Hex = $sha256Hex
                Sha1Hex   = $sha1Hex
            })
        }
    }
    return $outList.ToArray()
}

function Receive-FileWithProgress {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [AllowEmptyString()][string]$ExpectedSha256Hex = '',
        [AllowEmptyString()][string]$ExpectedSha1Hex = '',
        [switch]$Quiet
    )
    if ([string]::IsNullOrWhiteSpace($ExpectedSha256Hex) -and [string]::IsNullOrWhiteSpace($ExpectedSha1Hex)) {
        throw '検証用ハッシュ（SHA-256 または SHA-1）がないファイルは安全のためダウンロードできません。'
    }
    Enable-ModernTls
    $req = [System.Net.WebRequest]::Create($Url)
    $req.Timeout = 60000
    if ($req -is [System.Net.HttpWebRequest]) {
        $req.ReadWriteTimeout = 120000
        $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
        $req.AllowAutoRedirect = $true
    }

    $resp = $null
    $inStream = $null
    $outStream = $null
    $wroteProgress = $false
    try {
        $resp = $req.GetResponse()
        $totalLen = $resp.ContentLength
        $inStream = $resp.GetResponseStream()
        $outStream = New-Object System.IO.FileStream($DestinationPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 131072)

        $buf = New-Object byte[] 131072
        $readTotal = [long]0
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $lastReportMs = [long]-1000

        while (($n = $inStream.Read($buf, 0, $buf.Length)) -gt 0) {
            $outStream.Write($buf, 0, $n)
            $readTotal += $n
            if (-not $Quiet -and ($sw.ElapsedMilliseconds - $lastReportMs) -ge 500) {
                $lastReportMs = $sw.ElapsedMilliseconds
                if ($totalLen -gt 0) {
                    $pct = [Math]::Min(100, [int](($readTotal * 100) / $totalLen))
                    Write-Host -NoNewline ("`r    ダウンロード中: {0} / {1} ({2}%)   " -f (Format-ByteSize $readTotal), (Format-ByteSize $totalLen), $pct) -ForegroundColor Gray
                } else {
                    Write-Host -NoNewline ("`r    ダウンロード中: {0}   " -f (Format-ByteSize $readTotal)) -ForegroundColor Gray
                }
                $wroteProgress = $true
            }
        }
        $outStream.Flush()
        if (-not $Quiet -and $wroteProgress) {
            $finalTotal = if ($totalLen -gt 0) { $totalLen } else { $readTotal }
            Write-Host ("`r    ダウンロード完了: {0} / {1} (100%)   " -f (Format-ByteSize $readTotal), (Format-ByteSize $finalTotal)) -ForegroundColor Gray
        }
    } catch {
        if ($wroteProgress -and -not $Quiet) { Write-Host '' }
        throw
    } finally {
        if ($outStream) { $outStream.Dispose() }
        if ($inStream) { $inStream.Dispose() }
        if ($resp) { $resp.Close() }
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256Hex)) {
        $actual256 = (Get-FileHash -LiteralPath $DestinationPath -Algorithm SHA256).Hash
        if ($actual256 -ine $ExpectedSha256Hex.Trim()) {
            Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
            throw "ダウンロードファイルの SHA-256 ハッシュ不一致を検出したため破棄しました (Expected: $ExpectedSha256Hex, Actual: $actual256)"
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha1Hex)) {
        $actual1 = (Get-FileHash -LiteralPath $DestinationPath -Algorithm SHA1).Hash
        if ($actual1 -ine $ExpectedSha1Hex.Trim()) {
            Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
            throw "ダウンロードファイルの SHA-1 ハッシュ不一致を検出したため破棄しました (Expected: $ExpectedSha1Hex, Actual: $actual1)"
        }
    }
}

function Install-DriverViaWindowsUpdateApi {
    param(
        [Parameter(Mandatory = $true)]$SearchKeys,
        [string]$DeviceName = '',
        [string]$LogPath = ''
    )
    $session = New-Object -ComObject 'Microsoft.Update.Session'
    $searcher = $session.CreateUpdateSearcher()
    $sr = $searcher.Search("IsInstalled=0 and Type='Driver'")
    $updatesToInstall = New-Object -ComObject 'Microsoft.Update.UpdateColl'

    $allKeyPatterns = New-Object System.Collections.Generic.List[string]
    foreach ($k in @(@($SearchKeys.FourPartIds) + @($SearchKeys.TwoPartIds))) {
        if (-not [string]::IsNullOrWhiteSpace($k)) {
            $allKeyPatterns.Add('^' + [regex]::Escape($k.Trim()) + '(?:&|$)')
        }
    }

    foreach ($u in $sr.Updates) {
        $drvHw = ''
        try { $drvHw = [string]$u.DriverHardwareID } catch { $drvHw = '' }
        if ([string]::IsNullOrWhiteSpace($drvHw)) { continue }
        $matched = $false
        foreach ($pat in $allKeyPatterns) {
            if ($drvHw -match "(?i)$pat") { $matched = $true; break }
        }
        if ($matched) {
            if (-not $u.EulaAccepted) { $u.AcceptEula() }
            [void]$updatesToInstall.Add($u)
        }
    }

    if ($updatesToInstall.Count -eq 0) {
        return [PSCustomObject]@{ Installed = $false; RebootRequired = $false; Title = ''; Detail = 'Windows Update 上に該当する未適用ドライバ更新が見つかりませんでした。' }
    }

    $titles = @(for ($i = 0; $i -lt $updatesToInstall.Count; $i++) { $updatesToInstall.Item($i).Title }) -join ', '
    Write-Host ("    Windows Update 経由でダウンロードしています: {0}" -f $titles) -ForegroundColor Cyan
    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $updatesToInstall
    $dlRes = $downloader.Download()
    if ([int]$dlRes.ResultCode -notin @(2, 3)) {
        throw "Windows Update ダウンロード失敗 (ResultCode: $($dlRes.ResultCode))"
    }

    Write-Host '    Windows Update 経由でドライバを適用しています...' -ForegroundColor Cyan
    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $updatesToInstall
    $instRes = $installer.Install()
    if ($LogPath) {
        "[OnlineRestore:WUA] $DeviceName -> $titles (ResultCode=$($instRes.ResultCode), Reboot=$($instRes.RebootRequired))" | Out-File -LiteralPath $LogPath -Append -Encoding UTF8
    }
    if ([int]$instRes.ResultCode -notin @(2, 3)) {
        throw "Windows Update インストール失敗 (ResultCode: $($instRes.ResultCode))"
    }
    return [PSCustomObject]@{
        Installed      = $true
        RebootRequired = [bool]$instRes.RebootRequired
        Title          = $titles
        Detail         = "ResultCode=$($instRes.ResultCode)"
    }
}

function Find-PresentTargetDeviceForOnlineDriver {
    param(
        [array]$PresentDevices = @(),
        [hashtable]$InfByDev = @{},
        [hashtable]$VerByDev = @{},
        [hashtable]$HwByDev = @{},
        [hashtable]$CompatByDev = @{},
        [Parameter(Mandatory = $true)]$SearchKeys
    )
    $fourSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($k4 in @($SearchKeys.FourPartIds)) { if ($k4) { [void]$fourSet.Add($k4) } }
    $twoSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($k2 in @($SearchKeys.TwoPartIds)) { if ($k2) { [void]$twoSet.Add($k2) } }

    $twoMatchFallback = $null
    foreach ($dev in $PresentDevices) {
        if (-not $dev -or -not $dev.InstanceId) { continue }
        if (Test-ExcludedVirtualNetworkDevice -Device $dev) { continue }
        $id = [string]$dev.InstanceId
        if ($id -notmatch '^(?i)(PCI|ACPI)\\') { continue }

        $idPair = Get-DeviceHardwareAndCompatibleIds -Device $dev -HwIdsByDev $HwByDev -CompatIdsByDev $CompatByDev
        $devHw = @($idPair.HardwareIds)
        $devCompat = @($idPair.CompatibleIds)
        $devKeys = Get-NormalizedHardwareSearchKeys -HardwareIds $devHw -CompatibleIds $devCompat

        $isFourHit = $false
        foreach ($dk4 in $devKeys.FourPartIds) {
            if ($fourSet.Contains($dk4)) { $isFourHit = $true; break }
        }
        $isTwoHit = $false
        if (-not $isFourHit) {
            foreach ($dk2 in $devKeys.TwoPartIds) {
                if ($twoSet.Contains($dk2)) { $isTwoHit = $true; break }
            }
        }
        if (-not $isFourHit -and -not $isTwoHit) { continue }

        $prob = if ($dev.PSObject.Properties['Problem'] -and $null -ne $dev.Problem) { [int]$dev.Problem } else { 0 }
        $curInf = if ($InfByDev.ContainsKey($id)) { [string]$InfByDev[$id] } else { '' }
        $curVer = if ($VerByDev.ContainsKey($id)) { [string]$VerByDev[$id] } else { '' }
        $obj = [PSCustomObject]@{
            InstanceId = $id
            Device     = $dev
            Problem    = $prob
            CurrentInf = $curInf
            CurrentVer = $curVer
        }
        if ($isFourHit) { return $obj }
        if (-not $twoMatchFallback) { $twoMatchFallback = $obj }
    }
    return $twoMatchFallback
}

function Expand-AndInstallOnlineCabFiles {
    param(
        [Parameter(Mandatory = $true)][array]$DownloadFiles,
        [Parameter(Mandatory = $true)][string]$DeviceName,
        [Parameter(Mandatory = $true)][string]$LogPath,
        [AllowEmptyString()][string]$TargetInstanceId = '',
        [AllowEmptyString()][string]$PreferredLeafInf = '',
        [AllowEmptyString()][string]$PreferredDesc = ''
    )
    if (@($DownloadFiles).Count -eq 0) { throw 'ダウンロード対象ファイルがありません。' }
    $expandExe = Join-Path $env:SystemRoot 'System32\expand.exe'
    if (-not (Test-Path -LiteralPath $expandExe -PathType Leaf)) {
        throw '標準展開ツール expand.exe が見つかりません。'
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('drv-online-' + [guid]::NewGuid().ToString('N'))
    $cabDir = Join-Path $tempRoot 'cab'
    $extractRoot = Join-Path $tempRoot 'extracted'
    $needReboot = $false

    try {
        [System.IO.Directory]::CreateDirectory($cabDir) | Out-Null
        [System.IO.Directory]::CreateDirectory($extractRoot) | Out-Null
        Assert-NoReparsePoint -Path $tempRoot

        $cabIdx = 0
        foreach ($df in $DownloadFiles) {
            $cabIdx++
            $cabPath = Join-Path $cabDir ('pkg_{0}.cab' -f $cabIdx)
            Write-Host ("    [{0}/{1}] CAB パッケージを取得しています: {2}" -f $cabIdx, $DownloadFiles.Count, $df.FileName) -ForegroundColor Cyan
            Receive-FileWithProgress -Url $df.Url -DestinationPath $cabPath -ExpectedSha256Hex ([string]$df.Sha256Hex) -ExpectedSha1Hex ([string]$df.Sha1Hex)
            Write-Host '    [OK] ダウンロードとハッシュ検証が完了しました。展開しています...' -ForegroundColor Green

            $subExtract = Join-Path $extractRoot ('pkg_' + $cabIdx)
            [System.IO.Directory]::CreateDirectory($subExtract) | Out-Null
            $prevEap = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $global:LASTEXITCODE = $null
                $expOut = & $expandExe -F:* $cabPath $subExtract 2>&1
                $expCode = $global:LASTEXITCODE
            } finally {
                $ErrorActionPreference = $prevEap
            }
            $expOut | Out-File -LiteralPath $LogPath -Append -Encoding UTF8
            if ($expCode -ne 0) {
                throw "CABファイルの展開に失敗しました (expand.exe 終了コード: $expCode)"
            }
            Remove-Item -LiteralPath $cabPath -Force -ErrorAction SilentlyContinue
        }

        Write-Host '    展開されたドライバパッケージのカタログ署名（WHQL等）を検証しています...' -ForegroundColor Cyan
        Assert-DriverCatalogSignatures -Root $extractRoot
        Write-Host '    [OK] カタログデジタル署名が有効です。ドライバをインストールしています...' -ForegroundColor Green

        $pnpCode = Invoke-PnpUtil -Arguments @('/add-driver', (Join-Path $extractRoot '*.inf'), '/subdirs', '/install') -LogPath $LogPath
        if ($pnpCode -in @(3010, 1641)) {
            $needReboot = $true
        } elseif ($pnpCode -notin @(0, 259)) {
            throw "オンライン取得ドライバの pnputil 適用に失敗しました (終了コード: $pnpCode)"
        }

        $null = Invoke-PnpUtil -Arguments @('/scan-devices') -LogPath $LogPath
        Start-Sleep -Seconds 2

        if (-not [string]::IsNullOrWhiteSpace($TargetInstanceId)) {
            $curInfProp = Get-PnpDeviceProperty -InstanceId $TargetInstanceId -KeyName 'DEVPKEY_Device_DriverInfPath' -ErrorAction SilentlyContinue
            $curInfNow = if ($curInfProp -and $curInfProp.Data) { [string]$curInfProp.Data } else { '' }
            if ($curInfNow -notmatch '(?i)^oem\d+\.inf$') {
                $candInfs = @(Get-ChildItem -LiteralPath $extractRoot -Recurse -File -Filter '*.inf' -Force -ErrorAction SilentlyContinue)
                $chosenInf = $null
                if ($PreferredLeafInf) {
                    $chosenInf = $candInfs | Where-Object { $_.Name -ieq $PreferredLeafInf } | Select-Object -First 1
                }
                if (-not $chosenInf) {
                    foreach ($ci in $candInfs) {
                        if ((Read-InfTextLines -FilePath $ci.FullName) -match '(?i)^\s*Class\s*=\s*Display\b') {
                            $chosenInf = $ci; break
                        }
                    }
                }
                if ($chosenInf) {
                    Initialize-SetupApiDriverBinder
                    $stagedInf = Resolve-StagedOrBackupInfPath -BackupInfFullPath $chosenInf.FullName
                    $bReboot = $false; $bErr = 0; $bDesc = ''
                    if ([PnPForcedDriverBinder]::BindDriver($TargetInstanceId, $stagedInf, $PreferredDesc, [ref]$bReboot, [ref]$bErr, [ref]$bDesc)) {
                        if ($bReboot) { $needReboot = $true }
                        "[OnlineRestore:ForcedBind:OK] $TargetInstanceId -> $stagedInf ($bDesc, NeedReboot=$bReboot)" | Out-File -LiteralPath $LogPath -Append -Encoding UTF8
                    }
                }
            }
        }

        Write-Host ("    [完了] {0} のドライバ適用が完了しました。" -f $DeviceName) -ForegroundColor Green
        return $needReboot
    } finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-PendingOnlineDriverTargets {
    param(
        [Parameter(Mandatory = $true)][array]$OnlineDrivers,
        [Parameter(Mandatory = $true)][string]$LogPath
    )
    $curDevs = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue)
    if ($curDevs.Count -eq 0) {
        Write-Host '  接続デバイスを取得できなかったためオンライン取得をスキップします。' -ForegroundColor Yellow
        return @()
    }

    $curInfByDev = @{}; $curVerByDev = @{}; $curHwByDev = @{}; $curCompatByDev = @{}
    $onlineCheckKeys = @(
        'DEVPKEY_Device_DriverInfPath',
        'DEVPKEY_Device_DriverVersion',
        'DEVPKEY_Device_HardwareIds',
        'DEVPKEY_Device_CompatibleIds'
    )
    foreach ($prop in (Get-SafePnpDeviceProperties -Devices $curDevs -KeyNames $onlineCheckKeys)) {
        if (-not $prop.InstanceId -or $null -eq $prop.Data) { continue }
        switch ($prop.KeyName) {
            'DEVPKEY_Device_DriverInfPath' {
                if ($prop.Data) { $curInfByDev[[string]$prop.InstanceId] = [string]$prop.Data }
            }
            'DEVPKEY_Device_DriverVersion' {
                if ($prop.Data) { $curVerByDev[[string]$prop.InstanceId] = [string]$prop.Data }
            }
            'DEVPKEY_Device_HardwareIds' {
                $hwVals = @($prop.Data | ForEach-Object { [string]$_ } | Where-Object { $_ })
                if ($hwVals.Count -gt 0) { $curHwByDev[[string]$prop.InstanceId] = $hwVals }
            }
            'DEVPKEY_Device_CompatibleIds' {
                $compatVals = @($prop.Data | ForEach-Object { [string]$_ } | Where-Object { $_ })
                if ($compatVals.Count -gt 0) { $curCompatByDev[[string]$prop.InstanceId] = $compatVals }
            }
        }
    }

    $pendingItems = New-Object System.Collections.Generic.List[object]
    foreach ($od in $OnlineDrivers) {
        $devName = if ($od.DeviceName) { [string]$od.DeviceName } else { 'Display Device' }
        $recVer = if ($od.Version) { [string]$od.Version } else { '' }
        $hwIds = @(if ($od.PSObject.Properties['HardwareIds'] -and $od.HardwareIds) { $od.HardwareIds })
        $compatIds = @(if ($od.PSObject.Properties['CompatibleIds'] -and $od.CompatibleIds) { $od.CompatibleIds })
        $sKeys = Get-NormalizedHardwareSearchKeys -HardwareIds $hwIds -CompatibleIds $compatIds

        if ($sKeys.FourPartIds.Count -eq 0 -and $sKeys.TwoPartIds.Count -eq 0) {
            Write-Host ("  [スキップ] 有効なハードウェアIDがないため除外: {0}" -f $devName) -ForegroundColor Yellow
            continue
        }

        $presentHit = Find-PresentTargetDeviceForOnlineDriver -PresentDevices $curDevs -InfByDev $curInfByDev -VerByDev $curVerByDev -HwByDev $curHwByDev -CompatByDev $curCompatByDev -SearchKeys $sKeys
        if (-not $presentHit) {
            Write-Host ("  [スキップ] 現在のPCに該当ハードウェアが搭載されていないためスキップ: {0}" -f $devName) -ForegroundColor Gray
            "[OnlineRestore:SkipNotPresent] $devName" | Out-File -LiteralPath $LogPath -Append -Encoding UTF8
            continue
        }

        if ($presentHit.Problem -eq 0 -and $presentHit.CurrentInf -match '(?i)^oem\d+\.inf$') {
            $vNow = ConvertTo-ComparableDriverVersion -VersionString $presentHit.CurrentVer
            $vRec = ConvertTo-ComparableDriverVersion -VersionString $recVer
            if ($null -ne $vNow -and ($null -eq $vRec -or $vNow -ge $vRec)) {
                Write-Host ("  [適用済み] {0} には既にOEMドライバ (v{1} / {2}) が適用されています。" -f $devName, $presentHit.CurrentVer, $presentHit.CurrentInf) -ForegroundColor Green
                $skipAns = ([string](Read-Host '  不要な再ダウンロードをスキップしますか？ [Y/N]')).Trim()
                if ([string]::IsNullOrEmpty($skipAns) -or $skipAns -match '^(?i:y|yes)$') {
                    "[OnlineRestore:SkipAlreadyApplied] $devName (Current=$($presentHit.CurrentVer), Recorded=$recVer)" | Out-File -LiteralPath $LogPath -Append -Encoding UTF8
                    continue
                }
            }
        }

        $pendingItems.Add([PSCustomObject]@{
            Entry      = $od
            DeviceName = $devName
            TargetVer  = $recVer
            SearchKeys = $sKeys
            PresentHit = $presentHit
        })
    }
    return $pendingItems.ToArray()
}

function Invoke-OnlineDriverRestore {
    param(
        [Parameter(Mandatory = $true)][array]$OnlineDrivers,
        [Parameter(Mandatory = $true)][string]$LogPath
    )
    if (@($OnlineDrivers).Count -eq 0) { return $false }
    $anyReboot = $false

    Write-Host "`n--- オンライン取得対象ドライバの照合と復元 ---" -ForegroundColor Cyan
    $pendingItems = @(Get-PendingOnlineDriverTargets -OnlineDrivers $OnlineDrivers -LogPath $LogPath)
    if ($pendingItems.Count -eq 0) { return $false }

    if (-not (Test-InternetForDriverDownload -Interactive)) {
        Write-Host '[スキップ] オンライン取得をスキップしました。ネット接続後に再度 [3] 復元を実行するか、Windows Update / メーカー公式ドライバで適用してください。' -ForegroundColor Yellow
        '[OnlineRestore:SkippedOffline] User skipped online driver download.' | Out-File -LiteralPath $LogPath -Append -Encoding UTF8
        return $false
    }

    $osProf = Get-CurrentOsCatalogProfile
    $idx = 0
    foreach ($item in $pendingItems) {
        $idx++
        $verLabel = if ($item.TargetVer) { $item.TargetVer } else { '最新' }
        Write-Host ("`n  [{0}/{1}] オンライン検索中: {2} (目標版: v{3})" -f $idx, $pendingItems.Count, $item.DeviceName, $verLabel) -ForegroundColor Cyan
        $installedOk = $false

        try {
            $catMatch = Find-BestMsCatalogDriverForDevice -SearchKeys $item.SearchKeys -TargetVersion $item.TargetVer -OsProfile $osProf
            if ($catMatch -and $catMatch.Candidate) {
                $cand = $catMatch.Candidate
                Write-Host ("    候補決定 [{0}]: {1} ({2})" -f $catMatch.MatchTier, $cand.Title, $cand.SizeText) -ForegroundColor White
                "[OnlineRestore:CatalogSelected] $($item.DeviceName) -> $($cand.UpdateId) | $($cand.Title) | $($catMatch.MatchTier)" | Out-File -LiteralPath $LogPath -Append -Encoding UTF8

                $dlFiles = @(Get-MsCatalogDownloadFiles -UpdateId $cand.UpdateId -OsProfile $osProf)
                if ($dlFiles.Count -gt 0) {
                    $leafInf = if ($item.Entry.LeafInf) { [string]$item.Entry.LeafInf } else { '' }
                    $drvDesc = if ($item.Entry.DriverDesc) { [string]$item.Entry.DriverDesc } else { '' }
                    $reb = Expand-AndInstallOnlineCabFiles -DownloadFiles $dlFiles -DeviceName $item.DeviceName -LogPath $LogPath -TargetInstanceId $item.PresentHit.InstanceId -PreferredLeafInf $leafInf -PreferredDesc $drvDesc
                    if ($reb) { $anyReboot = $true }
                    $installedOk = $true
                } else {
                    Write-Host '    [警告] MSカタログからダウンロードURLを取得できませんでした。Windows Update API へフォールバックします...' -ForegroundColor Yellow
                }
            } else {
                Write-Host '    MSカタログ上に該当候補が見つかりませんでした。Windows Update API を照会します...' -ForegroundColor Yellow
            }
        } catch {
            Write-Host ("    [警告] MSカタログ経由の取得・適用でエラーが発生しました: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
            "[OnlineRestore:CatalogError] $($item.DeviceName): $($_.Exception.Message)" | Out-File -LiteralPath $LogPath -Append -Encoding UTF8
            Write-Host '    優先5 (Windows Update 標準 COM API) へフォールバックします...' -ForegroundColor Yellow
        }

        if (-not $installedOk) {
            try {
                $wuaRes = Install-DriverViaWindowsUpdateApi -SearchKeys $item.SearchKeys -DeviceName $item.DeviceName -LogPath $LogPath
                if ($wuaRes.Installed) {
                    if ($wuaRes.RebootRequired) { $anyReboot = $true }
                    Write-Host ("    [完了] Windows Update 経由で適用しました: {0}" -f $wuaRes.Title) -ForegroundColor Green
                    $installedOk = $true
                } else {
                    Write-Host ("    [未検出] {0}" -f $wuaRes.Detail) -ForegroundColor Yellow
                }
            } catch {
                Write-Host ("    [警告] Windows Update API フォールバックも失敗しました: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
                "[OnlineRestore:WuaError] $($item.DeviceName): $($_.Exception.Message)" | Out-File -LiteralPath $LogPath -Append -Encoding UTF8
            }
        }

        if (-not $installedOk) {
            Write-Host ("    [案内] {0} は自動取得できませんでした。Windows Update またはメーカー公式ドライバをご利用ください。" -f $item.DeviceName) -ForegroundColor Yellow
        }
    }

    return $anyReboot
}

function Invoke-DeviceDiagnostics {
    Show-Page 'デバイスドライバ適用状態の診断（読み取り専用）'
    Write-Host '現在のPCの主要デバイスとドライバ適用状態を診断します。' -ForegroundColor Gray
    Write-Host '※システムの変更やドライバの追加・削除は行いません。' -ForegroundColor DarkGray
    Write-Host ''

    $safeModel = Get-SafeModelName
    Write-Host "PCモデル : $safeModel" -ForegroundColor White
    Write-Host "OS       : $((Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption)" -ForegroundColor White
    Write-Host ''

    Write-Host '接続デバイスの情報を取得しています...' -ForegroundColor Gray
    $allDevs = @(Get-PnpDevice -PresentOnly -ErrorAction Stop)
    $infByDev = @{}
    $hwIdsByDev = @{}
    $compatIdsByDev = @{}
    $devNodeStatusByDev = @{}
    $diagPropKeys = @(
        'DEVPKEY_Device_DriverInfPath',
        'DEVPKEY_Device_HardwareIds',
        'DEVPKEY_Device_CompatibleIds',
        'DEVPKEY_Device_DevNodeStatus'
    )
    foreach ($prop in (Get-SafePnpDeviceProperties -Devices $allDevs -KeyNames $diagPropKeys)) {
        if (-not $prop.InstanceId -or $null -eq $prop.Data) { continue }
        switch ($prop.KeyName) {
            'DEVPKEY_Device_DriverInfPath' {
                if ($prop.Data) { $infByDev[[string]$prop.InstanceId] = [string]$prop.Data }
            }
            'DEVPKEY_Device_HardwareIds' {
                $hwVals = @($prop.Data | ForEach-Object { [string]$_ } | Where-Object { $_ })
                if ($hwVals.Count -gt 0) { $hwIdsByDev[[string]$prop.InstanceId] = $hwVals }
            }
            'DEVPKEY_Device_CompatibleIds' {
                $compatVals = @($prop.Data | ForEach-Object { [string]$_ } | Where-Object { $_ })
                if ($compatVals.Count -gt 0) { $compatIdsByDev[[string]$prop.InstanceId] = $compatVals }
            }
            'DEVPKEY_Device_DevNodeStatus' {
                if ($null -ne $prop.Data) { $devNodeStatusByDev[[string]$prop.InstanceId] = $prop.Data }
            }
        }
    }
    Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.DeviceID -and $_.InfName -and -not $infByDev.ContainsKey($_.DeviceID)) {
            $infByDev[$_.DeviceID] = [string]$_.InfName
        }
    }

    # 必須カテゴリ診断
    $catStatuses = @(Get-CoreCategoryStatus -Devices $allDevs -InfByDev $infByDev -HwIdsByDev $hwIdsByDev -CompatIdsByDev $compatIdsByDev -DevNodeStatusByDev $devNodeStatusByDev)
    Write-Host '--- 必須5カテゴリのドライバ適用状況 ---' -ForegroundColor Cyan
    foreach ($cs in $catStatuses) {
        $stateColor = switch ($cs.State) {
            'OemDriverBound'   { 'Green' }
            'InboxDriverOnly'  { 'White' }
            'UnboundOrError'   { 'Yellow' }
            default            { 'DarkGray' }
        }
        $stateText = switch ($cs.State) {
            'OemDriverBound'   { '[OEM適用中・保存対象]' }
            'InboxDriverOnly'  { '[OS標準インボックス・保存対象外]' }
            'UnboundOrError'   { '[未適用/要注意]' }
            default            { '[未検出]' }
        }
        Write-Host ("  {0,-40} : {1}" -f $cs.Name, $stateText) -ForegroundColor $stateColor
        foreach ($d in $cs.Details) {
            Write-Host "      $d" -ForegroundColor DarkGray
        }
    }

    # 未適用・異常デバイス
    $unhealthy = @(Get-UnhealthyOrUnboundDevices -Devices $allDevs -InfByDev $infByDev -HwIdsByDev $hwIdsByDev -CompatIdsByDev $compatIdsByDev -DevNodeStatusByDev $devNodeStatusByDev)
    Write-Host ''
    Write-Host ("--- 未適用・要注意デバイス一覧 ({0} 件) ---" -f $unhealthy.Count) -ForegroundColor Cyan
    if ($unhealthy.Count -eq 0) {
        Write-Host '  [OK] 未適用・異常デバイスは検出されませんでした。' -ForegroundColor Green
    } else {
        foreach ($uh in $unhealthy) {
            Write-Host ("  - [{0}] {1}" -f $uh.Severity, $uh.Name) -ForegroundColor Yellow
            Write-Host ("      ID   : {0}" -f $uh.InstanceId) -ForegroundColor DarkGray
            Write-Host ("      詳細 : {0}" -f $uh.Detail) -ForegroundColor Yellow
        }
    }
}

function Invoke-MainMenu {
    while ($true) {
        Show-Page 'メインメニュー'
        Write-Host '  エクスポート（OS再インストール前）' -ForegroundColor Gray
        Write-Host '    [1] 最小構成で保存   必須ドライバ（オーディオ・ビデオ(選択式)・LAN等）の保存と未使用・旧版を除外'
        Write-Host '    [2] 全て保存         未使用・旧版を含む全サードパーティINF'
        Write-Host ''
        Write-Host '  インポート（OS再インストール後）' -ForegroundColor Gray
        Write-Host '    [3] 保存フォルダから復元'
        Write-Host ''
        Write-Host '  診断・確認' -ForegroundColor Gray
        Write-Host '    [4] システム・デバイスドライバ適用状態の診断（読み取り専用）'
        Write-Host ''
        Write-Host '    [0] 終了（Qでも可）'
        Write-Host ''
        Write-Host "  既定の保存先: $(Join-Path $script:workDir 'driver')" -ForegroundColor DarkGray
        $choice = (Read-Host '選択 [0-4]').Trim()
        if ($choice -in @('0', 'q', 'Q')) { return }
        if ($choice -notin @('1', '2', '3', '4')) {
            Write-Host '0～4を入力してください。' -ForegroundColor Yellow
            $null = Read-Host 'Enterで戻る'
            continue
        }
        try {
            switch ($choice) {
                '1' { Invoke-DriverExport -MinimalMode $true }
                '2' { Invoke-DriverExport -MinimalMode $false }
                '3' { Invoke-DriverImport }
                '4' { Invoke-DeviceDiagnostics }
            }
        } catch {
            Write-Host "`n[中止] $($_.Exception.Message)" -ForegroundColor Red
            Write-Host '処理は正常完了していません。エクスポート失敗時はOSを消去しないでください。' -ForegroundColor Yellow
            Write-Host ("詳細: {0}" -f $_.InvocationInfo.PositionMessage) -ForegroundColor DarkGray
        }
        Write-Host ''
        $null = Read-Host 'Enterでメニューに戻る'
    }
}

# テスト時は関数定義のみ読み込む。UAC・実デバイス操作・対話を開始しない。
if ($LibraryOnly) { return }
$Host.UI.RawUI.WindowTitle = 'ドライバ エクスポート / インポート [CPU汎用]'
if ($PSVersionTable.PSVersion.Major -lt 5) { throw 'Windows PowerShell 5.1 以降が必要です。' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '管理者権限が必要です。UACで「はい」を選択してください。' -ForegroundColor Yellow
    $arguments = '/d /s /c ""{0}""' -f $env:SELF_PATH
    Start-Process -FilePath $env:ComSpec -ArgumentList $arguments -Verb RunAs
    return
}
if (-not (Test-Path -LiteralPath $script:pnpUtilPath -PathType Leaf)) { throw 'pnputil.exe が見つかりません。' }
Invoke-MainMenu

