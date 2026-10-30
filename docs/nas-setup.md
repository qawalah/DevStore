# NAS setup (one time): Docker apps with Watchtower

Docker apps (the first is Werd's server) are built on GitHub and published
**privately** to GitHub's container registry, `ghcr.io/qawalah/<app>`. On the
NAS, **Watchtower** checks every 10 minutes and installs a new version by
itself. Your app's data stays in its `data` folder.

Written for a Synology DS423+ (Intel) with DSM 7.2 and **Container Manager**.
Any Intel/AMD machine with Docker works the same way. ARM NAS models aren't
supported: the images are `linux/amd64` only.

## 1. Turn on SSH and check Docker
1. DSM → **Control Panel → Terminal & SNMP** → tick **Enable SSH service**.
2. From your PC: `ssh <your DSM user>@<NAS address>`.
3. Check Docker is new enough for Watchtower (API 1.43 or newer):
   ```bash
   sudo docker version --format '{{.Server.APIVersion}}'
   ```
   Container Manager on DSM 7.2 shows `1.43`. If yours is lower, update
   Container Manager in Package Center first.

You can turn SSH off again when you're done. Updates don't need it.

## 2. Create a read-only token for ghcr.io
GitHub's container registry only accepts **classic** tokens. Fine-grained
ones don't work here.

1. GitHub → your picture → **Settings → Developer settings → Personal access
   tokens → Tokens (classic) → Generate new token (classic)**.
2. Note: `NAS ghcr.io read`. Expiration: as long as you're comfortable with.
   When it expires, the NAS keeps running the version it has, and Watchtower's
   log says `unauthorized` until you do step 3 again with a new token.
3. Tick **only `read:packages`**, then **Generate token**, and copy it.

This token can download all your private images, but nothing else. Keep it
on the NAS only.

## 3. Log the NAS in to ghcr.io
```bash
sudo docker login ghcr.io -u qawalah
```
Paste the token when it asks for a password. Docker warns that it stores the
password unencrypted in `/root/.docker/config.json`. That's expected:
Watchtower reads its login from that same file.

## 4. Start Watchtower
1. In File Station, create the folder `docker/watchtower` (that's
   `/volume1/docker/watchtower`). Save this as `docker-compose.yml` in it:
   ```yaml
   services:
     watchtower:
       image: nickfedor/watchtower:1.23.2
       container_name: watchtower
       restart: unless-stopped
       volumes:
         - /var/run/docker.sock:/var/run/docker.sock
         - /root/.docker:/config:ro        # the ghcr.io login from step 3
       environment:
         - DOCKER_CONFIG=/config
         - WATCHTOWER_LABEL_ENABLE=true    # only update containers labelled com.centurylinklabs.watchtower.enable=true
         - WATCHTOWER_POLL_INTERVAL=600    # check every 10 minutes
         - WATCHTOWER_CLEANUP=true         # remove the old image after an update
         - TZ=Asia/Riyadh
   ```
2. Start it:
   ```bash
   cd /volume1/docker/watchtower && sudo docker compose up -d
   ```

Watchtower only touches containers that opt in with the label, so
Synology's own containers and anything else you run are left alone. Every
DevStore app's `docker-compose.yml` already has the label.

`nickfedor/watchtower` is the maintained fork of the original Watchtower,
which was archived in December 2025. It doesn't update itself. To move to a
newer version later, change the tag in this file and run the same
`sudo docker compose up -d` again.

## 5. Install Werd's server
**New install:**
1. In File Station, create `docker/werd`.
2. From the Werd repo on GitHub, open `server/docker-compose.yml`, click
   **Download raw file**, and upload it into `docker/werd`.
3. Edit the settings in it if you want (Tailscale addresses, voice keys).
   They're explained in Werd's `server/README.md`.
4. Start it:
   ```bash
   cd /volume1/docker/werd && sudo docker compose up -d
   ```

**Moving the existing Werd install** (the old folder that built the image on
the NAS, for example `docker/Werd App`):
1. Stop the old one:
   ```bash
   cd "/volume1/docker/Werd App" && sudo docker compose down
   ```
   Its data stays in `data/`.
2. Copy the data to the new folder. The old copy stays as a backup.
   ```bash
   sudo mkdir -p /volume1/docker/werd && sudo cp -a "/volume1/docker/Werd App/data" /volume1/docker/werd/
   ```
3. Do steps 2–4 of "New install" above. Copy over any settings you had
   changed in the old `docker-compose.yml`.
4. Once the check below passes, clean up:
   - In Container Manager, delete the old project, but don't tick any option
     to delete its folder.
   - Delete the old folder whenever you like.
   - Remove the old image: `sudo docker image rm werd-server:1.8.0`.

**Check:** open `http://<NAS address>:8080/v1/info` in a browser. It shows
`"version":"1.8.0"` (or newer). The admin password is in
`/volume1/docker/werd/data/admin-token.txt`, unless you set your own.

Both containers also appear in **Container Manager → Container**, where you
can see their logs and stop or restart them. If you'd rather create the
project in Container Manager's **Project** screen, that works too. If it then
says `pull access denied`, Container Manager isn't using the SSH login, so
use the command line above instead.

Back up `/volume1/docker/werd/data` with Hyper Backup like any other folder.

## Rolling back
GitHub keeps the newest two versions of each image. To go back one version:
1. In the app's `docker-compose.yml`, change `:latest` to the previous
   version, for example `image: ghcr.io/qawalah/werd-server:1.8.0`.
2. `cd /volume1/docker/werd && sudo docker compose up -d`.

Watchtower doesn't move a pinned version. When a fixed version is out,
change it back to `:latest` and run the same command.

## Troubleshooting
| What you see | Why | Fix |
|---|---|---|
| `pull access denied`, `unauthorized` or `denied` | The NAS isn't logged in, or the token expired or lacks `read:packages` | Step 3 again (with a new token from step 2 if needed) |
| A new version is out, but the NAS doesn't get it | The container has no Watchtower label, or Watchtower isn't running | `sudo docker logs watchtower`; check the label in the app's `docker-compose.yml` |
| `no matching manifest` | The NAS has an ARM processor | Not supported. Run the app on the PC instead |
| Werd doesn't start: address already in use | Something else uses port 8080 | Set `WERD_ADDR=:8090` (or another port) in `docker-compose.yml` |
| Container Manager shows the project as changed after an update | Watchtower recreated the container | Harmless |
| `docker: 'compose' is not a docker command` | An older Container Manager | Use `sudo docker-compose up -d` instead |

See what Watchtower did: `sudo docker logs --tail 50 watchtower`.

## Adding another Docker app
Nothing to do on the NAS beyond copying the app's `docker-compose.yml` into
its own folder and running `sudo docker compose up -d` there. The ghcr.io
login and Watchtower already cover it.
