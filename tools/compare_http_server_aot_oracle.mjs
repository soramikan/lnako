import http from "node:http";
import { access, mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join, relative, resolve } from "node:path";
import { spawn, spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const arguments_ = process.argv.slice(2);
let noBuild = false;
for (let index = 0; index < arguments_.length; index += 1) {
  const argument = arguments_[index];
  if (argument === "--no-build") {
    if (noBuild) throw new Error("--no-buildは1回だけ指定してください");
    noBuild = true;
    continue;
  }
  if (argument === "--oracle") {
    if (index + 1 >= arguments_.length || arguments_[index + 1].startsWith("--")) throw new Error("--oracleにはパスを指定してください");
    index += 1;
    continue;
  }
  throw new Error("usage: node tools/compare_http_server_aot_oracle.mjs [--no-build] [--oracle /absolute/path]");
}
const oracleArg = process.argv.indexOf("--oracle");
const oracleRoot = resolve(oracleArg >= 0 ? process.argv[oracleArg + 1] : process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"));
const officialCli = resolve(oracleRoot, "src/cnako3.mjs");
const executable = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
const fixture = JSON.parse(await readFile(resolve(root, "tests/oracle/http-server-cases.json"), "utf8"));
// cnako3 v3.7.24 treats a Windows drive-letter path in `取り込む` as a
// relative module specifier.  Keep the temporary fixture on the repository
// drive and pass a genuinely relative path to the official runtime.
const temporary = await mkdtemp(join(root, ".tmp-lnako-httpserver-aot-"));
const pluginPath = relative(temporary, resolve(oracleRoot, "src/plugin_httpserver.mjs")).replaceAll("\\", "/");
const staticDirectory = resolve(temporary, "static");
await mkdir(staticDirectory);
await writeFile(resolve(staticDirectory, "hello.txt"), "STATIC", "utf8");
if (!noBuild) buildLnako();
else await access(executable);

try {
  const official = await runSuite("official", null);
  for (const optimization of ["O0", "O1", "O2", "O3"]) {
    const actual = await runSuite(`lnako-${optimization}`, optimization);
    if (JSON.stringify(official) !== JSON.stringify(actual)) {
      console.error(`簡易HTTPサーバAOT差分 (${optimization}):\nofficial=${JSON.stringify(official, null, 2)}\nactual=${JSON.stringify(actual, null, 2)}`);
      throw new Error(`簡易HTTPサーバの公式差分があります (${optimization})`);
    }
  }
  console.log(`簡易HTTPサーバ公式差分テスト: ${fixture.commands.length}命令・O0/O1/O2/O3の各${requestCount()}リクエスト成功`);
} finally {
  await rm(temporary, { recursive: true, force: true });
}

async function runSuite(label, optimization) {
  const port = await reservePort();
  const sourcePath = resolve(temporary, `${label}.nako3`);
  const source = fixture.source
    .replaceAll("${PORT}", String(port))
    .replaceAll("${STATIC}", staticDirectory.replaceAll("\\", "/"))
    .replaceAll("${PLUGIN}", pluginPath);
  await writeFile(sourcePath, source, "utf8");

  let command = [process.execPath, officialCli, sourcePath];
  if (optimization !== null) {
    const nativeExecutable = resolve(temporary, `${label}${process.platform === "win32" ? ".exe" : ""}`);
    const compile = spawnSync(executable, ["build", sourcePath, "-o", nativeExecutable, `-${optimization}`], {
      cwd: temporary,
      encoding: "utf8",
      env: suiteEnvironment(),
      maxBuffer: 16 * 1024 * 1024,
    });
    if (compile.status !== 0) throw new Error(`${label}のAOTビルドに失敗しました:\nstdout=${compile.stdout}\nstderr=${compile.stderr}`);
    command = [nativeExecutable];
  }

  const child = spawn(command[0], command.slice(1), {
    cwd: temporary,
    stdio: ["ignore", "pipe", "pipe"],
    env: suiteEnvironment(),
    windowsHide: true,
  });
  let stderr = "";
  let stdout = "";
  child.stdout.on("data", (chunk) => { stdout += chunk.toString("utf8"); });
  child.stderr.on("data", (chunk) => { stderr += chunk.toString("utf8"); });
  try {
    await waitForServer(port, child, () => `stdout=${stdout}\nstderr=${stderr}`);
    const cases = [
      ["/echo?a=A%20B&plus=A+B", "GET"],
      ["/echo?duplicate=first&duplicate=last&flag&raw=a=b&empty=", "GET"],
      ["/echo?head=1", "HEAD"],
      ["/echo", "PUT"],
      ["/echo", "POST", "application/json", JSON.stringify({ message: "日本語" })],
      ["/echo", "POST", "application/x-www-form-urlencoded", "message=hello+world&x=A%2BB"],
      ["/echo", "POST-CHUNKED", "application/x-www-form-urlencoded", "message=chunked+body"],
      ["/upload", "POST", "multipart/form-data; boundary=----LnakoBoundary", multipartBody()],
      ["/echo", "POST", "multipart/form-data; boundary=----LnakoBoundary; charset=utf-8", multipartFieldBody()],
      ["/echo", "POST", "multipart/form-data; boundary=\"----LnakoBoundary\"; charset=utf-8", multipartFieldBody()],
      ["/echo", "POST", "multipart/form-data; boundary=----LnakoBoundary", multipartFieldBody("\n")],
      ["/echo", "POST", "Multipart/form-data; boundary=----LnakoBoundary", multipartFieldBody()],
      ["/echo", "POST", "multipart/form-data", multipartFieldBody()],
      ["/upload", "POST", "multipart/form-data; boundary=----LnakoBoundary", multipartBody("hello;v1.txt")],
      ["/upload", "POST", "multipart/form-data; boundary=----LnakoBoundary", multipartOrphanFileBody()],
      ["/headers", "GET"],
      ["/redirect", "GET"],
      ["/route/long/test", "GET"],
      ["/api2", "GET"],
      ["/static/hello.txt?x=1", "GET"],
      ["/static/missing.txt", "GET"],
    ];
    const requests = [];
    for (const requestCase of cases) requests.push(await request(port, ...requestCase));
    requests.push(await expectTimeout(port, "/unregistered"));
    requests.push(await request(port, "/echo", "POST", "application/octet-stream", Buffer.alloc(10 * 1024 * 1024 + 1, 65)));
    return requests.map(normalizeResponse);
  } finally {
    if (child.exitCode === null) {
      const exited = new Promise((done) => child.once("exit", done));
      child.kill("SIGTERM");
      await Promise.race([exited, new Promise((done) => setTimeout(() => { child.kill("SIGKILL"); done(); }, 2000))]);
    }
    if (child.exitCode && child.exitCode !== 0) throw new Error(`${label}サーバが異常終了しました:\nstdout=${stdout}\nstderr=${stderr}`);
  }
}

function suiteEnvironment() {
  return { ...process.env, TZ: "Asia/Tokyo", NAKO3_DISABLE_NEW_CONSOLE: "1" };
}

function requestCount() {
  return 23;
}

function multipartBody(filename = "hello.txt") {
  return Buffer.from(`------LnakoBoundary\r\nContent-Disposition: form-data; name="title"\r\n\r\nhello\r\n------LnakoBoundary\r\nContent-Disposition: form-data; name="file1"; filename="${filename}"\r\nContent-Type: text/plain\r\n\r\nhello upload--\r\n------LnakoBoundary--\r\n`);
}

function multipartFieldBody(lineEnding = "\r\n") {
  return Buffer.from([
    `------LnakoBoundary${lineEnding}`,
    `Content-Disposition: form-data; name="title"${lineEnding}`,
    lineEnding,
    `hello${lineEnding}`,
    `------LnakoBoundary--${lineEnding}`,
  ].join(""));
}

function multipartOrphanFileBody() {
  return Buffer.from("------LnakoBoundary\r\nContent-Disposition: form-data; filename=\"orphan.txt\"\r\nContent-Type: text/plain\r\n\r\norphan\r\n------LnakoBoundary--\r\n");
}

function normalizeResponse(response) {
  return {
    status: response.status,
    contentType: response.headers["content-type"] ?? "",
    location: response.headers.location ?? "",
    custom: response.headers["x-lnako"] ?? "",
    body: response.body.toString("utf8"),
  };
}

async function request(port, path, method, contentType, body = Buffer.alloc(0)) {
  const payload = Buffer.isBuffer(body) ? body : Buffer.from(body);
  const chunked = method === "POST-CHUNKED";
  if (chunked) method = "POST";
  return new Promise((resolveRequest, reject) => {
    const headers = contentType ? { "Content-Type": contentType } : {};
    if (!chunked && contentType) headers["Content-Length"] = payload.length;
    const req = http.request({ hostname: "127.0.0.1", port, path, method, headers }, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => resolveRequest({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) }));
    });
    req.setTimeout(5000, () => req.destroy(new Error("HTTP request timed out")));
    req.on("error", reject);
    if (payload.length > 0) req.write(payload);
    req.end();
  });
}

async function expectTimeout(port, path) {
  try {
    await request(port, path, "GET");
    return { status: 999, headers: {}, body: Buffer.from("unexpected-response") };
  } catch (error) {
    if (!String(error?.message).includes("timed out")) throw error;
    return { status: 0, headers: {}, body: Buffer.from("timeout") };
  }
}

async function reservePort() {
  const server = http.createServer();
  await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
  const port = server.address().port;
  await new Promise((resolveClose) => server.close(resolveClose));
  return port;
}

async function waitForServer(port, child, diagnostics) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (child.exitCode !== null) throw new Error(`サーバが起動前に終了しました: ${child.exitCode}\n${diagnostics()}`);
    try {
      await request(port, "/echo", "GET");
      return;
    } catch {
      await new Promise((done) => setTimeout(done, 20));
    }
  }
  throw new Error(`簡易HTTPサーバが5秒以内に起動しませんでした\n${diagnostics()}`);
}

function buildLnako() {
  const result = spawnSync("zig", ["build"], {
    cwd: root,
    encoding: "utf8",
    env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache") },
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.status !== 0) throw new Error(`lnakoのビルドに失敗しました:\n${result.stderr}`);
}
