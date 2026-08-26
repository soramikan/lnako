// Prevent the external-open oracle fixture from starting a browser or file
// manager. Only the platform launcher names are intercepted; all other child
// process operations retain their normal behavior.
import childProcess from "node:child_process";
import { syncBuiltinESMExports } from "node:module";

const externalCommands = new Set(["open", "xdg-open", "cmd", "cmd.exe", "explorer", "explorer.exe"]);
const commandName = (command) => {
  if (typeof command !== "string") return "";
  return command.replaceAll("\\", "/").split("/").at(-1).toLowerCase();
};
const fakeChild = () => ({
  unref() {},
  on() { return this; },
  once() { return this; },
  emit() { return false; },
});

const originalExecFile = childProcess.execFile;
childProcess.execFile = function (command, ...arguments_) {
  if (externalCommands.has(commandName(command))) return fakeChild();
  return originalExecFile.call(this, command, ...arguments_);
};

const originalSpawn = childProcess.spawn;
childProcess.spawn = function (command, ...arguments_) {
  if (externalCommands.has(commandName(command))) return fakeChild();
  return originalSpawn.call(this, command, ...arguments_);
};

syncBuiltinESMExports();
