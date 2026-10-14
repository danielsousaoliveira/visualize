export function hasAndroidApplicationPlugin(content: string): boolean {
  const tokens = content.match(/\/\/[^\r\n]*|\/\*[\s\S]*?\*\/|"""[\s\S]*?"""|'''[\s\S]*?'''|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[A-Za-z_$][\w$]*|[^\s]/g)
    ?.filter((token) => !token.startsWith("//") && !token.startsWith("/*")) ?? [];
  let depth = 0;
  let pluginsDepth: number | undefined;
  for (let index = 0; index < tokens.length; index += 1) {
    const token = tokens[index];
    if (token === "{") {
      depth += 1;
      if (tokens[index - 1] === "plugins" && depth === 1) pluginsDepth = depth;
      continue;
    }
    if (token === "}") {
      if (depth === pluginsDepth) pluginsDepth = undefined;
      depth -= 1;
      continue;
    }
    if (pluginsDepth !== depth || (token !== "id" && token !== "alias")) continue;
    let cursor = index + 1;
    const parenthesized = tokens[cursor] === "(";
    if (parenthesized) cursor += 1;
    if (token === "id") {
      if (!['"com.android.application"', "'com.android.application'"].includes(tokens[cursor] ?? "")) continue;
      cursor += 1;
    } else {
      const expected = ["libs", ".", "plugins", ".", "android", ".", "application"];
      if (!expected.every((part, offset) => tokens[cursor + offset] === part)) continue;
      cursor += expected.length;
    }
    if (parenthesized && tokens[cursor++] !== ")") continue;
    let disabled = false;
    while (cursor < tokens.length && !["id", "alias", "}", ";"].includes(tokens[cursor]!)) {
      if (tokens[cursor] === "apply") {
        disabled = tokens[cursor + 1] === "false" || (tokens[cursor + 1] === "(" && tokens[cursor + 2] === "false");
      }
      cursor += 1;
    }
    if (!disabled) return true;
  }
  return false;
}
