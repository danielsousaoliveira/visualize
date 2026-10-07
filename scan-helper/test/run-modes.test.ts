import { afterAll, describe, expect, it } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { exposedPort } from "../src/scan/run-modes";
import { scanFolder } from "../src/scan/scan-folder";

const workspace = mkdtempSync(join(tmpdir(), "visualize-modes-"));
afterAll(() => rmSync(workspace, { recursive: true, force: true }));

function folder(name: string, files: Record<string, string>): string {
  const root = join(workspace, name);
  for (const [path, content] of Object.entries(files)) {
    mkdirSync(join(root, path, ".."), { recursive: true });
    writeFileSync(join(root, path), content);
  }
  return root;
}

const node = '{"name":"api","scripts":{"dev":"node index.js"}}';

describe("service run modes", () => {
  it("reports a local Node service without a Dockerfile", async () => {
    const result = await scanFolder(join(import.meta.dir, "../fixtures/scan/node-dev"));
    const modes = result.services[0]!.runModes;
    expect(modes.local).toEqual({ available: true, reason: null });
    expect(modes.dockerfile).toEqual({ available: false, reason: "no Dockerfile in service root", dockerfilePath: null, containerPort: null });
    expect(modes.compose.available).toBe(false);
    expect(modes.compose.reason).toBeTruthy();
  });

  it("reports all three choices for a compose build and compose only for an image", async () => {
    const result = await scanFolder(join(import.meta.dir, "../fixtures/scan/run-modes"));
    const api = result.services.find((service) => service.rootDirectory === "apps/api")!;
    expect(api.runModes.local.available).toBe(true);
    expect(api.runModes.compose).toEqual({ available: true, reason: null, composeFile: "compose.yaml", serviceName: "api" });
    expect(api.runModes.dockerfile).toEqual({ available: true, reason: null, dockerfilePath: "apps/api/Dockerfile", containerPort: 8080 });
    const db = result.services.find((service) => service.name === "db")!;
    expect(db.runModes.compose.available).toBe(true);
    expect(db.runModes.local).toEqual({ available: false, reason: "no dev command detected" });
    expect(db.runModes.dockerfile.available).toBe(false);
  });

  it("keeps an app alongside image services and associates its compose build", async () => {
    const root = folder("app-compose", {
      "package.json": '{"name":"api","scripts":{"dev":"node index.js"},"dependencies":{"express":"^4"}}',
      "Dockerfile": "FROM node:22\nEXPOSE 8080\n",
      "compose.yaml": "services:\n  api:\n    build: .\n  db:\n    image: postgres:16\n",
    });
    const result = await scanFolder(root);
    expect(result.services.map((service) => service.id)).toEqual([".", "compose:db"]);
    expect(result.services[0]!.runModes.compose.serviceName).toBe("api");
    expect(result.services[0]!.runModes.local.available).toBe(true);
    expect(result.services[1]!.runModes.dockerfile.available).toBe(false);
  });

  it("uses the detected port when EXPOSE has no literal port", async () => {
    const result = await scanFolder(folder("fallback", { "package.json": node, "Dockerfile": "FROM node:22\nEXPOSE $PORT\n" }));
    expect(result.services[0]!.runModes.dockerfile.containerPort).toBe(result.services[0]!.port);
  });

  it("reports the custom compose Dockerfile and its exposed port", async () => {
    const result = await scanFolder(folder("custom", {
      "compose.yaml": "services:\n  api:\n    build:\n      context: ./api\n      dockerfile: Dockerfile.dev\n",
      "api/package.json": node,
      "api/Dockerfile.dev": "FROM node:22\nEXPOSE 9000\n",
    }));
    expect(result.services[0]!.hasDockerfile).toBe(true);
    expect(result.services[0]!.runModes.compose.available).toBe(true);
    expect(result.services[0]!.runModes.dockerfile).toEqual({
      available: true,
      reason: null,
      dockerfilePath: "api/Dockerfile.dev",
      containerPort: 9000,
    });
  });

  it("uses the custom Dockerfile for an app matched to a compose build", async () => {
    const result = await scanFolder(folder("custom-app", {
      "package.json": '{"name":"api","scripts":{"dev":"node index.js"},"dependencies":{"express":"^4"}}',
      "compose.yaml": "services:\n  api:\n    build:\n      context: .\n      dockerfile: docker/Dockerfile.dev\n",
      "Dockerfile": "FROM node:22\nEXPOSE 8080\n",
      "docker/Dockerfile.dev": "FROM node:22\nEXPOSE 9000\n",
    }));
    expect(result.services[0]!.id).toBe(".");
    expect(result.services[0]!.runModes.dockerfile.dockerfilePath).toBe("docker/Dockerfile.dev");
    expect(result.services[0]!.runModes.dockerfile.containerPort).toBe(9000);
  });

  it("does not read a custom Dockerfile symlink outside the project", async () => {
    const outside = folder("custom-outside", { "Dockerfile": "FROM node:22\nEXPOSE 9876\n" });
    const root = folder("custom-linked", {
      "compose.yaml": "services:\n  api:\n    build:\n      context: ./api\n      dockerfile: Dockerfile.dev\n",
      "api/package.json": node,
    });
    symlinkSync(join(outside, "Dockerfile"), join(root, "api/Dockerfile.dev"));
    const result = await scanFolder(root);
    expect(result.services[0]!.runModes.dockerfile.available).toBe(false);
  });

  it.each(["../outside"])("does not borrow a root Dockerfile for context %s", async (context) => {
    const result = await scanFolder(folder("context-" + context.replace(/[^a-z]/g, ""), {
      "compose.yaml": `services:\n  api:\n    build: ${context}\n`,
      "Dockerfile": "FROM node:22\nEXPOSE 8080\n",
    }));
    const api = result.services.find((service) => service.name === "api")!;
    expect(api.runModes.compose.available).toBe(true);
    expect(api.runModes.dockerfile.available).toBe(false);
  });

  it.each(["https://example.com/repo.git", "/outside"])("keeps unsupported context %s blocked", async (context) => {
    const root = folder("blocked-" + context.replace(/[^a-z]/g, ""), {
      "compose.yaml": `services:\n  api:\n    build: ${context}\n`,
      "Dockerfile": "FROM node:22\nEXPOSE 8080\n",
    });
    await expect(scanFolder(root)).rejects.toThrow("can't be run faithfully");
  });

  it("does not read a Dockerfile symlink outside the project", async () => {
    const outside = folder("outside", { "Dockerfile": "FROM node:22\nEXPOSE 9876\n" });
    const root = folder("linked", { "package.json": node });
    symlinkSync(join(outside, "Dockerfile"), join(root, "Dockerfile"));
    const result = await scanFolder(root);
    expect(result.services[0]!.runModes.dockerfile.available).toBe(false);
  });
});

describe("Dockerfile container ports", () => {
  it.each([
    ["EXPOSE 8080", 8080],
    ["  expose 53/udp 80/tcp", 53],
    ["# EXPOSE 9000\nEXPOSE 0 65536 8080", 8080],
    ["FROM node AS build\nEXPOSE 9000\nFROM nginx\nEXPOSE 80", 80],
    ["FROM node AS build\nEXPOSE 9000\nFROM nginx", null],
    ["EXPOSE $PORT", null],
    ["EXPOSE 1", 1],
  ])("reads %s", (content, expected) => {
    expect(exposedPort(content)).toBe(expected);
  });
});
