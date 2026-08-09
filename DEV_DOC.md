# Developer documentation

This document describes how to set up the project from nothing, how it is built
and how the data is stored. For day-to-day usage see [USER_DOC.md](USER_DOC.md).

## Prerequisites

The project is meant to run inside a virtual machine. It was developed on
Debian 13 under VirtualBox, with 4 GB of RAM, 2 CPUs and a 20 GB disk.

Install Docker Engine and the Compose v2 plugin from Docker's own repository
rather than the distribution packages, because the distribution may still ship
the end-of-life Python `docker-compose` v1:

```bash
sudo apt update
sudo apt install -y ca-certificates curl git make

sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg \
     -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io \
                    docker-buildx-plugin docker-compose-plugin
```

Add your user to the `docker` group so the Makefile can run without `sudo`,
then log out and back in for the group change to take effect:

```bash
sudo usermod -aG docker $USER
```

Verify:

```bash
docker compose version    # must report v2.x
```

Finally, point the project's domain name at the local machine:

```bash
echo "127.0.0.1 mahkilic.42.fr" | sudo tee -a /etc/hosts
```

## Repository layout

```
.
├── Makefile
├── README.md
├── USER_DOC.md
├── DEV_DOC.md
├── secrets/                  (git-ignored)
│   ├── credentials.txt
│   ├── db_password.txt
│   └── db_root_password.txt
└── srcs/
    ├── .env                  (git-ignored)
    ├── .env.example
    ├── docker-compose.yml
    └── requirements/
        ├── mariadb/
        │   ├── Dockerfile
        │   ├── .dockerignore
        │   ├── conf/50-server.cnf
        │   └── tools/entrypoint.sh
        ├── nginx/
        │   ├── Dockerfile
        │   ├── .dockerignore
        │   └── conf/default.conf
        └── wordpress/
            ├── Dockerfile
            ├── .dockerignore
            ├── conf/www.conf
            └── tools/entrypoint.sh
```

## Configuration files

Neither `srcs/.env` nor `secrets/` is committed. Both have to be created on a
fresh clone.

### srcs/.env

Copy the template and adjust:

```bash
cp srcs/.env.example srcs/.env
```

It holds non-sensitive configuration only:

```
DOMAIN_NAME=mahkilic.42.fr

MYSQL_DATABASE=wordpress
MYSQL_USER=wpuser

WP_TITLE=Inception
WP_ADMIN_USER=chief
WP_ADMIN_EMAIL=chief@example.com
WP_USER=editor
WP_USER_EMAIL=editor@example.com
```

The administrator's username must not contain `admin` or `administrator` in
any form — this is a requirement of the subject.

### secrets/

Three files, generated locally:

```bash
mkdir -p secrets
openssl rand -base64 24 > secrets/db_root_password.txt
openssl rand -base64 24 > secrets/db_password.txt

cat > secrets/credentials.txt <<EOF
WP_ADMIN_PASSWORD=$(openssl rand -base64 18)
WP_USER_PASSWORD=$(openssl rand -base64 18)
EOF

chmod 600 secrets/*
```

`credentials.txt` is written as `KEY=value` lines so the WordPress entrypoint
can source it directly with `.` rather than parsing it.

Compose declares these under a top-level `secrets:` block and attaches them to
the services that need them. Docker mounts each one read-only at
`/run/secrets/<name>` inside the container. No password is ever passed as a
build argument, written into an image layer, or stored in
`docker-compose.yml`.

## Building and running

The Makefile wraps Docker Compose:

| Target   | Command it runs                                                     |
|----------|---------------------------------------------------------------------|
| `all`    | `up`                                                                |
| `dirs`   | `mkdir -p /home/$(USER)/data/{mariadb,wordpress}`                   |
| `build`  | `docker compose build`                                              |
| `up`     | `docker compose up -d --build`                                      |
| `down`   | `docker compose down`                                               |
| `stop`   | `docker compose stop`                                               |
| `start`  | `docker compose start`                                              |
| `logs`   | `docker compose logs -f`                                            |
| `ps`     | `docker compose ps`                                                 |
| `clean`  | `down`, then `docker compose down --volumes --remove-orphans`       |
| `fclean` | `clean`, then `docker system prune -af` and remove the data directories |
| `re`     | `fclean` then `all`                                                 |

`build` and `up` both depend on the phony `dirs` target. This matters: the two
named volumes are backed by host directories, and Docker refuses to mount a
bind target that does not exist. Because `dirs` is phony, `mkdir -p` runs on
every invocation, so `make` works immediately after `make fclean` has deleted
those directories.

Compose is always invoked with `-f srcs/docker-compose.yml` since the file is
not at the repository root.

## Service internals

### Common design

All three images are built `FROM debian:bookworm` — the penultimate stable
Debian release. The `latest` tag is never used.

Each container runs exactly one foreground process as PID 1. The entrypoint
scripts end with `exec`, which replaces the shell process instead of forking,
so signals from `docker stop` reach the service directly rather than being
absorbed by a shell. No infinite loops, background daemons, or `tail -f`
tricks are used to keep a container running.

### mariadb

The entrypoint reads the two passwords from `/run/secrets/` and uses two
independent guards:

1. If `/var/lib/mysql/mysql` is missing, run `mariadb-install-db` to create the
   system tables.
2. If `/var/lib/mysql/${MYSQL_DATABASE}` is missing, generate an SQL file and
   feed it to `mariadbd --bootstrap`, which executes it in a one-shot server
   and exits. This avoids any need to poll for the server to become ready.

Splitting the guard in two means that a failure during step 2 leaves its marker
absent, so the next start retries instead of treating a half-initialised
directory as complete.

The bootstrap SQL begins with `FLUSH PRIVILEGES`. This is required because
`--bootstrap` implies `--skip-grant-tables`, under which the server refuses
every account-management statement with error 1290 until the grant tables have
been loaded. A second `FLUSH PRIVILEGES` at the end commits the new accounts.

`conf/50-server.cnf` sets `bind-address = 0.0.0.0`. Debian's default binds to
loopback only, which would make the database unreachable from the other
containers.

### wordpress

The image installs php-fpm and the PHP extensions WordPress and wp-cli need,
and downloads the wp-cli phar at build time so container startup does not
depend on the network.

`conf/www.conf` sets `listen = 0.0.0.0:9000`. Debian's default is a unix socket,
which cannot be reached from another container — nginx connects over TCP across
the Docker network.

The entrypoint sources `/run/secrets/credentials`, and if `wp-config.php` is
absent it runs `wp core download`, `wp config create`, `wp core install` and
`wp user create` for the second user. It then execs `php-fpm8.2 -F`; the `-F`
flag keeps php-fpm in the foreground instead of daemonising.

### nginx

The self-signed certificate is generated during the build with `openssl req
-x509`, so no key material is ever committed. The Debian default site in
`sites-enabled/` is removed so that only the project's server block is active
and nothing listens on port 80.

The configuration restricts `ssl_protocols` to TLSv1.2 and TLSv1.3, serves
`/var/www/html` from the shared WordPress volume, and forwards `.php` requests
to `wordpress:9000` over FastCGI. `SCRIPT_FILENAME` must be set explicitly
because Debian's `fastcgi_params` omits it.

## Managing containers and volumes

```bash
# state and logs
docker compose -f srcs/docker-compose.yml ps
docker compose -f srcs/docker-compose.yml logs -f mariadb

# a shell inside a running container
docker exec -it wordpress bash

# rebuild a single service
docker compose -f srcs/docker-compose.yml up -d --build nginx

# force containers to be recreated from freshly built images
docker compose -f srcs/docker-compose.yml up -d --force-recreate

# network
docker network ls
docker network inspect inception

# volumes
docker volume ls
docker volume inspect mariadb

# images: all three must be locally built, never pulled
docker images
```

Connecting to the database:

```bash
docker exec -it mariadb mariadb -h 127.0.0.1 -u wpuser \
    -p"$(cat secrets/db_password.txt)" -e "SHOW DATABASES;"
```

Using `-h 127.0.0.1` forces a TCP connection instead of the unix socket, which
is how WordPress connects.

## Where the data lives

Two named volumes are declared in `docker-compose.yml`:

| Volume      | Mounted at          | Holds                          |
|-------------|---------------------|--------------------------------|
| `mariadb`   | `/var/lib/mysql`    | The WordPress database.        |
| `wordpress` | `/var/www/html`     | WordPress core, themes, uploads. |

The `wordpress` volume is mounted into both the wordpress and the nginx
container, so nginx can serve static assets from disk while php-fpm executes
the PHP files.

Both volumes use the `local` driver with options that back them onto a chosen
host directory:

```yaml
volumes:
  mariadb:
    name: mariadb
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /home/mahkilic/data/mariadb
```

They remain genuine named volumes — they appear in `docker volume ls`, Docker
manages their lifecycle, and `docker compose down -v` removes them — but their
contents are stored where the subject requires. `docker volume inspect mariadb`
reports a `Mountpoint` under `/var/lib/docker/volumes/`, and the same files are
visible in `/home/mahkilic/data/mariadb`, because it is one directory mounted
in two places.

### Persistence behaviour

| Action                        | Data survives? |
|-------------------------------|----------------|
| `make down` / `make stop`     | Yes            |
| Rebuilding the images         | Yes            |
| Rebooting the virtual machine | Yes            |
| `make clean`                  | No             |
| `make fclean`                 | No             |

On a restart with the data intact, both entrypoints detect existing state and
skip initialisation. The logs show `database already present, skipping
bootstrap` and `already installed, skipping`.

The files under `/home/mahkilic/data/mariadb` are owned by the container's
`mysql` user, whose UID maps to a different (often unrelated) name on the host.
Removing them requires `sudo`, which is why `make fclean` uses it.

## Changing a service's port

If a service needs to listen elsewhere, the change has to be made in every
place that references the port. For nginx moving from 443 to 8443:

1. `srcs/docker-compose.yml` — change the published port to `"8443:8443"`.
2. `srcs/requirements/nginx/conf/default.conf` — change both `listen`
   directives.
3. `make down && make`, then test `https://mahkilic.42.fr:8443`.

For php-fpm, the port appears in `conf/www.conf` (`listen =`) and in nginx's
`fastcgi_pass`. For MariaDB it appears in `50-server.cnf` and in the
`--dbhost` argument in the WordPress entrypoint. Note that `EXPOSE` in a
Dockerfile is documentation only; the `ports:` entry in Compose is what
actually publishes a port on the host.
