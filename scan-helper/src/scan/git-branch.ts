import { lstat, readFile, realpath } from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";

const BRANCH_REF = /^ref: refs\/heads\/([A-Za-z0-9._\/-]{1,255})$/;
const GITDIR_POINTER = /^gitdir: (.+)$/;
const MAX_METADATA_BYTES = 4096;

async function readSmallRegularFile(path: string): Promise<string | undefined> {
  const stats = await lstat(path);
  if (!stats.isFile() || stats.size > MAX_METADATA_BYTES) return undefined;
  return (await readFile(path, "utf-8")).trim();
}

async function isLinkedWorktree(gitDirectory: string, dotGit: string): Promise<boolean> {
  if (basename(dirname(gitDirectory)) !== "worktrees") return false;
  const backLink = await readSmallRegularFile(join(gitDirectory, "gitdir"));
  if (!backLink) return false;
  return (await realpath(resolve(gitDirectory, backLink))) === (await realpath(dotGit));
}

async function gitDirectory(root: string): Promise<string | undefined> {
  const dotGit = join(root, ".git");
  const stats = await lstat(dotGit);
  if (stats.isDirectory()) return dotGit;
  const pointer = (await readSmallRegularFile(dotGit))?.match(GITDIR_POINTER);
  if (!pointer) return undefined;
  const target = await realpath(resolve(root, pointer[1]!));
  return (await isLinkedWorktree(target, dotGit)) ? target : undefined;
}

function isSafeBranchName(name: string): boolean {
  return !name.includes("..") && !name.startsWith("/") && !name.endsWith("/");
}

export async function readGitBranch(root: string): Promise<string | undefined> {
  try {
    const directory = await gitDirectory(root);
    if (!directory) return undefined;
    const branch = (await readSmallRegularFile(join(directory, "HEAD")))?.match(BRANCH_REF)?.[1];
    return branch && isSafeBranchName(branch) ? branch : undefined;
  } catch {
    return undefined;
  }
}
