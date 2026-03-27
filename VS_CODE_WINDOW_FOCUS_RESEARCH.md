# VS Code 特定ウィンドウフォーカス研究報告

## 調査日時
2026-03-27

## 調査内容

### 1. VS Code統合ターミナルの環境変数

**$VSCODE_PID について:**
- VS Code プロセスの PID を識別する環境変数
- 統合ターミナルから利用可能
- ただし、WSL などの仮想環境では設定されないことがある
- 拡張機能内では利用不可の制限あり

**その他の環境変数:**
- $TERM_PROGRAM は一般的な環境変数だが、VS Code 固有の機能ではない

**結論:** PID から直接ウィンドウを特定することは可能だが、VS Code 自体は複数ウィンドウを単一プロセスで管理するため、PID だけではどのウィンドウかは判断できない可能性がある。

---

### 2. VS Code CLI コマンド (`code`) でのウィンドウ指定

**利用可能なフラグ:**
- `-r` または `--reuse-window`: 既存ウィンドウを再利用する
  ```bash
  code -r /path/to/folder
  ```
- `-n` または `--new-window`: 新しいウィンドウを開く
- URI スキーム: `vscode://file//Users/...` でファイルを開く

**制限事項:**
- CLI からは特定ウィンドウを指定してアクティブにする直接的な方法がない
- 既存ウィンドウを前面に持ってくることはできるが、「どの」ウィンドウかは制御できない

**結論:** CLI コマンドだけではウィンドウ ID や PID を指定してフォーカスはできない。

---

### 3. macOS AppleScript / Accessibility API

**AppleScript の制限:**
- VS Code は Electron ベースのため、AppleScript 辞書がない
- VS Code と Base Electron App のバンドル ID がコンフリクトする (`com.github.electron`)
- 従来の AppleScript では VS Code を正確に指定できない可能性が高い
- System Events を使った間接的なアプローチが必要

**Accessibility API:**
- macOS 10.12 以降で利用可能
- アクセシビリティ権限が必須（ユーザーが許可を与える必要あり）
- PID からウィンドウを取得して、フォーカスを当てることは可能

**Accessibility API でのウィンドウフォーカスの流れ:**
1. システム全体のアクセシビリティ要素をクエリ
2. 実行中アプリケーションを列挙
3. PID に一致するアプリケーションのウィンドウを取得
4. `activateWithOptions` などでウィンドウをアクティブ化

---

### 4. NSRunningApplication と PID

**できること:**
- `init(processIdentifier:)` で PID からアプリケーション取得可能
- `activateWithOptions:` でアプリケーションをアクティブ化可能

**制限事項:**
- NSRunningApplication はアプリケーション レベルのみ
- **ウィンドウリストは取得できない**
- 複数ウィンドウがある場合、特定のウィンドウをフォーカスできない

**必要な追加技術:**
- CGWindow API または Accessibility API と組み合わせることで特定ウィンドウ取得が可能

**結論:** NSRunningApplication 単体では不十分。Accessibility API と組み合わせる必要がある。

---

### 5. VS Code 拡張機能 API

**利用可能な機能:**
- `vscode.window.onDidChangeWindowState`: ウィンドウフォーカス状態の変化をリッスン
- 各拡張機能は独立したコンテキストで動作（プロセスレベルのコントロールはできない）

**制限事項:**
- 拡張機能 API からは他のプロセスやウィンドウをフォーカスできない
- あくまで VS Code 内部の UI 制御に限定される

**結論:** 拡張機能 API だけでは外部から VS Code のウィンドウをアクティブ化できない。

---

## 実装可能なアプローチ

### **推奨案: Accessibility API + Swift/Objective-C**

CLI 通知ツール側から以下の処理を実行:

1. **VS Code のすべてのウィンドウを列挙**
   - Accessibility API で VS Code プロセスを検出
   - ウィンドウ情報（タイトル）を取得

2. **特定ウィンドウを特定**
   - 環境変数 `$VSCODE_PID` を保存
   - または Claude Code が実行されているウィンドウのタイトルパターンを保存
   - ウィンドウリストから一致するものを検出

3. **AXUIElement API を使ってフォーカス**
   ```swift
   // Accessibility API でウィンドウをアクティブ化
   let success = AXUIElementPerformAction(windowElement, kAXRaiseAction as CFString)
   ```

### **代替案: AppleScript + System Events**

```applescript
tell application "System Events"
    set frontmost of (every process whose name is "Visual Studio Code") to true
end tell
```

**欠点:** 複数 VS Code ウィンドウがある場合、最前面に持ってくるが特定ウィンドウは指定できない。

---

## 環境変数を活用した実装戦略

### **ステップ 1: VS Code 統合ターミナルで環境変数を設定**

Claude Code 実行時に以下を記録:
- `$VSCODE_PID`: プロセス ID
- アクティブウィンドウの標準出力を用いた識別情報

### **ステップ 2: CLI ツール側で PID とメタデータを保存**

通知受信時に:
```json
{
  "vscode_pid": 12345,
  "window_identifier": "claude-code-window-xxxxx",
  "created_at": "2026-03-27T..."
}
```

### **ステップ 3: Accessibility API で復元**

```swift
import Cocoa

// PID からアプリケーション取得
if let app = NSRunningApplication(processIdentifier: pid_from_notification) {
    // Accessibility API でウィンドウを特定・フォーカス
    app.activate(options: .activateAllWindows)
}
```

---

## 実現可能性と難易度

| アプローチ | 難易度 | 実行可能性 | メモ |
|----------|-------|---------|------|
| CLI コマンド只使用 | 低 | ❌ | ウィンドウ指定不可 |
| AppleScript | 中 | ⚠️ | 複数ウィンドウでは不確実 |
| NSRunningApplication 単体 | 低 | ❌ | ウィンドウ情報が取得不可 |
| Accessibility API | 高 | ✅ | 最も確実だが権限必須 |
| VS Code 拡張機能 API | 中 | ⚠️ | 内部制御のみで外部呼び出しは別手段必要 |

---

## 推奨実装フロー

1. **通知発火時の記録:**
   - Claude Code が実行される際、`$VSCODE_PID` と UUID などを環境変数で記録

2. **通知ペイロード:**
   - PID とウィンドウ識別子を含める

3. **macOS ツール (Swift/Objective-C):**
   - Accessibility API で VS Code プロセスを特定
   - ウィンドウリストから一致するものを検出
   - AXUIElement API でフォーカス

4. **ユーザー体験:**
   - 通知タップ → Accessibility 権限チェック → VS Code フォーカス切り替え

---

## 参考リソース

- [macOS Accessibility API](https://developer.apple.com/library/archive/documentation/Accessibility/Conceptual/AccessibilityMacOSX/)
- [NSRunningApplication Documentation](https://developer.apple.com/documentation/appkit/nsrunningapplication)
- [VS Code Extension API](https://code.visualstudio.com/api/references/vscode-api)
- [mac-focus-window (実装例)](https://github.com/karaggeorge/mac-focus-window)
- [MacWindowsLister (ウィンドウ列挙例)](https://github.com/allenlinli/MacWindowsLister)

