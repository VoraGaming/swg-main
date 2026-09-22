# Ordered stop of the SWG stack on host/LXC shutdown

## What problem this fixes

When the server (the Proxmox LXC) shuts down or reboots, Docker stops all
containers **at the same time**, and systemd gives Docker only **90 seconds**.
Oracle gets only 10 seconds, so it can go down while the game is still saving.

The files in this folder fix that:

| File | Goes to | What it does |
|------|---------|--------------|
| `swg-stack.service` | `/etc/systemd/system/swg-stack.service` | At shutdown, runs `docker compose stop` **before** Docker stops. Compose stops swg-auth, then swg-control, then swg-server (the game saves), then oracle last. At boot, starts the containers again. |
| `docker.service.d/override.conf` | `/etc/systemd/system/docker.service.d/override.conf` | Gives Docker up to 300 s to stop instead of 90 s (safety net). |

Plus two settings that are **not** files here:

- a `stop_grace_period` for oracle in the server's `docker-compose.override.yml` (step 7), and
- the Proxmox shutdown timeout (step 8).

Why the service must also **start** the stack at boot: containers stopped with
`docker compose stop` count as "stopped by hand". Their `unless-stopped`
restart policy then does **not** start them after the reboot. The service's
start step runs `docker compose start`, which only starts the containers that
already exist. It never builds images and never recreates containers, so the
Oracle data and account volumes are not touched.

## Before you start

- You need sudo on the server. Log in as `swg` and run:

  ```
  sudo -v
  ```

  If it asks for a password, type your `swg` password. If you want to know
  whether sudo asks for a password at all, run `sudo -n true` first: no output
  means no password is needed; "a password is required" means it is.
- The files must already be on the server: `~/swg-main` must be updated with
  `git pull` (done by swg-server-ops). Check with:

  ```
  ls ~/swg-main/docker/host
  ```

  You should see `README.md`, `swg-stack.service` and `docker.service.d`.
- Check Docker is at `/usr/bin/docker` (the service uses that path):

  ```
  command -v docker
  ```

  It must print `/usr/bin/docker`. If it prints something else, stop and ask.

## Install (numbered steps, run as `swg` on the server)

1. Copy the service file into systemd's folder:

   ```
   sudo install -m 0644 ~/swg-main/docker/host/swg-stack.service /etc/systemd/system/swg-stack.service
   ```

2. Create the Docker drop-in folder and copy the drop-in into it:

   ```
   sudo mkdir -p /etc/systemd/system/docker.service.d
   sudo install -m 0644 ~/swg-main/docker/host/docker.service.d/override.conf /etc/systemd/system/docker.service.d/override.conf
   ```

   If `/etc/systemd/system/docker.service.d/override.conf` already existed,
   stop and ask first (on 2026-09-22 there were no drop-ins).

3. Tell systemd to re-read its files:

   ```
   sudo systemctl daemon-reload
   ```

   This does **not** restart Docker or any container.

4. Enable the service (so it runs at every boot and shutdown) and start it now:

   ```
   sudo systemctl enable --now swg-stack.service
   ```

   On a running stack this does nothing to the containers (`docker compose
   start` skips containers that are already running). The game keeps running.

5. Check the service is active:

   ```
   systemctl status swg-stack.service --no-pager
   ```

   Look for `Active: active (exited)` and `enabled`. "exited" is correct for
   this kind of service.

6. Check the stop limits:

   ```
   systemctl show swg-stack.service -p TimeoutStopUSec
   systemctl show docker.service -p TimeoutStopUSec
   systemctl show docker.service -p DropInPaths
   ```

   Expected: `TimeoutStopUSec=4min 30s` for swg-stack, `TimeoutStopUSec=5min`
   for docker, and `DropInPaths=/etc/systemd/system/docker.service.d/override.conf`.

7. Oracle stop time (**swg-server-ops does this**, not part of the copy steps).
   Add `stop_grace_period: 120s` under the existing `oracle:` service in
   `~/swg-main/docker-compose.override.yml`. The `oracle:` section already
   exists there (it has the restart policy), so add only the one line inside it:

   ```yaml
   services:
     oracle:
       stop_grace_period: 120s
   ```

   Without it, `docker compose stop` kills Oracle after 10 seconds. Applying
   it recreates the oracle container (the data volume is kept), so do it only
   with the game shut down in-game first.

8. Proxmox shutdown timeout (in the Proxmox web page, not on the server):
   1. Click the SWG container in the left tree.
   2. Click **Options**.
   3. Double-click **Start/Shutdown order**.
   4. Set **Shutdown timeout** to `360` (seconds) and click **OK**.

   Why 360 and not 300: the ordered stop alone may use up to 270 s, and the
   rest of the container also has to shut down. If Proxmox's timeout runs out
   it kills the container outright, which is exactly the unsaved stop we are
   trying to avoid. A normal stop takes about 1-2 minutes, so this is only a
   ceiling.

## How the time adds up

- Normal: swg-auth + swg-control a few seconds each, game save 39-73 s,
  Oracle usually well under a minute. About 1-2 minutes in total.
- Worst case, if every step uses its full limit: 10 + 10 + 180 + 120 = 320 s.
  The service gives up at 270 s; Docker then stops whatever is left (the same
  as before this change, so never worse). `startServer.sh` stops waiting for
  the save at 150 s on its own, so swg-server normally finishes well before 180 s.

## Things to know

- `sudo systemctl stop swg-stack.service` **stops the whole game stack** (with a
  save). To start it again: `sudo systemctl start swg-stack.service`.
- If you stop the stack on purpose before a reboot, it **will** start again at
  boot. To keep it down across a reboot, run
  `sudo systemctl disable swg-stack.service` first (and `enable` it again later).
- If Docker is restarted (for example by a Docker package upgrade), this
  service is stopped first (the game saves) and started again afterwards.
- At boot, Oracle has to become healthy before the game starts. swg-server
  also waits for Oracle on its own.
- See what the service did at the last shutdown and boot:

  ```
  journalctl -u swg-stack.service -b -1 --no-pager
  journalctl -u swg-stack.service -b --no-pager
  ```

## Test it (optional, needs a maintenance window)

1. Warn players, then reboot the LXC from Proxmox (or `sudo reboot`).
2. After it is back, run `docker compose ps` in `~/swg-main`: all 4 containers
   should be up again (swg-server "healthy" can take several minutes).
3. Run `journalctl -u swg-stack.service -b -1 --no-pager` and
   `docker logs swg-server 2>&1 | grep startServer | tail -20`: you should see
   the containers stopping one by one and no "SAVE DID NOT COMPLETE".

## Uninstall / roll back

```
sudo systemctl disable --now swg-stack.service
sudo rm /etc/systemd/system/swg-stack.service
sudo rm /etc/systemd/system/docker.service.d/override.conf
sudo systemctl daemon-reload
```

Watch out: `disable --now` **stops the game stack** (with a save). Afterwards
start it again with `cd ~/swg-main && docker compose start`, because the
stopped containers will not start by themselves. The Proxmox timeout can
stay at 360 (it is only a ceiling).
