<p align="center">
  <img src="assets/devplusbar-icon.png" alt="" width="96" height="96" />
</p>

<h1 align="center">Dev+ Bar</h1>

<p align="center">
  Pull requests and issues people open on your GitHub repositories, in the macOS menu bar.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple" alt="macOS 14+" />
</p>

<p align="center">
  <img src="assets/panel.png" width="380" alt="The Dev+ Bar panel: tabs for reviews, pull requests and issues, each row with its author" />
</p>

## Install

```sh
curl -fsSL https://devplusbar.pages.dev/install.sh | sh
```

Or with Homebrew:

```sh
brew install --cask therbta/tap/devplusbar
```

Or download a packaged release from your internal distribution source and move
Dev+ Bar to Applications.

Needs macOS 14 or newer. The app is signed and notarized by Apple.

## Use

Open Dev+ Bar and sign in with GitHub. If the [GitHub CLI](https://cli.github.com) is signed in,
you can continue as that account instead.

Click the icon in the menu bar. The panel shows pull requests waiting for your review, pull
requests and issues other people opened on your repositories, issues assigned to you, and your
own open pull requests.
Green marks what you haven't seen yet.

| Key | |
| --- | --- |
| ↑ ↓, Return | Move between rows, open one on GitHub |
| ← → | Switch tabs |
| ⌘R | Refresh |
| ⌘, | Settings: organizations, hidden repositories, notifications, launch at login |

### Deployments (Vercel, Heroku)

Settings › Deployments connects a Vercel token and/or a Heroku API key. The panel then gets a
**Deploys** side: a card per deployment (live build timer, failure line from the build log, links
to the site, logs and pull request), a production strip per project, and **Insights** charts —
deploys per day, build time (median and p95), success rate, recovery time, preview-to-production
lead time and busiest hours. Pull request rows show a chip with their latest deployment.
Notifications, the menu bar box and sounds follow per-event rules you choose. Redeploy and
roll back are available from a card's menu once you turn them on; each asks first.

Each production branch's GitHub Actions are watched too. A project whose latest decisive run
failed gets a red **CI ✗** on its production pill and a row you can open to see the failed
step's last lines, open the run, or copy a prompt for a coding agent. Cancelled runs and
Dependabot jobs don't count.

### Local work

The **Local** side lists the git repositories on this Mac with commits that aren't on GitHub
yet: unpushed commits, and branches that were never pushed. Repositories that only have
uncommitted edits are folded under one line. A repository that deploys shows its production
state, waiting commits and CI on the same row. Below that are the processes listening on a
port (Vite, Next, Astro, PHP, databases), each with its project folder and memory use. A dev
server has a **Stop** button, which asks before it sends SIGTERM. Dev+ Bar runs only `git status`
(without touching the index), `lsof` and `ps`, and never fetches. Settings › General chooses
the folders to scan.

Dev+ Bar polls every 15 seconds while something builds, otherwise at the refresh interval. For
instant updates you can host the optional webhook relay in [`Relay/`](Relay/README.md).

Dev+ Bar talks only to GitHub, and to Vercel and Heroku if you connect them, with your own tokens
kept in the macOS Keychain. It has no server and no analytics.

## Update or remove

Run the install command again to update, or `brew upgrade --cask devplusbar`.
To remove Dev+ Bar, quit it and move it to the Trash, or run `brew uninstall --cask devplusbar`.

## Build from source

```sh
make install
```

## Release policy and checklist

Default release path (required for normal releases):

```sh
make preflight-release
make release
make publish
```

The `make preflight-release` guard must pass before any strict release is allowed.

Before running the strict path, ensure:
1. Developer ID signing identity is available in Keychain.
2. Notary credentials are configured for `xcrun notarytool` (`NOTARY_PROFILE` or API key vars).
3. `spctl` verification passes during publish.

Emergency fallback path (use only when strict signing/notary is temporarily unavailable):

```sh
make release SKIP_NOTARIZE=1
make publish ALLOW_UNNOTARIZED_PUBLISH=1
```

Do not use fallback flags as default release policy.
