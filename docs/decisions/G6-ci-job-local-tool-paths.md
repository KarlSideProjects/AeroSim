# G6 — CI Job-Local Tool Path 決策

| 欄位 | 內容 |
|---|---|
| 決策 | **所有會被 CI job 刪除或覆蓋的工具路徑必須 job-local** |
| 決策日期 | 2026-07-09 |
| 決策人（簽核） | Karl（維護者，CI multi-runner 調整） |
| 對應範圍 | GitHub Actions self-hosted Linux/X64 multi-runner CI |

## 決策內容

CI 已改成多 runner 平行執行。任何會被 job 下載、解壓、刪除、覆蓋或寫入設定的工具路徑，都不得使用共享全域位置。

剛性規則：

- Godot binary / zip / unpack dir 使用 `$RUNNER_TEMP` 底下的 run/job 專屬子目錄。
- Godot export templates 使用 `XDG_DATA_HOME` 底下的 job-local 路徑。
- Godot editor settings 使用 `XDG_CONFIG_HOME` 底下的 job-local 路徑。
- Godot cache 使用 `XDG_CACHE_HOME` 底下的 job-local 路徑。
- 不使用 shared temp 或 user-home 底下的 Godot binary、export template、editor settings 路徑。
- 其他會被覆蓋的工具暫存檔也使用 `$RUNNER_TEMP` 底下的 run/job 專屬子目錄，或該 job workspace 內的路徑。

## 理由

多個 self-hosted runner 可能同時在同一台機器上執行。共享 `/tmp`、`$HOME`，或 `$RUNNER_TEMP` 根層固定名稱的工具路徑，會讓 jobs 互相刪檔、覆蓋 export templates、污染 Godot editor settings，造成非決定性的 CI 失敗。

## 實作要求

- Workflow job 必須設定 job-local `XDG_DATA_HOME`、`XDG_CONFIG_HOME`、`XDG_CACHE_HOME`。
- Workflow job 應先建立 `$RUNNER_TEMP/aerosim-tools-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT-$GITHUB_JOB` 這類唯一工具根目錄，再從該根目錄派生 Godot、godot-cpp、Android SDK/NDK/AVD、keystore 與 XDG 路徑。
- Export scripts 預設從 `XDG_DATA_HOME/godot/export_templates/4.7.stable` 讀 templates；未設定 XDG 時必須 fail loud，或由呼叫端明確提供 `GODOT_EXPORT_TEMPLATES_DIR`。
- Android export script 寫入 editor settings 時必須尊重 `XDG_CONFIG_HOME`。
