[![CI](https://github.com/n0d33p/mts-k8s-hack/actions/workflows/ci.yml/badge.svg)](https://github.com/n0d33p/mts-k8s-hack/actions/workflows/ci.yml)
# Kubernetes + Gateway API + Prometheus + Filebeat (MTS Engineer Hack, DevOps)

Воспроизводимое решение: одноузловой кластер **kubeadm** на Ubuntu 24.04, демо-приложение (nginx) за **Kubernetes Gateway API**, мониторинг на **Prometheus**, сбор логов **Filebeat → Elasticsearch**. Всё разворачивается тремя командами: `make cluster`, `make deploy`, `make verify`.

## Архитектура

```
 Пользователь (curl)
        │  HTTP, Host: hello.local / canary.local
        ▼
 NodePort ──► Gateway "web-gw" (NGINX Gateway Fabric, GatewayClass "nginx")
                 │ HTTPRoute "web"    hello.local  /    -> Service web    (nginx v1)
                 │                    hello.local  /v2  -> Service web-v2 (nginx v2)
                 │ HTTPRoute "canary" canary.local      -> web 90% / web-v2 10%
                 ▼
          Pods web, web-v2 (nginx + sidecar nginx-prometheus-exporter)
              │ stdout (access-логи)            │ :9113/metrics
              ▼                                 ▼
   Filebeat (DaemonSet) ──► Elasticsearch   Prometheus (ServiceMonitor) ──► Grafana, Alertmanager
```

Namespaces: `demo` (приложение и Gateway), `nginx-gateway` (контроллер), `monitoring` (kube-prometheus-stack), `logging` (Filebeat, Elasticsearch).

## Технологии и версии

| Компонент | Версия |
|---|---|
| ОС (тестирование) | Ubuntu 24.04.5 LTS Server |
| Kubernetes (kubeadm, kubelet, kubectl) | **v1.36.5** (репозиторий pkgs.k8s.io, ветка 1.36, пакеты зафиксированы `hold`) |
| Container runtime | containerd (пакет Ubuntu, SystemdCgroup) |
| CNI | Flannel (версия в `ansible/group_vars/all.yml`) |
| Gateway API | CRD **v1.6.1** (standard channel) |
| Реализация Gateway API | **NGINX Gateway Fabric 2.7.2** (Helm) |
| Мониторинг | kube-prometheus-stack, Helm-чарт **91.8.2** (Prometheus, Alertmanager, Grafana 13.2.3, kube-state-metrics, node-exporter) |
| Метрики приложения | nginx-prometheus-exporter **1.5.3** |
| Логирование | Filebeat **9.5.4** → Elasticsearch **9.5.4** |
| Приложение | nginxinc/nginx-unprivileged 1.28-alpine |
| Автоматизация | Ansible, Helm, kubectl, GNU Make |

Версии чартов и образов зафиксированы в `versions.env` и манифестах.

## Требования к среде

- Ubuntu 24.04 (чистая машина или VM), 4 vCPU, **6 ГБ RAM минимум (рекомендуется 8)**, 30 ГБ диска.
- Пользователь с `sudo`, доступ в интернет (Docker Hub, ghcr.io, quay.io, docker.elastic.co, github.com).
- Пакеты: `git make ansible curl` (Helm ставится автоматически).

## Развёртывание

```bash
sudo apt update && sudo apt install -y git make ansible curl
git clone https://github.com/n0d33p/mts-k8s-hack.git
cd mts-k8s-hack

make cluster   # kubeadm-кластер (спросит пароль sudo), ~3 мин
make deploy    # приложение, Gateway API, мониторинг, логи, ~10 мин
make verify    # автоматическая проверка всех компонентов
```

Цели Makefile: `cluster`, `app`, `gateway`, `monitoring`, `rules`, `logging`, `deploy` (все, кроме cluster), `verify`.

Повторный запуск `make cluster` и `make deploy` безопасен (идемпотентность): Ansible не меняет уже настроенное (`changed=0`), Helm выполняет `upgrade --install`, ресурсы применяются через `kubectl apply`.

### Измеренные результаты (чистая VM Ubuntu 24.04.5, VirtualBox, 4 vCPU, 6 ГБ)

| Операция | Первый запуск | Повторный запуск |
|---|---|---|
| `make cluster` | 2 мин 31 с | `changed=0, failed=0` |
| `make deploy` | 9 мин 15 с | 55 с, без ошибок |
| `make verify` | 20 с, все проверки OK | все проверки OK |

## Проверка работоспособности

Быстро: `make verify` (проверяет всё ниже). Вручную:

### 1. Gateway API

```bash
NP=$(kubectl -n demo get svc web-gw-nginx -o jsonpath='{.spec.ports[0].nodePort}')
curl -H "Host: hello.local" http://127.0.0.1:$NP/       # Hello World!
curl -H "Host: hello.local" http://127.0.0.1:$NP/v2     # Hello World! v2
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:$NP/   # 404 (неизвестный host)
for i in $(seq 1 50); do curl -s -H "Host: canary.local" http://127.0.0.1:$NP/; done | sort | uniq -c   # ~90/10
kubectl get gatewayclass; kubectl -n demo get gateway,httproute
```

### 2. Мониторинг (Prometheus)

```bash
kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090 &
curl -s 'http://127.0.0.1:9090/api/v1/query?query=count(up==1)'                 # число живых targets
curl -s 'http://127.0.0.1:9090/api/v1/query?query=nginx_up'                      # 1 для каждого пода web*
curl -sg 'http://127.0.0.1:9090/api/v1/query?query=sum(rate(nginx_http_requests_total[1m]))'
```

Собираемые метрики: метрики nginx (`nginx_up`, `nginx_http_requests_total`, `nginx_connections_*` из stub_status через exporter), метрики Kubernetes (kube-state-metrics, kubelet/cAdvisor: CPU и память подов), метрики ноды (node-exporter), метрики самого Prometheus и Grafana. Alertmanager и два правила для приложения (`WebNoAvailableReplicas`, `NginxExporterDown`).

Проверка алерта: `kubectl -n demo scale deploy/web --replicas=0`, через ~2 минуты в `http://127.0.0.1:9090/api/v1/alerts` алерт `WebNoAvailableReplicas` в состоянии `firing`; вернуть: `kubectl -n demo scale deploy/web --replicas=2`.

Grafana: `kubectl -n monitoring port-forward svc/kps-grafana 3000:80`, логин `admin`, пароль: `kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo`. Дашборд **Web overview** создаётся автоматически из `k8s/monitoring/dashboards/web-overview.json`.

### 3. Логирование (Filebeat → Elasticsearch)

Собираются access-логи контейнеров nginx из namespace `demo` (файлы `/var/log/containers/*_demo_nginx-*.log`, то есть и приложение, и Gateway-прокси). Попадают в data stream `demo-logs` в Elasticsearch с метаданными Kubernetes.

```bash
curl -s -o /dev/null -A my-test-marker -H "Host: hello.local" http://127.0.0.1:$NP/
kubectl -n logging port-forward svc/elasticsearch 9200:9200 &
sleep 20
curl -sG 'http://127.0.0.1:9200/demo-logs*/_search' --data-urlencode 'q=message:my-test-marker' --data-urlencode 'size=1' --data-urlencode 'pretty=true'
```

В ответе должна быть запись `message` с `my-test-marker` и `kubernetes.namespace: demo`.

## CI

Файл `.github/workflows/ci.yml`, запускается при каждом push в `main`:

1. **lint:** `yamllint`, `ansible-playbook --syntax-check`, `kubeconform` для манифестов, `helm template` для чартов NGINX Gateway Fabric и kube-prometheus-stack с нашими values.
2. **smoke:** временный кластер **kind** на раннере GitHub, `make app` и `make gateway`, затем запросы через Gateway (`hello.local` и `hello.local/v2`) с проверкой ответов.

Границы: полноценное развёртывание на kubeadm, мониторинг и логи в CI не входят (у раннера не хватает ресурсов), их проверяет `make verify` на реальной VM. Дымовой тест использует kind, а не kubeadm.

## Структура репозитория

```
Makefile                 # точка входа
versions.env             # версии Helm-чартов
ansible/                 # kubeadm-кластер: node_prep, cluster, tools
k8s/app/                 # namespace, nginx v1 и v2, Service
k8s/gateway/             # Gateway, HTTPRoute (hello.local, canary.local), values NGF
k8s/monitoring/          # values kube-prometheus-stack, ServiceMonitor, алерты, дашборд
k8s/logging/             # Elasticsearch, Filebeat
scripts/verify.sh        # автоматическая проверка
.github/workflows/ci.yml # CI
```

## Дополнительные возможности

- **Gateway API:** несколько HTTPRoute, маршрутизация по hostname и по path, два backend, traffic splitting 90/10.
- **Мониторинг:** HTTP-метрики приложения (exporter + ServiceMonitor), правила алертов, дашборд Grafana как код, метрики CPU/RAM подов.
- **Логи:** централизованное хранение и поиск в Elasticsearch, обогащение метаданными Kubernetes.
- **Надёжность и безопасность:** probes и requests/limits у всех подов приложения, `runAsNonRoot` и `drop: ALL` capabilities, версии пакетов Kubernetes зафиксированы, секреты (пароль Grafana) генерируются при деплое и не хранятся в репозитории, автоматическая проверка `make verify`.
- **Идемпотентный деплой** и проверка «с нуля» на чистой Ubuntu 24.04.
- **CI (GitHub Actions):** линтинг YAML и Ansible, валидация манифестов по схемам Kubernetes, проверка рендеринга Helm-чартов с нашими values и дымовой тест на временном kind-кластере (приложение + Gateway API).

## Известные ограничения

- Одноузловой кластер (control-plane без taint), без высокой доступности.
- Доступ к Gateway через NodePort: в среде без облака нет LoadBalancer. Только HTTP, без TLS.
- Elasticsearch: один узел, без включённой безопасности (xpack), данные в `emptyDir` и пропадают при пересоздании пода. Это демонстрационная конфигурация.
- `stub_status` nginx не даёт коды ответов и латентность; их можно получить по логам или метрикам Gateway-контроллера (см. «развитие»).
- Prometheus не собирает метрики etcd, scheduler, controller-manager и kube-proxy: в kubeadm они слушают только на `127.0.0.1`, эти targets отключены в values.
- Flannel без NetworkPolicy; кластер не заужен по безопасности (hardening).
- На небольшой VM сразу после старта или перезагрузки возможны разовые рестарты компонентов (выбор лидера, медленный старт Grafana). Для Grafana увеличены таймауты проб; Filebeat запускается после готового Elasticsearch.
- Для первого запуска нужен интернет и около 10 минут на загрузку образов.