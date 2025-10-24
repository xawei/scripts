## Test

✅ 1) Set your reviewer token variables (the ServiceAccount in vault-auth)

```
export NAMESPACE="vault-auth"
export SECRET="vault-auth"

# Reviewer JWT (decoded)
export SA_JWT_TOKEN=$(kubectl -n $NAMESPACE get secret $SECRET -o jsonpath='{.data.token}' | base64 -d)

# Reviewer CA cert
kubectl -n $NAMESPACE get secret $SECRET -o jsonpath='{.data.ca\.crt}' | base64 -d > k8s-ca.crt
export K8S_CA=$(pwd)/k8s-ca.crt

# API server (from kubeconfig)
export K8S_HOST=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
echo "K8S_HOST=$K8S_HOST"

echo "SA_JWT_TOKEN length: ${#SA_JWT_TOKEN}"
echo "K8S_CA file:" $K8S_CA
```


✅ 2) Get a short-lived token for the application ServiceAccount

```
export APP_NS="test"
export APP_SA="test-cloud"
export TARGET_JWT=$(kubectl create token "$APP_SA" -n "$APP_NS")
echo "$TARGET_JWT" | head -c 40 && echo "..."
```

make sure the token is valid
```
test -n "$TARGET_JWT" && echo "✅ Got app token" || echo "❌ No token"
```
if you don't have permission to create serviceaccount/token, you can get a projected token from a running pod.

B) Read the pod’s projected token

```
export POD_NS="test"
export POD_NAME="test-1234567890"
export TOKEN_FILE="/var/run/secrets/kubernetes.io/serviceaccount/token"

# Read the token from the pod
export TARGET_JWT=$(kubectl -n $POD_NS exec $POD_NAME -- cat $TOKEN_FILE)
echo "$TARGET_JWT" | head -c 40 && echo "..."
```



✅ 3) Now re-run the TokenReview request (the API check that Vault also performs)

```
curl -sS -X POST "$K8S_HOST/apis/authentication.k8s.io/v1/tokenreviews" \
  --cacert "$K8S_CA" \
  -H "Authorization: Bearer $SA_JWT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"apiVersion":"authentication.k8s.io/v1","kind":"TokenReview","spec":{"token":"'"$TARGET_JWT"'"}}' \
| jq .
```