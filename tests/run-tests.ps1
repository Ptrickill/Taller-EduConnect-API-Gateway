# =============================================================================
# EduConnect PoC - Pruebas reproducibles para Windows (PowerShell 5.1 o 7+)
# Uso (desde la raíz del repositorio):
#   powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1
# Usa curl.exe (incluido en Windows 10/11) para leer códigos HTTP sin excepciones.
# =============================================================================
$ErrorActionPreference = "Continue"
$GW        = "http://localhost:8000"
$ADMIN     = "http://localhost:8001"
$KEY_QA    = "lab-qa-41d8b6f0-NO-REAL"
$KEY_MOVIL = "lab-movil-7f3a9c2e-NO-REAL"
$KEY_MALA  = "llave-incorrecta-123"
$HDR       = "x-api-key"

Set-Location (Join-Path $PSScriptRoot "..")
New-Item -ItemType Directory -Force -Path evidencias | Out-Null
$LOG = "evidencias\resultados-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss")
Start-Transcript -Path $LOG | Out-Null

$script:PASS = 0; $script:FAIL = 0
function Ts { Get-Date -Format "yyyy-MM-dd HH:mm:ss" }
function Titulo($t) { Write-Host "`n==================== $t ====================" }

function Req {
  param([string]$Url, [string]$Key = "", [string]$Method = "GET", [int]$Timeout = 15)
  $hdrFile = [System.IO.Path]::GetTempFileName()
  $cargs = @("-s", "-X", $Method, "-D", $hdrFile, "--max-time", "$Timeout", $Url)
  if ($Key -ne "") { $cargs += @("-H", "${HDR}: $Key") }
  $body = & curl.exe @cargs
  $h = Get-Content $hdrFile -ErrorAction SilentlyContinue
  Remove-Item $hdrFile -ErrorAction SilentlyContinue
  $code   = if ($h) { ($h[0] -split " ")[1] } else { "sin-respuesta" }
  $origen = ($h | Where-Object { $_ -match "^X-Servicio-Origen:" }) -replace "^X-Servicio-Origen:\s*", ""
  $rem    = ($h | Where-Object { $_ -match "^X-RateLimit-Remaining-Minute:" }) -replace "^X-RateLimit-Remaining-Minute:\s*", ""
  Write-Host ("[{0}] {1} {2} -> HTTP {3} | origen={4} | restante/min={5}" -f (Ts), $Method, $Url, $code, $origen, $rem)
  if ($body) { Write-Host ("    cuerpo: " + ($body | Out-String).Trim()) }
  return [pscustomobject]@{ Code = $code; Origen = "$origen".Trim() }
}

function Check($desc, $esperado, $obtenido) {
  if ("$obtenido" -match "^($esperado)$") { $script:PASS++; Write-Host "    [OK]    $desc (esperado $esperado, obtenido $obtenido)" -ForegroundColor Green }
  else { $script:FAIL++; Write-Host "    [FALLA] $desc (esperado $esperado, obtenido $obtenido)" -ForegroundColor Red }
}

function EsperarInicioVentana {
  $s = (Get-Date).Second
  if ($s -gt 40) { Write-Host "[$(Ts)] Segundo=$s; esperando $((61 - $s)) s al siguiente minuto..."; Start-Sleep -Seconds (61 - $s) }
}

Titulo "RETO 0 - Contenedores, versión y red interna"
docker compose ps
docker compose exec -T kong kong version
docker compose exec -T ms-estudiantes wget -qO- http://ms-pagos:3003/pagos; Write-Host ""
$c = & curl.exe -s -o NUL -w "%{http_code}" --max-time 2 http://localhost:3001/estudiantes
Check "Backend no expuesto directamente" "000" $c

Titulo "RETO 1 - Punto de acceso único"
foreach ($r in "estudiantes", "matriculas", "pagos") {
  $x = Req "$GW/api/$r" $KEY_QA
  Check "GET /api/$r responde 200" "200" $x.Code
  Check "GET /api/$r atendido por ms-$r" "ms-$r" $x.Origen
}

Titulo "RETO 2 - API Key (encabezado $HDR)"
Check "Sin API Key"        "401" (Req "$GW/api/estudiantes").Code
Check "API Key incorrecta" "401" (Req "$GW/api/estudiantes" $KEY_MALA).Code
Check "API Key válida"     "200" (Req "$GW/api/matriculas" $KEY_QA).Code

Titulo "RETO 3 - 5 req/min para app-movil-educonnect"
EsperarInicioVentana
Write-Host "[$(Ts)] INICIO de la secuencia"
$rutas = "estudiantes","matriculas","pagos","estudiantes","matriculas","pagos","pagos"
for ($i = 0; $i -lt $rutas.Count; $i++) {
  $n = $i + 1
  $x = Req "$GW/api/$($rutas[$i])" $KEY_MOVIL
  if ($n -le 5) { Check "Solicitud #$n (dentro del límite)" "200" $x.Code } else { Check "Solicitud #$n (supera el límite)" "429" $x.Code }
}
Check "Otro consumidor (qa) sigue con 200" "200" (Req "$GW/api/estudiantes" $KEY_QA).Code

Titulo "RETO 4 - Ruta no registrada y backend caído"
Check "Ruta no registrada" "404" (Req "$GW/api/no-existe" $KEY_QA).Code
Check "POST no habilitado en la Route" "404" (Req "$GW/api/estudiantes" $KEY_QA "POST").Code
Write-Host "[$(Ts)] Deteniendo ms-pagos..."; docker compose stop ms-pagos
Check "Backend no disponible" "502|503|504" (Req "$GW/api/pagos" $KEY_QA).Code
docker compose logs --since 30s kong 2>&1 | Select-String -Pattern "pagos|upstream|resolve|connect" | Select-Object -Last 5
Write-Host "[$(Ts)] Reiniciando ms-pagos..."; docker compose start ms-pagos
for ($k = 1; $k -le 10; $k++) { Start-Sleep -Seconds 2; $x = Req "$GW/api/pagos" $KEY_QA; if ($x.Code -eq "200") { break } }
Check "Backend recuperado (intento $k)" "200" $x.Code

Titulo "DESAFÍO - Certificados"
Check "Certificados sin API Key" "401" (Req "$GW/api/certificados").Code
EsperarInicioVentana
for ($n = 1; $n -le 4; $n++) {
  $x = Req "$GW/api/certificados" $KEY_QA
  if ($n -le 3) { Check "Certificados qa #$n (límite ruta 3/min)" "200" $x.Code } else { Check "Certificados qa #$n" "429" $x.Code }
}
for ($n = 1; $n -le 3; $n++) {
  $x = Req "$GW/api/certificados" $KEY_MOVIL
  if ($n -le 2) { Check "Certificados app-movil #$n (Consumer+Route 2/min)" "200" $x.Code } else { Check "Certificados app-movil #$n" "429" $x.Code }
}

Titulo "Configuración cargada (Admin API)"
(Invoke-RestMethod "$ADMIN/services").data | Select-Object name, host, port, path | Format-Table
(Invoke-RestMethod "$ADMIN/routes").data   | Select-Object name, @{n="paths";e={$_.paths -join ","}}, strip_path | Format-Table
(Invoke-RestMethod "$ADMIN/plugins").data  | Select-Object instance_name, name, @{n="consumer";e={$_.consumer.id}}, @{n="route";e={$_.route.id}} | Format-Table

Titulo "RESUMEN"
Write-Host "Correctas: $script:PASS | Fallidas: $script:FAIL | Evidencia: $LOG"
Stop-Transcript | Out-Null
