# Decisiones arquitectónicas de la PoC EduConnect API Gateway

**Alcance:** prueba de concepto local para validar un API Gateway (Kong 3.9.1 OSS) frente a cuatro APIs existentes, sin reescribirlas.

## 1. Decisiones y justificación

| # | Decisión | Alternativa descartada | Por qué |
|---|---|---|---|
| D1 | Kong **3.9.1 OSS** fijado en la imagen | `latest` / Enterprise | Reproducibilidad exacta; 3.9.x es la última línea OSS y cubre todo lo requerido sin licencia. |
| D2 | Modo **DB-less** con `kong.yml` declarativo | Kong + PostgreSQL + Admin API | Configuración versionable en Git, sin dependencias ni estado oculto. Costo: cambios requieren reinicio y la política `cluster` de rate limiting no está disponible. |
| D3 | Backends direccionados por **nombre DNS** de Compose; sin puertos publicados | IPs fijas / puertos expuestos | Desacopla de IPs efímeras y obliga a que todo tráfico externo pase por el gateway. TTL DNS de Kong reducido a 5 s para tolerar reinicios. |
| D4 | Rutas `/api/<recurso>` con `strip_path` y solo `GET` | Exponer rutas internas tal cual | Contrato público estable e independiente de la implementación; mínimo privilegio en métodos. |
| D5 | `key-auth` **global**, llave solo en header `x-api-key`, `hide_credentials` | Plugin por ruta; llave en query | Seguro por defecto (Certificados quedó protegido sin cambios); la llave no aparece en URLs/logs ni llega al backend. |
| D6 | `rate-limiting` en capas: Global 60/min, Consumer 5/min, Route certificados 3/min, Consumer+Route 2/min | Un único límite global | Protección base para todos + reglas de negocio específicas; aprovecha la precedencia de Kong (gana la más específica). |
| D7 | Mock único parametrizado en Node.js, 4 contenedores independientes | 4 implementaciones distintas | Menos de 30 min de construcción; el foco es la integración. Cada respuesta identifica al servicio (`servicio`, `X-Servicio-Origen`) y registra consumer y llamada. |
| D8 | Timeouts de conexión cortos (2 s) y 1 reintento | Valores por defecto (60 s, 5 reintentos) | Fallos de backend rápidos y observables, sin bloquear al cliente. |

## 2. Autenticación (AuthN) vs. autorización (AuthZ)

- **AuthN** responde *¿quién llama?* En la PoC, Kong identifica a la **aplicación** consumidora mediante su API Key y propaga `X-Consumer-Username` al backend.
- **AuthZ** responde *¿puede este sujeto hacer esta operación sobre este recurso?* Requiere conocer al **usuario final**, la propiedad de los datos (¿la matrícula 501 es de este estudiante?) y reglas de negocio que solo conocen los sistemas de Estudiantes, Matrículas y Pagos.
- Una API Key válida **no** prueba permiso: identifica a una app, no a una persona, y es un secreto compartido que puede filtrarse. El gateway puede aplicar autorización *gruesa* (qué consumidor accede a qué API, con el plugin `acl`, o validar scopes de un JWT), pero la autorización *fina* por objeto sigue siendo obligatoria en cada backend (OWASP API1:2023, *Broken Object Level Authorization*).

## 3. Límites de la PoC (lo que **no** demuestra)

1. **Identidad de usuarios finales**: no hay OAuth2/OIDC ni tokens de usuario.
2. **Autorización de negocio**: ninguna regla por recurso ni por rol.
3. **Seguridad de transporte y secretos**: HTTP sin TLS; llaves en texto plano en `kong.yml`, sin rotación ni expiración.
4. **Alta disponibilidad y escalado**: un solo nodo de Kong; contadores de rate limiting en memoria local (con N nodos el límite efectivo sería hasta N×, y se pierde al reiniciar).
5. **Observabilidad**: solo logs en consola; sin métricas, trazas distribuidas ni alertas.
6. **Resiliencia**: sin health checks activos, circuit breaker ni caché.
7. **Validación con carga real**: las pruebas son funcionales y secuenciales; no hay pruebas de concurrencia ni rendimiento.

## 4. Mejoras para un despliegue productivo

- **Escalado horizontal**: ≥ 2 nodos de Kong detrás de un balanceador; rate limiting con política **`redis`** (Redis gestionado y replicado) o *Rate Limiting Advanced* con ventana deslizante; configuración gestionada con **decK** en un pipeline CI/CD (o modo híbrido control plane / data plane).
- **Identidad**: OAuth2/OIDC con un IdP (Keycloak, Entra ID…) y validación de JWT en el gateway (`jwt` / `openid-connect`); API Keys solo para integraciones máquina-a-máquina, con rotación y almacenamiento cifrado (Vault / secretos del orquestador).
- **Autorización**: plugin `acl` o *consumer groups* para acceso por API; AuthZ fina por objeto en cada servicio, idealmente con un motor de políticas (OPA).
- **Transporte**: TLS en el borde y mTLS hacia los backends; Admin API deshabilitada o protegida por red y RBAC.
- **Observabilidad**: plugins `prometheus` + Grafana, trazas OpenTelemetry, logs centralizados con `X-Request-ID`/correlation-id.
- **Resiliencia y protección**: health checks activos/pasivos en *Upstreams*, `request-size-limiting`, `cors`, `bot-detection`, WAF delante del gateway, y límites diferenciados por plan de consumidor.
- **Gobierno de APIs**: versionado (`/api/v1/...`), catálogo/portal de desarrolladores y contratos OpenAPI publicados.
