import { readFile, stat } from "node:fs/promises";
import { join, resolve } from "node:path";

const BRANCH_REF = /^ref:\s*refs\/heads\/(.+)$/;
const GITDIR_POINTER = /^gitdir:\s*(.+)$/;

async function gitDirectory(root: string): Promise<string | undefined> {
  const dotGit = join(root, ".git");
  const stats = await stat(dotGit);
  if (stats.isDirectory()) return dotGit;
  const pointer = (await readFile(dotGit, "utf-8")).trim().match(GITDIR_POINTER);
  return pointer ? resolve(root, pointer[1]!.trim()) : undefined;
}

export async function readGitBranch(root: string): Promise<string | undefined> {
  try {
    const directory = await gitDirectory(root);
    if (!directory) return undefined;
    const head = (await readFile(join(directory, "HEAD"), "utf-8")).trim();
    return head.match(BRANCH_REF)?.[1];
  } catch {
    return undefined;
  }
}
