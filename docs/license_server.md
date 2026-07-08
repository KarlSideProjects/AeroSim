# 授權伺服器

`license_server/` 是與 Godot 專案分離的 Python 標準庫服務；目前沒有第三方 Python 依賴。

## 啟動

```bash
AEROSIM_LICENSE_SECRET="$(openssl rand -hex 32)" \
python3 -m license_server.server --host 127.0.0.1 --port 8080 --db license_server.sqlite3
```

也可以用 `--secret-file /run/secrets/aerosim-license-secret`。secret、`.env`、`*.secret`、`license_server.sqlite3*` 已被 `.gitignore` 排除，不得提交。

## API

所有 API 使用 `POST` 與 JSON body。

| API | Body | 成功回應 | 語意 |
| --- | --- | --- | --- |
| `/register` | `{"customer_id":"cust-1"}` | `201 {"license_key":"lic_...","status":"active"}` | 建立 active license key |
| `/issue` | `{"license_key":"lic_...","device_id":"rig-1"}` | `200 {"token":"..."}` | 對 active license 簽發 JWT |
| `/verify` | `{"token":"..."}` | `200 {"valid":true,"token":"..."}` | 線上驗簽、查撤銷狀態，成功時刷新 grace token |
| `/revoke` | `{"license_key":"lic_..."}` | `200 {"revoked":true}` | 撤銷 license key |

撤銷後，同一把 key 的下一次線上 `/verify` 回 `403 {"valid":false,"error":"revoked"}`；`/issue` 也會拒絕已撤銷 key。

## JWT claims

簽發與線上 verify 刷新的 JWT claim：

| Claim | 用途 |
| --- | --- |
| `iss` | 固定為 `aerosim-license-server` |
| `aud` | 固定為 `aerosim-client` |
| `sub` | license key |
| `customer_id` | 客戶識別 |
| `device_id` | 啟用裝置識別，可為空字串 |
| `iat` | token 簽發時間，Unix seconds |
| `online_verified_at` | 最近一次線上驗證時間 |
| `offline_grace_until` | `online_verified_at + 72h` |

線上與離線驗證都會拒絕不符合 `HS256` / `JWT` header、`iss` 或 `aud` 的 token。離線判定只需要本機驗簽成功且目前時間 `<= offline_grace_until`。測試用 `offline_grace_valid(token, secret, now)` 固定時間注入驗證 72h 邊界。

## 部署與金鑰管理

- 使用部署平台 secret store 或 root-only secret file 提供 `AEROSIM_LICENSE_SECRET`。
- 不要把 secret、SQLite DB、`.env` 放入版控。
- 備份 `license_server.sqlite3`；註冊與撤銷狀態存在 SQLite。
- 輪替 secret 會讓舊 JWT 無法驗簽；輪替前先規劃雙 key 驗證或強制客戶端重新線上啟用。
- 目前未做付款、訂閱、客戶端 UI 或 Quick Fly 錯誤分支。
