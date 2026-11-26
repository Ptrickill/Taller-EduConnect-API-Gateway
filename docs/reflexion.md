# Preguntas de reflexión

## 8. ¿Qué incidentes del caso EduConnect se reducen con esta PoC y cuáles permanecen sin solución?

**Se reducen:**
- *Acceso directo a múltiples APIs*: los consumidores ya no conocen hosts ni puertos internos; hay una sola dirección (`:8000/api/*`) y los backends no están expuestos.
- *Políticas heterogéneas de autenticación*: una única política (API Key en `x-api-key`) aplicada de forma uniforme y por defecto a toda ruta nueva.
- *Sobrecarga por consumidores externos*: límites por consumidor y por endpoint; los excesos se rechazan con 429 en el gateway, sin llegar al backend.
- *Visibilidad operativa* (parcialmente): el access log de Kong centraliza qué consumidor llamó, a qué ruta, con qué código y latencia.

**Permanecen:**
- Autorización de negocio e identidad de usuarios finales.
- Visibilidad real (métricas, trazas distribuidas, alertas, dashboards).
- Alta disponibilidad: el gateway es un único nodo y los contadores no se comparten.
- Seguridad de transporte y gestión de secretos.
- Los problemas internos de cada sistema (rendimiento, datos inconsistentes, errores de negocio) no cambian por ponerles un gateway delante.

## 9. ¿Por qué el gateway no elimina la obligación de autorizar operaciones y recursos dentro de los sistemas?

Porque el gateway solo ve la solicitud HTTP (ruta, cabeceras, credencial) y no los datos ni las reglas de negocio. No sabe si la matrícula 501 pertenece al estudiante que la consulta, ni si un pago puede verse en cierto estado. Además, aplicar *defensa en profundidad* implica que un backend no debe confiar ciegamente en que todo tráfico venga filtrado: una mala configuración del gateway, un acceso interno o un consumidor legítimo malicioso (llave válida usada para enumerar IDs) saltarían una seguridad centralizada solo en el borde. La autorización a nivel de objeto es la vulnerabilidad n.º 1 de OWASP API Security precisamente porque debe resolverse donde vive el dato.

## 10. ¿Cuál es la principal ventaja y el principal riesgo de centralizar el acceso a múltiples APIs?

- **Ventaja principal:** aplicar políticas transversales (autenticación, límites, logging, TLS) **una sola vez y de forma consistente**, desacoplando a los consumidores de la topología interna; cambiar o mover un backend no afecta el contrato público.
- **Riesgo principal:** el gateway se convierte en **punto único de falla y de ataque**. Si cae, caen todas las APIs; si se compromete o se configura mal (por ejemplo, un plugin global desactivado), todas quedan expuestas. También puede convertirse en cuello de botella de rendimiento y de gobierno (un equipo central del que dependen todos los cambios).

## 11. ¿Qué modificarían antes de desplegar en producción con múltiples instancias?

1. Rate limiting con política `redis` (contador compartido) o balanceo con afinidad por consumidor; revisar `fault_tolerant` según el riesgo de negocio.
2. Varias instancias de Kong detrás de un balanceador con health checks, y configuración distribuida con decK/CI (o modo híbrido CP/DP) para que todos los nodos tengan exactamente la misma versión.
3. TLS en el borde, Admin API cerrada a la red y protegida, credenciales fuera del repositorio (vault) con rotación.
4. OAuth2/OIDC para usuarios finales + `acl` para separar qué consumidor accede a qué API.
5. Observabilidad: métricas Prometheus, trazas OpenTelemetry, logs centralizados con ID de correlación.
6. Health checks y circuit breaking en los Upstreams; pruebas de carga para dimensionar límites y nodos.
