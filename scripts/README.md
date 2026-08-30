In [bootstrap script](./01-rebuild-and-bootstrap.sh) the script has an error in node addition, instead of fixing it there i chose to not touch the AI slop and add the node manually and then run the remaining commands manually as well.

## Adding worker node
msi: controller node
dell: worker node

On msi run `sudo microk8s add-node`, this will give the token embedded command to add dell as a woprker node and the command would be like this `sudo microk8s join <msi ip addr>:25000/<token1_long>/<hash2_short> --worker`.

## Continue bootstrap
Once the nodes are added i can run these commands to continue bootstrap process, mainly flux installation.
```bash
# ---- verify the join actually took ----
sudo /snap/bin/microk8s status --wait-ready
sudo /snap/bin/microk8s kubectl get nodes -o wide

# ---- kubeconfig ----
echo "==> Writing kubeconfig"
sudo /snap/bin/microk8s config > /tmp/kubeconfig.new

if grep -q 'server: https://' /tmp/kubeconfig.new; then
  mkdir -p /home/msi/.kube
  install -m 600 /tmp/kubeconfig.new /home/msi/.kube/config
  echo "    kubeconfig written and validated"
else
  echo "ERROR: microk8s config produced nothing usable; kubeconfig left untouched" >&2
fi
rm -f /tmp/kubeconfig.new

# ---- flux CLI ----
echo "==> Installing flux CLI"
curl -s https://fluxcd.io/install.sh | sudo bash
flux check --pre


```
