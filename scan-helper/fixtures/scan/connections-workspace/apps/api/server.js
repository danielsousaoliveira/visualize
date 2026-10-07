const express = require("express");
express().get("/", (_req, res) => res.send("ok")).listen(Number(process.env.PORT));
