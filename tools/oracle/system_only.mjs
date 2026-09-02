#!/usr/bin/env node

import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const root = resolve(import.meta.dirname, "../..");
const oracleRoot = resolve(process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"));
const { NakoCompiler } = await import(pathToFileURL(resolve(oracleRoot, "core/src/nako3.mjs")).href);
const arguments_ = process.argv.slice(2);
const compile = arguments_.includes("--compile");
const outputIndex = arguments_.indexOf("--output");
const output = outputIndex < 0 ? null : arguments_[outputIndex + 1];
const sourcePath = arguments_.filter((argument, index) =>
  !argument.startsWith("--") && (outputIndex < 0 || index !== outputIndex + 1)).at(-1);

if (sourcePath === undefined || (compile && output === null)) {
  console.error("usage: system_only.mjs [--compile --output FILE] SOURCE");
  process.exitCode = 2;
} else {
  try {
    const source = await readFile(sourcePath, "utf8");
    const compiler = new NakoCompiler({ useBasicPlugin: true });
    compiler.getLogger().addListener("error", ({ nodeConsole }) => console.log(nodeConsole));
    if (compile) {
      await writeFile(output, compiler.compileStandalone(source, sourcePath), "utf8");
    } else {
      await compiler.runAsync(source, sourcePath);
    }
  } catch (error) {
    console.error(`[system-only oracle] ${error?.message ?? error}`);
    process.exitCode = 1;
  }
}
