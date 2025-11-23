#!/usr/bin/env bash
# convert-ingress-nginx-to-haproxy-v3.sh  (V3)
# - Varre Ingress com ingressClassName = nginx
# - Gera Ingress convertidos para haproxy (nome + "-haproxy")
# - Detecta backends (service + port) automaticamente
# - Converte heurísticas comuns de configuration-snippet para BackendRule HAProxy
# - Marca blocos complexos (if/location/proxy_pass/sub_filter) para revisão manual
#
# Requisitos: kubectl, jq, yq (mikefarah) v4+, bash
set -euo pipefail
IFS=$'\n\t'

OUTPUT_DIR="haproxy-ingresses"
SNIPPET_DIR="$OUTPUT_DIR/snippet-templates"
mkdir -p "$OUTPUT_DIR"
mkdir -p "$SNIPPET_DIR"

echo "🔍 Buscando Ingress com ingressClassName = nginx..."
INGRESSES=$(kubectl get ingress --all-namespaces -o json | jq -r '
  .items[] | select(.spec.ingressClassName == "nginx") | [.metadata.namespace, .metadata.name] | @tsv
')

if [[ -z "${INGRESSES// }" ]]; then
  echo "✅ Nenhum Ingress com ingressClass nginx encontrado. Encerrando."
  exit 0
fi

echo "📌 Ingress encontrados:"
echo "$INGRESSES"
echo ""

# Função: escape para YAML (preservar $ e espaços)
yaml_escape() {
  # recebe string como primeiro arg, imprime safe YAML scalar (sem delimitar com |)
  local s="$1"
  # se conter caractere especial que pode quebrar, usa | block style
  if [[ "$s" =~ [$'\n\r'] ]] ; then
    # usa block scalar com indentação
    printf "%s" "|-\n"
    printf "%s\n" "$s" | sed 's/^/      /'
  else
    # inline (preserve $ by quoting)
    printf "%s" "\"%s\"" "$s"
  fi
}

# Função: inferir regras a partir de snippet (melhorada)
infer_rules_from_snippet() {
  local snippet="$1"
  local -n out_rules=$2
  out_rules=""
  local line
  # normalizar CRLF
  snippet=$(echo "$snippet" | sed 's/\r$//')
  # detectar blocos 'if' ou 'location' ou 'proxy_pass' ou 'sub_filter' -> desaconselhado automatizar
  if echo "$snippet" | grep -Eq '(^|\s)(if\s*\(|location\s+|proxy_pass\s+|sub_filter\s+)'; then
    out_rules+="  # ❗ Contém bloco 'if'/'location'/'proxy_pass'/'sub_filter' — revisar manualmente\n"
    # ainda assim tentamos extrair linhas simples das demais
  fi

  # iterar linha a linha
  while IFS= read -r rawline; do
    # remover espaços laterais
    line="$(echo "$rawline" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$line" ]] && continue

    # more_set_headers "Header: Value";
    if [[ "$line" =~ ^more_set_headers[[:space:]]+\"([^\"]+)\"[[:space:]]*;?[[:space:]]*$ ]]; then
      hdr="${BASH_REMATCH[1]}"
      hname=$(echo "$hdr" | awk -F': ' '{print $1}')
      hval=$(echo "$hdr" | awk -F': ' '{ $1=""; sub(/^ /,""); print }')
      out_rules+="  - command: http-response set-header\n    args: ${hname} ${hval}\n"
      continue
    fi

    # proxy_hide_header Header;
    if [[ "$line" =~ ^proxy_hide_header[[:space:]]+([A-Za-z0-9_-]+)[[:space:]]*;?[[:space:]]*$ ]]; then
      h=${BASH_REMATCH[1]}
      out_rules+="  - command: http-response del-header\n    args: ${h}\n"
      continue
    fi

    # proxy_set_header Header Value;
    # permitimos valores com variáveis e espaços: proxy_set_header Host $host;
    if [[ "$line" =~ ^proxy_set_header[[:space:]]+([A-Za-z0-9\-_]+)[[:space:]]+(.+?)[[:space:]]*;?[[:space:]]*$ ]]; then
      h=${BASH_REMATCH[1]}
      v=${BASH_REMATCH[2]}
      # limpar aspas finais/iniciais
      v=$(echo "$v" | sed 's/^"//;s/"$//;s/;$//')
      out_rules+="  - command: http-request set-header\n    args: ${h} ${v}\n"
      continue
    fi

    # add_header Header Value;
    if [[ "$line" =~ ^add_header[[:space:]]+([A-Za-z0-9\-_]+)[[:space:]]+(.+?)[[:space:]]*;?[[:space:]]*$ ]]; then
      h=${BASH_REMATCH[1]}
      v=${BASH_REMATCH[2]}
      v=$(echo "$v" | sed 's/^"//;s/"$//;s/;$//')
      out_rules+="  - command: http-response add-header\n    args: ${h} ${v}\n"
      continue
    fi

    # rewrite <from> <to> [flag];
    if [[ "$line" =~ ^rewrite[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+) ]]; then
      newpath=${BASH_REMATCH[2]}
      out_rules+="  - command: http-request set-path\n    args: ${newpath}\n"
      continue
    fi

    # return 301 <url>;
    if [[ "$line" =~ ^return[[:space:]]+301[[:space:]]+([^;]+) ]]; then
      url=$(echo "${BASH_REMATCH[1]}" | sed 's/[[:space:]]*$//')
      out_rules+="  - command: http-request redirect\n    args: location ${url} code 301\n"
      continue
    fi

    # sub_filter 'from' 'to';  -> http-response replace-value (heurística)
    if [[ "$line" =~ ^sub_filter[[:space:]]+\"?([^\"]+)\"?[[:space:]]+\"?([^\"]+)\"? ]]; then
      from="${BASH_REMATCH[1]}"
      to="${BASH_REMATCH[2]}"
      out_rules+="  - command: http-response replace-value\n    args: ${from} ${to}\n"
      continue
    fi

    # proxy_pass appears: mark for manual review (because may reference upstreams)
    if echo "$line" | grep -Eq '^proxy_pass[[:space:]]+'; then
      out_rules+="  # ❗ proxy_pass detectado — revisar manualmente (upstream mapping/host rewrite required): ${line}\n"
      continue
    fi

    # se não foi reconhecido, comentar
    out_rules+="  # ❗ Diretiva não reconhecida → revisar manualmente: ${line}\n"

  done <<< "$snippet"
}

# Percorre ingressos
for ENTRY in $INGRESSES; do
  NS=$(echo "$ENTRY" | awk '{print $1}')
  NAME=$(echo "$ENTRY" | awk '{print $2}')
  OUT_FILE="$OUTPUT_DIR/${NS}-${NAME}-haproxy.yaml"

  echo "------------------------------------------------------------"
  echo "➡ Processando: $NS/$NAME"

  YAML=$(kubectl get ingress "$NAME" -n "$NS" -o yaml)

  # detectar snippet (string vazia -> não presente)
  SNIPPET_TEXT=$(echo "$YAML" | yq e -r '.metadata.annotations."nginx.ingress.kubernetes.io/configuration-snippet" // ""' -)
  SNIPPET_PRESENT=false
  if [[ -n "${SNIPPET_TEXT// }" ]]; then
    SNIPPET_PRESENT=true
  fi

  # 1) Gerar Ingress convertido (sem snippet inline)
  echo "$YAML" | yq e '
    .metadata.name = .metadata.name + "-haproxy" |
    .spec.ingressClassName = "haproxy" |
    .metadata.annotations |= with(.;
      del(.["nginx.ingress.kubernetes.io/rewrite-target"]) |
      del(.["nginx.ingress.kubernetes.io/proxy-body-size"]) |
      del(.["nginx.ingress.kubernetes.io/ssl-redirect"]) |
      del(.["nginx.ingress.kubernetes.io/configuration-snippet"]) |
      (. + {
        "haproxy.org/rewrite-target": (.["nginx.ingress.kubernetes.io/rewrite-target"] // null),
        "haproxy.org/proxy-body-size": (.["nginx.ingress.kubernetes.io/proxy-body-size"] // null),
        "haproxy.org/ssl-redirect": (.["nginx.ingress.kubernetes.io/ssl-redirect"] // null)
      })
    ) |
    .metadata.annotations |= with(. ; del(.[] | select(. == null)))
  ' - > "$OUT_FILE"

  echo "   ✔ Ingress convertido gerado: $OUT_FILE"

  # 2) Cert-manager handling
  if [[ "$(echo "$YAML" | yq e '.spec.tls // empty' -)" != "" ]] && \
     [[ "$(echo "$YAML" | yq e '.metadata.annotations."cert-manager.io/cluster-issuer" // .metadata.annotations."cert-manager.io/issuer" // ""' -)" != "" ]]; then
    yq e -i '.metadata.annotations."haproxy.org/ssl-redirect" = "true"' "$OUT_FILE"
    echo "   ✔ Cert-manager detectado: haproxy.org/ssl-redirect adicionado"
  fi

  # 3) Extrair backends do Ingress (rules[].http.paths[] e spec.defaultBackend)
  BACKENDS_RAW=$(echo "$YAML" | yq e '.spec.rules[]?.http.paths[]?.backend.service as $s | $s.name + "|" + ($s.port.number // $s.port.name // "")' - 2>/dev/null || true)
  if [[ -z "${BACKENDS_RAW// }" ]]; then
    BACK_DEFAULT=$(echo "$YAML" | yq e '.spec.defaultBackend.service as $s | $s.name + "|" + ($s.port.number // $s.port.name // "")' - 2>/dev/null || true)
    BACKENDS_RAW="$BACK_DEFAULT"
  fi

  declare -A UNIQUE_BACKENDS=()
  while IFS= read -r b; do
    [[ -z "$b" ]] && continue
    # trim
    b="$(echo "$b" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    UNIQUE_BACKENDS["$b"]=1
  done <<< "$BACKENDS_RAW"

  if [[ ${#UNIQUE_BACKENDS[@]} -eq 0 ]]; then
    echo "   ⚠ Nenhum backend detectado no Ingress (paths/defaultBackend). Verificar manualmente."
  fi

  # 4) Se snippet presente, inferir regras e gerar BackendRule(s)
  if [[ "$SNIPPET_PRESENT" == true ]]; then
    echo "   🔍 configuration-snippet detectado — tentando inferir regras automaticamente..."
    INFERRED_RULES=""
    infer_rules_from_snippet "$SNIPPET_TEXT" INFERRED_RULES

    # gerar BackendRule por backend
    for key in "${!UNIQUE_BACKENDS[@]}"; do
      svc=$(echo "$key" | awk -F'|' '{print $1}')
      prt=$(echo "$key" | awk -F'|' '{print $2}')
      if [[ -z "$svc" ]]; then
        echo "   ⚠ Serviço não detectado para um backend — pula geração automatica para este caso."
        continue
      fi
      if [[ -z "$prt" ]]; then
        prt="<SERVICE_PORT_HERE>"
        echo "   ⚠ Porta não detectada para backend $svc — inserir manualmente no BackendRule."
      fi

      # nome seguro do arquivo (substitui / e espaços)
      safe_svc=$(echo "$svc" | sed 's/[^a-zA-Z0-9_.-]/_/g')
      safe_prt=$(echo "$prt" | sed 's/[^a-zA-Z0-9_.-]/_/g')
      RULE_FILE="$SNIPPET_DIR/${NS}-${NAME}-${safe_svc}-${safe_prt}-backendrule.yaml"

      cat > "$RULE_FILE" <<EOF
# Arquivo gerado automaticamente — revisar manualmente
# Ingress original: ${NS}/${NAME}
# Backend detectado: ${svc}:${prt}
# Snippet original (comentado abaixo):
# ---
$(echo "$SNIPPET_TEXT" | sed 's/^/# /')
# ---

apiVersion: haproxy-ingress.github.io/v1alpha1
kind: BackendRule
metadata:
  name: ${NAME}-${safe_svc}-backendrule
  namespace: ${NS}
spec:
  ingress:
    name: ${NAME}-haproxy
  backend:
    service: ${svc}
    port: ${prt}
  rules:
$INFERRED_RULES
EOF

      echo "   ⚠ BackendRule gerado: $RULE_FILE"
    done
  fi

  # limpar array associativo (para próxima iteração)
  unset UNIQUE_BACKENDS
done

echo ""
echo "🎉 Conversão V3 concluída!"
echo "📁 Manifests Ingress convertidos: $OUTPUT_DIR/"
echo "📁 BackendRules gerados: $SNIPPET_DIR/"
echo "⚠ Revise os BackendRules para serviços/portas/linhas não reconhecidas e blocos marcados com ❗."
