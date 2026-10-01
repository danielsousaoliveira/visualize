import { readdir, readFile, realpath } from "node:fs/promises";
import { join, sep } from "node:path";
import { isIgnoredRepoPath, type RepoTreeEntry } from "../engine/project-root-detector";
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

async function listLocalTree(root: string): Promise<RepoTreeEntry[]> {
  const tree: RepoTreeEntry[] = [];

  const visit = async (absolutePath: string, relativePath = "") => {
    const entries = await readdir(absolutePath, { withFileTypes: true });

    for (const entry of entries) {
      const nextRelativePath = relativePath ? `${relativePath}/${entry.name}` : entry.name;
      if (entry.isDirectory() && isIgnoredRepoPath(nextRelativePath)) {
        continue;
      }

      tree.push({ path: nextRelativePath, type: entry.isDirectory() ? "dir" : "file" });
      if (entry.isDirectory()) {
        await visit(join(absolutePath, entry.name), nextRelativePath);
      }
    }
  };

  await visit(root);
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
