Build and open the app from the repository root:

```sh
pnpm dev
```

This requests a normal quit of any running visualize instance, builds a debug
bundle at `build/visualize.app`, and opens that exact bundle. If services are
running, resolve the app's quit dialog. Cancelling quit prevents the rebuild.

There is one app name and bundle ID, so settings and the project library are the
same when switching between builds. No JavaScript dependencies are needed for
the root package; pnpm only runs the build and launch scripts.

Build the release app:

```sh
pnpm build
```

The bundle uses `Resources/AppIcon.icns`, generated from `Resources/AppIcon.png`.
`scripts/build-app.sh` also builds the release bundle directly. Use `pnpm dev` for
the macOS app name, icon, and bundled scanner; `swift run` runs the executable
without bundle metadata.
