# User documentation

This document is for someone who wants to run and use the Inception stack. For
information about modifying or rebuilding the project, see
[DEV_DOC.md](DEV_DOC.md).

## What the stack provides

Running the project starts three containers that together serve a WordPress
website over HTTPS:

- **nginx** — the web server. It is the only way into the infrastructure and
  accepts connections on port 443 only, using TLSv1.2 or TLSv1.3. It serves
  static files directly and forwards PHP requests to WordPress.
- **wordpress** — WordPress running under php-fpm. It is not reachable from
  outside; only nginx can talk to it.
- **mariadb** — the database holding all WordPress content: posts, pages,
  comments and users. It is not reachable from outside either.

Two named Docker volumes hold everything that must survive a restart: the
WordPress website files and the database. Both are stored under
`/home/mahkilic/data` on the host.

## Starting and stopping

All commands are run from the root of the repository.

| Command      | Effect                                                            |
|--------------|-------------------------------------------------------------------|
| `make`       | Build the images if needed and start all three containers.        |
| `make down`  | Stop and remove the containers and the network. **Data is kept.** |
| `make stop`  | Stop the containers without removing them.                        |
| `make start` | Start containers that were stopped.                               |
| `make clean` | Stop everything and remove the volumes. **Data is deleted.**      |
| `make fclean`| Full reset: containers, volumes, images, build cache and the host data directories. |

The first `make` takes a minute or two because the images are built from
scratch. Later runs reuse the cache and start in a few seconds.

The containers are configured with `restart: always`, so after a reboot of the
host machine they come back up on their own. There is no need to run `make`
again unless they were explicitly stopped.

## Accessing the website

Open **https://mahkilic.42.fr** in a browser.

The certificate is self-signed, so the browser shows a security warning
("Potential Security Risk Ahead" in Firefox). This is expected: the certificate
was generated locally and is not issued by a recognised certificate authority.
The connection is still encrypted with TLS. Click **Advanced** and then
**Accept the Risk and Continue** to proceed.

Note that `http://mahkilic.42.fr` will not work. Port 80 is not published at
all, and any attempt to connect over plain HTTP is refused. This is
intentional.

## The administration panel

The dashboard is at **https://mahkilic.42.fr/wp-admin**.

Two accounts exist:

| Account   | Role          | Can do                                                |
|-----------|---------------|-------------------------------------------------------|
| `chief`   | Administrator | Everything: settings, themes, users, pages and posts. |
| `editor`  | Author        | Write and publish their own posts, leave comments.    |

The passwords are in `secrets/credentials.txt`.

## Credentials

All passwords live in the `secrets/` directory at the root of the repository:

| File                     | Contents                                        |
|--------------------------|-------------------------------------------------|
| `db_root_password.txt`   | MariaDB root password.                          |
| `db_password.txt`        | Password of the WordPress database user.        |
| `credentials.txt`        | `WP_ADMIN_PASSWORD` and `WP_USER_PASSWORD`.     |

These files are excluded from version control by `.gitignore` and are never
copied into an image. Docker mounts them into the containers at runtime under
`/run/secrets/`, where the startup scripts read them.

To read a password:

```bash
cat secrets/db_password.txt
cat secrets/credentials.txt
```

### Changing a password

Editing a file in `secrets/` does **not** change a password that is already in
use, because the credentials were written into the database when the stack was
first initialised. There are two ways to apply a change.

To change a WordPress password on a running stack:

```bash
docker exec -it wordpress wp user update chief --user_pass='NEW_PASSWORD' --allow-root
```

To apply new values from the secret files, reinitialise from scratch. This
destroys all existing content:

```bash
make fclean
make
```

## Checking that everything works

Show the state of the three containers:

```bash
docker compose -f srcs/docker-compose.yml ps
```

All three should be `Up`, and `mariadb` should additionally show `(healthy)`.
The `PORTS` column should show a published port for nginx only —
`0.0.0.0:443->443/tcp`. The other two show their internal ports with no host
mapping, which confirms they are not exposed.

Read the logs of a service:

```bash
docker compose -f srcs/docker-compose.yml logs nginx
docker compose -f srcs/docker-compose.yml logs -f wordpress   # follow live
```

Confirm the site answers:

```bash
curl -Ik https://mahkilic.42.fr
```

`HTTP/1.1 200 OK` means nginx is serving and PHP is being executed correctly.
The `-k` flag tells curl to accept the self-signed certificate.

Confirm that plain HTTP is refused:

```bash
curl -I http://mahkilic.42.fr
```

This should fail to connect.

Check which TLS versions are accepted:

```bash
openssl s_client -connect mahkilic.42.fr:443 -tls1_3 </dev/null 2>&1 | grep Protocol
openssl s_client -connect mahkilic.42.fr:443 -tls1_1 </dev/null 2>&1 | grep -i error
```

The first should report `TLSv1.3`. The second should fail with
`no protocols available`, showing that older versions are rejected.

List the WordPress users:

```bash
docker exec -it wordpress wp user list --allow-root
```

## If something is wrong

- **The browser cannot reach the site at all.** Check that
  `127.0.0.1 mahkilic.42.fr` is present in `/etc/hosts`, and that the nginx
  container is running.
- **502 Bad Gateway.** nginx is running but cannot reach php-fpm. Check that
  the wordpress container is up, and look at
  `docker compose -f srcs/docker-compose.yml logs wordpress`.
- **The WordPress installation wizard appears.** WordPress did not find its
  configuration, which usually means the volume is empty. Check the wordpress
  container logs for an installation error.
- **A container keeps restarting.** Read its logs. Because the containers use
  `restart: always`, a container that fails at startup will loop, and the logs
  will show the same error repeating.
