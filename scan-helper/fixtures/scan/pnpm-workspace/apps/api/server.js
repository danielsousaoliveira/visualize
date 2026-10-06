const express = require("express");

express()
  .get("/", (_req, res) => res.send("hello from api"))
  .listen(Number(process.env.PORT ?? 3000));
