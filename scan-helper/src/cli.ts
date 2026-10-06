#!/usr/bin/env bun
import { resolve } from "node:path";
import { scanFolder } from "./scan/scan-folder";

const USAGE = "usage: visualize-scan <folder>";

function describeError(error: unknown, folder: string): string {
  const code = (error as NodeJS.ErrnoException | undefined)?.code;
  if (code === "ENOENT") return `No such folder: ${folder}`;
  if (code === "EACCES" || code === "EPERM") return `Permission denied: ${folder}`;
  if (error instanceof Error && error.message === "Path is not a directory") {
    return `Not a folder: ${folder}`;
  }
  return error instanceof Error ? error.message : String(error);
}

async function main(args: string[]): Promise<number> {
  if (args.length !== 1 || args[0] === "-h" || args[0] === "--help") {
    process.stderr.write(`${USAGE}\n`);
    return args.length === 1 ? 0 : 2;
  }

  const folder = resolve(args[0]!);
  try {
    process.stdout.write(`${JSON.stringify(await scanFolder(folder), null, 2)}\n`);
    return 0;
  } catch (error) {
    process.stderr.write(`visualize-scan: ${describeError(error, folder)}\n`);
    return 1;
  }
}

process.exitCode = await main(process.argv.slice(2));
