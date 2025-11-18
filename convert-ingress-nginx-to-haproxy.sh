#!/usr/bin/env bash

set -e

OUTPUT_DIR="haproxy-ingresses"
mkdir -p "$OUTPUT_DIR"

echo "🔍 Buscando ingressos com ingressClassName = nginx..."
INGRESSES=$(kubectl get ingress --all-namespaces -o json | jq -r '
  .items[] | select(.spec.ingressClassName == "nginx") | [.metadata.namespace, .metadata.name] | @tsv '
)

if [ -z "$INGRESSES" ]; then
  echo "Nenhum Ingress usando IngressClass nginx foi encontrado."
  exit 0
fi

echo "📌 Ingress encontrados:"
echo "$INGRESSES"
echo ""

for ENTRY in $INGRESSES; do
  NS=$(echo "$ENTRY" | cut -f1)
  NAME=$(echo "$ENTRY" | cut -f2)
  FILE="$OUTPUT_DIR/${NS}-${NAME}-haproxy.yaml"

  echo "➡ Convertendo $NS/$NAME → $FILE ..."

  kubectl get ingress "$NAME" -n "$NS" -o yaml \
  | yq "
      .metadata.name = .metadata.name + \"-haproxy\" |
      .spec.ingressClassName = \"haproxy\" |
      .metadata.annotations |=
        with(
          .;
          del(.\"nginx.ingress.kubernetes.io/rewrite-target\") |
          del(.\"nginx.ingress.kubernetes.io/proxy-body-size\") |
          del(.\"nginx.ingress.kubernetes.io/ssl-redirect\") |
          del(.\"nginx.ingress.kubernetes.io/configuration-snippet\") |
          (. + {
            \"haproxy.org/rewrite-target\": (.\"nginx.ingress.kubernetes.io/rewrite-target\" // null),
            \"haproxy.org/proxy-body-size\": (.\"nginx.ingress.kubernetes.io/proxy-body-size\" // null),
            \"haproxy.org/ssl-redirect\": (.\"nginx.ingress.kubernetes.io/ssl-redirect\" // null)
          })
        ) |
      .metadata.annotations |= with(. ; del(.[] | select(. == null)))
    " > "$FILE"

done

echo ""
echo "🎉 Concluído!"
echo "📁 Arquivos gerados em: $OUTPUT_DIR/"
echo "⚠ Revise especialmente itens com 'configuration-snippet', pois não são suportados por HAProxy"
