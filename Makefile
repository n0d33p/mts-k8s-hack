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
