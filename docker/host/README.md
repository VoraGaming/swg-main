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

# Weekly log cleanup

## What it does

The game server writes log files inside the `swg-server` container, and
nothing ever makes them smaller. `swg-log-cleanup.sh` (in this folder) checks
them once a week and **empties** (sets to 0 bytes) any file bigger than
**200 MB**. It never deletes a file and never touches anything else.

Files it checks (all inside the `swg-server` container):

- every file directly in `/swg-main/exe/linux/logs/` (`customerService.log`,
  `startupLog.log`, `taskProcessDied.txt`, `persistence.log`)
- `/swg-main/stationchat.log` and `/swg-main/chat/var/log/swgchat.log` (chat
  server logs)

Good to know:

- If `swg-server` is not running, it prints "Nothing to do" and stops.
- It is safe to run while the game is running. It does not stop, restart or
  slow down the game, and has no effect on saving.
- An emptied file loses its old lines. If you need an old log, copy it out
  before Sunday 04:00.
- The limit can be changed with `SWG_LOG_MAX_MB` (see "Run it once by hand").
- `swgchat.log` only: it is not confirmed that the chat server keeps writing
  from the start of the file after it is emptied. If it does not, the file
  shows its old size again with empty space at the start. That is only an
  odd-looking text log; game data and saves are not affected.
- Every run adds 1-5 lines to `~/swg-log-cleanup.log`. Times in it are UTC
  (one hour behind UK time in summer).

Runs as the normal `swg` user from **your own crontab**. **No sudo is
needed anywhere in this section.**

## Before you start

1. Log in to the server as `swg`.
2. Check the script is on the server (swg-server-ops updates `~/swg-main` with
   `git pull`):

   ```
   ls -l ~/swg-main/docker/host/swg-log-cleanup.sh
   ```

   It must print one line ending in `swg-log-cleanup.sh`. If it says
   "No such file or directory", stop and ask.
3. Check the cron service is running:

   ```
   systemctl is-active cron
   ```

   It must print `active`. If it prints anything else, stop and ask.

## Install (run as `swg` on the server)

1. Make a `bin` folder in your home folder (no error if it already exists):

   ```
   mkdir -p ~/bin
   ```

2. Copy the script there and make it runnable:

   ```
   cp ~/swg-main/docker/host/swg-log-cleanup.sh ~/bin/swg-log-cleanup.sh
   chmod +x ~/bin/swg-log-cleanup.sh
   ```

   Why a copy: cron keeps running the same file even while `~/swg-main` is
   being updated. If the script in `~/swg-main` changes later, repeat this
   step to update the copy.

3. Run it once by hand to check it works:

   ```
   ~/bin/swg-log-cleanup.sh
   ```

   Expected, when all logs are small: one line like
   `2026-09-27 03:00:01 UTC done: limit 200 MB, 0 file(s) emptied, 0 failed.`
   If you see `ERROR`, stop and ask.

4. Add the weekly job to your crontab:

   ```
   crontab -e
   ```

   - The first time, it may ask you to "Select an editor". Type the number
     next to `nano` (usually `1`) and press Enter.
   - In the editor, go to the very end of the file (arrow keys) and add this
     as **one new line**, exactly as written:

     ```
     0 4 * * 0 $HOME/bin/swg-log-cleanup.sh >> $HOME/swg-log-cleanup.log 2>&1
     ```

   - In nano: press `Ctrl+O`, then Enter to save, then `Ctrl+X` to leave.
   - It should print `crontab: installing new crontab`.

   What the line means: at minute `0`, hour `4`, any day of the month, any
   month, on day-of-week `0` (Sunday), run the script and add its output to
   `~/swg-log-cleanup.log`. The time is the server's clock, which is UK time
   (BST in summer, GMT in winter), so this is Sunday 04:00 UK time.

   Watch out: add the line only **once**. If `crontab` says you are "not
   allowed" to use it, stop and ask.

## Check it

- See that the job is installed:

  ```
  crontab -l
  ```

  The `0 4 * * 0 ...swg-log-cleanup.sh...` line must be there exactly once.
- After the first Sunday, see what it did:

  ```
  tail -n 20 ~/swg-log-cleanup.log
  ```

  Each run ends with a `done: limit 200 MB, ...` line. Emptied files show
  as `emptied <file> (was <size> MB, ...)`.
- See the current log sizes yourself (read-only):

  ```
  docker exec swg-server ls -l /swg-main/exe/linux/logs
  ```

## Run it once by hand

Any time, with the normal 200 MB limit:

```
~/bin/swg-log-cleanup.sh
```

With a different limit, for that one run only (example: 50 MB):

```
SWG_LOG_MAX_MB=50 ~/bin/swg-log-cleanup.sh
```

The number must be a whole number of MB above 0.

## Uninstall

1. Remove the cron line:

   ```
   crontab -e
   ```

   Delete the `0 4 * * 0 ...swg-log-cleanup.sh...` line (in nano, put the
   cursor on it and press `Ctrl+K`), then `Ctrl+O`, Enter, `Ctrl+X`. Check
   with `crontab -l` that the line is gone.
2. Remove the copy of the script and (optional) its output file:

   ```
   rm ~/bin/swg-log-cleanup.sh
   rm ~/swg-log-cleanup.log
   ```

The game logs themselves stay as they are.
