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

# 🔁 NGINXr Ingress → HAProxy Ingress Converter

Ferramenta automatizada para auxiliar na migração de workloads Kubernetes do **NGINX Ingress Controller** (em EOL) para o **HAProxy Kubernetes Ingress Controller**, com foco em conversões seguras e auditáveis.

O conversor identifica `Ingress` existentes que utilizam `ingressClassName: nginx` e gera manifestos equivalentes para HAProxy, converte anotações, trata integração com cert-manager e cria automaticamente **CRDs BackendRule** a partir de `configuration-snippet` com inferência de regras HTTP.

---

## ✨ Funcionalidades

| Função                                                     | Status                     |
| ---------------------------------------------------------- | -------------------------- |
| Conversão de Ingress NGINX → HAProxy                       | ✅                          |
| Copia metadados e simplifica anotações NGINX               | ✅                          |
| Mapeia automaticamente backends (service + port)           | ✅                          |
| Processamento de `configuration-snippet`                   | ✅                          |
| Inferência automática de regras de HAProxy                 | ⚙️ heurística              |
| Suporte completo ao cert-manager                           | 🔐 SSL redirect automático |
| Geração de múltiplos `BackendRule` para múltiplos backends | 🔁                         |
| Dry-run (não aplica no cluster)                            | 🔍                         |
| Separação de artefatos gerados                             | 📁                         |
| Arquivos sinalizados para revisão manual quando necessário | ⚠️                         |

---

## 📁 Estrutura gerada

Após a execução, os manifestos serão gerados em:

```
haproxy-ingresses/
  <namespace>-<name>-haproxy.yaml              → Ingress convertido
  snippet-templates/
      <namespace>-<name>-<svc>-<port>-backendrule.yaml  → BackendRules inferidos
```

---

## 🚀 Como executar

### Dependências

| Binário              | Teste             |
| -------------------- | ----------------- |
| kubectl              | `kubectl version` |
| jq                   | `jq --version`    |
| yq (4.x — mikefarah) | `yq --version`    |

### Rodando

```bash
chmod +x convert-ingress-nginx-to-haproxy-v2.sh
./convert-ingress-nginx-to-haproxy-v2.sh
```

O script NÃO aplica nada no cluster — apenas gera os manifestos.

---

## 📌 Como funciona

1. Procura todos os Ingress com `ingressClassName: nginx`
2. Para cada um:

   * Cria novo objeto `Ingress` com `ingressClassName: haproxy`
   * Converte anotações NGINX → equivalentes HAProxy quando possível
   * Se houver TLS + cert-manager → adiciona `haproxy.org/ssl-redirect=true`
   * Se existir `configuration-snippet`:

     * Analisa linha por linha
     * Converte diretivas conhecidas para comandos HAProxy (`http-request`, `http-response`, rewrite, headers, redirect)
     * Gera um `BackendRule` para cada backend detectado
     * Marca diretivas não suportadas com `# ❗` para revisão manual

---

## 🧠 Diretivas suportadas na conversão automática

| Diretiva NGINX      | Conversão HAProxy          |
| ------------------- | -------------------------- |
| `more_set_headers`  | `http-response set-header` |
| `proxy_hide_header` | `http-response del-header` |
| `proxy_set_header`  | `http-request set-header`  |
| `add_header`        | `http-response add-header` |
| `rewrite`           | `http-request set-path`    |
| `return 301 <url>`  | `http-request redirect`    |

Diretivas desconhecidas são preservadas em comentários para tratamento manual.

---

## ⚠️ Limitações conhecidas

* Snippets específicos de path são aplicados a todos os backends (revisar em casos complexos)
* Diretivas com lógica Lua / includes externos / map / if-blocks requerem revisão manual
* Conversão de `regex-paths` para HAProxy ACL pode exigir intervenção humana

---

## 🔬 Roadmap futuro

| Item                                                  | Status     |
| ----------------------------------------------------- | ---------- |
| Execução com `--apply` (aplicar mudanças via kubectl) | 🔜         |
| Criação de PR automático para repositórios GitOps     | 🔜         |
| Scan pré-migração e geração de relatório de impacto   | 🔜         |
| Suporte a conversion-operator modo webhook            | ✨ possivel |

---

## 🤝 Contribuições

PRs, issues e sugestões são bem-vindos!

Pontos sugeridos:

* Adicionar novas regras de conversão automática
* Suporte a casos especiais do NGINX PLUS
* Testes de compatibilidade com vários provedores de LoadBalancer

---

## 📝 Licença

MIT — livre para uso empresarial.

---
