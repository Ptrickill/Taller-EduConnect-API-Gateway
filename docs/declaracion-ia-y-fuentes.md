# Declaración de uso de IA y fuentes consultadas

## Uso de IA generativa


**Integrantes:** JOSE CARVAJAL, DANIEL DIAZ, DARWIN LOPEZ, DILAN HERRERA · **Fecha:** 25/11/2026

Se utilizó **Claude (Anthropic)** como asistente para: proponer la estructura del repositorio, redactar borradores de `docker-compose.yml`, `kong.yml`, el mock en Node.js, los scripts de prueba, la colección Postman y la documentación. Cada decisión técnica se contrastó con la documentación oficial y, en los puntos críticos, con el **código fuente de Kong 3.9.1**:

| Afirmación usada en la PoC | Cómo se verificó |
|---|---|
| `key-auth` responde 401 sin llave («No API key found in request») y 401 con llave inválida («Unauthorized») | Docs de Key Authentication + `kong/plugins/key-auth/handler.lua` (tag 3.9.1) |
| Campos `key_names`, `key_in_header/query/body`, `hide_credentials` | `kong/plugins/key-auth/schema.lua` (3.9.1) |
| En DB-less solo se admiten las políticas `local` y `redis` de rate limiting | Docs del plugin Rate Limiting |
| El contador se agrega por consumidor y usa la Route/Service **del plugin** (por eso el límite de Consumer suma todas las rutas) | `kong/plugins/rate-limiting/policies/init.lua`, función `get_local_key` (3.9.1) |
| 429 con «API rate limit exceeded» por defecto | `kong/plugins/rate-limiting/schema.lua` (`error_code`, `error_message`) |
| Precedencia de plugins (Consumer+Route > Consumer > Route > Global) | Docs «Plugins – scoping and precedence» |
| Referencias de Route/Consumer en `kong.yml` válidas | `deck file validate` (decK v1.43.0) sin errores |
| `kong:3.9.1` existe como imagen oficial y 3.9.x es la línea OSS | Docker Hub (library/kong) + guía de instalación de Kong |

Ninguna decisión se justifica únicamente por sugerencia de la IA. Los resultados de la matriz de evidencias provienen de la ejecución real de los scripts en el equipo del grupo.

## Fuentes consultadas

- Kong Gateway — documentación general: https://developer.konghq.com/gateway/
- Kong — modo DB-less: https://developer.konghq.com/gateway/db-less-mode/
- Kong — Key Authentication: https://developer.konghq.com/plugins/key-auth/
- Kong — Rate Limiting: https://developer.konghq.com/plugins/rate-limiting/
- Kong — Plugins (alcance y precedencia): https://developer.konghq.com/gateway/entities/plugin/
- Kong — Instalación (versiones OSS): https://developer.konghq.com/gateway/install/
- Código fuente Kong 3.9.1: https://github.com/Kong/kong/tree/3.9.1/kong/plugins
- Imagen oficial Kong en Docker Hub: https://hub.docker.com/_/kong
- Docker Compose: https://docs.docker.com/compose/
- Docker — redes bridge definidas por el usuario y DNS: https://docs.docker.com/engine/network/drivers/bridge/
- Postman — documentación: https://learning.postman.com/docs/
- OWASP API Security Top 10 (2023): https://owasp.org/API-Security/
