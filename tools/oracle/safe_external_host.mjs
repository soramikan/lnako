// Prevent the external-open oracle fixture from starting a browser or file
// manager. Only the platform launcher names are intercepted; all other child
// process operations retain their normal behavior.
import childProcess from "node:child_process";
import fs from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import path from "node:path";

const externalCommands = new Set(["open", "xdg-open", "cmd", "cmd.exe", "explorer", "explorer.exe"]);
const archiveHelperName = "lnako-archive-7z-helper";
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

const originalExec = childProcess.exec;
childProcess.exec = function (command, ...arguments_) {
  const operation = parseArchiveCommand(command);
  if (operation === null) return originalExec.call(this, command, ...arguments_);
  const callback = arguments_.at(-1);
  if (typeof callback !== "function") throw new TypeError("hermetic archive helper requires an exec callback");
  const child = fakeChild();
  setImmediate(() => {
    try {
      executeArchiveOperation(operation);
      callback(null, "", "");
    } catch (error) {
      callback(error, "", "");
    }
  });
  return child;
};

const originalExecSync = childProcess.execSync;
childProcess.execSync = function (command, ...arguments_) {
  const operation = parseArchiveCommand(command);
  if (operation === null) return originalExecSync.call(this, command, ...arguments_);
  executeArchiveOperation(operation);
  return Buffer.alloc(0);
};

const originalSpawn = childProcess.spawn;
childProcess.spawn = function (command, ...arguments_) {
  if (externalCommands.has(commandName(command))) return fakeChild();
  return originalSpawn.call(this, command, ...arguments_);
};

syncBuiltinESMExports();

function parseArchiveCommand(command) {
  if (typeof command !== "string") return null;
  const words = shellWords(command);
  if (words[0] !== archiveHelperName) return null;
  if (words[1] === "a" && words[2] === "-r" && words.length >= 6 && words.at(-1) === "-y") {
    return { operation: "create", source: words[4], destination: words[3] };
  }
  if (words[1] === "x" && words.length >= 5 && words.at(-1) === "-y") {
    const output = words.find((word) => word.startsWith("-o"));
    if (output !== undefined && output.length > 2) return { operation: "extract", source: words[2], destination: output.slice(2) };
  }
  throw new Error(`hermetic archive helper command is unsupported: ${command}`);
}

function shellWords(command) {
  const words = [];
  let current = "";
  let quote = null;
  for (let index = 0; index < command.length; index += 1) {
    const character = command[index];
    if (quote === "'") {
      if (character === "'") quote = null;
      else current += character;
      continue;
    }
    if (quote === '"') {
      if (character === '"') quote = null;
      else current += character;
      continue;
    }
    if (character === "'" || character === '"') {
      quote = character;
    } else if (character === "\\" && index + 1 < command.length) {
      current += command[++index];
    } else if (/\s/.test(character)) {
      if (current.length > 0) {
        words.push(current);
        current = "";
      }
    } else {
      current += character;
    }
  }
  if (quote !== null) throw new Error("hermetic archive helper command has an unterminated quote");
  if (current.length > 0) words.push(current);
  return words;
}

function executeArchiveOperation(operation) {
  const cwd = process.cwd();
  const source = path.resolve(cwd, operation.source);
  const destination = path.resolve(cwd, operation.destination);
  if (operation.operation === "create") createStoredZip(source, destination);
  else extractStoredZip(source, destination);
}

function createStoredZip(source, destination) {
  const entries = collectEntries(source);
  const chunks = [];
  const central = [];
  let offset = 0;
  for (const entry of entries) {
    const name = Buffer.from(entry.name, "utf8");
    const crc = crc32(entry.data);
    const size = entry.data.length;
    if (name.length > 0xffff || size > 0xffffffff || offset > 0xffffffff) throw new Error("hermetic archive helper ZIP32 limit exceeded");
    const header = Buffer.alloc(30);
    header.writeUInt32LE(0x04034b50, 0);
    header.writeUInt16LE(20, 4);
    header.writeUInt16LE(0x0800, 6);
    header.writeUInt16LE(0, 8);
    header.writeUInt16LE(0, 10);
    header.writeUInt16LE(0, 12);
    header.writeUInt32LE(entry.isDirectory ? 0 : crc, 14);
    header.writeUInt32LE(size, 18);
    header.writeUInt32LE(size, 22);
    header.writeUInt16LE(name.length, 26);
    header.writeUInt16LE(0, 28);
    chunks.push(header, name, entry.data);
    central.push({ name, crc, size, offset, isDirectory: entry.isDirectory });
    offset += header.length + name.length + size;
  }

  const centralOffset = offset;
  for (const entry of central) {
    const header = Buffer.alloc(46);
    header.writeUInt32LE(0x02014b50, 0);
    header.writeUInt16LE(0x0314, 4);
    header.writeUInt16LE(20, 6);
    header.writeUInt16LE(0x0800, 8);
    header.writeUInt16LE(0, 10);
    header.writeUInt16LE(0, 12);
    header.writeUInt16LE(0, 14);
    header.writeUInt32LE(entry.isDirectory ? 0 : entry.crc, 16);
    header.writeUInt32LE(entry.size, 20);
    header.writeUInt32LE(entry.size, 24);
    header.writeUInt16LE(entry.name.length, 28);
    header.writeUInt16LE(0, 30);
    header.writeUInt16LE(0, 32);
    header.writeUInt16LE(0, 34);
    header.writeUInt16LE(0, 36);
    header.writeUInt32LE(entry.isDirectory ? 0x41ed0010 : 0x81a40000, 38);
    header.writeUInt32LE(entry.offset, 42);
    chunks.push(header, entry.name);
    offset += header.length + entry.name.length;
  }

  const end = Buffer.alloc(22);
  const count = central.length;
  if (count > 0xffff || centralOffset > 0xffffffff || offset - centralOffset > 0xffffffff) throw new Error("hermetic archive helper ZIP32 directory limit exceeded");
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(0, 4);
  end.writeUInt16LE(0, 6);
  end.writeUInt16LE(count, 8);
  end.writeUInt16LE(count, 10);
  end.writeUInt32LE(offset - centralOffset, 12);
  end.writeUInt32LE(centralOffset, 16);
  end.writeUInt16LE(0, 20);
  chunks.push(end);
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.writeFileSync(destination, Buffer.concat(chunks));
}

function collectEntries(source) {
  const information = fs.statSync(source);
  if (information.isFile()) return [{ name: path.basename(source), data: fs.readFileSync(source), isDirectory: false }];
  if (!information.isDirectory()) throw new Error(`hermetic archive helper source is not a file or directory: ${source}`);
  const rootName = path.basename(source.replace(/[\\/]+$/g, ""));
  const entries = [{ name: `${rootName}/`, data: Buffer.alloc(0), isDirectory: true }];
  collectDirectoryEntries(source, rootName, entries);
  return entries.sort((left, right) => left.name.localeCompare(right.name));
}

function collectDirectoryEntries(directory, prefix, entries) {
  const children = fs.readdirSync(directory, { withFileTypes: true }).sort((left, right) => left.name.localeCompare(right.name));
  for (const child of children) {
    const name = `${prefix}/${child.name}`;
    const childPath = path.join(directory, child.name);
    if (child.isDirectory()) {
      entries.push({ name: `${name}/`, data: Buffer.alloc(0), isDirectory: true });
      collectDirectoryEntries(childPath, name, entries);
    } else if (child.isFile()) {
      entries.push({ name, data: fs.readFileSync(childPath), isDirectory: false });
    } else {
      throw new Error(`hermetic archive helper cannot archive special entry: ${childPath}`);
    }
  }
}

function extractStoredZip(source, destination) {
  const bytes = fs.readFileSync(source);
  fs.mkdirSync(destination, { recursive: true });
  let offset = 0;
  while (offset + 4 <= bytes.length) {
    const signature = bytes.readUInt32LE(offset);
    if (signature === 0x02014b50 || signature === 0x06054b50) break;
    if (signature !== 0x04034b50 || offset + 30 > bytes.length) throw new Error("hermetic archive helper ZIP local header is invalid");
    const flags = bytes.readUInt16LE(offset + 6);
    const method = bytes.readUInt16LE(offset + 8);
    const expectedCrc = bytes.readUInt32LE(offset + 14);
    const size = bytes.readUInt32LE(offset + 22);
    const nameLength = bytes.readUInt16LE(offset + 26);
    const extraLength = bytes.readUInt16LE(offset + 28);
    const dataStart = offset + 30 + nameLength + extraLength;
    const dataEnd = dataStart + size;
    if ((flags & 0x0008) !== 0 || method !== 0 || dataEnd > bytes.length) throw new Error("hermetic archive helper accepts only stored ZIP entries");
    const name = bytes.subarray(offset + 30, offset + 30 + nameLength).toString("utf8").replaceAll("\\", "/");
    const data = bytes.subarray(dataStart, dataEnd);
    if (crc32(data) !== expectedCrc) throw new Error(`hermetic archive helper ZIP checksum mismatch: ${name}`);
    const target = safeExtractPath(destination, name);
    if (name.endsWith("/")) fs.mkdirSync(target, { recursive: true });
    else {
      fs.mkdirSync(path.dirname(target), { recursive: true });
      fs.writeFileSync(target, data);
    }
    offset = dataEnd;
  }
}

function safeExtractPath(destination, name) {
  if (name.length === 0 || name.includes("\0") || name.startsWith("/") || /^[A-Za-z]:\//.test(name)) {
    throw new Error(`hermetic archive helper ZIP path is unsafe: ${name}`);
  }
  const root = path.resolve(destination);
  const target = path.resolve(root, ...name.split("/").filter((part) => part.length > 0));
  if (target !== root && !target.startsWith(`${root}${path.sep}`)) throw new Error(`hermetic archive helper ZIP path escapes destination: ${name}`);
  return target;
}

const crcTable = new Uint32Array(256);
for (let index = 0; index < crcTable.length; index += 1) {
  let value = index;
  for (let bit = 0; bit < 8; bit += 1) value = (value & 1) === 0 ? value >>> 1 : (value >>> 1) ^ 0xedb88320;
  crcTable[index] = value >>> 0;
}

function crc32(bytes) {
  let value = 0xffffffff;
  for (const byte of bytes) value = (value >>> 8) ^ crcTable[(value ^ byte) & 0xff];
  return (value ^ 0xffffffff) >>> 0;
}
