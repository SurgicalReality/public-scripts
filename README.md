# Deployment on a RHEL 10 VM

## 1 Prepare a test VM

Use a fresh RHEL 10.x x86_64 VM, registered with `subscription-manager` (the installer needs the AppStream repository), with the NFS share already mounted and listed in `/etc/fstab`. Prefer a VM you can revert with a snapshot, so every run starts clean. Check that the export lets the `relay` user (system-assigned UID) write; the installer only warns when it can't.

## 2 Run the published installer

```shell
# public repository / releases
curl -fsSLO https://raw.githubusercontent.com/SurgicalReality/public-scripts/refs/heads/main/install-relay.sh
sudo GITHUB_TOKEN="$(gh auth token)" RELAY_VERSION=<tag> bash install-relay.sh
```

`sudo` resets the environment, so pass variables on its command line as above (or use `sudo -E`).

For a VM without access to GitHub, download the tarball and its `.sha256` elsewhere, copy both to the VM and run `sudo RELAY_PAYLOAD_FILE=/path/relay-rhel-linux-x64.tar.gz bash install-relay.sh`. The payload bundles the Node dependencies, but `dnf` still needs the RHEL repositories (or a mirror) for Node.js and the tools.

### 3 Verify on the VM

```shell
systemctl status relay --no-pager
journalctl -u relay -n 50 --no-pager
curl -ks https://127.0.0.1:10005/api/health
cat /opt/relay/VERSION                                  # must be the released version
findmnt -T /mnt/relay                                   # nfs4, from the real share
ls -ld /mnt/relay/IN /mnt/relay/OUT
getenforce; sudo ausearch -m avc -ts recent             # no denials for node/pm2
sudo firewall-cmd --list-ports                          # 10004/tcp and 10005/tcp
```

Then from another machine:

- open `https://<host>:10005/dash` and sign in;
- send a DICOM series with a C-STORE (for example `storescu -aec <AET> <host> 10004 file.dcm`) and see it arrive in `IN`, and the case appear in `OUT` and in the Cases view;
- upload a case through the dashboard's "Create Case" dialog;
- reboot the VM and check that the service comes back after the NFS share is mounted (the unit requires the mounts of both directories).

### 4 Test the upgrade and rollback

1. Install the previous release, then run the new release's installer on top of it, keeping the existing configuration.
2. Repeat the checks above, confirm the dashboard login still works (the JWT secret is kept) and that `/opt/relay.prev` holds the old version.
3. Roll back as the installer prints on failure:

   ```shell
   sudo systemctl stop relay && sudo rm -rf /opt/relay && sudo mv /opt/relay.prev /opt/relay && sudo systemctl start relay
   ```
