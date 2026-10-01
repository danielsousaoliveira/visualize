import { lstat, readdir, readFile, realpath } from "node:fs/promises";
import { join, sep } from "node:path";
import {
  DISCOVERED_ROOT_MARKERS,
  isIgnoredRepoPath,
  type RepoTreeEntry,
} from "../engine/project-root-detector";
import type { RepoFile } from "../engine/stack-detector";

export interface ProjectReader {
  listDirectory: (path: string) => Promise<RepoFile[]>;
  readText: (path: string) => Promise<string | undefined>;
  readJson: (path: string) => Promise<Record<string, unknown> | undefined>;
  listTree: () => Promise<RepoTreeEntry[]>;
}

function isInside(root: string, candidate: string): boolean {
  return candidate === root || candidate.startsWith(root + sep);
}

export const MAX_TREE_DIRECTORIES = 10_000;

async function isContainedDirectory(root: string, absolutePath: string): Promise<boolean> {
  const stats = await lstat(absolutePath);
  if (!stats.isDirectory()) return false;
  return isInside(root, await realpath(absolutePath));
}

function isTreeFileNeeded(relativePath: string, name: string): boolean {
  return relativePath === "" || DISCOVERED_ROOT_MARKERS.has(name.toLowerCase());
}

export async function listLocalTree(
  root: string,
  maxDirectories = MAX_TREE_DIRECTORIES,
): Promise<RepoTreeEntry[]> {
  const tree: RepoTreeEntry[] = [];
  const directories = [""];
  const realRoot = await realpath(root);

  for (let cursor = 0; cursor < directories.length; cursor += 1) {
    const relativePath = directories[cursor]!;
    const absolutePath = relativePath ? join(realRoot, relativePath) : realRoot;

    let entries;
    try {
      if (!(await isContainedDirectory(realRoot, absolutePath))) continue;
      entries = await readdir(absolutePath, { withFileTypes: true });
    } catch {
      continue;
    }

    for (const entry of entries) {
      const nextRelativePath = relativePath ? `${relativePath}/${entry.name}` : entry.name;
      if (entry.isDirectory()) {
        if (directories.length < maxDirectories && !isIgnoredRepoPath(nextRelativePath)) {
          directories.push(nextRelativePath);
        }
      } else if (isTreeFileNeeded(relativePath, entry.name)) {
        tree.push({ path: nextRelativePath, type: "file" });
      }
    }
  }

  return tree;
}

export function createLocalReader(root: string): ProjectReader {
  let treePromise: Promise<RepoTreeEntry[]> | null = null;

  const resolveInside = async (path: string): Promise<string | undefined> => {
    if (path.split("/").includes("..")) return undefined;
    const resolved = await realpath(path ? join(root, path) : root);
    return isInside(root, resolved) ? resolved : undefined;
  };

  const readText = async (path: string) => {
    try {
      const resolved = await resolveInside(path);
      return resolved ? await readFile(resolved, "utf-8") : undefined;
    } catch {
      return undefined;
    }
  };

  return {
    listDirectory: async (path: string) => {
      try {
        const resolved = await resolveInside(path);
        if (!resolved) return [];
        const entries = await readdir(resolved, { withFileTypes: true });
        return entries.map((entry) => ({
          name: entry.name,
          type: entry.isDirectory() ? "dir" : "file",
        }));
      } catch {
        return [];
      }
    },
    readText,
    readJson: async (path: string) => {
      const content = await readText(path);
      if (!content) return undefined;
      try {
        return JSON.parse(content);
      } catch {
        return undefined;
      }
    },
    listTree: async () => {
      if (!treePromise) {
        treePromise = listLocalTree(root);
      }
      return treePromise;
    },
  };
}
