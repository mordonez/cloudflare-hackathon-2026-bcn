#!/usr/bin/env bash
# demo.sh — GateWatch Live Demo
#
# Usage:
#   ADMIN_SECRET=<your-secret> WORKER=https://gatewatch-proxy.<subdomain>.workers.dev bash demo.sh

set -euo pipefail

WORKER="${WORKER:-https://gatewatch-proxy.<subdomain>.workers.dev}"
ADMIN_SECRET="${ADMIN_SECRET:?Set ADMIN_SECRET env var before running demo.sh}"
MODEL="@cf/moonshotai/kimi-k2.6"

BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; WHITE='\033[1;37m'; BLUE='\033[0;34m'

TOTAL=0; PASSED=0; BLOCKED=0
TMPDIR_GW=$(mktemp -d)
trap 'rm -rf "$TMPDIR_GW"' EXIT

# ── Helpers ───────────────────────────────────────────────────────────────────
banner()  { echo -e "\n${BOLD}${CYAN}  ╔══════════════════════════════════════════════════════════╗\n  ║  $(printf '%-56s' "$1")  ║\n  ╚══════════════════════════════════════════════════════════╝${RESET}\n"; }
divider() { echo -e "${DIM}  ─────────────────────────────────────────────────────${RESET}"; }

row_ok() {
  local num="$1" user="$2" dept="$3" tokens="$4" answer="$5"
  TOTAL=$((TOTAL+1)); PASSED=$((PASSED+1))
  printf "${GREEN}  ✔${RESET} ${BOLD}%-3s${RESET} ${MAGENTA}%-22s${RESET} ${CYAN}[%-12s]${RESET} tokens=%-5s\n" "$num" "$user" "$dept" "$tokens"
  echo -e "     ${DIM}↳ ${answer}${RESET}"
}

row_blocked() {
  local num="$1" user="$2" dept="$3" pattern="$4"
  TOTAL=$((TOTAL+1)); BLOCKED=$((BLOCKED+1))
  printf "${RED}  ✘${RESET} ${BOLD}%-3s${RESET} ${MAGENTA}%-22s${RESET} ${CYAN}[%-12s]${RESET} ${RED}BLOQUEADO${RESET}\n" "$num" "$user" "$dept"
  echo -e "     ${DIM}↳ patrón detectado: ${YELLOW}${pattern}${RESET}"
}

# ── issue_token ────────────────────────────────────────────────────────────────
issue_token() {
  curl -s -X POST "$WORKER/gatewatch/token" \
    -H "x-admin-secret: $ADMIN_SECRET" \
    -H "Content-Type: application/json" \
    -d "{\"usuario\":\"$1\",\"departamento\":\"$2\",\"project\":\"$3\",\"client\":\"$4\",\"expires_in\":\"8h\"}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['api_key'])"
}

# ── Lanza una llamada AI en background, guarda resultado en fichero ────────────
fire_ai() {
  local id="$1" key="$2" prompt="$3"
  (
    out=$(curl -s -X POST "$WORKER/workers-ai/v1/chat/completions" \
      -H "Authorization: Bearer $key" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"$prompt\"}]}")
    echo "$out" | python3 -c "
import sys, json
d = json.load(sys.stdin)
msg     = ((d.get('choices') or [{}])[0].get('message') or {})
content = msg.get('content') or msg.get('reasoning_content') or ''
if not content:
    content = (d.get('error') or {}).get('message') or 'sin respuesta'
tokens  = str((d.get('usage') or {}).get('total_tokens') or '?')
answer  = content.replace(chr(10), ' ').strip()[:90]
print(tokens + chr(9) + answer)
" 2>/dev/null || echo "?\t-"
  ) > "$TMPDIR_GW/ai_${id}.out" &
}

# ── Lanza una llamada DLP en background, guarda http_code ─────────────────────
fire_dlp() {
  local id="$1" key="$2" prompt="$3"
  (
    curl -s -o /dev/null -w "%{http_code}" \
      -X POST "$WORKER/workers-ai/v1/chat/completions" \
      -H "Authorization: Bearer $key" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"$prompt\"}]}"
  ) > "$TMPDIR_GW/dlp_${id}.out" &
}

# ── Lee resultado de fichero (espera si aún no existe) ─────────────────────────
read_result() {
  local file="$1"
  while [ ! -s "$file" ]; do sleep 0.2; done
  cat "$file"
}

# ══════════════════════════════════════════════════════════════════════════════
clear
echo ""
echo -e "${BOLD}${CYAN}"
echo "   ██████╗  █████╗ ████████╗███████╗██╗    ██╗ █████╗ ████████╗ ██████╗██╗  ██╗"
echo "  ██╔════╝ ██╔══██╗╚══██╔══╝██╔════╝██║    ██║██╔══██╗╚══██╔══╝██╔════╝██║  ██║"
echo "  ██║  ███╗███████║   ██║   █████╗  ██║ █╗ ██║███████║   ██║   ██║     ███████║"
echo "  ██║   ██║██╔══██║   ██║   ██╔══╝  ██║███╗██║██╔══██║   ██║   ██║     ██╔══██║"
echo "  ╚██████╔╝██║  ██║   ██║   ███████╗╚███╔███╔╝██║  ██║   ██║   ╚██████╗██║  ██║"
echo "   ╚═════╝ ╚═╝  ╚═╝   ╚═╝   ╚══════╝ ╚══╝╚══╝ ╚═╝  ╚═╝   ╚═╝    ╚═════╝╚═╝  ╚═╝"
echo -e "${RESET}"
echo -e "  ${DIM}AI Observability & Identity Gateway · Cloudflare Hackathon BCN 2026${RESET}"
echo ""

# ── 0. Health ─────────────────────────────────────────────────────────────────
banner "0 · HEALTH CHECK"
STATUS=$(curl -s "$WORKER/gatewatch/health" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','?'))" 2>/dev/null)
if [ "$STATUS" = "ok" ]; then
  echo -e "  ${GREEN}✔ Worker operativo${RESET}  ${DIM}→ $WORKER${RESET}"
else
  echo -e "  ${RED}✘ Worker no responde${RESET}"; exit 1
fi

# ── 1. Tokens — todos en paralelo ────────────────────────────────────────────
banner "1 · REGISTRO DE IDENTIDADES"
echo -e "  ${DIM}Emitiendo 6 tokens en paralelo...${RESET}\n"

issue_token "maria@acme.com"  "legal"       "due-diligence"    "webapp"       > "$TMPDIR_GW/tok_maria.out"  &
issue_token "carlos@acme.com" "engineering" "api-platform"     "opencode"     > "$TMPDIR_GW/tok_carlos.out" &
issue_token "ana@acme.com"    "marketing"   "campaign-q2-2026" "webapp"       > "$TMPDIR_GW/tok_ana.out"    &
issue_token "david@acme.com"  "finance"     "budget-2026"      "sheets-addon" > "$TMPDIR_GW/tok_david.out"  &
issue_token "sofia@acme.com"  "hr"          "talent-q3"        "webapp"       > "$TMPDIR_GW/tok_sofia.out"  &
issue_token "pablo@acme.com"  "ventas"      "crm-2026"         "salesapp"     > "$TMPDIR_GW/tok_pablo.out"  &
wait

KEY_MARIA=$(cat  "$TMPDIR_GW/tok_maria.out")
KEY_CARLOS=$(cat "$TMPDIR_GW/tok_carlos.out")
KEY_ANA=$(cat    "$TMPDIR_GW/tok_ana.out")
KEY_DAVID=$(cat  "$TMPDIR_GW/tok_david.out")
KEY_SOFIA=$(cat  "$TMPDIR_GW/tok_sofia.out")
KEY_PABLO=$(cat  "$TMPDIR_GW/tok_pablo.out")

echo -e "  ${GREEN}✔${RESET} ${MAGENTA}maria@acme.com  ${CYAN}[legal]       ${RESET}${DIM}${KEY_MARIA:0:16}…${RESET}"
echo -e "  ${GREEN}✔${RESET} ${MAGENTA}carlos@acme.com ${CYAN}[engineering] ${RESET}${DIM}${KEY_CARLOS:0:16}…${RESET}"
echo -e "  ${GREEN}✔${RESET} ${MAGENTA}ana@acme.com    ${CYAN}[marketing]   ${RESET}${DIM}${KEY_ANA:0:16}…${RESET}"
echo -e "  ${GREEN}✔${RESET} ${MAGENTA}david@acme.com  ${CYAN}[finance]     ${RESET}${DIM}${KEY_DAVID:0:16}…${RESET}"
echo -e "  ${GREEN}✔${RESET} ${MAGENTA}sofia@acme.com  ${CYAN}[hr]          ${RESET}${DIM}${KEY_SOFIA:0:16}…${RESET}"
echo -e "  ${GREEN}✔${RESET} ${MAGENTA}pablo@acme.com  ${CYAN}[ventas]      ${RESET}${DIM}${KEY_PABLO:0:16}…${RESET}"

# ── 2. Llamadas AI — todas en paralelo ────────────────────────────────────────
banner "2 · LLAMADAS AI → CF AI GATEWAY → GRAFANA"
echo -e "  ${DIM}Lanzando 15 requests en paralelo...${RESET}\n"
echo -e "  ${DIM}  #   Usuario                Depto          Tokens   Respuesta${RESET}"
divider

fire_ai  1 "$KEY_MARIA"  "En 1 frase, qué es una cláusula de no competencia"
fire_ai  2 "$KEY_MARIA"  "Lista 3 puntos clave del due diligence legal en una adquisición"
fire_ai  3 "$KEY_MARIA"  "En 1 frase, qué obliga el GDPR al responsable del tratamiento"
fire_ai  4 "$KEY_CARLOS" "En 1 frase, cuándo elegir GraphQL sobre REST"
fire_ai  5 "$KEY_CARLOS" "En 1 frase, cómo hacer rate limiting con Redis"
fire_ai  6 "$KEY_CARLOS" "En 1 frase, ventaja de Cloudflare Workers frente a AWS Lambda"
fire_ai  7 "$KEY_DAVID"  "En 1 frase, cómo calcular el ROI de adoptar IA en una empresa"
fire_ai  8 "$KEY_DAVID"  "Dame 2 estrategias para optimizar presupuesto tecnológico en Q2"
fire_ai  9 "$KEY_ANA"    "Tagline de 8 palabras para GateWatch, plataforma de observabilidad AI"
fire_ai 10 "$KEY_ANA"    "2 ideas de campaña digital para lanzar una plataforma B2B de seguridad AI"
fire_ai 11 "$KEY_ANA"    "Asunto y primera línea de email de lanzamiento para audiencia técnica"
fire_ai 12 "$KEY_SOFIA"  "Lista 3 habilidades clave para contratar un AI Engineer en 2026"
fire_ai 13 "$KEY_SOFIA"  "3 puntos clave para onboarding de 30 días de un desarrollador senior"
fire_ai 14 "$KEY_PABLO"  "Pitch de 1 frase para vender GateWatch a un CISO"
fire_ai 15 "$KEY_PABLO"  "2 objeciones típicas al comprar observabilidad AI y cómo rebatirlas"
wait

# Mostrar resultados en orden
IFS=$'\t' read -r T A < <(read_result "$TMPDIR_GW/ai_1.out");  row_ok  1  "maria@acme.com"  "legal"       "$T" "$A"
IFS=$'\t' read -r T A < <(read_result "$TMPDIR_GW/ai_2.out");  row_ok  2  "maria@acme.com"  "legal"       "$T" "$A"
IFS=$'\t' read -r T A < <(read_result "$TMPDIR_GW/ai_3.out");  row_ok  3  "maria@acme.com"  "legal"       "$T" "$A"
divider
IFS=$'\t' read -r T A < <(read_result "$TMPDIR_GW/ai_4.out");  row_ok  4  "carlos@acme.com" "engineering" "$T" "$A"
IFS=$'\t' read -r T A < <(read_result "$TMPDIR_GW/ai_5.out");  row_ok  5  "carlos@acme.com" "engineering" "$T" "$A"
IFS=$'\t' read -r T A < <(read_result "$TMPDIR_GW/ai_6.out");  row_ok  6  "carlos@acme.com" "engineering" "$T" "$A"
divider
IFS=$'\t' read -r T A < <(read_result "$TMPDIR_GW/ai_7.out");  row_ok  7  "david@acme.com"  "finance"     "$T" "$A"
IFS=$'\t' read -r T A < <(read_result "$TMPDIR_GW/ai_8.out");  row_ok  8  "david@acme.com"  "finance"     "$T" "$A"
divider
IFS=$'\t' read -r T A < <(read_result "$TMPDIR_GW/ai_9.out");  row_ok  9  "ana@acme.com"    "marketing"   "$T" "$A"
IFS=$'\t' read -r T A < <(read_result "$TMPDIR_GW/ai_10.out"); row_ok 10  "ana@acme.com"    "marketing"   "$T" "$A"
IFS=$'\t' read -r T A < <(read_result "$TMPDIR_GW/ai_11.out"); row_ok 11  "ana@acme.com"    "marketing"   "$T" "$A"
divider
IFS=$'\t' read -r T A < <(read_result "$TMPDIR_GW/ai_12.out"); row_ok 12  "sofia@acme.com"  "hr"          "$T" "$A"
IFS=$'\t' read -r T A < <(read_result "$TMPDIR_GW/ai_13.out"); row_ok 13  "sofia@acme.com"  "hr"          "$T" "$A"
divider
IFS=$'\t' read -r T A < <(read_result "$TMPDIR_GW/ai_14.out"); row_ok 14  "pablo@acme.com"  "ventas"      "$T" "$A"
IFS=$'\t' read -r T A < <(read_result "$TMPDIR_GW/ai_15.out"); row_ok 15  "pablo@acme.com"  "ventas"      "$T" "$A"

# ── 3. DLP — todas en paralelo ────────────────────────────────────────────────
banner "3 · AI FIREWALL DLP — prompts con datos sensibles"
echo -e "  ${YELLOW}Regla: acme_password_policy  →  /acme_[a-zA-Z0-9]{4,}/i  →  BLOCK${RESET}"
echo -e "  ${DIM}Lanzando 7 requests en paralelo...${RESET}\n"
echo -e "  ${DIM}  #   Usuario                Depto          Estado${RESET}"
divider

fire_dlp 16 "$KEY_SOFIA"  "No puedo entrar al portal, mi contraseña es acme_Hr2026 ¿me ayudas?"
fire_dlp 17 "$KEY_CARLOS" "Este script falla: export KEY=acme_dev_k3y_abc123 && curl https://internal.acme.com"
fire_dlp 18 "$KEY_CARLOS" "Revisa: headers = {'Authorization': 'Bearer acme_prod_jwt_9x2z'}"
fire_dlp 19 "$KEY_DAVID"  "Accedo al sistema de pagos con acme_finance_2026 para cerrar el presupuesto"
fire_dlp 20 "$KEY_ANA"    "Email al equipo con credenciales CRM: usuario acme_mkt_ana clave acme_CRM_pass"
fire_dlp 21 "$KEY_PABLO"  "Para la demo usa el token acme_sales_tok2026 en staging"
fire_dlp 22 "$KEY_MARIA"  "¿Cuáles son las cláusulas más importantes en un NDA?"
wait

show_dlp() {
  local id="$1" user="$2" dept="$3" pattern="$4"
  local code
  code=$(read_result "$TMPDIR_GW/dlp_${id}.out")
  if [ "$code" != "200" ]; then
    row_blocked "$id" "$user" "$dept" "$pattern"
  else
    IFS=$'\t' read -r T A < <(echo "?||prompt limpio — permitido")
    row_ok "$id" "$user" "$dept" "$T" "$A"
  fi
}

show_dlp 16 "sofia@acme.com"  "hr"          "acme_Hr2026"
show_dlp 17 "carlos@acme.com" "engineering" "acme_dev_k3y_abc123"
show_dlp 18 "carlos@acme.com" "engineering" "acme_prod_jwt_9x2z"
show_dlp 19 "david@acme.com"  "finance"     "acme_finance_2026"
show_dlp 20 "ana@acme.com"    "marketing"   "acme_mkt_ana / acme_CRM_pass"
show_dlp 21 "pablo@acme.com"  "ventas"      "acme_sales_tok2026"
show_dlp 22 "maria@acme.com"  "legal"       "—"

# ── 4. Resumen ────────────────────────────────────────────────────────────────
banner "RESUMEN"

PPASS=$((PASSED * 100 / TOTAL))
PBLOCK=$((BLOCKED * 100 / TOTAL))
BAR_PASS=$(python3 -c "print('█' * $((PPASS / 5)))")
BAR_BLOCK=$(python3 -c "print('█' * $((PBLOCK / 5)))")

echo -e "  ${WHITE}Requests totales : ${BOLD}$TOTAL${RESET}"
echo ""
echo -e "  ${GREEN}✔ Permitidas  : ${BOLD}$PASSED${RESET}  ${GREEN}${BAR_PASS}${RESET}  ${PPASS}%"
echo -e "  ${RED}✘ Bloqueadas  : ${BOLD}$BLOCKED${RESET}  ${RED}${BAR_BLOCK}${RESET}  ${PBLOCK}%"
echo ""
echo -e "  ${DIM}Por departamento:${RESET}"
echo -e "  ${MAGENTA}legal        ${RESET}${GREEN}✔ ✔ ✔ ✔${RESET}"
echo -e "  ${MAGENTA}engineering  ${RESET}${GREEN}✔ ✔ ✔${RESET}  ${RED}✘ ✘${RESET}"
echo -e "  ${MAGENTA}finance      ${RESET}${GREEN}✔ ✔${RESET}    ${RED}✘${RESET}"
echo -e "  ${MAGENTA}marketing    ${RESET}${GREEN}✔ ✔ ✔${RESET}  ${RED}✘${RESET}"
echo -e "  ${MAGENTA}hr           ${RESET}${GREEN}✔ ✔${RESET}    ${RED}✘${RESET}"
echo -e "  ${MAGENTA}ventas       ${RESET}${GREEN}✔ ✔${RESET}    ${RED}✘${RESET}"
echo ""
echo -e "  ${DIM}Todos los spans están ahora en Grafana con usuario + departamento + proyecto${RESET}"
echo ""
echo -e "  ${BOLD}CF AI Gateway:${RESET}"
echo -e "  ${BLUE}https://dash.cloudflare.com → AI → AI Gateway → your gateway → Overview${RESET}"
echo ""
