# Diagrama de arquitectura de la PoC

![Arquitectura de la PoC EduConnect](arquitectura.png)

(Fuente vectorial editable: [`arquitectura.svg`](arquitectura.svg).)

## Versión Mermaid (se renderiza en GitHub/GitLab)

```mermaid
flowchart LR
  subgraph C[Clientes externos]
    M[App móvil<br/>Consumer app-movil-educonnect]
    Q[Postman / scripts QA<br/>Consumer qa-integracion]
    X[Cliente sin llave]
  end

  subgraph H[Equipo local - Docker host]
    P8000((:8000 público))
    P8001((:8001 solo 127.0.0.1))
    subgraph N[Red bridge educonnect-net - DNS interno]
      subgraph K[Kong 3.9.1 DB-less]
        R[1. Router<br/>/api/estudiantes, /api/matriculas,<br/>/api/pagos, /api/certificados]
        A[2. key-auth global<br/>header x-api-key]
        L[3. rate-limiting<br/>Consumer+Route 2/min · Consumer 5/min<br/>Route certificados 3/min · Global 60/min]
        S[4. Proxy al Service]
        R --> A --> L --> S
      end
      E[ms-estudiantes:3001]
      MA[ms-matriculas:3002]
      PA[ms-pagos:3003]
      CE[ms-certificados:3004]
    end
  end

  M --> P8000
  Q --> P8000
  X -. 401 .-> P8000
  P8000 --> R
  P8001 -.-> K
  S --> E & MA & PA & CE
```

## Lectura del diagrama

| Elemento | Rol | Decisión clave |
|---|---|---|
| Puerto 8000 | Único punto de entrada público | Los backends no publican puertos; solo son alcanzables a través de Kong. |
| Puerto 8001 | Admin API | Publicado solo en `127.0.0.1` para consultar evidencias; nunca expuesto a la red. |
| Router (Routes) | Criterio de coincidencia | Prefijo `/api/<recurso>`, solo `GET`, `strip_path: true`. |
| key-auth | Autenticación del consumidor | Alcance global (seguro por defecto), llave solo en header, `hide_credentials`. |
| rate-limiting | Control de consumo | Cuatro alcances con precedencia Consumer+Route > Consumer > Route > Global. |
| Service | Destino | URL por nombre DNS de Compose; timeouts cortos para fallar rápido. |
| Red `educonnect-net` | Descubrimiento | DNS interno de Docker: Kong resuelve `ms-pagos` sin IP fija. |
