# Add a device to the local `.sunny` DNS

What it gives: names like `msi.sunny`, `gw.sunny`, `grafana.sunny`, `postgres.sunny` on that device, answered by the Pi (`192.168.0.203`, house side). Apps are also reachable from ANY device as `<app>.lab.sanskararora.in` without this, so `.sunny` is only for convenience and non-public names (nodes, Postgres).

Prefer "split DNS": only `.sunny` goes to the Pi, everything else stays on the normal DNS. Then a dead Pi costs only `.sunny` names, never the internet. Laptops and desktops can do this; phones cannot.

Check from any device first: `dig +short @192.168.0.203 msi.sunny` -> `10.10.1.10` (Windows: `nslookup msi.sunny 192.168.0.203`).

## Linux with NetworkManager (sunny)
```bash
sudo tee /etc/NetworkManager/conf.d/00-dns-dnsmasq.conf >/dev/null <<'CONF'
[main]
dns=dnsmasq
CONF
sudo tee /etc/NetworkManager/dnsmasq.d/sunny.conf >/dev/null <<'CONF'
server=/sunny/192.168.0.203
CONF
sudo systemctl restart NetworkManager     # Wi-Fi drops for a few seconds
cat /etc/resolv.conf                      # nameserver 127.0.0.1
dig +short msi.sunny; dig +short example.com
```
Needs `dnsmasq-base` (`sudo apt install dnsmasq-base`) and no system `dnsmasq` service running. Undo: delete both files, restart NetworkManager.
Linux with systemd-resolved instead: `sudo resolvectl dns <iface> 192.168.0.203` + `sudo resolvectl domain <iface> '~sunny'` (runtime only; make it permanent with a NetworkManager connection: `nmcli con mod <con> ipv4.dns 192.168.0.203 ipv4.dns-search '~sunny'`).

## macOS (true split DNS, built in)
```bash
sudo mkdir -p /etc/resolver
echo "nameserver 192.168.0.203" | sudo tee /etc/resolver/sunny
scutil --dns | grep -A3 'domain   : sunny'
```
Undo: `sudo rm /etc/resolver/sunny`. Note `dig` ignores /etc/resolver; test with `ping msi.sunny` or `dscacheutil -q host -a name msi.sunny`.

## Windows (true split DNS via NRPT, PowerShell as admin)
```powershell
Add-DnsClientNrptRule -Namespace ".sunny" -NameServers "192.168.0.203"
Resolve-DnsName msi.sunny
```
Undo: `Get-DnsClientNrptRule | Where Namespace -eq ".sunny" | Remove-DnsClientNrptRule -Force`.

## Android (per Wi-Fi network, home Wi-Fi only)
1. Settings -> Network -> Private DNS: Off (a Private DNS hostname overrides everything below).
2. Wi-Fi -> long-press the home network -> Modify -> Advanced -> IP settings: Static. Keep the IP the phone has now (or reserve one on the Archer first), gateway `192.168.0.1`, prefix 24.
3. DNS 1 `192.168.0.203`. DNS 2: `1.1.1.1` (internet survives a Pi outage, but `.sunny` can occasionally miss when Android picks DNS 2) or `192.168.0.203` again (no misses, but no DNS on home Wi-Fi if the Pi is down).
Undo: IP settings back to DHCP.

## iPhone / iPad (per Wi-Fi network)
Settings -> Wi-Fi -> (i) on the home network -> Configure DNS -> Manual -> remove the existing server, add `192.168.0.203` (and optionally `1.1.1.1`, same trade-off as Android). Undo: Configure DNS -> Automatic. iOS has no plain-DNS split rule for one domain.

## After adding a device
Add a line to the device list below so we know who depends on the Pi.

Devices using `.sunny`:
- sunny (laptop): pending (step 5 of phase 3)
- phone: pending
