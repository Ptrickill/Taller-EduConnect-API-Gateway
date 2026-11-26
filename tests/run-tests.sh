#!/usr/bin/env bash
# =============================================================================
# EduConnect PoC - Pruebas reproducibles (Retos 0 a 4 + Certificados)
# Uso:   bash tests/run-tests.sh            (desde la raíz del repositorio)
# Salida: consola + evidencias/resultados-AAAAMMDD-HHMMSS.log
# Requisitos: docker compose, curl. (jq opcional, solo para formato)
# =============================================================================
set -u

GW="${GW:-http://localhost:8000}"
ADMIN="${ADMIN:-http://localhost:8001}"
KEY_QA="lab-qa-41d8b6f0-NO-REAL"          # consumidor qa-integracion
KEY_MOVIL="lab-movil-7f3a9c2e-NO-REAL"    # consumidor app-movil-educonnect (Reto 3)
KEY_MALA="llave-incorrecta-123"
HDR="x-api-key"

cd "$(dirname "$0")/.." || exit 1
mkdir -p evidencias
LOG="evidencias/resultados-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

PASS=0; FAIL=0
ts() { date '+%Y-%m-%d %H:%M:%S'; }
titulo() { printf '\n==================== %s ====================\n' "$1"; }

# req METODO URL [header...] -> imprime línea de evidencia, deja estado en $CODE y cuerpo en $BODY
req() {
  local url="$1"; shift
  local hdrs; hdrs=$(mktemp)
  BODY=$(curl -s -D "$hdrs" -o - "$@" "$url")
  CODE=$(head -1 "$hdrs" | awk '{print $2}')
  ORIGEN=$(grep -i '^X-Servicio-Origen:' "$hdrs" | tr -d '\r' | cut -d' ' -f2)
  REM=$(grep -i '^X-RateLimit-Remaining-Minute:' "$hdrs" | tr -d '\r' | cut -d' ' -f2)
  RETRY=$(grep -i '^Retry-After:' "$hdrs" | tr -d '\r' | cut -d' ' -f2)
  rm -f "$hdrs"
  echo "[$(ts)] GET $url -> HTTP ${CODE:-sin-respuesta} | origen=${ORIGEN:--} | restante/min=${REM:--} ${RETRY:+| Retry-After=$RETRY}"
  echo "    cuerpo: ${BODY:0:160}"
}

check() { # check "descripcion" esperado(regex) obtenido
  if [[ "$3" =~ ^($2)$ ]]; then PASS=$((PASS+1)); echo "    [OK]   $1 (esperado $2, obtenido $3)";
  else FAIL=$((FAIL+1)); echo "    [FALLA] $1 (esperado $2, obtenido $3)"; fi
}

esperar_inicio_ventana() { # evita que la secuencia cruce el cambio de minuto
  local s; s=$((10#$(date +%S)))
  if (( s > 40 )); then
    echo "[$(ts)] Segundo actual=$s; se espera $((61 - s)) s al inicio del siguiente minuto para no partir la ventana..."
    sleep $((61 - s))
  fi
}

echo "Log de evidencias: $LOG"
echo "Inicio: $(ts) | Gateway: $GW"

# --------------------------------------------------------------------- RETO 0
titulo "RETO 0 - Contenedores, versión y red interna"
docker compose ps
echo; echo "Versión de Kong:"; docker compose exec -T kong kong version
echo; echo "Admin API (solo localhost) -> versión y modo:"
curl -s "$ADMIN" | grep -o '"version":"[^"]*"\|"database":"[^"]*"' | sort -u
echo; echo "Conectividad interna por nombre DNS (desde ms-estudiantes hacia ms-pagos):"
docker compose exec -T ms-estudiantes wget -qO- http://ms-pagos:3003/pagos; echo
echo; echo "Los backends NO están publicados en el host (se espera fallo de conexión):"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://localhost:3001/estudiantes)
echo "    curl http://localhost:3001/estudiantes -> ${code} (000 = sin conexión)"
check "Backend no expuesto directamente" "000" "$code"

# --------------------------------------------------------------------- RETO 1
titulo "RETO 1 - Punto de acceso único (/api/*)"
for r in estudiantes matriculas pagos; do
  req "$GW/api/$r" -H "$HDR: $KEY_QA"
  check "GET /api/$r responde 200" "200" "$CODE"
  check "GET /api/$r atendido por ms-$r" "ms-$r" "${ORIGEN:-ninguno}"
done

# --------------------------------------------------------------------- RETO 2
titulo "RETO 2 - Autenticación por API Key (encabezado $HDR)"
req "$GW/api/estudiantes"
check "Sin API Key" "401" "$CODE"
req "$GW/api/estudiantes" -H "$HDR: $KEY_MALA"
check "API Key incorrecta" "401" "$CODE"
req "$GW/api/estudiantes?apikey=$KEY_QA"
check "API Key en query string (deshabilitado a propósito)" "401" "$CODE"
req "$GW/api/matriculas" -H "$HDR: $KEY_QA"
check "API Key válida" "200" "$CODE"

# --------------------------------------------------------------------- RETO 3
titulo "RETO 3 - Rate limiting: 5 req/min para app-movil-educonnect"
esperar_inicio_ventana
echo "[$(ts)] INICIO de la secuencia (ventana de minuto fijo)."
rutas=(estudiantes matriculas pagos estudiantes matriculas pagos pagos)
for i in "${!rutas[@]}"; do
  n=$((i+1))
  req "$GW/api/${rutas[$i]}" -H "$HDR: $KEY_MOVIL"
  if (( n <= 5 )); then check "Solicitud #$n (dentro del límite)" "200" "$CODE";
  else check "Solicitud #$n (supera el límite)" "429" "$CODE"; fi
done
echo "Aislamiento por consumidor: qa-integracion no se ve afectado en la misma ventana:"
req "$GW/api/estudiantes" -H "$HDR: $KEY_QA"
check "Otro consumidor sigue con 200" "200" "$CODE"

# --------------------------------------------------------------------- RETO 4
titulo "RETO 4 - Casos negativos: ruta no registrada y backend caído"
req "$GW/api/no-existe" -H "$HDR: $KEY_QA"
check "Ruta no registrada" "404" "$CODE"
req "$GW/api/estudiantes" -X POST -H "$HDR: $KEY_QA"
check "Método no habilitado en la Route (POST)" "404" "$CODE"

echo "[$(ts)] Deteniendo temporalmente ms-pagos..."
docker compose stop ms-pagos
req "$GW/api/pagos" -H "$HDR: $KEY_QA" --max-time 15
check "Backend no disponible (502/503/504 según causa)" "502|503|504" "$CODE"
echo "Fragmento del log de Kong para esa solicitud:"
docker compose logs --since 30s kong 2>&1 | grep -iE 'pagos|upstream|resolve|connect' | tail -5
echo "[$(ts)] Reiniciando ms-pagos..."
docker compose start ms-pagos
for intento in 1 2 3 4 5 6 7 8 9 10; do   # Kong re-resuelve el DNS (TTL corto configurado)
  sleep 2
  req "$GW/api/pagos" -H "$HDR: $KEY_QA"
  [[ "$CODE" == "200" ]] && break
done
check "Backend recuperado (intento $intento)" "200" "$CODE"

# ------------------------------------------------------------ TRANSFERENCIA
titulo "DESAFÍO - Certificados (/api/certificados)"
req "$GW/api/certificados"
check "Certificados sin API Key" "401" "$CODE"
esperar_inicio_ventana
echo "[$(ts)] qa-integracion: límite de la ruta = 3 req/min (contador propio de certificados)"
for n in 1 2 3 4; do
  req "$GW/api/certificados" -H "$HDR: $KEY_QA"
  if (( n <= 3 )); then check "Certificados qa #$n" "200" "$CODE"; else check "Certificados qa #$n" "429" "$CODE"; fi
done
echo "[$(ts)] app-movil-educonnect: regla Consumer+Route = 2 req/min en certificados"
for n in 1 2 3; do
  req "$GW/api/certificados" -H "$HDR: $KEY_MOVIL"
  if (( n <= 2 )); then check "Certificados app-movil #$n" "200" "$CODE"; else check "Certificados app-movil #$n" "429" "$CODE"; fi
done

# ----------------------------------------------------------------- RESUMEN
titulo "Configuración efectiva cargada en Kong (Admin API)"
echo "Services:";  curl -s "$ADMIN/services" | grep -o '"name":"svc-[^"]*"' | sort -u
echo "Routes:";    curl -s "$ADMIN/routes"   | grep -o '"name":"rt-[^"]*"'  | sort -u
echo "Plugins:";   curl -s "$ADMIN/plugins"  | grep -o '"instance_name":"[^"]*"' | sort -u

titulo "RESUMEN"
echo "Fin: $(ts) | Correctas: $PASS | Fallidas: $FAIL"
echo "Evidencia guardada en: $LOG"
echo "Logs de los mocks:  docker compose logs ms-estudiantes ms-matriculas ms-pagos ms-certificados"
exit $(( FAIL > 0 ))
