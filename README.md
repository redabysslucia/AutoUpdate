# AutoUpdate - 整合包自动更新系统 v5.0

多源模组自动更新：GitHub 托管 + CurseForge/Modrinth 远程直连。

## 架构

```
AutoUpdate/
├── server/                     # 服务端（托管在 GitHub）
│   ├── update.bat              # 生成更新清单
│   ├── find_sources.bat        # 一键自动匹配所有未映射模组
│   ├── find_mod.bat            # 按关键词搜索特定模组
│   ├── generate_update.ps1     # 生成更新清单（混合来源）
│   ├── find_mod_source.ps1     # 核心：jar拆解 + 平台匹配 + 自动填入
│   ├── mod_sources.json        # 模组来源映射（自动填入，也可手工编辑）
│   ├── modpack.json            # 更新清单（自动生成）
│   ├── changelog.json          # 更新历史（自动生成）
│   └── files/mods/             # GitHub 兜底的本地 jar 文件
│
└── client/                     # 客户端
    └── .minecraft/
        ├── update.ps1          # 自动更新脚本（多源下载）
        ├── modpack_version.json # 本地版本快照
        └── mods/               # 本地模组目录
```

## 工作原理

### 三种下载来源

| 来源 | 说明 | 需要本地 jar？ |
|------|------|---------------|
| **GitHub** | 直接托管 jar 文件 | 是（放 `files/mods/`） |
| **CurseForge** | 通过 CDN 直链下载 | 否 |
| **Modrinth** | 通过 CDN 直链下载 | 否 |

`generate_update.ps1` 优先使用远程映射（`mod_sources.json`），本地 jar 作为兜底。

### 模组来源映射 (mod_sources.json)

```json
{
    "mappings": {
        "76ea0beb": {
            "source": "curseforge",
            "downloadUrl": "https://edge.forgecdn.net/files/.../mod.jar",
            "sha256": "abc123...",
            "fileName": "mod-1.0.0.jar"
        }
    }
}
```

### 客户端更新清单 (modpack.json)

每个文件条目格式：

```json
{
    "prefix": "76ea0beb",
    "path": "mods/76ea0beb_mod-1.0.0.jar",
    "sha256": "abc123...",
    "source": "curseforge",
    "downloadUrl": "https://edge.forgecdn.net/files/.../mod.jar"
}
```

- 有 `source` + `downloadUrl`：客户端从对应平台下载
- 无这两个字段：客户端从 GitHub `files/mods/` 下载

## 使用流程

### 首次使用

```batch
cd server
update              # 扫描 files/mods/ 生成初始清单
```

### 迁移模组到远程平台（一键自动匹配）

```batch
# 自动扫描所有未映射模组，读取jar内部modId
# 在 Modrinth 上精确匹配版本 → 自动填入 mod_sources.json
find_sources

# 手动搜索（不自动填入，仅查看结果）
find_mod create
find_mod "touhou little maid"

# 对特定jar文件执行自动匹配并填入
find_mod sodium --auto files\mods\dd004f7a_sodium.jar

# 重新生成清单（已映射的模组自动转为远程CDN链接）
update
```

**自动匹配引擎：**
1. 读取 jar 内 `META-INF/neoforge.mods.toml` 获取 `modId`、`displayName`、`version`
2. 在 Modrinth 上按 slug 精确查找 → 按名称搜索
3. 版本模糊匹配（`0.6.13+mc1.21.1` ≈ `mc1.21.1-0.6.13`）
4. 下载文件到临时目录 → 计算 SHA256 → 自动写入映射表
5. 可选：删除 `files/mods/` 中已映射的本地 jar 释放 GitHub 空间

### 日常更新

```batch
cd server
update              # patch 版本号 +1
update minor        # minor 版本号 +1
update major        # major 版本号 +1
```

然后 `git push` 到 GitHub。

## 优势

- **减小仓库体积**：CurseForge/Modrinth 上的模组不占用 GitHub 存储
- **完整性校验**：所有来源统一 SHA256 校验
- **自动清理**：客户端自动删除不在清单中的旧模组
- **用户模组保护**：未经 prefix 标记的用户自制模组不会被删除
- **混合兜底**：自研/国内特有模组仍可托管在 GitHub
