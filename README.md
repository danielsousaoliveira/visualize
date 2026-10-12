<div align="center">
  <img src="Resources/AppIcon.png" width="112" alt="visualize app icon">
  <h1>visualize</h1>
  <p>Your local projects, services, and ports in one macOS app.</p>
  <p>
    <img src="https://img.shields.io/badge/macOS-14%2B-111827?style=flat-square&logo=apple&logoColor=white" alt="macOS 14 or later">
    <img src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6">
    <img src="https://img.shields.io/badge/UI-SwiftUI-2563EB?style=flat-square" alt="Built with SwiftUI">
    <img src="https://img.shields.io/badge/status-in%20development-64748B?style=flat-square" alt="In development">
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-16A34A?style=flat-square" alt="MIT license"></a>
  </p>
  <p>
    <a href="#getting-started">Getting started</a> ·
    <a href="#using-visualize">Usage</a> ·
    <a href="#development">Development</a> ·
    <a href="https://github.com/danielsousaoliveira/visualize/issues">Report a bug</a>
  </p>
</div>

Add a repository folder to see its services, detected stack, run commands, and infrastructure. Start services locally or in Docker, read their logs, and see which processes own the listening ports. A menu bar popover keeps the running services within reach while you work.

visualize is built with SwiftUI and AppKit. The repository scanner runs as a separate, bundled Bun executable.

## What you can do

| Feature              | Details                                                                                                                                |
| :------------------- | :------------------------------------------------------------------------------------------------------------------------------------- |
| Project library      | Add local folders, rescan projects, and locate folders after they move.                                                                |
| Repository analysis  | Detect services, frameworks, workspace layouts, environment requirements, Dockerfiles, and Compose configuration.                      |
| Service controls     | Choose Local, Compose, or Dockerfile mode per service. Start the project as configured, all locally, or all in Docker where supported. |
| Listening ports      | See user-owned TCP listeners, project attribution, working directories, Git branches, CPU, and memory when available.                  |
| Service graph        | Inspect detected connections between services and infrastructure. Select a service to open its logs.                                   |
| Logs                 | Read stdout and stderr in the app, with rotating files and configurable retention per service.                                         |
| Menu bar             | Check listeners and control running services without opening the main window.                                                          |
| Production branches  | Review remote commits and update a production branch to the reviewed main commit.                                                      |
| Database connections | Discover, save, and test read-only Postgres and SQLite connections. Postgres passwords are stored in macOS Keychain.                   |

Detection depends on the files in each repository. An available run mode means the scanner found a command or configuration; the project still needs its own dependencies, environment, and runtime installed.

## Getting started

### Requirements

- macOS 14 or later.
- Swift 6 or later and Apple's Command Line Tools. A full Xcode installation is optional.
- Bun to install scanner dependencies and compile the bundled helper.
- pnpm to run the development and packaging commands.
- Git to clone the repository and use production branch updates.
- Docker with a running daemon and the Compose plugin if you want Docker run modes.

Install Apple's Command Line Tools if needed:

```sh
xcode-select --install
```

Then clone and launch:

```sh
git clone https://github.com/danielsousaoliveira/visualize.git
cd visualize
pnpm dev
```

`pnpm dev` requests a normal quit of the running app, builds a debug bundle at `build/visualize.app`, and opens it. If services are running, resolve the quit dialog before the build can continue. Cancelling quit cancels the rebuild.

The build script installs the scanner's dependencies. The root package uses pnpm only to run scripts, so it does not need a separate `pnpm install`.

The first bundled build also downloads checksum-verified PostgreSQL source and builds the static client library. Later builds reuse it from `build/`. Both debug and release bundles include that library and the scanner.

### Build a release bundle

```sh
pnpm build
open build/visualize.app
```

The script signs the app with hardened runtime. It uses `VISUALIZE_SIGNING_IDENTITY` when set, otherwise the first Developer ID Application identity in the keychain, otherwise an ad-hoc signature. It verifies the signature before finishing. Packaging does not notarize the app.

```sh
VISUALIZE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" pnpm build
```

## Using visualize

1. Choose **Add project** and select a repository folder.
2. Review the detected services, commands, environment requirements, and scan warnings.
3. Choose a run mode for each service, or use the project controls to start multiple services. Review the command confirmation before a new local command runs.
4. Open a service's logs to inspect its output. Switch to **Graph** to see detected connections.
5. Open **Listening ports** or the menu bar popover to see what is running and which project it belongs to.

Removing a project from the library leaves its folder and files on disk. Use **Locate** if a folder has moved, or **Rescan** after changing the project configuration.

| Shortcut | Action                      |
| :------- | :-------------------------- |
| `⌘O`     | Add a project               |
| `⌘R`     | Rescan the selected project |
| `⌘,`     | Open settings               |
| `⌘Q`     | Quit                        |

Settings include launch at login, the port scan interval and range, log retention, and a Docker CLI path override. Coding agent listeners can be included through **View > Show coding agents**.

### Push to production

Open **Push to production**, choose the remote and branch names, then select **Fetch and review**. visualize detects `main` or `master` and `production` or `prod` when the branch fields are empty.

The review lists commits arriving in production and commits production has that main lacks. A normal update uses a regular push. Creating a production branch or replacing divergent production history requires typing its name and uses an explicit `--force-with-lease` against the reviewed remote state. The final confirmation shows the intended update.

The push uses the reviewed remote main commit. Your working files stay in place, and a local production branch checked out in a worktree stays unchanged. Git authentication uses your existing setup; the app disables interactive terminal prompts.

### Local databases

Use **Connect** to choose a detected connection or enter one manually. SQLite opens read-only. Postgres requires a dedicated reader role and rejects connections with write or administrative privileges. Credentials detected from a project's configuration may need to be replaced with reader credentials.

See [Postgres reader credentials](docs/postgres-read-only.md) for the required grants and checks. The current interface manages connections; a table browser and query editor are not yet available.

## Detection coverage

The scanner reads manifests and configuration for JavaScript and TypeScript, Python, Go, Rust, Ruby, PHP, Java, Elixir, and Docker projects. Workspace detection includes npm, pnpm, Rush, Cargo, Go, uv, Elixir umbrella apps, Maven, Gradle, and .NET solutions.

Dockerfile and Compose detection also covers infrastructure such as databases and caches. Environment analysis reports variable names, missing requirements, and connection host/port information without putting raw environment values into scan output.

## Local data and process controls

visualize has no telemetry, analytics, crash reporting, or automatic update checks. Repository scanning reads local files. Git fetches and pushes, database connections, and projects you start perform the network operations needed for those actions.

The app runs as your user and never requests administrator privileges. Restart controls are restricted to processes and containers started by visualize. Stopping an external listener requires confirmation and identity checks; desktop and system processes are excluded.

The bundled app stores its project library and logs under:

```text
~/Library/Application Support/com.danielsousaoliveira.visualize/
```

Settings use macOS preferences. Database passwords use Keychain. Service logs contain the output produced by your services, so check them for credentials or private data before sharing them.

## Development

| Command                        | Purpose                                                      |
| :----------------------------- | :----------------------------------------------------------- |
| `pnpm dev`                     | Quit normally, build the debug app bundle, and launch it     |
| `swift build`                  | Compile the Swift executable without packaging the app       |
| `pnpm build`                   | Package and sign the release app                             |
| `scripts/build-app.sh --debug` | Package the debug app without launching it                   |
| `scripts/test.sh`              | Run the Swift and scanner test suites                        |
| `scripts/test-databases.sh`    | Run Postgres connection tests with a temporary local cluster |

Use the bundled app for normal development. `swift build` alone does not package the scanner or app metadata. There is one app identity for both debug and release builds, so they share settings and the project library.

For scanner development:

```sh
cd scan-helper
bun install --frozen-lockfile
bun run typecheck
bun test
bun run src/cli.ts /path/to/project
```

The database integration script needs a local PostgreSQL installation. Set `VISUALIZE_POSTGRES_BIN` to its `bin` directory if auto-detection cannot find it. See [the reader credentials guide](docs/postgres-read-only.md) for integration options and [development notes](docs/development.md) for the build workflow.

### Repository layout

```text
Sources/Visualize/      SwiftUI views, app state, scanning, and service controls
Sources/DatabaseDriver/ C bridge for SQLite and Postgres
Resources/             App icon, bundle metadata, and helper entitlements
scan-helper/           Bun/TypeScript scanner, fixtures, and contract tests
Tests/VisualizeTests/   Swift tests
scripts/               Development, packaging, and test scripts
docs/                  Development and database setup notes
```

### Troubleshooting

| Symptom                        | Check                                                                                                                                       |
| :----------------------------- | :------------------------------------------------------------------------------------------------------------------------------------------ |
| Scanner helper is missing      | Launch `build/visualize.app` after `pnpm dev` or `pnpm build`.                                                                              |
| Docker mode is unavailable     | Start the Docker daemon, check the Compose plugin, and refresh with **View > Check Docker status**. Set the CLI path in settings if needed. |
| A service fails to start       | Read its logs, install its project dependencies, and check the detected command and environment requirements.                               |
| A port is already in use       | Review the owner in the port conflict dialog before deciding whether to stop it.                                                            |
| Postgres rejects a connection  | Use a dedicated reader role and review [the privilege requirements](docs/postgres-read-only.md).                                            |
| Launch at login needs approval | Allow visualize in **System Settings > General > Login Items**.                                                                             |

## Contributing

Bug reports and pull requests are welcome. For larger changes, open an issue first to discuss the scope.

When reporting a bug, include your macOS version, the build or commit, steps to reproduce, and what you expected to happen. Remove private data from logs and screenshots. For detection issues, attach a small sample repository that reproduces the problem. Screenshots are useful for visual bugs when you can share them safely.

To contribute a change:

1. Fork the repository and create a branch for your change.
2. Use `pnpm dev` to build and run the bundled app.
3. Run `scripts/test.sh` for code changes. For scanner changes, also run `bun run typecheck` inside `scan-helper` and add a fixture for new detection behavior.
4. Verify UI changes in the running app, including the menu bar and keyboard shortcuts where relevant.
5. Open a pull request describing the problem, the change, and how you checked it.

Keep changes focused. Swift code uses one type per file, named after the type. Preserve the app's local-data boundaries and process ownership checks, and avoid adding telemetry or background network requests.

## License and credits

visualize is licensed under the [MIT license](LICENSE), except for components with their own license notices. The scanner retains its [Apache 2.0 license](scan-helper/LICENSE). Bundled PostgreSQL code retains the PostgreSQL license, copied into the app as `PostgreSQL-LICENSE.txt` during packaging.

Repository detection borrows ideas from [openship](https://github.com/oblien/openship). Technology icons come from [Simple Icons](https://github.com/simple-icons/simple-icons) under [CC0](Sources/Visualize/Icons/LICENSE.md); see the [icon notice](Sources/Visualize/Icons/NOTICE.md) for attribution and brand ownership.
