# ArgoCD
 Homelab ArgoCD manifests

1. Prepare hosts
    ansible-playbook setup_environment_rpi_cluster.yml
2. install k3s
    https://technotim.live/posts/k3s-etcd-ansible/
    git clone https://github.com/techno-tim/k3s-ansible
    resources/ansible.cfg
    resources/my-cluster
    ansible-playbook site.yml -i inventory/my-cluster/hosts.ini
    cp kubeconfig ~/.kube/config
3. traefik-cert-manager
    https://technotim.live/posts/kube-traefik-cert-manager-le/
4. Install ArgoCD
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update
    helm install argocd argo/argo-cd --namespace argocd --values values.yaml
5. Bootstrap ArgoCD
    kubrctl apply -f bootstrap/app-of-apps.yaml
