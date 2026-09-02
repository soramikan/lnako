import http from "node:http";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join, relative, resolve } from "node:path";
import { spawn, spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const oracleArg = process.argv.indexOf("--oracle");
const oracleRoot = resolve(oracleArg >= 0 ? process.argv[oracleArg + 1] : process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"));
const officialCli = resolve(oracleRoot, "src/cnako3.mjs");
const executable = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
const fixture = JSON.parse(await readFile(resolve(root, "tests/oracle/http-server-cases.json"), "utf8"));
// cnako3 v3.7.24 treats a Windows drive-letter path in `取り込む` as a
// relative module specifier.  Keep the temporary fixture on the repository
// drive and pass a genuinely relative path to the official runtime.
const temporary = await mkdtemp(join(root, ".tmp-lnako-httpserver-"));
const pluginPath = relative(temporary, resolve(oracleRoot, "src/plugin_httpserver.mjs")).replaceAll("\\", "/");
const staticDirectory = resolve(temporary, "static");
await mkdir(staticDirectory);
await writeFile(resolve(staticDirectory, "hello.txt"), "STATIC", "utf8");
buildLnako();

try {
  const official = await runSuite("official", [process.execPath, officialCli]);
  const actual = await runSuite("lnako", [executable, "run"]);
  if (JSON.stringify(official) !== JSON.stringify(actual)) {
    console.error(`簡易HTTPサーバ差分:\nofficial=${JSON.stringify(official, null, 2)}\nlnako=${JSON.stringify(actual, null, 2)}`);
    throw new Error("簡易HTTPサーバの公式差分があります");
  }
  console.log(`簡易HTTPサーバ公式差分テスト: ${fixture.commands.length}命令・${actual.length}リクエスト成功`);
} finally {
  await rm(temporary, { recursive: true, force: true });
}

async function runSuite(label, command) {
  const port = await reservePort();
  const sourcePath = resolve(temporary, `${label}.nako3`);
  const source = fixture.source
    .replaceAll("${PORT}", String(port))
    .replaceAll("${STATIC}", staticDirectory.replaceAll("\\", "/"))
    .replaceAll("${PLUGIN}", pluginPath);
  await writeFile(sourcePath, source, "utf8");
  const child = spawn(command[0], [...command.slice(1), sourcePath], {
    cwd: temporary,
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, TZ: "Asia/Tokyo", NAKO3_DISABLE_NEW_CONSOLE: "1" },
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
      ["/headers", "GET"],
      ["/redirect", "GET"],
      ["/route/long/test", "GET"],
      ["/api2", "GET"],
      ["/static/hello.txt?x=1", "GET"],
      ["/static/missing.txt", "GET"],
    ];
    const requests = [];
    for (const requestCase of cases) {
      console.log(`${label}: ${requestCase[1]} ${requestCase[0]}`);
      requests.push(await request(port, ...requestCase));
    }
    console.log(`${label}: GET /unregistered (応答保留)`);
    const unregistered = await expectTimeout(port, "/unregistered");
    requests.push(unregistered);
    console.log(`${label}: POST /echo (10MB超過)`);
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

function multipartBody() {
  return Buffer.from("------LnakoBoundary\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nhello\r\n------LnakoBoundary\r\nContent-Disposition: form-data; name=\"file1\"; filename=\"hello.txt\"\r\nContent-Type: text/plain\r\n\r\nhello upload--\r\n------LnakoBoundary--\r\n");
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
  const result = spawnSync("zig", ["build"], { cwd: root, encoding: "utf8", env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache") }, maxBuffer: 16 * 1024 * 1024 });
  if (result.status !== 0) throw new Error(`lnakoのビルドに失敗しました:\n${result.stderr}`);
}
