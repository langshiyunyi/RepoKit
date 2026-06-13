# RepoKit

RepoKit 是一个直接在越狱 iPhone 本机运行的越狱源管理工具。它包含一个 UIKit 图形界面 App 和一个配套的命令行辅助程序
`repokit-helper`，可以**在没有 Mac 的情况下**创建、导入、编辑、索引并发布 Cydia / Sileo / Zebra 越狱源。

![RepoKit](screenshots/app-preview.png)

[English README](README.md)

## 功能

- 一键创建全新本地越狱源
- 导入已有越狱源目录
- 导入单个 `.deb` 文件，或直接从 `dpkg` 已安装记录重建 `.deb`
- 在 App 内编辑任意 `DEBIAN/control` 字段和软件包图标
- 使用 `dpkg-scanpackages` 生成 `Packages`、`Packages.gz`、`Packages.zst`、`Packages.bz2`、`Packages.xz`
- 生成带 MD5 / SHA256 校验和的 `Release` 文件
- 检查重复包版本、缺失字段、架构不匹配和孤立 `.deb` 文件
- 配置 GitHub remote / 分支 / SSH 用户名，直接推送到 GitHub Pages
- 完整中英文本地化

## 系统要求

- 越狱 iPhone（iOS 15+，scheme：**rootless** 或 **roothide**）
- 构建机上安装 Theos 工具链
- 运行时依赖（由 `control` 自动拉取）：

```
dpkg, dpkg-dev, gzip, zstd, git, openssh-client
```

可选依赖（存在时额外生成对应压缩索引）：`bzip2`、`xz`

## 构建

克隆仓库并把 `THEOS` 指向你的 Theos 安装路径。顶层 Makefile 会聚合 `repokit-helper` 和 `RepoKitApp`。

### rootless（默认）

```sh
export THEOS=/path/to/theos
make clean
make package
```

### roothide

```sh
export THEOS=/path/to/theos
make clean THEOS_PACKAGE_SCHEME=roothide
make package THEOS_PACKAGE_SCHEME=roothide
```

构建完成后 `.deb` 位于 `packages/`，传到设备安装后刷新图标：

```sh
uicache -a
```

> App 和 helper 始终以 `ARCHS=arm64` 编译，rootless / roothide 的区别仅体现在
> `.deb` 包元数据（`iphoneos-arm64` vs `iphoneos-arm64e`）。

## 项目结构

```
RepoKit/
├── Makefile                 # Theos 聚合构建入口
├── control                  # Debian 包元数据
├── RepoKitApp/              # UIKit 图形界面
│   ├── Makefile
│   ├── Info.plist
│   ├── Sources/             # main.m、AppDelegate、UI、helper client
│   └── Resources/           # Localizable.strings（en / zh-Hans）
├── repokit-helper/          # /usr/bin/repokit-helper 命令行工具
│   ├── Makefile
│   └── Sources/main.m
├── layout/DEBIAN/postinst   # 安装后脚本（数据目录 chown、.jbroot 链接）
├── screenshots/             # README 截图
└── .gitignore
```

生成目录（**不要提交**）：

```
.theos/      # Theos 缓存
packages/    # .deb 构建产物
repos/       # 运行时源数据（设备端路径 /var/mobile/RepoKit）
logs/        # 运行时日志
repo-trash/  # 软删除的源数据回收目录
```

## 工作原理

1. 在 App 中创建、导入或选择一个越狱源。
2. App 通过 `posix_spawn` 调用 `/usr/bin/repokit-helper`。
3. `repokit-helper` 读写 `repo.json`，把 `.deb` 复制到 `public/debs/`，
   运行 `dpkg-scanpackages` 生成索引，并写入 `Release`。
4. 点“推送 GitHub”时，helper 在 `public/` 目录执行
   `git init` / `git add` / `git commit` / `git push`，使用
   `/var/mobile/.ssh/id_ed25519` SSH 密钥。
5. 在 GitHub 仓库 Settings → Pages 将 `main` 分支 `/root` 目录开启，
   然后把 `https://<user>.github.io/<repo>/` 填进 Sileo / Zebra。

RepoKit 始终向用户暴露**逻辑路径**（`/var/mobile/RepoKit`、
`/usr/bin/repokit-helper`），内部通过 `jbroot(...)` 自动适配 rootless 与
roothide 的真实 preboot 路径，用户无需（也不应该）手动填写 `/var/jb` 或
`/private/preboot` 实际路径。

## Helper 命令行

App 里能做的一切都有对应 CLI：

```sh
repokit-helper init <repo-id> [options]
repokit-helper import-source <path> [options]
repokit-helper repo <repo-id>
repokit-helper repos
repokit-helper list <repo-id>
repokit-helper add <repo-id> <deb-path>
repokit-helper add-many <repo-id> <deb-path>
repokit-helper rescan <repo-id>
repokit-helper build <repo-id>
repokit-helper check <repo-id>
repokit-helper edit-deb <repo-id> <package> <version> [control options]
repokit-helper remove <repo-id> <package> <version> [--delete-file]
repokit-helper repo-edit <repo-id> [meta options]
repokit-helper github <repo-id> --remote <url> --branch <name> --user <u> --email <e>
repokit-helper push <repo-id> [--message "…"]
repokit-helper delete-repo <repo-id>
repokit-helper import-installed <repo-id> <package-id> [<package-id> ...]
repokit-helper import-all-installed <repo-id>
repokit-helper help
```

设备上运行 `repokit-helper help` 可查看完整选项。

## 设备首次配置

```sh
# 1. 生成 SSH 密钥（只需做一次）
mkdir -p /var/mobile/.ssh
ssh-keygen -t ed25519 -f /var/mobile/.ssh/id_ed25519 -C "you@example.com"

# 2. 把公钥加到 GitHub → Settings → SSH and GPG keys
cat /var/mobile/.ssh/id_ed25519.pub

# 3. 在 GitHub 创建公开仓库，RepoKit 里填写：
#    Remote : git@github.com:you/my-repo.git
#    Branch : main
#    User   : GitHub 用户名
#    Email  : Git 提交邮箱
```

## 许可证

MIT — 见 [LICENSE](LICENSE)。

## 作者

DaFei
