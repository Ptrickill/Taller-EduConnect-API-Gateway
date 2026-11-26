/**
 * Mock HTTP genérico para la PoC EduConnect.
 *
 * Un mismo archivo sirve a los cuatro servicios; cada contenedor es un proceso
 * independiente que recibe su identidad por variables de entorno:
 *   SERVICE_NAME  -> nombre lógico (estudiantes, matriculas, pagos, certificados)
 *   PORT          -> puerto interno en la red Docker
 *   RESOURCE_PATH -> ruta del recurso (p. ej. /estudiantes)
 *   DATA_FILE     -> JSON con la respuesta estática
 *
 * Sin dependencias externas (solo módulos nativos de Node.js).
 */
const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");

const SERVICE_NAME = process.env.SERVICE_NAME || "mock";
const PORT = Number(process.env.PORT || 3000);
const RESOURCE_PATH = process.env.RESOURCE_PATH || `/${SERVICE_NAME}`;
const DATA_FILE =
  process.env.DATA_FILE || path.join(__dirname, "data", `${SERVICE_NAME}.json`);
const INSTANCE = os.hostname();

// Se valida el JSON al arrancar, pero se conserva el texto original para no
// alterar el formato de los números (p. ej. 150.00 en Pagos).
const rawPayload = fs.readFileSync(DATA_FILE, "utf8").trim();
JSON.parse(rawPayload);
// Se agrega el campo "servicio" para distinguir de forma comprobable qué backend respondió.
const okBody = rawPayload.replace(/}\s*$/, `,"servicio":"${SERVICE_NAME}"}`);

function log(req, status) {
  // Kong agrega X-Consumer-Username tras autenticar; útil como evidencia.
  const consumer = req.headers["x-consumer-username"] || "-";
  const via = req.headers["x-forwarded-for"] || req.socket.remoteAddress;
  const leakedKey = req.headers["x-api-key"] ? "SI" : "no";
  console.log(
    `[${new Date().toISOString()}] ms-${SERVICE_NAME} ${req.method} ${req.url} ` +
      `-> ${status} | consumer=${consumer} | origen=${via} | api-key-recibida=${leakedKey}`
  );
}

function send(req, res, status, body) {
  const text = typeof body === "string" ? body : JSON.stringify(body);
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "X-Servicio-Origen": `ms-${SERVICE_NAME}`,
    "X-Instancia": INSTANCE,
  });
  res.end(text);
  log(req, status);
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || "localhost"}`);
  const p = url.pathname.replace(/\/+$/, "") || "/";

  if (p === "/health") {
    return send(req, res, 200, { status: "UP", servicio: SERVICE_NAME });
  }
  if (p !== RESOURCE_PATH) {
    return send(req, res, 404, {
      error: "Recurso no encontrado en el backend",
      servicio: SERVICE_NAME,
      ruta: url.pathname,
    });
  }
  if (req.method !== "GET") {
    return send(req, res, 405, { error: "Método no permitido", servicio: SERVICE_NAME });
  }
  return send(req, res, 200, okBody);
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(
    `ms-${SERVICE_NAME} escuchando en :${PORT} (recurso ${RESOURCE_PATH}, instancia ${INSTANCE})`
  );
});

// Apagado limpio al detener el contenedor (docker compose stop)
for (const sig of ["SIGTERM", "SIGINT"]) {
  process.on(sig, () => {
    console.log(`ms-${SERVICE_NAME} recibió ${sig}, cerrando...`);
    server.close(() => process.exit(0));
  });
}
