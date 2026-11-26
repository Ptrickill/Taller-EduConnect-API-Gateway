# EduConnect · PoC de API Gateway con Kong

Prueba de concepto reproducible que expone cuatro APIs simuladas de EduConnect (Estudiantes, Matrículas, Pagos y Certificados) a través de **un único punto de entrada** (Kong Gateway), con **autenticación por API Key** y **control de tráfico (rate limiting)**. Todo corre en contenedores con Docker Compose; no hay configuración oculta fuera de este repositorio.

> Laboratorio de Arquitectura Aplicada — Integración de Sistemas.
> Las credenciales incluidas son **ficticias** y solo válidas en este entorno local.

---

## 1. Requisitos

| Herramienta | Versión probada / mínima | Comprobación |
|---|---|---|
| Docker Engine o Docker Desktop | 24+ | `docker version` |
| Docker Compose v2 (plugin) | 2.20+ | `docker compose version` |
| curl | cualquiera (Windows 10/11 trae `curl.exe`) | `curl --version` |
| Postman (opcional) | 10+ | importar la colección |
| Bash (Linux/macOS/Git Bash) **o** PowerShell 5.1+ | — | para los scripts de prueba |

Puertos libres en el equipo: **8000** (proxy del gateway) y **8001** (Admin API, solo `127.0.0.1`).

## 2. Versión elegida de Kong y justificación

Se fija la imagen **`kong:3.9.1`** (imagen oficial de Docker Hub, edición OSS / Community).

- **Es la línea OSS vigente.** Según la guía de instalación oficial, la serie 3.9.x es la última de Kong Gateway OSS (las versiones posteriores se distribuyen como edición Enterprise). 3.9.1 es la etiqueta publicada en la imagen oficial `kong` de Docker Hub. No requiere licencia y todo lo usado aquí (DB-less, Services, Routes, Consumers, `key-auth`, `rate-limiting`) está incluido.
- **Soporta modo DB-less**, que permite declarar toda la configuración en un archivo versionable (`kong/kong.yml`) sin PostgreSQL, lo que simplifica la reproducibilidad.
- **Versión exacta, no `latest`.** Fijar `3.9.1` evita que otra persona obtenga una versión distinta al ejecutar el proyecto.
- El formato declarativo usado es `_format_version: "3.0"`, compatible con la serie 3.x.

## 3. Estructura del repositorio

```
educonnect-api-gateway/
├── docker-compose.yml          # Kong + 4 mocks en la red educonnect-net
├── kong/
│   └── kong.yml                # Configuración declarativa (Services, Routes, Consumers, Plugins)
├── mocks/
│   ├── server.js               # Mock HTTP genérico (Node.js, sin dependencias)
│   └── data/                   # Respuesta estática de cada servicio
│       ├── estudiantes.json
│       ├── matriculas.json
│       ├── pagos.json
│       └── certificados.json
├── tests/
│   ├── run-tests.sh            # Pruebas automáticas (Bash)
│   ├── run-tests.ps1           # Pruebas automáticas (PowerShell / Windows)
│   └── postman/EduConnect-API-Gateway.postman_collection.json
├── evidencias/                 # Aquí se guardan los logs generados por los scripts
└── docs/
    ├── arquitectura.md / .svg / .png   # Diagrama de la PoC
    ├── matriz-evidencias.md            # Predicción–prueba–análisis por reto
    ├── decisiones-arquitectonicas.md   # Documento corto (≤ 2 páginas)
    ├── reflexion.md                    # Preguntas de cierre
    └── declaracion-ia-y-fuentes.md
```

## 4. Arranque

```bash
git clone <url-del-repositorio> educonnect-api-gateway
cd educonnect-api-gateway
docker compose up -d
docker compose ps        # esperar a que kong aparezca como "healthy" (~15 s)
```

La primera ejecución descarga las imágenes `kong:3.9.1` y `node:22-alpine`.

## 5. URLs, rutas y credenciales

**Punto de entrada único:** `http://localhost:8000`

| Ruta pública (gateway) | Service Kong | Backend interno (no publicado) | Límite aplicado |
|---|---|---|---|
| `GET /api/estudiantes` | `svc-estudiantes` | `http://ms-estudiantes:3001/estudiantes` | ver tabla de límites |
| `GET /api/matriculas` | `svc-matriculas` | `http://ms-matriculas:3002/matriculas` | ver tabla de límites |
| `GET /api/pagos` | `svc-pagos` | `http://ms-pagos:3003/pagos` | ver tabla de límites |
| `GET /api/certificados` | `svc-certificados` | `http://ms-certificados:3004/certificados` | ver tabla de límites |

**Credencial:** encabezado `x-api-key` (no se acepta en query string ni en el cuerpo).

| Consumer (ficticio) | API Key de laboratorio | Uso |
|---|---|---|
| `app-movil-educonnect` | `lab-movil-7f3a9c2e-NO-REAL` | Consumidor de prueba del Reto 3 |
| `qa-integracion` | `lab-qa-41d8b6f0-NO-REAL` | Pruebas funcionales (Retos 1, 2, 4, Certificados) |

**Límites (rate limiting, ventana fija de 1 minuto, contador local del nodo):**

| Consumer | estudiantes + matrículas + pagos | certificados |
|---|---|---|
| `app-movil-educonnect` | **5 req/min en total** (plugin de alcance *Consumer*) | **2 req/min** (alcance *Consumer + Route*) |
| `qa-integracion` y cualquier otro | 60 req/min (plugin *Global*, por consumidor) | **3 req/min** (alcance *Route*) |

**Admin API (solo lectura de evidencias, solo desde el propio equipo):** `http://localhost:8001` → `/services`, `/routes`, `/consumers`, `/plugins`.

### Ejemplos rápidos

```bash
# 200 - respuesta del servicio Estudiantes (ver header X-Servicio-Origen)
curl -i http://localhost:8000/api/estudiantes -H "x-api-key: lab-qa-41d8b6f0-NO-REAL"

# 401 - sin credencial
curl -i http://localhost:8000/api/estudiantes

# 401 - credencial incorrecta
curl -i http://localhost:8000/api/estudiantes -H "x-api-key: llave-incorrecta-123"
```

En PowerShell usar `curl.exe` (no el alias `curl`).

## 6. Reproducir las pruebas

### Opción A — Script automático (recomendado, genera el log de evidencia)

```bash
bash tests/run-tests.sh                                        # Linux / macOS / Git Bash
powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1   # Windows
```

El script ejecuta, en orden: Reto 0 (contenedores, versión, DNS interno, backends no expuestos), Reto 1 (rutas), Reto 2 (401/401/200), Reto 3 (7 solicitudes seguidas → 5×200 y 2×429), Reto 4 (ruta inexistente, método no habilitado, **detiene y reinicia `ms-pagos`**) y el desafío Certificados. Cada línea registra hora, URL, código HTTP, servicio que respondió y cuota restante. El resultado queda en `evidencias/resultados-AAAAMMDD-HHMMSS.log`.

> El rate limiting usa ventanas fijas alineadas al minuto del reloj. El script espera al inicio del siguiente minuto si faltan menos de 20 s, para que la secuencia no quede partida entre dos ventanas. **Entre dos ejecuciones completas, espere 60 s.**

### Opción B — Postman

1. *Import* → `tests/postman/EduConnect-API-Gateway.postman_collection.json` (las variables ya vienen en la colección).
2. Ejecutar con **Collection Runner**, en orden y sin delay. La carpeta *Reto 4b – Backend caído* se ejecuta aparte:
   `docker compose stop ms-pagos` → *Send* → `docker compose start ms-pagos`.
3. Por línea de comandos (opcional): `npx newman run tests/postman/EduConnect-API-Gateway.postman_collection.json --folder "Reto 1 - Punto de acceso único"`.

### Opción C — Comandos manuales del Reto 3

```bash
for i in 1 2 3 4 5 6; do
  date +%T
  curl -s -o /dev/null -w "#$i -> %{http_code}\n" http://localhost:8000/api/pagos \
       -H "x-api-key: lab-movil-7f3a9c2e-NO-REAL"
done
```

## 7. Logs y diagnóstico

```bash
docker compose logs -f kong              # access log del gateway (código, ruta, latencias)
docker compose logs -f ms-pagos          # cada mock registra método, ruta, consumer y si recibió la API Key
docker compose exec ms-estudiantes wget -qO- http://ms-pagos:3003/pagos   # prueba de red interna
curl -s http://localhost:8001/plugins    # plugins efectivamente cargados
```

Orden de diagnóstico sugerido: (a) `docker compose ps`; (b) acceso al mock dentro de la red; (c) coincidencia de Route (404 *no Route matched*); (d) key-auth (401); (e) rate limiting (429); (f) respuesta del backend (502/503/504).

Si se modifica `kong/kong.yml`: `docker compose restart kong` (en DB-less la configuración se carga al arrancar). Para validar el archivo antes: `docker compose run --rm kong kong config parse /kong/declarative/kong.yml`.

## 8. Detener la solución

```bash
docker compose down          # detiene y elimina contenedores y la red
docker compose down --rmi all   # además elimina las imágenes descargadas
```

No hay volúmenes ni datos persistentes que limpiar.

## 9. Documentación del laboratorio

- [Diagrama de arquitectura](docs/arquitectura.md)
- [Matriz de evidencias por reto](docs/matriz-evidencias.md)
- [Decisiones arquitectónicas, AuthN/AuthZ, límites y mejoras](docs/decisiones-arquitectonicas.md)
- [Preguntas de reflexión](docs/reflexion.md)
- [Declaración de uso de IA y fuentes](docs/declaracion-ia-y-fuentes.md)
