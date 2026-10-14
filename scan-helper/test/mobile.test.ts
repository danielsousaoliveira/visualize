import { describe, expect, it } from "bun:test";
import { hasAndroidApplicationPlugin } from "../src/scan/android-plugins";
import { detectMobileApps } from "../src/scan/mobile";
import type { ScanResult } from "../src/scan/contract";

describe("Android application plugins", () => {
  it.each([
    'plugins { id("com.android.application") }',
    "plugins { id 'com.android.application' }",
    'plugins { alias(libs.plugins.android.application) }',
    'plugins { id("com.android.library"); id("com.android.application") version "8.0" }',
  ])("recognizes %s", (content) => expect(hasAndroidApplicationPlugin(content)).toBe(true));

  it.each([
    '// plugins { id("com.android.application") }',
    '/* plugins { id("com.android.application") } */',
    'val example = "plugins { id(\\"com.android.application\\") }"',
    'plugins { id("com.android.library") }',
    'plugins { id("com.android.application") version "8.0" apply false }',
    'plugins { alias(libs.plugins.android.application)\n apply(false) }',
    'val plugin = "com.android.application"\nplugins { id("com.android.library") }',
  ])("ignores %s", (content) => expect(hasAndroidApplicationPlugin(content)).toBe(false));
});

it("keeps nested iOS projects in their containing directories", async () => {
  const files: Record<string, string> = {
    "apps/ios/App.xcodeproj/project.pbxproj": "SDKROOT = iphoneos;",
    "apps/ios/App/Info.plist": "http://localhost:3000",
    "apps/other/Other.xcodeproj/project.pbxproj": "IPHONEOS_DEPLOYMENT_TARGET = 18;",
    "apps/other/Other/Info.plist": "http://localhost:4000",
  };
  const result: ScanResult = {
    schemaVersion: 1, project: { name: "mobile", rootPath: "/mobile", gitBranch: null, type: "monorepo" },
    services: [], infra: [], connections: [], composeFiles: [], composeServices: [], envRequirements: [], warnings: [],
  };
  await detectMobileApps({
    listTree: async () => Object.keys(files).map((path) => ({ path, type: "file" })),
    readText: async (path) => files[path], readJson: async () => undefined, listDirectory: async () => [],
  }, result);
  expect(result.services.map((service) => service.rootDirectory)).toEqual(["apps/ios", "apps/other"]);
  expect(result.services.map((service) => service.name)).toEqual(["apps/ios (iOS)", "apps/other (iOS)"]);
});
