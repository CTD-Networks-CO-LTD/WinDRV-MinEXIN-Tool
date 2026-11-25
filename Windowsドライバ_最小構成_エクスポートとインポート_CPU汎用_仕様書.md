# コーディング仕様書：`Windowsドライバ_最小構成_エクスポートとインポート_CPU汎用.cmd`

## 1. ファイル構造・実行基盤規約

- **単一ファイル構成**: 先頭6行のバッチラッパー（`.cmd`）と、`# === PS_BODY_START ===` マーカー以降の PowerShell 本体で構成する。
- **文字コード・改行**: **UTF-8（BOMなし）＋ CRLF** 必須。
  - 先頭 BOM は `cmd.exe` の `@echo off` 解釈を破損させるため禁止。
  - PowerShell 側は厳密 UTF-8（`UTF8Encoding($false, $true)`）で自己読み込みし、失敗時のみ CP932 へフォールバックする。
  - 端末のコードページ変更や `Clear-Host` は全角文字描画崩れ防止のため行わない。
- **実行要件と自動昇格**:
  - Windows PowerShell 5.1 以降・管理者権限必須。
  - 非管理者実行時は `cmd.exe /d /s /c ""{0}""`（`-Verb RunAs`）で再起動する（`/s` により空白・半角括弧を含むパスに対応）。
- **テスト用エントリ**: `param([switch]$LibraryOnly)` 指定時は UAC 昇格やメニュー対話を開始せず、関数定義のみをロードして終了する。
- **PowerShell 5.1 記述規約**:
  - グローバルは `$ErrorActionPreference = 'Stop'` とする。
  - `pnputil.exe` / `expand.exe` 等のネイティブコマンド実行時は、stderr の `ErrorRecord` 化による中断を防ぐため一時的に `'Continue'` へ切り替え、`$LASTEXITCODE` で成否判定する。
  - 要素1件の配列がスカラーにアンロールされて `.Count` が `$null` になる PowerShell 5.1 仕様を回避するため、`@(if (...) { ... })` や `[string[]]@(...)` で配列型を明示する。

---

## 2. メニュー構成（`Invoke-MainMenu`）

| キー | 機能 | 呼び出し先 |
| :--- | :--- | :--- |
| `1` | 最小構成エクスポート（必須ドライバ一式、Displayはオンライン取得を選択可） | `Invoke-DriverExport -MinimalMode $true` |
| `2` | 全ドライバエクスポート（全サードパーティ `oem*.inf`） | `Invoke-DriverExport -MinimalMode $false` |
| `3` | 保存フォルダからインポート（ローカル復元 ＋ オンライン取得） | `Invoke-DriverImport` |
| `4` | デバイスドライバ適用状態の診断（読み取り専用） | `Invoke-DeviceDiagnostics` |
| `0` / `Q` | 終了 | - |

---

## 3. エクスポート仕様（`Invoke-DriverExport`）

1. **保存先バリデーション（`Resolve-ExportFolder`）**
   - `.cmd` と同一階層直下のフォルダ名のみ許可（既定 `driver`）。パストラバーサル、Windows 予約名、既存ファイル入りフォルダ（上書き禁止）、再解析ポイント（ジャンクション/シンボリックリンク）を拒否する。
2. **デバイス診断・選別ルール**
   - **仮想デバイス除外**: Hyper-V 仮想スイッチ/NIC、WAN Miniport、Kernel Debug NIC、Wi-Fi Direct Virtual、Bluetooth 仮想 PAN 等を除外する。
   - **仕様上ドライバレスの内部 RAW PDO / バス論理ノード除外（`Test-ExpectedDriverlessRawDevice`）**: `Problem = 0`（正常稼働）かつ `Class`・`DriverInfPath` 未設定のノードのうち、① `HardwareIds` / `CompatibleIds` を一切報告しない非物理バス上の内部制御 RAW PDO（Realtek Bluetooth フィルタの `RtkFilter0` 等）、および ② AMD ACP バス（`amdacpbus.sys`）の HDA 論理子ノード（`ACP\DEVTYPE_0001*`）は、独立 INF 不要な正規仕様（By Design）として未適用警告・必須カテゴリ異常判定・フォールバックバインド対象から除外する（`Problem != 0` 発生時は通常どおり異常検出する）。
   - **常時除外クラス**: `Printer` / `PrintQueue` / `Fax`。
   - **最小構成時の保持対象**:
     - 現在接続中デバイスの `DriverInfPath` および `ExtendedInfNames` に紐づく `oem*.inf`
     - `BootCritical = $true`、または `Extension` / `SoftwareComponent` / `AudioProcessingObject` クラスのパッケージ
   - **物理ディスプレイドライバのオンライン取得切り替え（最小構成時のみ）**:
     - 物理バス（`PCI\` / `ACPI\`）接続かつ `Display` クラスの正常稼働 `oem*.inf` を動的に検出し、`[Y/N]`（既定 `Y`、大文字・小文字区別なし）でローカル保存除外＋ `OnlineDrivers` メタデータ記録を選択可能とする。
     - `SWD\` / `ROOT\` / `USB\` 等の仮想・USBディスプレイアダプタは対象外としローカル保存に残す。
   - **`CopyINF` 連鎖解析**: 選択済み INF 内の `CopyINF` ディレクティブを幅優先探索（BFS）で辿り関連 `oem*.inf` を追加する（オンライン取得へ切り替えた Display `oem*.inf` は再追加しない）。
3. **パッケージ出力・検証**
   - `pnputil /export-driver <oem*.inf> <dest>` でサブフォルダ単位に出力し、DriverStore 元フォルダとファイルのサイズ・SHA-256 一致を検証する。`.pnf` キャッシュ、および INF 未記載の既知の実行時生成ファイル（`amdfendr.inf` の `AMD\*Dumps\`・`AMD\Persistent\`・`AMD\Real\` 配下の実行時ログ/ダンプ、ならびに AMD Display ドライバ `u\d+\.inf` / `c\d+\.inf` の `HDCPSrmData.txt`）は元フォルダ照合の対象外とする。保存先に出力された非 PNF ファイルは引き続きハッシュを記録する。
   - `_エクスポート内訳レポート.txt`（UTF-8 BOM付）および `driver-backup.json` を生成する。

---

## 4. マニフェスト仕様（`driver-backup.json`）

- **`FormatVersion`**: `1`（固定）
- **`Status`**: `'InProgress'` → 全検証完了時のみ `'Complete'`（失敗時 `'Failed'`）
- **`Files`**: ローカル保存ファイルの `Path`（相対パス）、`Length`、`SHA256` 配列
- **`DeviceBindings`**: エクスポート時点で正常バインドされていたデバイスの `HardwareIds`・`LeafInf`・`DriverDesc`・`InfRelativePath`（インポート時の未バインド救済用）
- **`OnlineDrivers`**: オンライン取得対象デバイスの `DeviceName`・`ClassName`・`LeafInf`・`Version`・`HardwareIds`・`CompatibleIds` 等

---

## 5. インポート仕様（`Invoke-DriverImport`）

1. **事前セキュリティ・完全性検証**
   - 再解析ポイント検査（`Assert-NoReparsePoint`）。
   - マニフェストがある場合は先に完了状態（`Status = 'Complete'`）およびマニフェスト対象ファイルの正常性（存在・サイズ・SHA-256 ハッシュ一致、`OnlineDrivers` がある場合は有効なハードウェアIDの有無）のみを確認する（`Test-BackupIntegrity`）。マニフェスト未登録のファイル（後から同梱したインストーラーや追加ドライバ等）がフォルダ内に存在していてもエラーとしない。未完了の場合は元の Windows から別名で再エクスポートする。
   - ローカル INF の `CatalogFile`（`.cat`）に対する Authenticode 署名を検証する。マニフェスト検証済みのバックアップでは、署名検証済みの同階層の親 INF が `SourceDisksFiles` に明記し、自身の CAT がすべて存在しない同梱 INF を単独インストール対象から除外する（ファイルは削除しない）。マニフェストが無い場合はこの例外を適用せず、署名検証後に `IMPORT` の明示入力を要求する。
2. **フェーズ1：ローカルドライバ復元**
   - マニフェスト付きバックアップでは検証済みの単独インストール対象 INF を `CopyINF` の参照先が先になる順序で個別に `pnputil /add-driver <inf> /install` へ渡す（保留分は全件処理後に1回再試行し、一部旧版・非対応パッケージの失敗で全体が中断しないようにする）。マニフェストなしの場合は従来どおり `<folder>\*.inf /subdirs` を使用する。終了コード `0`・`259`（`ERROR_NO_MORE_ITEMS`：既に登録済み・最新適用済み）・`3010` / `1641`（要再起動）を正常扱いとし、続いて `/scan-devices`（3秒間隔で2回）を実行する。
   - 未適用デバイス（Problem 28 / Null Driver）が残る場合、①マニフェスト記録バインド一致、②オーディオコーデック（`INTELAUDIO` / `HDAUDIO`）の SUBSYS 違い救済の順で検索し、C# P/Invoke（`PnPForcedDriverBinder`：`SetupDi*` + `DiInstallDevice`）で直接バインドする。
3. **フェーズ2：オンライン取得・復元（`Invoke-OnlineDriverRestore`）**
   - **対象判定**: インポート先PCに該当物理デバイス（4パートID `VEN&DEV&SUBSYS` または 2パートID `VEN&DEV`）が存在しない場合はスキップ。既に記録版以上の OEM ドライバが正常適用済みの場合はスキップ選択（既定 `Y`）を提示する。
   - **疎通待機**: `catalog.update.microsoft.com` への HTTPS 疎通（TLS 1.2 有効化）を確認し、未接続時は接続待機またはスキップ（`S`）を選択可能とする。
   - **候補検索・OS適合スコアリング**:
     - ハード除外（スコア `-1`）は CPU アーキテクチャ不一致（`AMD64` / `ARM64` / `x86`）および OS 種別不一致（Client 専用 / Server 専用）のみに限定する。
     - OS の `BuildNumber` やバージョンタグ（`26H2` や未知・将来バージョン等を含む）の違いでは候補を切り捨てず、適合度に応じた正の優先度スコア（ネイティブ適合帯 `>= 70` を優先し、ビルド未達・世代差・未知表記もフォールバック帯 `40〜65` として許容）を付与することで、どのビルド番号でも動作可能とする。その上で以下の優先順で選定する：
       1. OEM 4パートID（`SUBSYS` 付）× 同一バージョン（MSカタログ）
       2. 汎用 2パートID × 同一バージョン（MSカタログ）
       3. OEM 4パートID × 最新WHQL版（MSカタログ）
       4. 汎用 2パートID × 最新WHQL版（MSカタログ）
       5. Windows Update 標準 COM API（`Microsoft.Update.Session`）フォールバック
   - **取得・二重検証・適用**:
     - `DownloadDialog.aspx` から公式ドメイン（`*.windowsupdate.com` / `*.microsoft.com`）の `.cab` URL と SHA-256 / SHA-1 を取得し、`$env:TEMP` 配下へ 128KB チャンクでストリーム保存する。
     - ① CAB の SHA-256 / SHA-1 ハッシュ照合 → `expand.exe` 展開 → ② `Assert-DriverCatalogSignatures` による WHQL カタログ署名検証を通過したもののみ `pnputil` で適用する（未バインド時は `PnPForcedDriverBinder` で補助）。
     - `finally` で `$env:TEMP` の一時フォルダを必ず削除する。
4. **事後診断**: 接続デバイスの適用状態を再照合し、未適用・要注意デバイスがあれば画面と `driver-import-*.log` に出力する（強制上書き・自動再起動は行わない）。

---

## 6. 主要関数一覧

| 区分 | 関数名 | 役割 |
| :--- | :--- | :--- |
| 共通・検証 | `Assert-NoReparsePoint` | ジャンクション・シンボリックリンクの混入阻止 |
| 共通・検証 | `Read-InfTextLines` | BOM / UTF-16LE/BE / UTF-8 / CP932 自動判別による INF 行読み取り |
| 共通・検証 | `Assert-DriverCatalogSignatures` | INF 参照 `.cat` ファイルの Authenticode デジタル署名検証 |
| 共通・検証 | `Get-PackageFiles` / `Assert-ExportedPackage` / `Test-KnownDriverStoreRuntimeFile` | エクスポート出力のサイズ・SHA-256 照合と DriverStore 内既知実行時生成ファイルの除外判定 |
| 共通・検証 | `Write-BackupManifest` / `Test-BackupIntegrity` | `driver-backup.json` の出力とマニフェスト対象ファイルの正常性（存在・サイズ・SHA-256）検証 |
| 共通・検証 | `Get-SafePnpDeviceProperties` / `Get-DeviceHardwareAndCompatibleIds` | WMI クエリ長上限（`WBEM_E_QUOTA_VIOLATION`）を回避する PnP プロパティ一括/分割取得と `HardwareID`/`CompatibleID` フォールバック |
| 診断 | `Test-ExpectedDriverlessRawDevice` | `Problem = 0` で稼働する仕様上ドライバレスの内部 RAW PDO（`RtkFilter0` 等）および AMD ACP 論理ノード（`ACP\DEVTYPE_0001*`）の判定 |
| 診断 | `Get-CoreCategoryStatus` | 必須5カテゴリ（Audio / Video / 有線LAN / 無線LAN / Bluetooth）の状態集計（Video 集計時は `Processor` クラスを除外） |
| 診断 | `Get-UnhealthyOrUnboundDevices` | PnP 問題コード・Null Driver（仕様上ドライバレスノードを除く）・SST インボックス状態の検出 |
| エクスポート | `Invoke-DriverExport` | ドライバ選別・オンライン切り替え選択・`pnputil` 出力・検証・レポート生成 |
| エクスポート | `Get-OnlineEligibleDisplayDrivers` | 物理バス接続 `Display` クラス `oem*.inf` と検索用 ID の動的抽出 |
| ローカル復元 | `Invoke-DriverImport` | 事前検証・ローカル復元・オンライン復元・事後診断の統括 |
| ローカル復元 | `Invoke-UnboundDeviceFallbackBinding` | 未適用デバイスへの SetupAPI（`PnPForcedDriverBinder`）強制バインド救済 |
| オンライン復元 | `Get-NormalizedHardwareSearchKeys` | HardwareIds / CompatibleIds から 4パートID・2パートID を正規化抽出 |
| オンライン復元 | `Search-MsCatalogDriver` / `Get-MsCatalogDownloadFiles` | MSカタログ検索解析および `.cab` URL・検証ハッシュ取得 |
| オンライン復元 | `Get-MsCatalogOsMatchScore` / `Select-BestMsCatalogCandidate` | アーキテクチャ・Client/Server種別の適合判定と、ビルド番号非除外のソフトスコアリング・同一版優先選定 |
| オンライン復元 | `Find-BestMsCatalogDriverForDevice` | 優先1〜優先4の多段階カタログ検索オーケストレーション |
| オンライン復元 | `Receive-FileWithProgress` / `Expand-AndInstallOnlineCabFiles` | チャンクストリームDL・ハッシュ検証・CAB展開・署名検証・適用 |
| オンライン復元 | `Install-DriverViaWindowsUpdateApi` | 優先5フォールバック（`Microsoft.Update.Session` COM API 経由の適用） |
| オンライン復元 | `Invoke-OnlineDriverRestore` | オンライン取得対象デバイスの実機照合〜取得・適用の統括 |

