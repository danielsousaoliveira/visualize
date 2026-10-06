import { STACKS, type StackDefinition, type StackId } from "../core";
import { shellSplitWords } from "../core/shell-split";
import type { ScanDevCommand } from "./contract";

export interface DevCommandInput {
  stackId: StackId;
  packageManager: string | null;
  scripts: Record<string, unknown>;
  startCommand: string | null;
  port: number | null;
  workingDirectory: string;
}

export type DevCommandResult =
  | { devCommand: ScanDevCommand; problem?: undefined }
  | { devCommand: null; problem: string };

const JS_LANGUAGES = new Set(["javascript", "typescript"]);
const JS_PACKAGE_MANAGERS = new Set(["npm", "pnpm", "yarn", "bun"]);
const JS_DEV_SCRIPTS = ["dev", "serve", "start"];
const PYTHON_RUNNERS = new Set(["uv", "poetry", "pipenv"]);
const SHELL_OPERATORS = new Set(["&&", "||", ";", "|", "&", ">", ">>", "<"]);
const ENV_ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*=/;
const ASGI_TARGET = /^[A-Za-z_][\w.]*:[A-Za-z_]\w*$/;

function jsScriptCommand(input: DevCommandInput): ScanDevCommand | undefined {
  const pm = input.packageManager;
  if (!pm || !JS_PACKAGE_MANAGERS.has(pm)) return undefined;
  const script = JS_DEV_SCRIPTS.find((name) => typeof input.scripts[name] === "string");
  if (!script) return undefined;
  return {
    argv: [pm, "run", script],
    workingDirectory: input.workingDirectory,
    source: `script:${script}`,
  };
}

function pythonArgv(packageManager: string | null, argv: string[]): string[] {
  return packageManager && PYTHON_RUNNERS.has(packageManager)
    ? [packageManager, "run", ...argv]
    : argv;
}

function asgiTarget(startCommand: string | null): string | undefined {
  return shellSplitWords(startCommand ?? "").find((word) => ASGI_TARGET.test(word));
}

function stackDefaultArgv(input: DevCommandInput, port: string): string[] | undefined {
  const { stackId, packageManager } = input;
  const language = (STACKS[stackId] as StackDefinition).language;
  switch (stackId) {
    case "django":
      return pythonArgv(packageManager, ["python", "manage.py", "runserver", port]);
    case "fastapi": {
      const target = asgiTarget(input.startCommand);
      return target
        ? pythonArgv(packageManager, ["uvicorn", target, "--reload", "--port", port])
        : undefined;
    }
    case "flask":
      return pythonArgv(packageManager, ["flask", "run", "--debug", "--port", port]);
    case "rails":
      return ["bin/rails", "server", "-p", port];
    case "phoenix":
      return ["mix", "phx.server"];
    case "laravel":
      return ["php", "artisan", "serve", `--port=${port}`];
  }
  if (language === "go") return ["go", "run", "."];
  if (language === "rust") return ["cargo", "run"];
  return undefined;
}

function missingCommandReason(stackId: StackId): string {
  switch (stackId) {
    case "docker":
      return "it builds and runs from its Dockerfile";
    case "static":
      return "it is a static site with no dev script";
    default:
      return "no dev script and no start command was detected";
  }
}

function fallbackStart(input: DevCommandInput): DevCommandResult {
  const words = shellSplitWords(input.startCommand ?? "");
  if (words.length === 0) {
    return { devCommand: null, problem: missingCommandReason(input.stackId) };
  }
  if (words.some((word) => SHELL_OPERATORS.has(word))) {
    return { devCommand: null, problem: "the start command needs a shell to run" };
  }
  const argv = ENV_ASSIGNMENT.test(words[0]!) ? ["env", ...words] : words;
  return {
    devCommand: { argv, workingDirectory: input.workingDirectory, source: "fallback-start" },
  };
}

export function deriveDevCommand(input: DevCommandInput): DevCommandResult {
  const language = (STACKS[input.stackId] as StackDefinition).language;
  if (JS_LANGUAGES.has(language)) {
    const script = jsScriptCommand(input);
    if (script) return { devCommand: script };
  }

  const port = String(input.port ?? (STACKS[input.stackId] as StackDefinition).defaultPort);
  const argv = stackDefaultArgv(input, port);
  if (argv) {
    return {
      devCommand: { argv, workingDirectory: input.workingDirectory, source: "stack-default" },
    };
  }

  return fallbackStart(input);
}
