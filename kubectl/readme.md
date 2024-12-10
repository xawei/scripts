## kubectl script
### 1. view the certificate details
CA of current cluster
```
kubectl config view --raw -o jsonpath='{.clusters[?(@.name == "'$(kubectl config current-context)'")].cluster.certificate-authority-data}' | base64 --decode | openssl x509 -text -noout | grep "Subject:"

```

public key in current context:
``` 
kubectl config view --raw -o jsonpath='{.users[?(@.name == "'$(kubectl config current-context)'")].user.client-certificate-data}' | base64 --decode | openssl x509 -text -noout | grep "Subject:"
```

### 2. list containers in a pod
```yaml
kubectl get pod <pod-name> -o jsonpath="{range .spec.initContainers[*]}{.name}{'\t\t'}{.image}{'\n'}{end}{range .spec.containers[*]}{.name}{'\t'}{.image}{'\n'}{end}"
```

### 3. get specific container related info in a deployment
```yaml
kubectl get deployment <deployment-name> -o yaml | yq '.spec.template.spec.containers[] | select(.name == "<container-name>")'
```

### 4. get specific container related info in a pod
```yaml
kubectl get pod <pod-name> -o yaml | yq '.spec.containers[] | select(.name == "<container-name>")'
```

### 5. get specific parts of every container in a deployment
for example, container name / image / livenessProbe / readinessProbe
```yaml
kubectl get deployment <deployment-name> -o json | jq -r '
  .spec.template.spec.containers[] | 
  {
    name: .name, 
    image: .image, 
    livenessProbe: .livenessProbe, 
    readinessProbe: .readinessProbe
  }' | yq eval -P -
```