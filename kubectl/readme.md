## KubeConfig
### 1. view the certificate details
CA of current cluster
```
kubectl config view --raw -o jsonpath='{.clusters[?(@.name == "'$(kubectl config current-context)'")].cluster.certificate-authority-data}' | base64 --decode | openssl x509 -text -noout | grep "Subject:"

```

public key in current context:
``` 
kubectl config view --raw -o jsonpath='{.users[?(@.name == "'$(kubectl config current-context)'")].user.client-certificate-data}' | base64 --decode | openssl x509 -text -noout | grep "Subject:"
```

### 2. check containers
```yaml
kubectl get pod <pod-name> -o jsonpath="{range .spec.initContainers[*]}{.name}{'\t\t'}{.image}{'\n'}{end}{range .spec.containers[*]}{.name}{'\t'}{.image}{'\n'}{end}"
```
