# Matriz de evidencias por reto

Ciclo aplicado en cada reto: **predicción → configuración → prueba → resultado → análisis → limitación.**

> **Cómo completar la columna «Observado».** Ejecutar `bash tests/run-tests.sh` (o la versión `.ps1`). Cada caso imprime una línea `[hora] GET url -> HTTP código | origen=… | restante/min=…` y un veredicto `[OK]` / `[FALLA]`. Copiar esa línea (o adjuntar captura) en la fila correspondiente, junto con el nombre del archivo `evidencias/resultados-*.log`. Si lo observado difiere de lo predicho, explicar la diferencia en «Análisis».

---

## Reto 0 — Comprender y desplegar Kong

| Registro | Contenido |
|---|---|
| **Hipótesis** | Si declaro Kong y los cuatro mocks en un mismo `docker-compose.yml` con una red bridge definida por el usuario (`educonnect-net`), espero ver 5 contenedores en estado *running* (Kong *healthy*) porque Compose crea la red y registra cada servicio en su DNS interno. Espero que `kong version` devuelva `3.9.1` porque la imagen está fijada. |
| **Decisión** | Modo **DB-less** (configuración declarativa en `kong/kong.yml`, montada read-only): reproducible, versionable, sin PostgreSQL. Imagen `kong:3.9.1` fijada (ver README §2). Mocks en `node:22-alpine` sin dependencias. Backends sin `ports:`. |
| **Prueba** | `docker compose ps` · `docker compose exec kong kong version` · `curl http://localhost:8001` · `docker compose exec ms-estudiantes wget -qO- http://ms-pagos:3003/pagos` · `curl http://localhost:3001/estudiantes` (debe fallar). |
| **Resultado esperado** | 5 contenedores *Up*; versión `3.9.1`; Admin API reporta `database: off`; la consulta interna por nombre devuelve el JSON de Pagos; `localhost:3001` devuelve código `000` (sin conexión). |
| **Observado** | _(pegar salida del log)_ |
| **Análisis** | **¿Cómo se comunica Kong sin IP rígidas?** En una red bridge definida por el usuario, Docker ofrece un servidor DNS embebido que resuelve el **nombre del servicio** de Compose (`ms-pagos`) a la IP actual del contenedor. Los Services de Kong apuntan a `http://ms-pagos:3003/pagos`; si el contenedor se recrea y cambia de IP, el nombre sigue siendo válido. Como el DNS de Docker publica TTL de 600 s, se configuró `KONG_DNS_VALID_TTL=5` para que Kong vuelva a resolver rápido tras un reinicio. |
| **Limitación** | Demuestra un único nodo en un único host. No prueba descubrimiento de servicios entre hosts, ni TLS, ni alta disponibilidad. |

## Reto 1 — Unificar el punto de acceso

| Registro | Contenido |
|---|---|
| **Hipótesis** | Si creo un Service por backend y una Route con `paths: [/api/<recurso>]` y `strip_path: true`, al enviar `GET /api/pagos` al puerto 8000 espero HTTP 200 con el JSON de Pagos, porque Kong elimina el prefijo coincidente y concatena el resto a la ruta del Service (`/pagos`). |
| **Decisión** | `strip_path: true` + ruta del recurso en la URL del Service: el contrato público (`/api/...`) queda desacoplado de la ruta interna. `methods: [GET]` por mínimo privilegio. Para demostrar qué backend respondió: campo `"servicio"` en el JSON y header `X-Servicio-Origen`. |
| **Prueba** | `GET http://localhost:8000/api/estudiantes` · `/api/matriculas` · `/api/pagos` con header `x-api-key: lab-qa-41d8b6f0-NO-REAL`. |
| **Resultado esperado** | Tres respuestas 200, `Content-Type: application/json`, `X-Servicio-Origen` = `ms-estudiantes`, `ms-matriculas`, `ms-pagos` respectivamente. El log de cada mock registra la solicitud. |
| **Observado** | _(pegar)_ |
| **Análisis** | **Service vs Route.** El *Service* describe el **destino** (protocolo, host, puerto, ruta, timeouts, reintentos). La *Route* describe **qué solicitudes entran** (path, método, host, protocolo) y a qué Service se asocian. Una Route sin Service no tiene a dónde ir; un Service sin Route no es alcanzable desde fuera. **Si cambia la dirección interna de un backend**, solo se modifica la URL del Service en `kong.yml` y se reinicia Kong: los consumidores no cambian nada porque la Route pública es la misma. Si no se actualiza, Kong responde 502/503 (ver Reto 4). |
| **Limitación** | El match por prefijo también acepta `/api/pagos/xyz` (llega al backend como `/pagos/xyz` y el mock responde 404). No se prueban métodos distintos de GET ni versionado de API. |

## Reto 2 — Proteger el acceso con API Key

| Registro | Contenido |
|---|---|
| **Hipótesis** | Si habilito `key-auth` con `key_names: [x-api-key]`, espero 401 sin llave («No API key found in request»), 401 con llave inexistente («Unauthorized», mensaje verificado en el código de key-auth 3.9.1) y 200 con la llave de un Consumer, porque el plugin busca la credencial en el header y la compara contra las `keyauth_credentials` declaradas. |
| **Decisión** | Plugin en **alcance global** (seguro por defecto: cualquier Route nueva queda protegida). Llave solo en header (`key_in_query: false`, `key_in_body: false`) para que no quede en URLs ni logs de acceso. `hide_credentials: true`: el backend no recibe la llave (el log del mock muestra `api-key-recibida=no`) pero sí `X-Consumer-Username`. Dos consumidores ficticios con llaves marcadas `NO-REAL`. |
| **Prueba** | Sin header · `x-api-key: llave-incorrecta-123` · llave en query string (`?apikey=…`) · `x-api-key: lab-qa-41d8b6f0-NO-REAL`. |
| **Resultado esperado** | 401 · 401 · 401 (query deshabilitado) · 200. Los 401 incluyen `WWW-Authenticate: Key realm="kong"` y no llegan al backend (no aparecen en su log). |
| **Observado** | _(pegar)_ |
| **Análisis** | **Autenticación ≠ autorización.** La API Key solo responde *«¿quién es la aplicación cliente?»* (AuthN). No dice *qué* puede hacer: Kong no sabe si la matrícula 501 pertenece al estudiante que usa la app, ni si ese consumidor debería ver pagos. Una llave válida identifica a una **aplicación**, no a un **usuario final**, y además es un secreto compartido que puede filtrarse. La autorización (AuthZ) —«este sujeto puede leer este recurso concreto»— depende de reglas de negocio y datos que viven en cada sistema (riesgo OWASP API1: *Broken Object Level Authorization*). |
| **Limitación** | Las llaves están en texto plano en `kong.yml` (aceptable solo en laboratorio). Sin rotación, expiración ni TLS: en HTTP la llave viaja en claro. No hay control por consumidor de qué rutas puede usar (eso requeriría el plugin `acl`). |

## Reto 3 — Controlar el consumo

| Registro | Contenido |
|---|---|
| **Hipótesis** | Si aplico `rate-limiting` con `minute: 5` al Consumer `app-movil-educonnect`, al enviar 6–7 solicitudes dentro del mismo minuto (repartidas entre estudiantes, matrículas y pagos) espero 200 en las 5 primeras y **429** desde la 6.ª, porque el plugin no está atado a Route ni Service y su contador es único para ese consumidor. Espero que `X-RateLimit-Remaining-Minute` baje 4→0. |
| **Decisión** | `limit_by: consumer`, `policy: local` (la política `cluster` no está soportada en DB-less; `redis` exigiría otro componente). Alcances combinados: **Global 60/min por consumidor** como protección base, **Consumer 5/min** para el consumidor de prueba. Se usa otro consumidor (`qa-integracion`) para las pruebas funcionales, para no consumir la cuota del Reto 3. |
| **Prueba** | El script espera al inicio de un minuto si quedan < 20 s, registra la hora de inicio y envía 7 solicitudes seguidas con `x-api-key: lab-movil-7f3a9c2e-NO-REAL` a `/api/estudiantes, /api/matriculas, /api/pagos, …`. Luego una solicitud con la llave de `qa-integracion`. |
| **Resultado esperado** | #1–#5: 200 (restante 4,3,2,1,0). #6–#7: 429 `{"message":"API rate limit exceeded"}` con `Retry-After`. `qa-integracion`: 200 en la misma ventana. |
| **Observado** | _(pegar hora de inicio + 7 líneas)_ |
| **Análisis** | **Alcance real del límite:** 5 solicitudes por minuto calendario, **por consumidor, sumando las tres APIs**, **por nodo de Kong**. Verificado en el código de Kong 3.9.1 (`plugins/rate-limiting/policies/init.lua`): la clave del contador es `ratelimit:<route_id>:<service_id>:<identificador>:<ventana>`, donde route/service son los del **plugin**; al estar asociado solo al Consumer quedan vacíos y el contador es compartido entre rutas. La ventana es fija (no deslizante): si la secuencia cruza el cambio de minuto, el contador se reinicia y pueden verse más de 5 respuestas 200 seguidas. **Con varias instancias del gateway**, cada nodo cuenta por separado en su memoria: con N nodos detrás de un balanceador round-robin el consumidor podría lograr hasta 5×N req/min, y los contadores se pierden al reiniciar. **Solución empresarial:** política `redis` (contador compartido; o *Rate Limiting Advanced* con Redis Cluster/Sentinel y ventana deslizante en la edición Enterprise), balanceo con afinidad por consumidor (hash consistente), o límites en una capa dedicada (API management / WAF). |
| **Limitación** | No demuestra exactitud bajo concurrencia ni con múltiples nodos. `fault_tolerant: true` prioriza disponibilidad: si el almacenamiento del contador falla, se deja pasar el tráfico. |

## Reto 4 — Verificar comportamiento (casos negativos)

| Registro | Contenido |
|---|---|
| **Hipótesis** | (a) `GET /api/no-existe` → **404**, porque ninguna Route coincide y Kong responde antes de ejecutar plugins de autenticación. (b) `POST /api/estudiantes` → **404**, porque la Route solo admite GET. (c) Con `ms-pagos` detenido, `GET /api/pagos` → **502, 503 o 504**, porque Kong autentica y aplica límites, pero no logra conectar con el upstream. (d) Al reiniciarlo, vuelve 200 en pocos segundos gracias al TTL DNS corto. |
| **Decisión** | `connect_timeout: 2000 ms` y `retries: 1` para que el fallo sea rápido y observable. Prueba automatizada que detiene y reinicia el contenedor y captura el log de Kong. |
| **Prueba** | `curl …/api/no-existe` · `curl -X POST …/api/estudiantes` · `docker compose stop ms-pagos` → `curl …/api/pagos` → `docker compose logs kong` → `docker compose start ms-pagos` → reintentos cada 2 s. |
| **Resultado esperado** | 404 `{"message":"no Route matched with those values"}` (×2) · 502/503/504 · 200 tras la recuperación. |
| **Observado** | _(pegar código obtenido y fragmento del log de Kong)_ |
| **Análisis** | El código depende de **dónde** falla la conexión: **503** `name resolution failed` si Kong ya no puede resolver `ms-pagos` (el contenedor detenido desaparece del DNS de Docker); **502** si aún tiene la IP en caché y la conexión es rechazada / el host es inalcanzable; **504** si se agota `connect_timeout`. Los tres indican que el problema está **detrás** del gateway (no es error del cliente). El 404 de ruta inexistente lo genera Kong (no llega a ningún backend) y es distinto del 404 que devolvería un backend ante un recurso inexistente: el cuerpo del mensaje permite distinguirlos. |
| **Limitación** | No hay *health checks* activos ni *circuit breaker*: Kong intenta cada solicitud contra un backend caído. No se prueba degradación parcial ni latencia alta. |

## Desafío de transferencia — Certificados Académicos

| Registro | Contenido |
|---|---|
| **Hipótesis** | Si agrego `ms-certificados` en Compose y un Service/Route `/api/certificados`, la ruta quedará protegida **sin tocar key-auth** (es global). Si agrego un `rate-limiting` de alcance Route con `minute: 3`, espero que `qa-integracion` reciba 429 en la 4.ª solicitud. Predicción inicial errónea a revisar: «app-movil también tendrá 3/min». Por la precedencia de Kong (Consumer > Route), app-movil seguiría con su límite de Consumer (5/min compartido), así que se añade una regla Consumer+Route de 2/min. |
| **Decisión / cambios** | 1) `docker-compose.yml`: nuevo servicio `ms-certificados` (mismo mock, `PORT=3004`). 2) `mocks/data/certificados.json`. 3) `kong.yml`: `svc-certificados` + `rt-certificados`. 4) Plugin Route `rl-certificados-ruta` (3/min por consumidor, contador propio). 5) Plugin Consumer+Route `rl-app-movil-certificados` (2/min). Justificación: emitir certificados es costoso y sensible; merece un límite más estricto que las consultas. |
| **Prueba** | Sin llave → 401. `qa-integracion` ×4 → 200,200,200,429. `app-movil-educonnect` ×3 → 200,200,429. |
| **Resultado esperado** | Como se indica; `X-Servicio-Origen: ms-certificados`. |
| **Observado** | _(pegar)_ |
| **Análisis** | Kong ejecuta **una sola instancia** de un mismo plugin por solicitud: la más específica según la precedencia documentada (Consumer+Route > Consumer+Service > Route+Service > Consumer > Route > Service > Global). Por eso la regla de ruta no bastaba para app-movil. La edición OSS permite límites por Consumer, Route, Service, Consumer+Route y Global con políticas `local`/`redis`; no ofrece ventanas deslizantes ni límites por *Consumer Group* (eso es de *Rate Limiting Advanced*, Enterprise). Las solicitudes a certificados **no** descuentan del contador de 5/min de las otras APIs (claves de contador distintas). |
| **Limitación** | Requiere reiniciar Kong para aplicar cambios (DB-less). La precedencia hace que la configuración crezca por cada consumidor especial; a escala convendría agrupar consumidores (Consumer Groups, Enterprise) o gestionar la configuración con decK/CI. |
