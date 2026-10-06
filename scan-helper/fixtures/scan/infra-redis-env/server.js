const http = require("node:http");

http
  .createServer((_req, res) => res.end("hello from infra-redis-env\n"))
  .listen(Number(process.env.PORT ?? 3000));
