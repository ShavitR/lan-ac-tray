#requires -Version 7.4
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Keep manual launches and the Windows startup entry from creating duplicate icons.
$script:InstanceMutex = [System.Threading.Mutex]::new($false, 'Local\LanAcTraySingleInstance')
$script:OwnsInstanceMutex = $false
try { $script:OwnsInstanceMutex = $script:InstanceMutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $script:OwnsInstanceMutex = $true }
if (-not $script:OwnsInstanceMutex) {
    $script:InstanceMutex.Dispose()
    exit
}

$script:SettingsDirectory = Join-Path $env:APPDATA 'LanAcTray'
$script:SettingsPath = Join-Path $script:SettingsDirectory 'devices.json'
$script:AppDirectory = Split-Path -Parent $PSCommandPath
$script:StartupShortcutName = 'LAN AC Tray.lnk'
$script:PairedDevices = @()
$script:ActiveDeviceMac = $null
$script:DeviceIp = $null
$script:LocalIp = $null
$script:DeviceMac = $null
$script:DeviceProtocol = 'GCM'
$script:DeviceKey = $null
$script:State = $null
$script:Busy = $false
$script:DiscoveryCache = @()
$script:DiscoveryCacheAt = [DateTime]::MinValue
$script:GenericGcmKey = [Text.Encoding]::UTF8.GetBytes('{yxAHAY_Lm6pbC/<')
$script:GenericEcbKey = [Text.Encoding]::UTF8.GetBytes('a3K8Bx%2r8Y7#xDh')
$script:Nonce = [byte[]](0x54,0x40,0x78,0x44,0x49,0x67,0x5a,0x51,0x6c,0x5e,0x63,0x13)
$script:Aad = [Text.Encoding]::UTF8.GetBytes('qualcomm-test')
$script:ModeValues = @{ Auto=0; Cool=1; Dry=2; Fan=3; Heat=4 }
$script:FanValues = @{ Auto=0; Low=1; 'Medium low'=2; Medium=3; 'Medium high'=4; High=5 }
$script:ModeItems = @{}
$script:FanItems = @{}

function New-GcmPack([byte[]]$Key, [byte[]]$Plain) {
    $cipher = [byte[]]::new($Plain.Length)
    $tag = [byte[]]::new(16)
    $aes = [System.Security.Cryptography.AesGcm]::new($Key, 16)
    try { $aes.Encrypt($script:Nonce, $Plain, $cipher, $tag, $script:Aad) }
    finally { $aes.Dispose() }
    return @{ pack=[Convert]::ToBase64String($cipher); tag=[Convert]::ToBase64String($tag) }
}

function Read-GcmPack([byte[]]$Key, $Envelope) {
    $cipher = [Convert]::FromBase64String($Envelope.pack)
    $tag = [Convert]::FromBase64String($Envelope.tag)
    $plain = [byte[]]::new($cipher.Length)
    $aes = [System.Security.Cryptography.AesGcm]::new($Key, 16)
    try { $aes.Decrypt($script:Nonce, $cipher, $tag, $plain, $script:Aad) }
    finally { $aes.Dispose() }
    return [Text.Encoding]::UTF8.GetString($plain)
}

function New-EcbPack([byte[]]$Key, [byte[]]$Plain) {
    $padding = 16 - ($Plain.Length % 16)
    $padded = [byte[]]::new($Plain.Length + $padding)
    [Array]::Copy($Plain, $padded, $Plain.Length)
    for ($i=$Plain.Length; $i -lt $padded.Length; $i++) { $padded[$i] = [byte]$padding }
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Mode = [System.Security.Cryptography.CipherMode]::ECB
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::None
    $aes.Key = $Key
    try {
        $cipher = $aes.CreateEncryptor().TransformFinalBlock($padded, 0, $padded.Length)
        return [Convert]::ToBase64String($cipher)
    } finally { $aes.Dispose() }
}

function Read-EcbPack([string]$Encoded, [byte[]]$Key = $script:GenericEcbKey) {
    $cipher = [Convert]::FromBase64String($Encoded)
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Mode = [System.Security.Cryptography.CipherMode]::ECB
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::None
    $aes.Key = $Key
    try {
        $plain = $aes.CreateDecryptor().TransformFinalBlock($cipher, 0, $cipher.Length)
        $value = [Text.Encoding]::UTF8.GetString($plain)
        $end = $value.LastIndexOf('}')
        if ($end -lt 0) { throw 'Bad discovery response.' }
        return $value.Substring(0, $end + 1)
    } finally { $aes.Dispose() }
}

function Read-EnvelopePayload($Envelope, [byte[]]$Key = $null) {
    if ($Envelope.PSObject.Properties.Name -contains 'tag') {
        if ($null -eq $Key) { $Key = $script:GenericGcmKey }
        return Read-GcmPack $Key $Envelope
    }
    if ($null -eq $Key) { $Key = $script:GenericEcbKey }
    return Read-EcbPack $Envelope.pack $Key
}

function New-DeviceEnvelope([string]$Text, [int]$Index, [string]$Tcid, [byte[]]$Key, [string]$Protocol) {
    if ($Protocol -eq 'GCM') {
        $pack = New-GcmPack $Key ([Text.Encoding]::UTF8.GetBytes($Text))
        return (@{ cid='app'; i=$Index; uid=0; tcid=$Tcid; t='pack'; pack=$pack.pack; tag=$pack.tag } | ConvertTo-Json -Compress)
    }
    $encoded = New-EcbPack $Key ([Text.Encoding]::UTF8.GetBytes($Text))
    return (@{ cid='app'; i=$Index; uid=0; tcid=$Tcid; t='pack'; pack=$encoded } | ConvertTo-Json -Compress)
}

function Read-DevicePayload($Envelope, [byte[]]$Key) {
    if ($Envelope.PSObject.Properties.Name -contains 'tag') { return Read-GcmPack $Key $Envelope }
    return Read-EcbPack $Envelope.pack $Key
}

function Load-LocalSettings {
    if (-not (Test-Path -LiteralPath $script:SettingsPath)) { return }
    try {
        $saved = Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json -AsHashtable
        $valid = @()
        foreach ($entry in @($saved.devices)) {
            $mac = ([string]$entry.mac).ToLowerInvariant()
            if ($mac -notmatch '^[0-9a-f]{12}$') { continue }
            $name = [string]$entry.name
            if ([string]::IsNullOrWhiteSpace($name)) { $name = 'Air conditioner ' + $mac.Substring(8) }
            $valid += [pscustomobject]@{ Mac=$mac; Name=$name; Brand=[string]$entry.brand; Model=[string]$entry.model }
        }
        $script:PairedDevices = $valid
        $active = ([string]$saved.activeMac).ToLowerInvariant()
        if ($active -match '^[0-9a-f]{12}$' -and $script:PairedDevices.Mac -contains $active) {
            $script:ActiveDeviceMac = $active
        }
    } catch {
        $script:PairedDevices = @()
        $script:ActiveDeviceMac = $null
    }
}

function Save-LocalSettings {
    New-Item -ItemType Directory -Path $script:SettingsDirectory -Force | Out-Null
    $data = [ordered]@{
        version = 1
        activeMac = $script:ActiveDeviceMac
        devices = @($script:PairedDevices | ForEach-Object {
            @{ mac=$_.Mac; name=$_.Name; brand=$_.Brand; model=$_.Model }
        })
    }
    $json = $data | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($script:SettingsPath, $json, [System.Text.UTF8Encoding]::new($false))
}

function Get-StartupShortcutPath {
    $startupFolder = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
    return Join-Path $startupFolder $script:StartupShortcutName
}

function Test-StartupEnabled {
    $launcher = Join-Path $script:AppDirectory 'Start-Lan-AC-Tray.vbs'
    $shell = New-Object -ComObject WScript.Shell
    $candidate = Get-StartupShortcutPath
    if (-not (Test-Path -LiteralPath $candidate)) { return $false }
    $link = $shell.CreateShortcut($candidate)
    if ($link.Arguments.Contains($launcher)) { return $true }
    return $false
}

function Set-StartupEnabled([bool]$Enabled) {
    $launcher = Join-Path $script:AppDirectory 'Start-Lan-AC-Tray.vbs'
    $shell = New-Object -ComObject WScript.Shell
    $startupFolder = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
    $linkPath = Join-Path $startupFolder $script:StartupShortcutName
    if ($Enabled) {
        if (-not (Test-Path -LiteralPath $launcher)) { throw 'The launcher file is missing.' }
        $link = $shell.CreateShortcut($linkPath)
        $link.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
        $link.Arguments = '//B //NoLogo "' + $launcher + '"'
        $link.WorkingDirectory = $script:AppDirectory
        $link.Description = 'Start LAN AC Tray; read device status without changing AC power.'
        $link.Save()
    }
    if (-not $Enabled -and (Test-Path -LiteralPath $linkPath)) {
        $existing = $shell.CreateShortcut($linkPath)
        if ($existing.Arguments.Contains($launcher)) {
            Remove-Item -LiteralPath $linkPath
        }
    }
}

function Get-IPv4Broadcast([System.Net.IPAddress]$Address, [System.Net.IPAddress]$Mask) {
    $a = $Address.GetAddressBytes()
    $m = $Mask.GetAddressBytes()
    $b = [byte[]]::new(4)
    for ($i=0; $i -lt 4; $i++) { $b[$i] = $a[$i] -bor (255 -bxor $m[$i]) }
    return [System.Net.IPAddress]::new($b)
}

function Find-Devices {
    $found = @{}
    $interfaces = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -in @('Ethernet','Wireless80211') }
    foreach ($nic in $interfaces) {
        foreach ($ua in $nic.GetIPProperties().UnicastAddresses) {
            if ($ua.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
            $local = $ua.Address
            if ($local.ToString().StartsWith('127.') -or $local.ToString().StartsWith('169.254.')) { continue }
            $udp = [System.Net.Sockets.UdpClient]::new()
            try {
                $udp.EnableBroadcast = $true
                $udp.Client.Bind([System.Net.IPEndPoint]::new($local, 0))
                $udp.Client.ReceiveTimeout = 250
                $scan = [Text.Encoding]::UTF8.GetBytes('{"t":"scan"}')
                $broadcast = Get-IPv4Broadcast $local $ua.IPv4Mask
                [void]$udp.Send($scan, $scan.Length, [System.Net.IPEndPoint]::new($broadcast, 7000))
                $until = [DateTime]::UtcNow.AddMilliseconds(1500)
                while ([DateTime]::UtcNow -lt $until) {
                    try {
                        $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any,0)
                        $raw = $udp.Receive([ref]$remote)
                        $outer = [Text.Encoding]::UTF8.GetString($raw) | ConvertFrom-Json
                        $inner = Read-EnvelopePayload $outer | ConvertFrom-Json
                        $mac = [string]$inner.mac
                        if ([string]::IsNullOrWhiteSpace($mac)) { $mac = [string]$inner.cid }
                        if ([string]::IsNullOrWhiteSpace($mac)) { $mac = [string]$outer.cid }
                        $mac = $mac.ToLowerInvariant()
                        if ($mac -notmatch '^[0-9a-f]{12}$') { continue }
                        $name = [string]$inner.name
                        if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$inner.model }
                        if ([string]::IsNullOrWhiteSpace($name)) { $name = 'Gree-compatible AC' }
                        $found[$mac] = [pscustomobject]@{
                            Mac=$mac
                            Address=$remote.Address.ToString()
                            LocalAddress=$local.ToString()
                            Name=$name
                            Brand=([string]$inner.brand)
                            Model=([string]$inner.model)
                            Version=([string]$inner.ver)
                            ProtocolHint=$(if ($outer.PSObject.Properties.Name -contains 'tag') { 'GCM' } else { 'ECB' })
                        }
                    } catch [System.Net.Sockets.SocketException] { }
                    catch { }
                }
            } catch { }
            finally { $udp.Dispose() }
        }
    }
    $script:DiscoveryCache = @($found.Values | Sort-Object Name, Address)
    $script:DiscoveryCacheAt = [DateTime]::UtcNow
    return $script:DiscoveryCache
}

function Find-ActiveDevice {
    if ([string]::IsNullOrWhiteSpace($script:ActiveDeviceMac)) {
        throw 'No AC is paired. Open Settings to scan and pair a device.'
    }
    if ($script:DiscoveryCache.Count -eq 0 -or ([DateTime]::UtcNow - $script:DiscoveryCacheAt).TotalSeconds -gt 20) {
        $devices = @(Find-Devices)
    } else { $devices = $script:DiscoveryCache }
    $device = $devices | Where-Object { $_.Mac -eq $script:ActiveDeviceMac } | Select-Object -First 1
    if (-not $device) { throw 'The selected AC was not found on this local network. Open Settings to scan again.' }
    return $device
}

function Send-DeviceEnvelope([string]$Ip, [string]$Local, [string]$Json, [int]$TimeoutMs = 2500) {
    $udp = [System.Net.Sockets.UdpClient]::new()
    try {
        $udp.Client.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($Local),0))
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $bytes = [Text.Encoding]::UTF8.GetBytes($Json)
        [void]$udp.Send($bytes,$bytes.Length,[System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($Ip),7000))
        $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any,0)
        return [Text.Encoding]::UTF8.GetString($udp.Receive([ref]$remote)) | ConvertFrom-Json
    } finally { $udp.Dispose() }
}

function Connect-Target {
    $found = Find-ActiveDevice
    $script:DeviceMac = $found.Mac
    $script:DeviceIp = $found.Address
    $script:LocalIp = $found.LocalAddress
    $inner = '{"mac":"' + $script:DeviceMac + '","t":"bind","uid":0}'
    $attempts = if ($found.ProtocolHint -eq 'GCM') {
        @(
            [pscustomobject]@{ Protocol='GCM'; Tcid='' },
            [pscustomobject]@{ Protocol='GCM'; Tcid=$script:DeviceMac },
            [pscustomobject]@{ Protocol='ECB'; Tcid=$script:DeviceMac },
            [pscustomobject]@{ Protocol='ECB'; Tcid='' }
        )
    } else {
        @(
            [pscustomobject]@{ Protocol='ECB'; Tcid=$script:DeviceMac },
            [pscustomobject]@{ Protocol='ECB'; Tcid='' },
            [pscustomobject]@{ Protocol='GCM'; Tcid='' },
            [pscustomobject]@{ Protocol='GCM'; Tcid=$script:DeviceMac }
        )
    }
    $lastError = 'No supported local handshake was accepted.'
    foreach ($attempt in $attempts) {
        $protocol = $attempt.Protocol
        try {
            $genericKey = if ($protocol -eq 'GCM') { $script:GenericGcmKey } else { $script:GenericEcbKey }
            $envelope = New-DeviceEnvelope $inner 1 $attempt.Tcid $genericKey $protocol
            $reply = Send-DeviceEnvelope $script:DeviceIp $script:LocalIp $envelope 1250
            $data = Read-EnvelopePayload $reply $(if ($protocol -eq 'GCM') { $script:GenericGcmKey } else { $script:GenericEcbKey }) | ConvertFrom-Json
            if ($data.t -eq 'bindok' -and $data.r -eq 200 -and $data.key) {
                $script:DeviceProtocol = $protocol
                $script:DeviceKey = [Text.Encoding]::UTF8.GetBytes([string]$data.key)
                return
            }
            $lastError = 'The device did not accept the binding request.'
        } catch { $lastError = $_.Exception.Message }
    }
    throw ('Could not pair with ' + $found.Name + '. ' + $lastError)
}

function Get-ACStatus {
    if ($null -eq $script:DeviceKey) { Connect-Target }
    $cols = 'Pow','Mod','SetTem','WdSpd','TemSen'
    $colsJson = ConvertTo-Json -InputObject $cols -Compress
    $inner = '{"cols":' + $colsJson + ',"mac":"' + $script:DeviceMac + '","t":"status"}'
    $envelope = New-DeviceEnvelope $inner 0 $script:DeviceMac $script:DeviceKey $script:DeviceProtocol
    try {
        $reply = Send-DeviceEnvelope $script:DeviceIp $script:LocalIp $envelope
        $data = Read-DevicePayload $reply $script:DeviceKey | ConvertFrom-Json
    } catch {
        $script:DeviceKey = $null
        Connect-Target
        $envelope = New-DeviceEnvelope $inner 0 $script:DeviceMac $script:DeviceKey $script:DeviceProtocol
        $reply = Send-DeviceEnvelope $script:DeviceIp $script:LocalIp $envelope
        $data = Read-DevicePayload $reply $script:DeviceKey | ConvertFrom-Json
    }
    if ($data.t -ne 'dat' -or $data.r -ne 200) { throw 'The AC did not return its current state.' }
    $values = @{}
    for ($i=0; $i -lt $data.cols.Count; $i++) { $values[[string]$data.cols[$i]] = $data.dat[$i] }
    $modes = @{0='Auto';1='Cool';2='Dry';3='Fan';4='Heat'}
    $fans = @{0='Auto';1='Low';2='Medium low';3='Medium';4='Medium high';5='High'}
    $raw = 0
    if ([int]::TryParse([string]$values.TemSen,[ref]$raw)) { $room = $raw - 40 } else { $room = $null }
    return @{
        Online=$true; Power=([int]$values.Pow -eq 1); Mode=$modes[[int]$values.Mod]
        Temperature=[int]$values.SetTem; Fan=$fans[[int]$values.WdSpd]
        FanValue=[int]$values.WdSpd; RoomTemperature=$room
    }
}

function Set-ACValue([string]$Name, [int]$Value) {
    if ($script:Busy) { return }
    $script:Busy = $true
    try {
        if ($null -eq $script:DeviceKey) { Connect-Target }
        $inner = '{"opt":["' + $Name + '"],"p":[' + $Value + '],"t":"cmd"}'
        $envelope = New-DeviceEnvelope $inner 0 $script:DeviceMac $script:DeviceKey $script:DeviceProtocol
        $reply = Send-DeviceEnvelope $script:DeviceIp $script:LocalIp $envelope
        $ack = Read-DevicePayload $reply $script:DeviceKey | ConvertFrom-Json
        if ($ack.t -ne 'res' -or $ack.r -ne 200) { throw 'The AC did not confirm the change.' }
        Start-Sleep -Milliseconds 300
        Update-ACStatus
    } catch { Show-ACError $_.Exception.Message }
    finally { $script:Busy = $false }
}

function Get-ActiveDeviceName {
    $paired = $script:PairedDevices | Where-Object { $_.Mac -eq $script:ActiveDeviceMac } | Select-Object -First 1
    if ($paired) { return [string]$paired.Name }
    return 'Air conditioner'
}

function Reset-DeviceSession {
    $script:DeviceIp = $null
    $script:LocalIp = $null
    $script:DeviceMac = $null
    $script:DeviceKey = $null
    $script:State = $null
}

function Update-ACStatus {
    if ([string]::IsNullOrWhiteSpace($script:ActiveDeviceMac)) {
        $script:State = $null
        $script:StatusItem.Text = 'No AC paired · open Settings'
        $script:PowerItem.Enabled = $false
        $script:TempMenu.Enabled = $false
        $script:ModeMenu.Enabled = $false
        $script:FanMenu.Enabled = $false
        $script:PowerItem.Text = 'Pair an AC in Settings'
        $script:TempMenu.Text = 'Temperature unavailable'
        $script:ModeMenu.Text = 'Mode unavailable'
        $script:FanMenu.Text = 'Fan unavailable'
        $script:NotifyIcon.Icon = $script:IconOff
        $script:NotifyIcon.Text = 'LAN AC Tray · Not paired'
        return
    }
    try {
        $script:State = Get-ACStatus
        $deviceName = Get-ActiveDeviceName
        $script:StatusItem.Text = if ($script:State.Power) { $deviceName + ' · On' } else { $deviceName + ' · Off' }
        $script:PowerItem.Enabled = $true
        $script:TempMenu.Enabled = $true
        $script:ModeMenu.Enabled = $true
        $script:FanMenu.Enabled = $true
        $script:PowerItem.Text = if ($script:State.Power) { 'Turn AC off' } else { 'Turn AC on' }
        $script:TempMenu.Text = 'Temperature · ' + $script:State.Temperature + '°C'
        $script:ModeMenu.Text = 'Mode · ' + $script:State.Mode
        $script:FanMenu.Text = 'Fan · ' + $script:State.Fan
        foreach ($name in $script:ModeItems.Keys) { $script:ModeItems[$name].Checked = ($script:State.Mode -eq $name) }
        foreach ($name in $script:FanItems.Keys) { $script:FanItems[$name].Checked = ($script:State.Fan -eq $name) }
        $script:NotifyIcon.Icon = if ($script:State.Power) { $script:IconOn } else { $script:IconOff }
        $script:NotifyIcon.Text = if ($script:State.Power) { $deviceName + ' · On · ' + $script:State.Temperature + '°C' } else { $deviceName + ' · Off' }
    } catch {
        $script:State = $null
        $deviceName = Get-ActiveDeviceName
        $script:StatusItem.Text = $deviceName + ' · Offline'
        $script:PowerItem.Enabled = $false
        $script:TempMenu.Enabled = $false
        $script:ModeMenu.Enabled = $false
        $script:FanMenu.Enabled = $false
        $script:PowerItem.Text = 'AC unavailable'
        $script:TempMenu.Text = 'Temperature unavailable'
        $script:ModeMenu.Text = 'Mode unavailable'
        $script:FanMenu.Text = 'Fan unavailable'
        $script:NotifyIcon.Icon = $script:IconOff
        $script:NotifyIcon.Text = $deviceName + ' · Offline'
    }
}

function Show-ACError([string]$Message) {
    $script:NotifyIcon.BalloonTipTitle = 'LAN AC Tray'
    $script:NotifyIcon.BalloonTipText = $Message
    $script:NotifyIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
    $script:NotifyIcon.ShowBalloonTip(4000)
    Update-ACStatus
}

function Refresh-SettingsPairedDevices {
    if (-not $script:SettingsPairedList -or $script:SettingsPairedList.IsDisposed) { return }
    $script:SettingsPairedList.Items.Clear()
    $selectedIndex = -1
    foreach ($device in $script:PairedDevices) {
        $detail = if ($device.Model) { ' · ' + $device.Model } else { '' }
        $item = [pscustomobject]@{
            Mac=$device.Mac
            Name=$device.Name
            Display=($device.Name + $detail)
        }
        [void]$script:SettingsPairedList.Items.Add($item)
        if ($device.Mac -eq $script:ActiveDeviceMac) { $selectedIndex = $script:SettingsPairedList.Items.Count - 1 }
    }
    if ($selectedIndex -ge 0) { $script:SettingsPairedList.SelectedIndex = $selectedIndex }
    $hasItems = $script:SettingsPairedList.Items.Count -gt 0
    $script:SettingsUseButton.Enabled = $hasItems
    $script:SettingsForgetButton.Enabled = $hasItems
}

function Show-DeviceSettings {
    if ($script:SettingsForm -and -not $script:SettingsForm.IsDisposed) {
        $script:SettingsForm.Activate()
        return
    }

    $form = [System.Windows.Forms.Form]::new()
    $form.Text = 'LAN AC Tray · Settings'
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $false
    $form.ClientSize = [Drawing.Size]::new(640, 620)
    $script:SettingsForm = $form

    $heading = [System.Windows.Forms.Label]::new()
    $heading.Text = 'Air conditioner settings'
    $heading.Location = [Drawing.Point]::new(24,18)
    $heading.AutoSize = $true
    $heading.Font = [Drawing.Font]::new($heading.Font.FontFamily, 16, [Drawing.FontStyle]::Bold)
    $form.Controls.Add($heading)

    $intro = [System.Windows.Forms.Label]::new()
    $intro.Text = 'Pair a device on this network and choose which one the tray controls.'
    $intro.Location = [Drawing.Point]::new(24,52)
    $intro.AutoSize = $true
    $form.Controls.Add($intro)

    $pairedLabel = [System.Windows.Forms.Label]::new()
    $pairedLabel.Text = 'Paired devices'
    $pairedLabel.Location = [Drawing.Point]::new(24,91)
    $pairedLabel.AutoSize = $true
    $pairedLabel.Font = [Drawing.Font]::new($form.Font, [Drawing.FontStyle]::Bold)
    $form.Controls.Add($pairedLabel)

    $script:SettingsPairedList = [System.Windows.Forms.ComboBox]::new()
    $script:SettingsPairedList.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $script:SettingsPairedList.DisplayMember = 'Display'
    $script:SettingsPairedList.Location = [Drawing.Point]::new(24,116)
    $script:SettingsPairedList.Size = [Drawing.Size]::new(355,28)
    $form.Controls.Add($script:SettingsPairedList)

    $script:SettingsUseButton = [System.Windows.Forms.Button]::new()
    $script:SettingsUseButton.Text = 'Use'
    $script:SettingsUseButton.Location = [Drawing.Point]::new(391,115)
    $script:SettingsUseButton.Size = [Drawing.Size]::new(78,30)
    $script:SettingsUseButton.add_Click({
        $choice = $script:SettingsPairedList.SelectedItem
        if (-not $choice) { return }
        $script:ActiveDeviceMac = $choice.Mac
        Save-LocalSettings
        Reset-DeviceSession
        Update-ACStatus
        $script:SettingsMessage.Text = 'Selected ' + $choice.Name + '.'
    })
    $form.Controls.Add($script:SettingsUseButton)

    $script:SettingsForgetButton = [System.Windows.Forms.Button]::new()
    $script:SettingsForgetButton.Text = 'Forget'
    $script:SettingsForgetButton.Location = [Drawing.Point]::new(479,115)
    $script:SettingsForgetButton.Size = [Drawing.Size]::new(96,30)
    $script:SettingsForgetButton.add_Click({
        $choice = $script:SettingsPairedList.SelectedItem
        if (-not $choice) { return }
        $forgotMac = $choice.Mac
        $script:PairedDevices = @($script:PairedDevices | Where-Object { $_.Mac -ne $forgotMac })
        if ($script:ActiveDeviceMac -eq $forgotMac) {
            $script:ActiveDeviceMac = if ($script:PairedDevices.Count) { $script:PairedDevices[0].Mac } else { $null }
        }
        Save-LocalSettings
        Reset-DeviceSession
        Refresh-SettingsPairedDevices
        Update-ACStatus
        $script:SettingsMessage.Text = 'Saved pairing removed.'
    })
    $form.Controls.Add($script:SettingsForgetButton)

    $divider = [System.Windows.Forms.Label]::new()
    $divider.BorderStyle = [System.Windows.Forms.BorderStyle]::Fixed3D
    $divider.Location = [Drawing.Point]::new(24,162)
    $divider.Size = [Drawing.Size]::new(590,2)
    $form.Controls.Add($divider)

    $discoverLabel = [System.Windows.Forms.Label]::new()
    $discoverLabel.Text = 'Find devices on your network'
    $discoverLabel.Location = [Drawing.Point]::new(24,181)
    $discoverLabel.AutoSize = $true
    $discoverLabel.Font = [Drawing.Font]::new($form.Font, [Drawing.FontStyle]::Bold)
    $form.Controls.Add($discoverLabel)

    $script:SettingsScanButton = [System.Windows.Forms.Button]::new()
    $script:SettingsScanButton.Text = 'Scan network'
    $script:SettingsScanButton.Location = [Drawing.Point]::new(24,207)
    $script:SettingsScanButton.Size = [Drawing.Size]::new(110,30)
    $script:SettingsScanButton.add_Click({
        $script:SettingsScanButton.Enabled = $false
        $script:SettingsPairButton.Enabled = $false
        $script:SettingsFoundList.Items.Clear()
        $script:SettingsMessage.Text = 'Scanning local network…'
        $script:SettingsForm.Refresh()
        try {
            $devices = @(Find-Devices)
            foreach ($device in $devices) {
                $display = $device.Name + ' · ' + $device.Address
                if ($device.Model -and $device.Model -ne $device.Name) { $display += ' · ' + $device.Model }
                [void]$script:SettingsFoundList.Items.Add([pscustomobject]@{ Device=$device; Display=$display })
            }
            if ($devices.Count -eq 0) {
                $script:SettingsMessage.Text = 'No compatible devices found on this network.'
            } else {
                $script:SettingsFoundList.SelectedIndex = 0
                $script:SettingsMessage.Text = $devices.Count.ToString() + ' compatible device(s) found.'
            }
        } catch {
            $script:SettingsMessage.Text = 'Scan failed. Check that this PC and AC share a local network.'
        } finally {
            $script:SettingsScanButton.Enabled = $true
        }
    })
    $form.Controls.Add($script:SettingsScanButton)

    $script:SettingsFoundList = [System.Windows.Forms.ListBox]::new()
    $script:SettingsFoundList.DisplayMember = 'Display'
    $script:SettingsFoundList.Location = [Drawing.Point]::new(24,247)
    $script:SettingsFoundList.Size = [Drawing.Size]::new(590,185)
    $script:SettingsFoundList.add_SelectedIndexChanged({
        $selected = $script:SettingsFoundList.SelectedItem
        $script:SettingsPairButton.Enabled = $null -ne $selected
        if ($selected) {
            $suggested = [string]$selected.Device.Name
            if ($suggested -eq 'Gree-compatible AC') { $suggested = 'AC · ' + $selected.Device.Address }
            $script:SettingsDeviceName.Text = $suggested
        }
    })
    $form.Controls.Add($script:SettingsFoundList)

    $nameLabel = [System.Windows.Forms.Label]::new()
    $nameLabel.Text = 'Name'
    $nameLabel.Location = [Drawing.Point]::new(24,447)
    $nameLabel.AutoSize = $true
    $form.Controls.Add($nameLabel)

    $script:SettingsDeviceName = [System.Windows.Forms.TextBox]::new()
    $script:SettingsDeviceName.Location = [Drawing.Point]::new(24,470)
    $script:SettingsDeviceName.Size = [Drawing.Size]::new(590,27)
    $form.Controls.Add($script:SettingsDeviceName)

    $script:SettingsPairButton = [System.Windows.Forms.Button]::new()
    $script:SettingsPairButton.Text = 'Pair and use selected'
    $script:SettingsPairButton.Location = [Drawing.Point]::new(414,510)
    $script:SettingsPairButton.Size = [Drawing.Size]::new(200,32)
    $script:SettingsPairButton.Enabled = $false
    $script:SettingsPairButton.add_Click({
        $selection = $script:SettingsFoundList.SelectedItem
        if (-not $selection) { return }
        $device = $selection.Device
        $name = $script:SettingsDeviceName.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$device.Name }
        $script:PairedDevices = @($script:PairedDevices | Where-Object { $_.Mac -ne $device.Mac })
        $script:PairedDevices += [pscustomobject]@{
            Mac=$device.Mac; Name=$name; Brand=$device.Brand; Model=$device.Model
        }
        $script:ActiveDeviceMac = $device.Mac
        Save-LocalSettings
        Reset-DeviceSession
        Refresh-SettingsPairedDevices
        Update-ACStatus
        if ($script:State) { $script:SettingsMessage.Text = 'Paired and ready to use.' }
        else { $script:SettingsMessage.Text = 'Saved. The AC is not responding; check its Wi-Fi connection and refresh.' }
    })
    $form.Controls.Add($script:SettingsPairButton)

    $script:SettingsMessage = [System.Windows.Forms.Label]::new()
    $script:SettingsMessage.Text = 'Scan to find compatible ACs.'
    $script:SettingsMessage.Location = [Drawing.Point]::new(24,514)
    $script:SettingsMessage.Size = [Drawing.Size]::new(370,24)
    $form.Controls.Add($script:SettingsMessage)

    $script:SettingsStartupCheck = [System.Windows.Forms.CheckBox]::new()
    $script:SettingsStartupCheck.Text = 'Start when I sign in to Windows'
    $script:SettingsStartupCheck.Location = [Drawing.Point]::new(24,550)
    $script:SettingsStartupCheck.AutoSize = $true
    $script:SettingsStartupCheck.Checked = Test-StartupEnabled
    $script:SettingsStartupCheck.add_CheckedChanged({
        if ($script:UpdatingStartupCheck) { return }
        try {
            Set-StartupEnabled $script:SettingsStartupCheck.Checked
            $script:SettingsMessage.Text = if ($script:SettingsStartupCheck.Checked) { 'Starts when you sign in; it will only read AC status.' } else { 'Automatic startup is off.' }
        } catch {
            $script:SettingsMessage.Text = 'Could not update the Windows startup setting.'
            $script:UpdatingStartupCheck = $true
            $script:SettingsStartupCheck.Checked = Test-StartupEnabled
            $script:UpdatingStartupCheck = $false
        }
    })
    $form.Controls.Add($script:SettingsStartupCheck)

    $compatibility = [System.Windows.Forms.Label]::new()
    $compatibility.Text = 'This release supports GREE / EWPE-compatible local Wi-Fi units.'
    $compatibility.Location = [Drawing.Point]::new(24,583)
    $compatibility.AutoSize = $true
    $form.Controls.Add($compatibility)

    $closeButton = [System.Windows.Forms.Button]::new()
    $closeButton.Text = 'Done'
    $closeButton.Location = [Drawing.Point]::new(526,576)
    $closeButton.Size = [Drawing.Size]::new(88,30)
    $closeButton.add_Click({ $script:SettingsForm.Close() })
    $form.Controls.Add($closeButton)
    $form.AcceptButton = $closeButton

    Refresh-SettingsPairedDevices
    try { [void]$form.ShowDialog() }
    finally {
        $form.Dispose()
        $script:SettingsForm = $null
        $script:SettingsPairedList = $null
        $script:SettingsUseButton = $null
        $script:SettingsForgetButton = $null
        $script:SettingsScanButton = $null
        $script:SettingsFoundList = $null
        $script:SettingsDeviceName = $null
        $script:SettingsPairButton = $null
        $script:SettingsMessage = $null
        $script:SettingsStartupCheck = $null
    }
}

function New-TrayIcon([bool]$IsOn) {
    $bitmap = [Drawing.Bitmap]::new(32,32)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $accent = if ($IsOn) { [Drawing.Color]::FromArgb(46,157,128) } else { [Drawing.Color]::FromArgb(112,128,138) }
    $pen = [Drawing.Pen]::new($accent,4.5)
    $pen.StartCap = [Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [Drawing.Drawing2D.LineCap]::Round
    $pen.LineJoin = [Drawing.Drawing2D.LineJoin]::Round
    try {
        $graphics.Clear([Drawing.Color]::Transparent)
        $points = [Drawing.Point[]]@(
            [Drawing.Point]::new(7,22),
            [Drawing.Point]::new(16,10),
            [Drawing.Point]::new(25,22)
        )
        $graphics.DrawLines($pen,$points)
        $handle = $bitmap.GetHicon()
        return [Drawing.Icon]::FromHandle($handle)
    } finally {
        $pen.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Invoke-ACPowerToggle {
    if ($null -eq $script:State) { Update-ACStatus; return }
    Set-ACValue 'Pow' ([int](-not $script:State.Power))
}

# Build the native notification-area menu.
$script:ContextMenu = [System.Windows.Forms.ContextMenuStrip]::new()
$script:ContextMenu.ShowImageMargin = $false
$script:StatusItem = [System.Windows.Forms.ToolStripMenuItem]::new('LAN AC Tray · Connecting…')
$script:StatusItem.Enabled = $false
$script:StatusItem.Font = [Drawing.Font]::new($script:ContextMenu.Font, [Drawing.FontStyle]::Bold)
$script:PowerItem = [System.Windows.Forms.ToolStripMenuItem]::new('Turn AC off')
$script:PowerItem.add_Click({ Invoke-ACPowerToggle })
$script:ContextMenu.Items.Add($script:StatusItem) | Out-Null
$script:ContextMenu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new()) | Out-Null
$script:ContextMenu.Items.Add($script:PowerItem) | Out-Null

$script:TempMenu = [System.Windows.Forms.ToolStripMenuItem]::new('Temperature')
$lower = [System.Windows.Forms.ToolStripMenuItem]::new('Lower by 1°C')
$lower.Tag = -1
$lower.add_Click({ param($sender,$eventArgs) if ($script:State) { Set-ACValue 'SetTem' ([Math]::Max(16,$script:State.Temperature + [int]$sender.Tag)) } })
$raise = [System.Windows.Forms.ToolStripMenuItem]::new('Raise by 1°C')
$raise.Tag = 1
$raise.add_Click({ param($sender,$eventArgs) if ($script:State) { Set-ACValue 'SetTem' ([Math]::Min(30,$script:State.Temperature + [int]$sender.Tag)) } })
$script:TempMenu.DropDownItems.Add($lower) | Out-Null
$script:TempMenu.DropDownItems.Add($raise) | Out-Null
$script:ContextMenu.Items.Add($script:TempMenu) | Out-Null

$script:ModeMenu = [System.Windows.Forms.ToolStripMenuItem]::new('Mode')
foreach ($modeName in @('Auto','Cool','Heat','Dry','Fan')) {
    $modeItem = [System.Windows.Forms.ToolStripMenuItem]::new($modeName)
    $modeItem.Tag = $modeName
    $modeItem.add_Click({ param($sender,$eventArgs) Set-ACValue 'Mod' ([int]$script:ModeValues[[string]$sender.Tag]) })
    $script:ModeItems[$modeName] = $modeItem
    $script:ModeMenu.DropDownItems.Add($modeItem) | Out-Null
}
$script:ContextMenu.Items.Add($script:ModeMenu) | Out-Null

$script:FanMenu = [System.Windows.Forms.ToolStripMenuItem]::new('Fan')
foreach ($fanName in @('Auto','Low','Medium low','Medium','Medium high','High')) {
    $fanItem = [System.Windows.Forms.ToolStripMenuItem]::new($fanName)
    $fanItem.Tag = $fanName
    $fanItem.add_Click({ param($sender,$eventArgs) Set-ACValue 'WdSpd' ([int]$script:FanValues[[string]$sender.Tag]) })
    $script:FanItems[$fanName] = $fanItem
    $script:FanMenu.DropDownItems.Add($fanItem) | Out-Null
}
$script:ContextMenu.Items.Add($script:FanMenu) | Out-Null
$script:ContextMenu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new()) | Out-Null
$script:SettingsItem = [System.Windows.Forms.ToolStripMenuItem]::new('Settings…')
$script:SettingsItem.add_Click({ Show-DeviceSettings })
$script:ContextMenu.Items.Add($script:SettingsItem) | Out-Null
$retryItem = [System.Windows.Forms.ToolStripMenuItem]::new('Refresh')
$retryItem.add_Click({ Update-ACStatus })
$script:ContextMenu.Items.Add($retryItem) | Out-Null
$exitItem = [System.Windows.Forms.ToolStripMenuItem]::new('Exit')
$exitItem.add_Click({
    $script:NotifyIcon.Visible = $false
    $script:NotifyIcon.Dispose()
    $script:RefreshTimer.Stop()
    $script:RefreshTimer.Dispose()
    $script:AppContext.ExitThread()
})
$script:ContextMenu.Items.Add($exitItem) | Out-Null

$script:IconOn = New-TrayIcon $true
$script:IconOff = New-TrayIcon $false
$script:NotifyIcon = [System.Windows.Forms.NotifyIcon]::new()
$script:NotifyIcon.Icon = $script:IconOff
$script:NotifyIcon.Text = 'LAN AC Tray · Connecting'
$script:NotifyIcon.ContextMenuStrip = $script:ContextMenu
$script:NotifyIcon.Visible = $true
$script:NotifyIcon.add_MouseClick({
    param($sender,$eventArgs)
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Invoke-ACPowerToggle }
})

Load-LocalSettings
Update-ACStatus
$script:RefreshTimer = [System.Windows.Forms.Timer]::new()
$script:RefreshTimer.Interval = 15000
$script:RefreshTimer.add_Tick({ if (-not $script:Busy) { Update-ACStatus } })
$script:RefreshTimer.Start()
$script:AppContext = [System.Windows.Forms.ApplicationContext]::new()
try {
    [System.Windows.Forms.Application]::Run($script:AppContext)
} finally {
    $script:NotifyIcon.Visible = $false
    $script:NotifyIcon.Dispose()
    $script:RefreshTimer.Stop()
    $script:RefreshTimer.Dispose()
    $script:ContextMenu.Dispose()
    $script:IconOn.Dispose()
    $script:IconOff.Dispose()
    $script:StatusItem.Font.Dispose()
    $script:InstanceMutex.ReleaseMutex()
    $script:InstanceMutex.Dispose()
}
