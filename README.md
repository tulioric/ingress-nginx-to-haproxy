| Etapa                    | Status |
| ------------------------ | ------ |
| Duplicar Ingress         | ⬜      |
| Converter anotações      | ⬜      |
| TLS funcionando          | ⬜      |
| Testes de conectividade  | ⬜      |
| Testes carga/latência    | ⬜      |
| Corte de tráfego         | ⬜      |
| Observabilidade validada | ⬜      |
| Remover recurso antigo   | ⬜      |


🧪 Como executar

chmod +x convert-ingress-nginx-to-haproxy.sh
./convert-ingress-nginx-to-haproxy.sh

kubectl
jq
yq v4+

sudo apt install jq -y
pip install yq

📂 Resultado
Depois da execução você terá algo como:

haproxy-ingresses/
  default-web-haproxy.yaml
  payments-api-haproxy.yaml
  auth-haproxy.yaml
  frontend-haproxy.yaml

Cada manifesto está pronto para aplicação lado a lado, sem remover o Ingress original:

kubectl apply -f haproxy-ingresses/frontend-haproxy.yaml
