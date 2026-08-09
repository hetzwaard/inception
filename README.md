*This project has been created as part of the 42 curriculum by mahkilic.*

# Inception

## Description

Inception is a system administration project that builds a small web
infrastructure from scratch using Docker and Docker Compose, running inside a
dedicated virtual machine.

The stack serves a WordPress website over HTTPS and is composed of three
services, each running in its own container, each built from a hand-written
Dockerfile based on `debian:bookworm` (the penultimate stable Debian release):

| Service     | Role                                                        |
|-------------|-------------------------------------------------------------|
| `nginx`     | TLS termination and web server. The only entry point, on port 443. |
| `wordpress` | WordPress core served by php-fpm, listening on port 9000.   |
| `mariadb`   | Database server holding the WordPress database, on port 3306. |

No pre-built images are pulled from Docker Hub other than the Debian base
image. The containers communicate over a user-defined bridge network, and all
persistent data lives in two named Docker volumes backed by
`/home/mahkilic/data` on the host.

The site is reachable at `https://mahkilic.42.fr`, which resolves to the local
machine through an entry in `/etc/hosts`.

## Instructions

### Prerequisites

- A Linux virtual machine (this project was developed on Debian 13).
- Docker Engine and the Docker Compose v2 plugin.
- The domain name mapped to the loopback address:

```bash
echo "127.0.0.1 mahkilic.42.fr" | sudo tee -a /etc/hosts
```

### Configuration

Two things are required before the first build and are deliberately excluded
from version control by `.gitignore`:

1. `srcs/.env` — non-sensitive configuration. Copy `srcs/.env.example` and
   adjust the values.
2. `secrets/` — three files holding credentials:
   - `db_root_password.txt` — MariaDB root password
   - `db_password.txt` — password of the WordPress database user
   - `credentials.txt` — WordPress passwords, as `KEY=value` lines:
     `WP_ADMIN_PASSWORD=...` and `WP_USER_PASSWORD=...`

Passwords can be generated with `openssl rand -base64 24`.

### Building and running

```bash
make          # create data directories, build the images, start the stack
make down     # stop and remove the containers and the network
make clean    # the above, plus remove the volumes
make fclean   # full reset: images, build cache and host data directories
make re       # fclean followed by a fresh build
make logs     # follow the logs of all services
make ps       # show the state of each container
```

The first build takes roughly one and a half minutes. Subsequent builds reuse
the layer cache and complete in a few seconds.

Once the stack is up, open `https://mahkilic.42.fr` in a browser. The
certificate is self-signed, so the browser will show a security warning that
has to be accepted manually. The administration panel is at
`https://mahkilic.42.fr/wp-admin`.

More detail is available in [USER_DOC.md](USER_DOC.md) and
[DEV_DOC.md](DEV_DOC.md).

## Project description

### Design choices

**One process per container.** Each service runs a single foreground process
as PID 1: `mariadbd --console`, `php-fpm8.2 -F`, and `nginx -g "daemon off;"`.
The entrypoint scripts finish with `exec`, which replaces the shell rather than
forking a child, so the service itself becomes PID 1 and receives `SIGTERM`
directly when the container is stopped. No `tail -f`, no sleep loop, and no
background daemons are used to keep a container alive.

**Idempotent entrypoints.** Both the MariaDB and the WordPress entrypoints
check whether initialisation has already happened before doing any work — the
former by looking for the system tables and the project database, the latter by
looking for `wp-config.php`. Because those paths live on persistent volumes, a
restart skips initialisation and starts serving immediately. The MariaDB script
uses two separate guards so that a failure partway through initialisation is
retried on the next start instead of being mistaken for a completed setup.

**Startup ordering without polling.** WordPress cannot install itself until
MariaDB accepts connections. Instead of a wait loop in the entrypoint, the
MariaDB service declares a `healthcheck` and the WordPress service declares
`depends_on: condition: service_healthy`. Docker performs the polling, and the
WordPress container is not started until the database reports healthy.

**Credentials outside the image.** No password appears in a Dockerfile, in
`docker-compose.yml`, or anywhere in the repository. Passwords are provided as
Docker secrets and read at runtime from `/run/secrets/`. Even the MariaDB
healthcheck reads the root password from the mounted secret rather than
embedding it in the Compose file.

### Virtual Machines vs Docker

A virtual machine virtualises hardware. The hypervisor presents a fake CPU,
fake RAM, a fake disk and a fake network card, and on top of that the guest
boots **its own kernel**, its own init system and a complete userland stored in
its own disk image. Nothing is shared with the host except the physical machine
underneath.

A container virtualises nothing. It is an ordinary process on the host, started
from an image that is a stack of filesystem layers rather than a disk image,
and isolated by two kernel features:

- **namespaces** — the process gets its own view of PIDs, mount points, network
  interfaces, hostname and IPC, which is why `mariadbd` believes it is PID 1
  and why each container has its own `/etc` and its own IP address;
- **cgroups** — the kernel accounts for and caps the resources the process is
  allowed to consume.

There is no second kernel. `uname -r` inside any of the three containers prints
the kernel of the VM, because it *is* the kernel of the VM.

The difference is very visible in practice. Installing Debian in VirtualBox
took about twenty minutes and a 20 GB disk image before a single line of this
project existed. `make` starts the three services in roughly six seconds, and
the whole stack — three images built from `debian:bookworm` — comes to about
1.3 GB. A container has nothing to boot: there is no BIOS, no bootloader, no
kernel to initialise, no systemd bringing up units. Docker sets up the
namespaces and executes the entrypoint, and that is the entire startup.

The price of that lightness is weaker isolation. Because every container shares
the host kernel, the kernel is a shared attack surface: a kernel-level exploit
triggered from inside a container compromises the host and every other
container on it, whereas escaping a VM means defeating the hypervisor, a far
narrower and better-guarded interface. The same applies to anything the kernel
exposes globally — a container running as root with the wrong capabilities is
very close to root on the host. Containers isolate *processes from each other*;
they are not a security boundary in the sense that a VM is.

That is exactly why this project uses both. The VM is the disposable machine:
it can be snapshotted, broken and rebuilt without touching the real host, and
it provides the hard boundary. Docker then divides that machine into one
isolated environment per service, so nginx, php-fpm and MariaDB each get their
own filesystem, their own dependencies and their own lifecycle, without paying
for three kernels and three disk images.

### Secrets vs Environment Variables

The configuration of this stack is split in two according to a single question:
does knowing this value get you anything?

`srcs/.env` holds the values where the answer is no — `DOMAIN_NAME`,
`MYSQL_DATABASE`, `MYSQL_USER`, the WordPress site title, the administrator
login and the second user's login. They are identifiers and settings. They
belong in ordinary configuration because the stack cannot be described without
them, and an attacker who reads them learns the shape of the deployment but
cannot authenticate anywhere.

`secrets/` holds the values where the answer is yes: `db_root_password.txt`,
`db_password.txt` and `credentials.txt`. These never appear in a Dockerfile, in
`docker-compose.yml`, or in any file that is committed. Compose mounts them
read-only into the containers that declare them, under `/run/secrets/`, and the
entrypoints read them at runtime with a plain `cat`. Nothing is baked into an
image layer, so the credentials are not distributed with the image and can be
changed without rebuilding.

The distinction matters because an environment variable is far more visible
than it looks:

- `docker inspect` prints the complete `Env` array of a container, so anyone in
  the `docker` group on the VM can read the password without touching the
  container;
- inside the container, `/proc/<pid>/environ` exposes it to any process that
  can read that file;
- and it is **inherited by every child process**. A variable given to php-fpm is
  inherited by every PHP worker it forks, which means a code-execution bug in a
  WordPress plugin would hand the attacker the database credentials for free.

A file under `/run/secrets/` has none of these properties: it is visible only to
the services that were granted it, and only to code that deliberately opens it.

The clearest example in this project is the MariaDB healthcheck. It has to
authenticate as root to be meaningful, so the obvious version would put the
root password in `docker-compose.yml`. Instead the test runs inside the
container and reads the mounted file:

```yaml
healthcheck:
  test: ["CMD-SHELL", "mariadb-admin ping -h localhost -u root -p\"$$(cat /run/secrets/db_root_password)\" --silent"]
```

The Compose file therefore contains the *path* of the secret and never its
value, and `docker inspect` on the container shows that a secret is mounted,
not what is in it.

Both `srcs/.env` and `secrets/` are listed in `.gitignore`. `srcs/.env.example`
is committed with the same keys and placeholder values, so anyone cloning the
repository can reproduce the stack by filling in their own values, and nothing
sensitive ever reaches the history.

### Docker Network vs Host Network

The three services are attached to a user-defined bridge network called
`inception`, declared in the `networks:` block of the Compose file. Docker
creates a virtual bridge on the VM and gives each container its own IP address
on a private subnet; `docker network inspect inception` lists the three
containers with their addresses.

The important property of a *user-defined* bridge — as opposed to the default
`bridge` network — is the embedded DNS server that Docker runs at `127.0.0.11`
inside the network namespace of every attached container. Docker registers each
container under its service name, so name resolution happens automatically:

```nginx
fastcgi_pass wordpress:9000;
```

```sh
wp core install --dbhost=mariadb:3306 ...
```

Neither line contains an IP address, and neither has to be updated when a
container is recreated with a different one. This is also why the old `links:`
directive is unnecessary here: it existed to inject `/etc/hosts` entries on the
default bridge, and the embedded DNS made it obsolete — it is deprecated
precisely because user-defined networks do the job properly.

Only nginx publishes a port: `443:443`. `docker compose ps` shows `9000/tcp`
and `3306/tcp` for the other two services with no host mapping at all. From the
VM, `curl 127.0.0.1:3306` fails to connect — MariaDB is listening, but only on
the `inception` network, so the database and php-fpm are reachable from the
sibling containers and from nowhere else. That is the requirement of the
subject expressed as network configuration rather than as a firewall rule.

Running with `network: host` would break this in three ways. The container
would share the host's network namespace instead of getting its own, so there
would be no Docker DNS at `127.0.0.11` and the service names would stop
resolving — every reference would have to become `127.0.0.1`, hardcoding
topology into the configuration. Every listening socket would bind directly on
the VM, so MariaDB on 3306 and php-fpm on 9000 would be exposed alongside
nginx, and nginx would no longer be the single entry point. And port conflicts
would become real: only one process can bind a given address and port, so two
containers wanting the same port could not coexist, whereas on the bridge
network each has its own address and its own full range of ports.

### Docker Volumes vs Bind Mounts

A container's filesystem is the image's read-only layers plus a thin writable
layer on top, and that writable layer is destroyed with the container. Without
external storage, `docker compose down` followed by `make` would come back with
an empty database and a fresh WordPress install every time — every post, every
user, every uploaded file gone. The database directory and the WordPress files
therefore have to live outside the container's lifecycle.

Docker offers two ways to do that:

- A **named volume** is an object Docker owns and tracks. It is declared in the
  `volumes:` block, appears in `docker volume ls`, is created on demand,
  survives `docker compose down`, and is deleted only when explicitly asked —
  `docker compose down -v`. That is exactly the split between `make down` and
  `make clean` in the Makefile: the first stops the stack and keeps the data,
  the second throws the data away.
- A **bind mount** is just a host path attached to a container path. Docker does
  not manage it, does not track it, and does not create it; permissions and
  ownership come from the host, and the mount silently shadows whatever the
  image had at that path.

The subject looks self-contradictory here: named volumes are mandatory, bind
mounts are forbidden, and yet the data must sit in `/home/mahkilic/data`. The
resolution is the `driver_opts` block of the `local` driver:

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

This is still a genuine named volume: it is declared in `volumes:`, it shows up
in `docker volume ls`, Compose creates it, and `down -v` removes it — the
Docker-managed lifecycle is intact. What `driver_opts` changes is only where
its contents are physically stored. Instead of letting the driver allocate a
directory in its own area, the volume is backed by a host directory chosen by
me, bound at volume-creation time rather than at container start.

The consequence is visible and was confusing at first: `docker volume inspect
mariadb` reports a `Mountpoint` under `/var/lib/docker/volumes/mariadb/_data`,
while the same files are plainly there in `/home/mahkilic/data/mariadb`. Both
are true. It is one directory made visible at two paths by a bind mount, which
`findmnt` on the VM confirms. It also explains why `make fclean` has to remove
the host directories itself: `docker volume rm` unbinds and forgets the volume,
but the real data is in `/home/mahkilic/data` and stays there until it is
deleted.

## Resources

### Documentation

- [Docker documentation](https://docs.docker.com/)
- [Docker Compose file reference](https://docs.docker.com/reference/compose-file/)
- [Dockerfile best practices](https://docs.docker.com/build/building/best-practices/)
- [Docker secrets in Compose](https://docs.docker.com/compose/how-tos/use-secrets/)
- [MariaDB knowledge base](https://mariadb.com/kb/en/documentation/)
- [`mariadb-install-db`](https://mariadb.com/kb/en/mariadb-install-db/)
- [php-fpm configuration](https://www.php.net/manual/en/install.fpm.configuration.php)
- [NGINX FastCGI module](https://nginx.org/en/docs/http/ngx_http_fastcgi_module.html)
- [WP-CLI commands](https://developer.wordpress.org/cli/commands/)
- [Mozilla SSL configuration generator](https://ssl-config.mozilla.org/)

### Use of AI

This was my first project using Docker, and I used AI (Claude) throughout it as
an interactive tutor and a pair-programmer rather than as a code generator.
Concretely:

**Planning.** I used it to break the subject into an ordered sequence of phases
and to think through the structural decisions before writing anything: the
choice of `debian:bookworm` as the base image, one service per container with a
single foreground process, and the split between what belongs in `.env` and
what belongs in `secrets/`.

**Scaffolding.** The first versions of `docker-compose.yml`, the Makefile and
the three Dockerfiles were drafted with AI assistance. None of them survived
unchanged — I edited, rewrote and tested each one against the actual behaviour
of the stack.

**Debugging.** This was where it helped most, and these are the problems I
worked through and can explain:

- MariaDB's bootstrap failing with error 1290, because `mariadbd --bootstrap`
  implies `--skip-grant-tables`; the fix was to issue `FLUSH PRIVILEGES` before
  any account statement in the bootstrap SQL.
- `DELETE FROM mysql.user` no longer working on MariaDB 10.11, where
  `mysql.user` is a view over `mysql.global_priv` and not a writable table.
- A healthcheck that pinged as root with no password and therefore passed
  during early development, then silently stopped passing as soon as the
  bootstrap actually set a root password — which is what led to reading the
  password from `/run/secrets/` inside the healthcheck itself.
- A Makefile bug where the `up` target depended on the data directory itself,
  so Make considered the prerequisite satisfied and skipped recreating the
  per-service subdirectories that `fclean` had removed.

**Explanation.** I used it to understand the concepts behind the requirements
rather than to satisfy them blindly: why PID 1 matters and why `exec` in the
entrypoint is what makes the service receive `SIGTERM`, why php-fpm needs `-F`
and nginx needs `daemon off`, and why a unix socket cannot be used between two
containers that do not share a mount namespace.

Everything generated was read, tested and kept only once I understood it, and I
rebuilt the whole stack from scratch with `make fclean && make` to confirm it
works end to end. Having gone through it, I could now write the nginx and
WordPress services unaided; the MariaDB entrypoint is the part I had to work
through most carefully, and the one I would still want to re-read the
documentation for.
