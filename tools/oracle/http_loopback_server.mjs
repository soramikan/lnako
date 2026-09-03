import http from "node:http";

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url, "http://127.0.0.1");
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  const body = Buffer.concat(chunks);
  const contentType = request.headers["content-type"] ?? "";

  if (url.pathname === "/text") return send(response, 200, "text/plain; charset=utf-8", `TEXT:${request.method}:${url.searchParams.get("q") ?? ""}`);
  if (url.pathname === "/status") return send(response, 400, "text/plain", "bad status");
  if (url.pathname === "/json") return send(response, 200, "application/json", JSON.stringify({ ok: true, value: 3 }));
  if (url.pathname === "/empty") return send(response, 204, "application/json", "");
  if (url.pathname === "/binary") return send(response, 200, "application/octet-stream", Buffer.from([65, 0, 66, 255]));
  if (url.pathname === "/options") return send(response, 200, "text/plain", `${request.method}|${request.headers["x-lnako"] ?? ""}|${body.toString("utf8")}`);
  if (url.pathname === "/post") {
    if (contentType.startsWith("application/x-www-form-urlencoded")) {
      const params = new URLSearchParams(body.toString("utf8"));
      return send(response, 200, "text/plain", `FORM:${params.get("a")}:${params.get("日本")}`);
    }
    if (contentType.startsWith("multipart/form-data")) {
      const boundary = /boundary=(?:"([^"]+)"|([^;]+))/.exec(contentType)?.slice(1).find(Boolean);
      const text = body.toString("utf8");
      const values = [...text.matchAll(/name="([^"]+)"\r\n\r\n([^\r]*)/g)].map((match) => `${match[1]}=${match[2]}`).join(",");
      return send(response, 200, "text/plain", `MULTIPART:${boundary ? "boundary" : "missing"}:${values}`);
    }
    return send(response, 200, "text/plain", `RAW:${contentType}:${body.toString("utf8")}`);
  }
  if (url.pathname === "/discord-ok") return send(response, 204, "text/plain", "");
  if (url.pathname === "/discord-file") {
    const boundary = /boundary=(?:\"([^\"]+)\"|([^;]+))/.exec(contentType)?.slice(1).find(Boolean);
    const text = body.toString("latin1");
    const valid = Boolean(boundary) && text.includes('name="content"') && text.includes("hello discord") && text.includes('name="file"; filename="discord.txt"') && text.includes("hello-file");
    return send(response, valid ? 204 : 400, "text/plain", valid ? "" : "invalid multipart");
  }
  if (url.pathname === "/discord-fail") return send(response, 400, "text/plain", "bad request");
  if (url.pathname === "/abort") {
    request.socket.destroy();
    return;
  }
  return send(response, 404, "text/plain", "not found");
});

server.listen(0, "127.0.0.1", () => process.stdout.write(`${server.address().port}\n`));
for (const signal of ["SIGTERM", "SIGINT"]) process.on(signal, () => server.close(() => process.exit(0)));

function send(response, status, contentType, body) {
  response.writeHead(status, { "Content-Type": contentType, "Content-Length": Buffer.byteLength(body) });
  response.end(body);
}
