include versions.env

.PHONY: cluster app gateway verify

cluster:
	cd ansible && ansible-playbook site.yml -K

app:
	kubectl apply -f k8s/app/
	kubectl -n demo rollout status deploy/web --timeout=120s

gateway:
	kubectl kustomize "https://github.com/nginx/nginx-gateway-fabric/config/crd/gateway-api/standard?ref=v$(NGF_VERSION)" | kubectl apply -f -
	helm upgrade --install ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric --version $(NGF_VERSION) -n nginx-gateway --create-namespace -f k8s/gateway/helm/ngf-values.yaml --wait
	kubectl apply -f k8s/gateway/

verify:
	./scripts/verify.sh

.PHONY: monitoring
monitoring:
	kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
	kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1 || kubectl -n monitoring create secret generic grafana-admin --from-literal=admin-user=admin --from-literal=admin-password="$$(openssl rand -base64 18)"
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
	helm upgrade --install kps prometheus-community/kube-prometheus-stack --version $(KPS_VERSION) -n monitoring -f k8s/monitoring/helm/kps-values.yaml --wait --timeout 10m

.PHONY: rules deploy
rules:
	kubectl apply -f k8s/monitoring/

deploy: app gateway monitoring rules
