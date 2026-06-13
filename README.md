# RepoKit

RepoKit is a *local* jailbreak repository manager that runs directly on your
jailbroken iPhone. It ships a UIKit app and a companion command-line helper so
you can create, import, edit, index and publish a Cydia/Sileo/Zebra repository
*without* a Mac.

![RepoKit](screenshots/app-preview.png)

## Features

- Create a brand-new local repository with one tap
- Import an existing repository folder
- Import a single `.deb` file or rebuild a `.deb` from an already-installed
  package via `dpkg`
- Edit any `DEBIAN/control` field and the package icon from the app
- Generate `Packages`, `Packages.gz`, `Packages.zst`, `Packages.bz2` and
  `Packages.xz` with `dpkg-scanpackages`
- Generate the `Release` file with MD5 / SHA256 checksums
- Lint your repository for duplicate versions, missing fields, architecture
  mismatches and orphan `.deb` files
- Configure a GitHub remote / branch / SSH user and push straight to GitHub
  Pages
- Full Chinese and English localization

## Requirements

- A jailbroken iPhone (iOS 15+, scheme: **rootless** or **roothide**)
- Theos toolchain on your build machine
- Runtime dependencies (pulled from the `control` file):

```
dpkg, dpkg-dev, gzip, zstd, git, openssh-client
```

Optional (if present RepoKit will also generate those indexes):
`bzip2`, `xz`

## Building

Clone the repo and point `THEOS` at your Theos installation. The top-level
Makefile aggregates `repokit-helper` and `RepoKitApp`.

### rootless (default)

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

After the build you will find the `.deb` under `packages/`. Install it on
device, then refresh the icon cache:

```sh
uicache -a
```

> App and helper are always built with `ARCHS=arm64`. The package
> architecture differs only in the `.deb` metadata (`iphoneos-arm64` for
> rootless, `iphoneos-arm64e` for roothide).

## Project Layout

```
RepoKit/
├── Makefile                 # Theos aggregate entry
├── control                  # Debian package metadata
├── RepoKitApp/              # UIKit app
│   ├── Makefile
│   ├── Info.plist
│   ├── Sources/             # main.m, AppDelegate, UI, helper client
│   └── Resources/           # Localizable.strings (en / zh-Hans)
├── repokit-helper/          # /usr/bin/repokit-helper command-line tool
│   ├── Makefile
│   └── Sources/main.m
├── layout/DEBIAN/postinst   # Post-install script (chowns data dir, links .jbroot)
├── screenshots/             # README screenshot
└── .gitignore
```

Generated folders (do **not** commit them):

```
.theos/      # Theos caches
packages/    # .deb build output
repos/       # Runtime repository data (lives on device at /var/mobile/RepoKit)
logs/        # Runtime logs
repo-trash/  # Soft-deleted repository data
```

## How It Works

1. You create, import or pick a repository from the app.
2. The app shells out to `/usr/bin/repokit-helper`.
3. `repokit-helper` reads/writes `repo.json`, copies `.deb`s into
   `public/debs/`, runs `dpkg-scanpackages`, writes the index files and
   generates `Release`.
4. When you hit *Push GitHub*, the helper runs `git init`, `git add`,
   `git commit` and `git push` from inside `public/` using
   `/var/mobile/.ssh/id_ed25519`.
5. Enable GitHub Pages on `main` → `/root`, then add
   `https://<user>.github.io/<repo>/` in Sileo / Zebra.

RepoKit exposes *logical paths* only (`/var/mobile/RepoKit`,
`/usr/bin/repokit-helper`). Internally every path goes through
`jbroot(...)`, so you never need to type a `/var/jb` or preboot path.

## Helper CLI

Everything the app does can also be driven from the command line:

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

Run `repokit-helper help` on device for the full option list.

## First-time Setup on Device

```sh
# 1. Generate an SSH key (do this once)
mkdir -p /var/mobile/.ssh
ssh-keygen -t ed25519 -f /var/mobile/.ssh/id_ed25519 -C "you@example.com"

# 2. Copy the public key to GitHub → Settings → SSH and GPG keys
cat /var/mobile/.ssh/id_ed25519.pub

# 3. Create a public repo on GitHub, then configure in RepoKit:
#    Remote : git@github.com:you/my-repo.git
#    Branch : main
#    User   : your GitHub username
#    Email  : your Git commit email
```

## License

MIT — see [LICENSE](LICENSE).

## Author

DaFei
