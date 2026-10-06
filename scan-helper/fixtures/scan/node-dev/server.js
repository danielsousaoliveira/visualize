const http = require("node:http");

http
  .createServer((_req, res) => res.end("hello from node-dev\n"))
  .listen(Number(process.env.PORT ?? 3000));
