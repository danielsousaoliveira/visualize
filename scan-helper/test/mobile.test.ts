import { describe, expect, it } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createLocalReader } from "../src/scan/local-reader";
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

function mobileResult(): ScanResult {
  return {
    schemaVersion: 1, project: { name: "app", rootPath: "/app", gitBranch: null, type: "monorepo" },
    services: [{
      id: "backend", name: "Backend", kind: "app", rootDirectory: ".", stackId: "express", category: "backend",
      packageManager: "npm", installCommand: null, buildCommand: null, startCommand: null, port: 3000,
      hasDockerfile: false, devCommand: { argv: ["node", "server.js"], workingDirectory: ".", source: "script" },
      runModes: {
        local: { available: true, reason: null },
        compose: { available: false, reason: null, composeFile: null, serviceName: null },
        dockerfile: { available: false, reason: null, dockerfilePath: null, containerPort: null },
      },
    }],
    infra: [], connections: [], composeFiles: [], composeServices: [], envRequirements: [], warnings: [],
  };
}

function mobileReader(files: Record<string, string>) {
  return {
    listTree: async () => Object.keys(files).map((path) => ({ path, type: "file" })),
    readText: async (path: string, maxBytes?: number) => {
      const content = files[path];
      return content !== undefined && (maxBytes === undefined || Buffer.byteLength(content) <= maxBytes) ? content : undefined;
    },
    readJson: async () => undefined, listDirectory: async () => [],
  };
}

it("includes root-level iOS configuration without a dot prefix", async () => {
  const result = mobileResult();
  await detectMobileApps(mobileReader({
    "App.xcodeproj/project.pbxproj": "SDKROOT = iphoneos;",
    "Config.swift": 'let api = "http://localhost:3000"',
  }), result);
  expect(result.connections).toContainEqual({ from: "mobile:ios:App.xcodeproj", to: "backend", kind: "env-url", label: "Local API" });
});

it("preserves runnable services and distinct mobile identities in one directory", async () => {
  const result = mobileResult();
  const backend = structuredClone(result.services[0]!);
  const reader = mobileReader({
    "App.xcodeproj/project.pbxproj": "SDKROOT = iphoneos;",
    "Other.xcodeproj/project.pbxproj": "SDKROOT = iphoneos;",
    "build.gradle.kts": 'plugins { id("com.android.application") }',
  });
  await detectMobileApps(reader, result);
  await detectMobileApps(reader, result);
  expect(result.services).toHaveLength(4);
  expect(result.services.find((service) => service.id === "backend")).toEqual(backend);
  expect(new Set(result.services.map((service) => service.id)).size).toBe(4);
  expect(result.services.filter((service) => service.category === "mobile").map((service) => service.stackId).sort()).toEqual(["android", "ios", "ios"]);
});

it("reads Android main and debug sources without unrelated files or other modules", async () => {
  const result = mobileResult();
  const reader = mobileReader({
    "apps/mobile/build.gradle.kts": 'plugins { id("com.android.application") }',
    "apps/mobile/src/main/kotlin/example/Api.kt": 'val api = "http://10.0.2.2:3000"',
    "apps/mobile/src/debug/java/example/Api.java": 'String api = "http://localhost:3000";',
    "docs/Unrelated.kt": 'val api = "http://localhost:3000"',
    "other/src/main/kotlin/Api.kt": 'val api = "http://localhost:3000"',
  });
  const reads: string[] = [];
  const readText = reader.readText;
  reader.readText = async (path, maxBytes) => { reads.push(path); return readText(path, maxBytes); };
  await detectMobileApps(reader, result);
  expect(result.connections).toEqual([{ from: "mobile:android:apps/mobile", to: "backend", kind: "env-url", label: "Local API" }]);
  expect(reads).toContain("apps/mobile/src/main/kotlin/example/Api.kt");
  expect(reads).toContain("apps/mobile/src/debug/java/example/Api.java");
  expect(reads).not.toContain("docs/Unrelated.kt");
  expect(reads).not.toContain("other/src/main/kotlin/Api.kt");
});

it("bounds the Android source count and rejects oversized source files", async () => {
  const result = mobileResult();
  const files: Record<string, string> = { "build.gradle.kts": 'plugins { id("com.android.application") }' };
  for (let index = 0; index < 130; index += 1) files[`src/main/kotlin/Api${String(index).padStart(3, "0")}.kt`] = "x";
  files["src/main/kotlin/Api000.kt"] = 'val api = "http://localhost:3000"' + " ".repeat(65536);
  files["src/main/kotlin/Api129.kt"] = 'val api = "http://localhost:3000"';
  const reader = mobileReader(files);
  const reads: string[] = [];
  const readText = reader.readText;
  reader.readText = async (path, maxBytes) => {
    if (path.endsWith(".kt")) { reads.push(path); expect(maxBytes).toBe(65536); }
    return readText(path, maxBytes);
  };
  await detectMobileApps(reader, result);
  expect(reads).toHaveLength(128);
  expect(result.connections).toEqual([]);
});


it("collects Android sources through the filesystem reader and bounds actual reads", async () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "visualize-mobile-")));
  try {
    const files = {
      "android/build.gradle.kts": 'plugins { id("com.android.application") }',
      "android/src/main/kotlin/Api.kt": " ".repeat(65537),
      "android/src/debug/java/Api.java": 'String api = "http://localhost:3000";',
      "android/src/test/java/Test.java": 'String api = "http://localhost:3000";',
      "unrelated/Api.kt": 'val api = "http://localhost:3000"',
    };
    for (const [path, content] of Object.entries(files)) {
      mkdirSync(join(root, path, ".."), { recursive: true });
      writeFileSync(join(root, path), content);
    }
    const reader = createLocalReader(root);
    const paths = (await reader.listTree()).map(({ path }) => path);
    expect(paths).toContain("android/src/main/kotlin/Api.kt");
    expect(paths).toContain("android/src/debug/java/Api.java");
    expect(paths).not.toContain("android/src/test/java/Test.java");
    expect(paths).not.toContain("unrelated/Api.kt");
    expect(await reader.readText("android/src/main/kotlin/Api.kt", 65536)).toBeUndefined();
    const result = mobileResult();
    await detectMobileApps(reader, result);
    expect(result.connections).toEqual([{ from: "mobile:android:android", to: "backend", kind: "env-url", label: "Local API" }]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
